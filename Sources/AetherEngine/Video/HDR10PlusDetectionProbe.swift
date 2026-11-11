import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Bounds for the pre-playback dynamic HDR metadata scan, `AetherEngine.probe(url:detecting:)` with
/// `.hdr10Plus` (ST 2094-40) and/or `.hdrVivid` (CUVA). Both run in one pass over the same packets and
/// share these bounds.
///
/// Separate from `LoadOptions` and from the lightweight `probe(url:)` path, exactly like
/// `AtmosDetectionOptions`: a host opts into reading real video packets without the default probe changing
/// behaviour or cost.
///
/// Unlike the Atmos pass this one opens no decoder. It reads demuxed video packets and validates codec
/// metadata (see `HDR10PlusMetadataScan`), so its cost is I/O and structural parsing, not decode.
public struct HDR10PlusDetectionOptions: Sendable, Equatable {
    /// Stop after this many video packets have been scanned. Default 32.
    ///
    /// HDR10+ metadata is per frame, so a carrying source almost always confirms on the very first video
    /// packet; the budget exists for the source that starts with a run of frames without the SEI, and for
    /// the adversarial one that never has it.
    public var maxPackets: Int

    /// Inspect at most this many cumulative video-packet bytes. Default 16 MiB.
    ///
    /// This is the cap that actually binds on the content the feature targets: one UHD HEVC keyframe runs to
    /// several MB, so a handful of packets can exhaust it long before `maxPackets` does. A packet larger
    /// than the remaining budget stops the pass BEFORE inspection, even if it carries HDR10+.
    ///
    /// It also sets what the pass may read from the source in total, video or not: four times this
    /// value, and never less than 4 MiB. That bound sits below the demuxer, so the blocks of the other
    /// streams, which the demuxer reads and drops without ever handing them back as packets, count too.
    public var maxBytes: Int64

    /// Soft wall-clock budget, checked before and after reads and after inspection. NOT preemptive:
    /// one blocking read can still overrun it, but a late result never confirms HDR10+. Default 2 seconds.
    public var timeBudget: TimeInterval

    public init(
        maxPackets: Int = 32,
        maxBytes: Int64 = 16 * 1024 * 1024,
        timeBudget: TimeInterval = 2.0
    ) {
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
        self.timeBudget = timeBudget
    }
}

/// Result of the bounded HDR10+ carriage scan. Internal: hosts read the enriched `SourceProbe` instead. It
/// exists at module visibility so the stop conditions are unit-testable without media.
struct HDR10PlusDetectionOutcome: Sendable, Equatable {
    enum StopReason: Sendable, Equatable {
        /// No video stream at the resolved index, or the source has no video at all.
        case noVideoTrack
        /// Structural HDR10+ metadata was validated within the budget. The only positive answer.
        case found
        /// `maxPackets` video packets were scanned without a hit.
        case packetCap
        /// The byte budget was exhausted, or the next packet would exceed it.
        case byteCap
        /// `timeBudget` elapsed before a finding could be confirmed.
        case timeCap
        /// The demuxer reached EOF without a hit (a source short enough to scan whole).
        case demuxEOF
        /// `Demuxer.readPacket()` threw. Tolerated, never rethrown.
        case demuxError
    }

    let stopReason: StopReason
    let packetsRead: Int
    let bytesRead: Int64
    /// What the pass confirmed. `.found` means every requested format was; a cap can still end a pass
    /// that confirmed one of two, and that confirmation stands. Defaults to the single-target reading.
    let found: ProbeDetail
    /// Set exactly when `found` contains `.dolbyVisionEnhancementLayer`.
    let enhancementLayer: DolbyVisionEnhancementLayer?

    init(
        stopReason: StopReason, packetsRead: Int, bytesRead: Int64, found: ProbeDetail? = nil,
        enhancementLayer: DolbyVisionEnhancementLayer? = nil
    ) {
        self.stopReason = stopReason
        self.packetsRead = packetsRead
        self.bytesRead = bytesRead
        self.found = found ?? (stopReason == .found ? .hdr10Plus : [])
        self.enhancementLayer = enhancementLayer
    }

    /// A negative is never authoritative and is never published as one: only a validated payload sets a
    /// flag, and a flag is only ever set, never cleared. Not found means "not seen inside this budget",
    /// which for a cap is genuinely inconclusive and for EOF is only as conclusive as the source is short.
    var carriesHDR10Plus: Bool { found.contains(.hdr10Plus) }
    var carriesHDRVivid: Bool { found.contains(.hdrVivid) }
}

