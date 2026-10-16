import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// The display-metadata content of one frame's RPU, as libdovi parses it.
///
/// This is the *other half* of an RPU from what `DoviMetalParams` carries. `DoviMetalParams` has
/// the reshaping coefficients the GPU composer needs to rebuild pixels; this has the display
/// metadata a Dolby Vision TV acts on: L1 frame statistics and L2 creative trims. Nothing here
/// feeds playback; it exists so `aetherctl dvsurvey` can tell an operator which frame of a title
/// carries the most extreme metadata, which is the frame worth pinning for the on-device
/// consumption test (see `DoviDisplayMetadataDebug`).
@_spi(Diagnostics)
public struct DoviRpuFrameSurvey: Sendable {
    /// Position among the title's RPU-carrying video packets, counted whether or not the RPU parsed, so
    /// it matches the pin test's scan count (`darkest:N` scans the first N of these).
    public let frameIndex: Int
    /// Non-zero on the first frame of a new scene. Dolby Vision DM resets its temporal filters here.
    public let sceneRefresh: Bool
    /// 12-bit PQ codes (0...4095) describing the frame's luminance distribution.
    public let l1MinPQ: UInt16
    public let l1AvgPQ: UInt16
    public let l1MaxPQ: UInt16
    /// Creative trims, one entry per target display peak brightness present in this RPU.
    public let l2Trims: [Trim]
    /// Source mastering range, from the RPU header rather than an L1 block.
    public let sourceMinPQ: UInt16
    public let sourceMaxPQ: UInt16
    /// Byte length of the Profile 8.1 payload that would be attached for this frame.
    public let payloadBytes: Int

    public struct Trim: Sendable {
        public let targetMaxPQ: UInt16
        public let slope: UInt16
        public let offset: UInt16
        public let power: UInt16
        public let chromaWeight: UInt16
        public let saturationGain: UInt16
        public let msWeight: Int16
    }

    /// L1 max as display luminance. The PQ codes are what the TV consumes; nits are for reading.
    public var l1MaxNits: Double { DoviRpuSurvey.pqCodeToNits(l1MaxPQ) }
    public var l1AvgNits: Double { DoviRpuSurvey.pqCodeToNits(l1AvgPQ) }
    public var l1MinNits: Double { DoviRpuSurvey.pqCodeToNits(l1MinPQ) }
}

/// Whole-title survey plus the frame picks that matter for the consumption test.
@_spi(Diagnostics)
public struct DoviRpuSurveyResult: Sendable {
    public let frames: [DoviRpuFrameSurvey]
    public let packetsProcessed: Int
    /// Frames whose RPU failed to parse or convert. Non-zero means the survey is incomplete.
    public let rpuFailures: Int
    public let enhancementLayerType: String?

    /// Frame with the lowest L1 `avg_pq`, the darkest frame in the survey. Ranked on `avg_pq`
    /// rather than `max_pq` because `avg_pq` is what anchors the display-mapping curve's mid-tone,
    /// and because it is typically the field with the widest range in a title: a frame can hold a
    /// bright specular highlight (high `max_pq`) while being almost entirely black. Pinning this
    /// one while a bright scene plays tells the TV the scene is nearly dark, which should visibly
    /// crush it if the metadata is reaching the panel.
    public var darkestFrame: DoviRpuFrameSurvey? { frames.min { $0.l1AvgPQ < $1.l1AvgPQ } }
    /// Frame with the highest L1 `avg_pq`, the brightest. The complementary poison: pinned over a
    /// dark scene the TV should stop protecting shadows and lift them.
    public var brightestFrame: DoviRpuFrameSurvey? { frames.max { $0.l1AvgPQ < $1.l1AvgPQ } }

    /// The pin that puts the largest total distance between its L1 and this title's own median
    /// frame, with that distance in PQ codes and which field carries most of it.
    ///
    /// Scored across all three L1 fields, not just one: the display-mapping curve is fitted to
    /// `min`/`max`/`avg` together, so a frame that disagrees with the scene on two of them
    /// misleads the TV more than one that disagrees harder on a single field.
    public var strongestPoison: (frame: DoviRpuFrameSurvey, deltaPQ: Int, dominantField: String)? {
        guard !frames.isEmpty else { return nil }
        func median(_ v: [UInt16]) -> Int { Int(v.sorted()[v.count / 2]) }
        let mMin = median(frames.map(\.l1MinPQ))
        let mMax = median(frames.map(\.l1MaxPQ))
        let mAvg = median(frames.map(\.l1AvgPQ))
        func deltas(_ f: DoviRpuFrameSurvey) -> (min: Int, max: Int, avg: Int) {
            (abs(Int(f.l1MinPQ) - mMin), abs(Int(f.l1MaxPQ) - mMax), abs(Int(f.l1AvgPQ) - mAvg))
        }
        func score(_ f: DoviRpuFrameSurvey) -> Int { let d = deltas(f); return d.min + d.max + d.avg }
        guard let pick = frames.max(by: { score($0) < score($1) }) else { return nil }
        let d = deltas(pick)
        let dominant = d.avg >= d.max && d.avg >= d.min ? "avg_pq" : (d.max >= d.min ? "max_pq" : "min_pq")
        return (pick, score(pick), dominant)
    }

    /// Median L1 of the surveyed frames, for reporting what a pin is being measured against.
    public var medianL1: (min: UInt16, max: UInt16, avg: UInt16)? {
        guard !frames.isEmpty else { return nil }
        func med(_ v: [UInt16]) -> UInt16 { v.sorted()[v.count / 2] }
        return (med(frames.map(\.l1MinPQ)), med(frames.map(\.l1MaxPQ)), med(frames.map(\.l1AvgPQ)))
    }
}

