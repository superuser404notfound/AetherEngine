// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// What one sampled frame's enhancement layer actually does to its luma: the residual the composer adds before its range clamp,
/// `inverseNlq(el_code)`, measured over every pixel of the decoded enhancement-layer picture.
///
/// In 12-bit PQ codes (the VDR domain), which is a perceptual brightness scale: a code is roughly the same
/// visible step anywhere on it, so averages and percentiles over it mean something. One 10-bit step is
/// four codes. Measured on the enhancement layer's own grid (typically 1080p, a quarter of the picture's
/// pixels), which is what the composer upsamples; the base layer is never decoded.
@_spi(Diagnostics)
public struct DoviResidualFrame: Sendable {
    public let seconds: Double
    /// Mean of |residual| over the frame, in 12-bit codes.
    public let meanAbs: Double
    /// Mean of the signed residual: positive brightens the frame on average, negative darkens it.
    public let meanSigned: Double
    /// 99th percentile of |residual|, in 12-bit codes: where the enhancement layer moves highlights or detail.
    public let p99Abs: Int
    /// Share of pixels the residual moves by at least one 10-bit step (4 codes).
    public let visibleFraction: Double
    /// The frame's L1 statistics, 12-bit PQ, the anchors the nits readings below are taken at.
    public let l1AvgPQ: UInt16
    public let l1MaxPQ: UInt16

    /// The frame's mean |residual| as luminance at its average level, in nits.
    public var averageLevelNits: Double { DoviResidualSurvey.nitsDelta(at: l1AvgPQ, codes: meanAbs) }
    /// The 99th-percentile residual as luminance at the frame's peak, in nits: the brightness change where it shows most.
    public var highlightNits: Double { DoviResidualSurvey.nitsDelta(at: l1MaxPQ, codes: Double(p99Abs)) }
}

@_spi(Diagnostics)
public struct DoviResidualSurveyResult: Sendable {
    public let durationSeconds: Double
    public let frames: [DoviResidualFrame]
    /// Sampled frames whose RPU disables the residual (`disable_residual_flag`, or an RPU that is MEL).
    public let residualOffFrames: Int
    /// Sample points that produced no measurement (no keyframe, no RPU, an EL that did not decode).
    public let failures: Int
}

enum DoviResidualSurvey {
    /// How many nits `codes` 12-bit PQ codes are worth, centred on `pq`.
    static func nitsDelta(at pq: UInt16, codes: Double) -> Double {
        let half = codes / 2
        let lo = UInt16(max(0, min(4095, Double(pq) - half)))
        let hi = UInt16(max(0, min(4095, Double(pq) + half)))
        return DoviRpuSurvey.pqCodeToNits(hi) - DoviRpuSurvey.pqCodeToNits(lo)
    }

    /// The composer's inverse NLQ on the CPU: the same arithmetic as `dovi_eval_inv_nlq` in the kernels
    /// (reconstruction at the middle of the quantisation step, in doubled fixed point), wrapping like their
    /// 32/64-bit integers so parameters no real stream carries give a deterministic value, not a trap.
    static func inverseNlq(_ nlq: DoviNlqParams, elCode: Int) -> Int32 {
        guard nlq.nlqMethod == .linear, nlq.nlqScale != 0 else { return 0 }
        let r = Int32(truncatingIfNeeded: elCode) &- nlq.nlqOffset
        if r == 0 { return 0 }
        let magFp = (2 &* Int64(r.magnitude) &- 1) &* Int64(nlq.nlqScale)
        var mag = (magFp &+ 2 &* Int64(nlq.nlqThreshold)) >> (Int64(nlq.nlqShift) + 1)
        if nlq.vdrInMax > 0 && mag > Int64(nlq.vdrInMax) { mag = Int64(nlq.vdrInMax) }
        let m = Int32(truncatingIfNeeded: mag)
        return r < 0 ? 0 &- m : m
    }

    /// Residual statistics over a decoded enhancement-layer picture's luma plane.
    static func measure(luma buffer: CVPixelBuffer, nlq: DoviNlqParams) -> (meanAbs: Double, meanSigned: Double, p99Abs: Int, visible: Double)? {
        var lut = [Int32](repeating: 0, count: 1024)
        for code in 0..<1024 { lut[code] = inverseNlq(nlq, elCode: code) }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }

        var histogram = [Int](repeating: 0, count: 4096)
        var sumAbs = 0
        var sumSigned = 0
        var visible = 0
        for y in 0..<height {
            let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let r = Int(lut[Int(row[x] >> 6)])
                let a = abs(r)
                sumAbs += a
                sumSigned += r
                if a >= 4 { visible += 1 }
                histogram[min(a, 4095)] += 1
            }
        }
        let count = width * height
        var target = Int(Double(count) * 0.99)
        var p99 = 0
        for (value, n) in histogram.enumerated() {
            target -= n
            if target < 0 { p99 = value; break }
        }
        return (Double(sumAbs) / Double(count), Double(sumSigned) / Double(count), p99, Double(visible) / Double(count))
    }
}