/// Which extra, strictly more expensive detail a probe should resolve on top of the container metadata.
///
/// Each member costs real reads past `avformat_find_stream_info`, which is why the base `probe(url:)` never
/// does any of it. They combine into one pass over one open handle, so a host that badges both Atmos and
/// HDR10+ pays one connection rather than two.
public struct ProbeDetail: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Authoritative E-AC-3 JOC (Dolby Atmos) via a bounded decode pass. See `AtmosDetectionOptions`.
    public static let atmos = ProbeDetail(rawValue: 1 << 0)

    /// HDR10+ (ST 2094-40) carriage via a bounded packet scan. See `HDR10PlusDetectionOptions`.
    public static let hdr10Plus = ProbeDetail(rawValue: 1 << 1)

    /// HDR Vivid (CUVA T/UWA 005.1) carriage in HEVC via the same bounded packet scan as `.hdr10Plus`,
    /// sharing its `HDR10PlusDetectionOptions` budget. See `SourceProbe.carriesHDRVividMetadata`.
    public static let hdrVivid = ProbeDetail(rawValue: 1 << 2)

    /// The enhancement layer of a single-track Dolby Vision Profile 7 source, FEL or MEL, from its first
    /// RPU's `el_type` (AE#1030). Read in the same packet pass and under the same `HDR10PlusDetectionOptions`
    /// budget as `.hdr10Plus`, and only when the container declares Profile 7; any other source reads no
    /// packet for it. See `SourceProbe.dolbyVisionEnhancementLayer`.
    public static let dolbyVisionEnhancementLayer = ProbeDetail(rawValue: 1 << 3)
}

extension AetherEngine {

    /// Pure stop-condition check for the scan loop, in cap priority order (packets, bytes, time). `nil` while
    /// inside all three budgets.
    nonisolated static func hdr10PlusScanCapReached(
        packetsRead: Int,
        bytesRead: Int64,
        elapsed: TimeInterval,
        options: HDR10PlusDetectionOptions
    ) -> HDR10PlusDetectionOutcome.StopReason? {
        if packetsRead >= options.maxPackets { return .packetCap }
        if bytesRead >= options.maxBytes { return .byteCap }
        if elapsed >= options.timeBudget { return .timeCap }
        return nil
    }

    /// Source bytes the scan may consume, whatever stream they belong to. `maxBytes` alone bounds only
    /// the video packets the scan sees; with the other streams at AVDISCARD_ALL the demuxer reads and
    /// drops their blocks inside one `av_read_frame`, so a file with one video packet followed by
    /// gigabytes of another stream would otherwise be read to its end. Saturating: `maxBytes` is public.
    nonisolated static func hdr10PlusInputByteBudget(maxBytes: Int64) -> Int64 {
        let (product, overflowed) = max(0, maxBytes).multipliedReportingOverflow(by: 4)
        return overflowed ? .max : max(product, 4 * 1024 * 1024)
    }

    /// Packet ceiling for the AVDISCARD_ALL fuse, saturating rather than trapping: `maxPackets` is public and
    /// `Int.max` is a plausible "no limit" value to pass.
    nonisolated static func hdr10PlusForeignPacketFuse(maxPackets: Int) -> Int {
        let (product, overflowed) = maxPackets.multipliedReportingOverflow(by: foreignPacketFuseMultiplier)
        return overflowed ? Int.max : product
    }

    /// The label an HDR10+ finding produces, given what the container already said.
    ///
    /// The same rule the running session applies in `handleHDR10PlusDetected`, in one place so probe and
    /// session cannot drift: `.hdr10` is the only format that moves, because the ST 2094-40 payload rides an
    /// HDR10 base. A Dolby Vision source keeps its label (Profile 7 and the 8.1 remuxes of it carry an HDR10+
    /// base layer under the RPU), an HLG or SDR one has no HDR10 base for the payload to describe, and
    /// `SourceProbe.carriesHDR10PlusMetadata` carries the evidence in all of those cases.
    nonisolated static func hdr10PlusUpgradedFormat(_ detected: VideoFormat) -> VideoFormat {
        detected == .hdr10 ? .hdr10Plus : detected
    }