@_spi(Diagnostics)
public enum DoviRpuSurvey {

    /// Parses the display metadata out of one `unspec62` NAL.
    ///
    /// The NAL is converted to Profile 8.1 first, so what comes back is what would actually be
    /// attached to the frame rather than what the Profile 7 bitstream held; the two agree on
    /// L1/L2 by construction (`dovi_convert_rpu_with_mode` rewrites only the profile container),
    /// and surveying the converted form means a surprise there shows up here instead of on the TV.
    public static func parse(nal: UnsafePointer<UInt8>, length: Int, frameIndex: Int) -> DoviRpuFrameSurvey? {
        guard let rpu = DoviRpuGuard.parse(nal, length) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard let out = DoviRpuConverter.convertedUnspec62(rpu) else { return nil }
        // Minus the 2-byte NAL header, which `DoviDisplayMetadata` strips before attaching.
        let payloadBytes = max(0, out.pointee.len - 2)
        dovi_data_free(out)

        guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
        defer { dovi_rpu_free_vdr_dm_data(dm) }

        var minPQ: UInt16 = 0, avgPQ: UInt16 = 0, maxPQ: UInt16 = 0
        if let l1 = dm.pointee.dm_data.level1 {
            minPQ = l1.pointee.min_pq
            avgPQ = l1.pointee.avg_pq
            maxPQ = l1.pointee.max_pq
        }

        var trims: [DoviRpuFrameSurvey.Trim] = []
        let l2 = dm.pointee.dm_data.level2
        if let list = l2.list, l2.len > 0 {
            for i in 0..<Int(l2.len) {
                guard let t = list[i] else { continue }
                trims.append(.init(targetMaxPQ: t.pointee.target_max_pq,
                                   slope: t.pointee.trim_slope,
                                   offset: t.pointee.trim_offset,
                                   power: t.pointee.trim_power,
                                   chromaWeight: t.pointee.trim_chroma_weight,
                                   saturationGain: t.pointee.trim_saturation_gain,
                                   msWeight: t.pointee.ms_weight))
            }
        }

        return DoviRpuFrameSurvey(
            frameIndex: frameIndex,
            sceneRefresh: dm.pointee.scene_refresh_flag != 0,
            l1MinPQ: minPQ,
            l1AvgPQ: avgPQ,
            l1MaxPQ: maxPQ,
            l2Trims: trims,
            sourceMinPQ: dm.pointee.source_min_pq,
            sourceMaxPQ: dm.pointee.source_max_pq,
            payloadBytes: payloadBytes
        )
    }

    /// ST.2084 (PQ) EOTF on a 12-bit code value, in cd/m². Reporting only.
    public static func pqCodeToNits(_ code: UInt16) -> Double {
        let e = min(1.0, max(0.0, Double(code) / 4095.0))
        let m1 = 2610.0 / 16384.0
        let m2 = 2523.0 / 4096.0 * 128.0
        let c1 = 3424.0 / 4096.0
        let c2 = 2413.0 / 4096.0 * 32.0
        let c3 = 2392.0 / 4096.0 * 32.0
        let ep = pow(e, 1.0 / m2)
        let num = max(ep - c1, 0.0)
        let den = c2 - c3 * ep
        guard den > 0 else { return 0 }
        return pow(num / den, 1.0 / m1) * 10000.0
    }
}

extension AetherEngine {

    /// Walks a title's video stream and surveys every frame's Dolby Vision display metadata.
    ///
    /// Runs the demuxer and `DoviRpuConverter` only, no decoders, no GPU, so it is fast enough to
    /// sweep thousands of frames. Its purpose is picking the pin for the on-device consumption test:
    /// the operator arms `AetherEngine.armDolbyVisionPinTest(_:)` with `strongestPoison`'s frame.
    @_spi(Diagnostics)
    public nonisolated static func doviRpuSurvey(
        url: URL,
        maxFrames: Int = 2000,
        options: LoadOptions = .init()
    ) throws -> DoviRpuSurveyResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0 else { throw AetherEngineError.noVideoStream }

        var frames: [DoviRpuFrameSurvey] = []
        var packetsProcessed = 0
        var rpuPackets = 0
        var failures = 0
        var elType: String?

        while frames.count < maxFrames {
            let maybePacket: UnsafeMutablePointer<AVPacket>?
            do { maybePacket = try demuxer.readPacket() } catch { break }
            guard let packet = maybePacket else { break }

            if packet.pointee.stream_index == videoIdx {
                packetsProcessed += 1
                if elType == nil { elType = DoviRpuConverter.enhancementLayerType(packet) }
                // extractEL: false; the survey never touches pixels, so the EL is dead weight.
                let layers = DoviRpuConverter.separateDualLayers(packet, extractEL: false)
                if let raw = layers.rpuData {
                    // Counted per RPU packet, parsed or not: a parse failure must not shift every later index.
                    let idx = rpuPackets
                    rpuPackets += 1
                    let parsed: DoviRpuFrameSurvey? = raw.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return nil }
                        return DoviRpuSurvey.parse(nal: base, length: buf.count, frameIndex: idx)
                    }
                    if let parsed { frames.append(parsed) } else { failures += 1 }
                }
            }

            av_packet_unref(packet)
            var opt: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&opt)
        }

        return DoviRpuSurveyResult(
            frames: frames,
            packetsProcessed: packetsProcessed,
            rpuFailures: failures,
            enhancementLayerType: elType
        )
    }
}