extension AetherEngine {

    /// Measures how much a Profile 7 FEL title's enhancement layer changes its picture, at `points` evenly
    /// spaced keyframes: each one's enhancement layer is decoded (VideoToolbox, EL resolution only) and every
    /// pixel is put through that frame's luma NLQ, as the composer would (``DoviResidualFrame``).
    ///
    /// Opens the source with the still-extraction profile (no read-ahead, small ranged chunks), so a sample
    /// costs about one keyframe of reads, and a feature a few seconds on a LAN.
    @_spi(Diagnostics)
    public nonisolated static func doviResidualSurvey(
        url: URL,
        points: Int = 48,
        options: LoadOptions = .init()
    ) throws -> DoviResidualSurveyResult {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url, extraHeaders: options.httpHeaders, profile: .stillExtraction)
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else { throw AetherEngineError.noVideoStream }
        let timeBase = stream.pointee.time_base
        let duration = demuxer.duration

        final class LastFrame: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer: CVPixelBuffer?
            func set(_ b: CVPixelBuffer) { lock.withLock { buffer = b } }
            func take() -> CVPixelBuffer? { lock.withLock { defer { buffer = nil }; return buffer } }
        }
        let last = LastFrame()
        var decoder: HardwareVideoDecoder?
        defer { decoder?.close() }

        var frames: [DoviResidualFrame] = []
        var residualOff = 0
        var failures = 0

        for point in 0..<max(1, points) {
            // Centre of each slice, so neither the studio logo at 0 nor the credits at the end dominate.
            let target = duration * (Double(point) + 0.5) / Double(max(1, points))
            guard demuxer.seek(to: target) else { failures += 1; continue }

            var packet: UnsafeMutablePointer<AVPacket>?
            for _ in 0..<64 {
                guard let p = (try? demuxer.readPacket()) ?? nil else { break }
                if p.pointee.stream_index == videoIdx, p.pointee.flags & AV_PKT_FLAG_KEY != 0 { packet = p; break }
                av_packet_unref(p)
                var opt: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&opt)
            }
            guard let packet else { failures += 1; continue }
            defer {
                av_packet_unref(packet)
                var opt: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&opt)
            }
            let seconds = Double(packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts) * av_q2d(timeBase)

            let layers = DoviRpuConverter.separateDualLayers(packet, extractEL: true)
            var elPacket = layers.elPacket
            defer { if elPacket != nil { av_packet_unref(elPacket!); trackedPacketFree(&elPacket) } }
            guard let raw = layers.rpuData else { failures += 1; continue }

            // The RPU: the luma NLQ the residual goes through, whether the residual is on, and L1.
            var nlq: DoviNlqParams?
            var avgPQ: UInt16 = 0, maxPQ: UInt16 = 0
            var off = false
            raw.withUnsafeBufferPointer { buf in
                guard let b = buf.baseAddress, let rpu = DoviRpuGuard.parse(b, buf.count) else { return }
                defer { dovi_rpu_free(rpu) }
                guard let params = DoviFelComposer.parseRpuParameters(rpu: rpu) else { return }
                off = params.flags.contains(.disableResidual)
                nlq = params.nlqY
                if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
                    if let l1 = dm.pointee.dm_data.level1 { avgPQ = l1.pointee.avg_pq; maxPQ = l1.pointee.max_pq }
                    dovi_rpu_free_vdr_dm_data(dm)
                }
            }
            if off { residualOff += 1; continue }
            guard let nlq, let el = elPacket else { failures += 1; continue }

            // The EL decoder opens on the first keyframe's in-band parameter sets and is reused after.
            if decoder == nil {
                var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
                if let data = el.pointee.data {
                    A53SEIParser.forEachNAL(data, Int(el.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
                        let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
                        switch (nal[0] >> 1) & 0x3F {
                        case 32: vps = bytes
                        case 33: sps = bytes
                        case 34: pps = bytes
                        default: break
                        }
                    }
                }
                guard let vps, let sps, let pps else { failures += 1; continue }
                let d = HardwareVideoDecoder()
                do {
                    try d.open(parameterSets: [vps, sps, pps], timeBase: timeBase) { buffer, _, _ in last.set(buffer) }
                } catch { failures += 1; continue }
                decoder = d
            }
            _ = last.take()
            decoder?.decode(packet: el)
            decoder?.flush()
            guard let picture = last.take(),
                  let m = DoviResidualSurvey.measure(luma: picture, nlq: nlq) else { failures += 1; continue }
            frames.append(DoviResidualFrame(seconds: seconds, meanAbs: m.meanAbs, meanSigned: m.meanSigned,
                                            p99Abs: m.p99Abs, visibleFraction: m.visible,
                                            l1AvgPQ: avgPQ, l1MaxPQ: maxPQ))
        }
        return DoviResidualSurveyResult(durationSeconds: duration, frames: frames,
                                        residualOffFrames: residualOff, failures: failures)
    }
}
#endif