    /// Bounded scan for HDR10+ and/or HDR Vivid carriage on `videoIndex` (`targets`). Opens no decoder: it
    /// reads demuxed packets and asks `HDR10PlusMetadataScan` / `HDRVividMetadataScan` about each one,
    /// stopping once every target is confirmed or at the first cap.
    ///
    /// Deliberately runs BEFORE any queue-flushing seek, unlike `detectAtmos`. `avformat_find_stream_info`
    /// leaves the packets it read queued, `av_read_frame` hands those back first, and at the head of a
    /// container those are video packets: the common case is answered out of bytes that are already paid for,
    /// with no further I/O at all. (The Atmos pass has to throw that queue away precisely because what it
    /// needs is audio, which may sit far into the file.)
    ///
    /// `Demuxer.readPacket()` failures fold into `.demuxError` rather than propagating: an unreadable stream
    /// fails to confirm HDR10+, it does not fail the probe.
    nonisolated static func detectHDR10Plus(
        demuxer: Demuxer,
        videoIndex: Int32,
        options: HDR10PlusDetectionOptions,
        targets: ProbeDetail = .hdr10Plus,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> HDR10PlusDetectionOutcome {
        var targets = targets.intersection([.hdr10Plus, .hdrVivid, .dolbyVisionEnhancementLayer])
        guard videoIndex >= 0, let stream = demuxer.stream(at: videoIndex),
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else {
            return HDR10PlusDetectionOutcome(stopReason: .noVideoTrack, packetsRead: 0, bytesRead: 0)
        }

        // Matroska's BlockAdditional carriage is attached by the demuxer to the packet, so the scan needs the
        // packets themselves either way; dropping the other streams keeps the byte budget spent on video.
        demuxer.discardAllStreamsExcept([videoIndex])
        demuxer.beginInputByteBudget(Self.hdr10PlusInputByteBudget(maxBytes: options.maxBytes))
        defer { demuxer.endInputByteBudget() }
        // A read the input budget refused surfaces as an error or as EOF, depending on the container.
        func readEnded(_ reason: HDR10PlusDetectionOutcome.StopReason) -> HDR10PlusDetectionOutcome.StopReason {
            demuxer.inputByteBudgetExhausted ? .byteCap : reason
        }

        let start = now()
        func elapsed() -> TimeInterval {
            Double(now() - start) / 1_000_000_000
        }
        var packetsRead = 0
        var bytesRead: Int64 = 0
        var packetsSeen = 0
        var found: ProbeDetail = []
        var enhancementLayer: DolbyVisionEnhancementLayer?
        func outcome(_ reason: HDR10PlusDetectionOutcome.StopReason) -> HDR10PlusDetectionOutcome {
            HDR10PlusDetectionOutcome(
                stopReason: reason, packetsRead: packetsRead, bytesRead: bytesRead, found: found,
                enhancementLayer: enhancementLayer)
        }
        let fuse = Self.hdr10PlusForeignPacketFuse(maxPackets: options.maxPackets)
        let rpuFraming = targets.contains(.dolbyVisionEnhancementLayer)
            ? A53SEIParser.nalFraming(
                codec: .hevc, extradata: codecpar.pointee.extradata, size: Int(codecpar.pointee.extradata_size))
            : .lengthPrefixed(size: 4)

        while true {
            if let cap = Self.hdr10PlusScanCapReached(
                packetsRead: packetsRead, bytesRead: bytesRead, elapsed: elapsed(), options: options
            ) {
                return outcome(cap)
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                return outcome(readEnded(.demuxError))
            }
            defer {
                if let packet {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                }
            }
            guard elapsed() < options.timeBudget else {
                return outcome(.timeCap)
            }
            guard let pkt = packet else {
                return outcome(readEnded(.demuxEOF))
            }

            packetsSeen += 1
            if pkt.pointee.stream_index == videoIndex {
                let packetBytes = Int64(pkt.pointee.size)
                guard packetBytes >= 0 else {
                    return outcome(.demuxError)
                }
                guard packetBytes <= options.maxBytes - bytesRead else {
                    return outcome(.byteCap)
                }
                packetsRead += 1
                bytesRead += packetBytes
                if targets.contains(.hdr10Plus), !found.contains(.hdr10Plus),
                   HDR10PlusMetadataScan.packetCarriesHDR10Plus(pkt, codecParameters: codecpar) {
                    found.insert(.hdr10Plus)
                }
                if targets.contains(.hdrVivid), !found.contains(.hdrVivid),
                   HDRVividMetadataScan.packetCarriesHDRVivid(pkt, codecParameters: codecpar) {
                    found.insert(.hdrVivid)
                }
                if targets.contains(.dolbyVisionEnhancementLayer), !found.contains(.dolbyVisionEnhancementLayer) {
                    if let layer = DoviRpuConverter.enhancementLayerType(pkt, framing: rpuFraming)
                        .flatMap(DolbyVisionEnhancementLayer.init(rawValue:)) {
                        enhancementLayer = layer
                        found.insert(.dolbyVisionEnhancementLayer)
                    } else if packetsRead >= DolbyVisionRecordAudit.auditPacketBudget {
                        // Every Profile 7 picture carries an RPU, so the load path's own walk gives up here,
                        // and so does this one: the rest of the budget belongs to the dynamic HDR targets.
                        targets.remove(.dolbyVisionEnhancementLayer)
                        if targets.isEmpty { return outcome(.packetCap) }
                    }
                }
            }
            // Evidence in hand outranks the soft budget. The caps exist to bound what this pass SPENDS,
            // and a confirmation is already paid for; dropping it would turn an overrun into a false
            // negative on a slow origin, which the caller cannot tell apart from "this source has none".
            if !targets.isEmpty, found.isSuperset(of: targets) {
                return outcome(.found)
            }

            guard elapsed() < options.timeBudget else {
                return outcome(.timeCap)
            }

            // AVDISCARD_ALL is advisory, so a container that keeps handing back foreign packets still ends.
            if packetsSeen >= fuse {
                return outcome(.packetCap)
            }
        }
    }
}
