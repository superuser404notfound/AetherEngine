import Foundation

/// AetherEngine#168 follow-up: AVFoundation's HLS demuxer builds video tracks for HEVC only from fMP4
/// carriage (HLS Authoring Spec); a master that advertises hvc1/hev1 but delivers MPEG-TS segments
/// reaches readyToPlay with audio only and never creates a video track, so the picture stays black and
/// there is no CMFormatDescription for the #168 range detection to read. The loopback ingest path
/// (HLSLiveIngestReader -> HLSVideoEngine) remuxes TS to fMP4 and plays the same stream, so the engine
/// reroutes a live `nativeRemoteHLS` session there when this signature is detected.
///
/// Pure decision logic; the timing loop and AVFoundation reads live in NativeAVPlayerHost.
enum RemoteHLSIngestFallback {

    enum Verdict: Equatable {
        /// No verdict yet; poll again after the tick cadence.
        case keepWaiting
        /// Healthy or legitimately video-free session; stop watching.
        case disarm
        /// Advertised video never built a track; reroute onto the live-ingest path.
        case fire
    }

    /// #293: what the concurrent playlist/PMT probe (`HLSCarriageProbe`) has established about the
    /// source's carriage while the native mount runs. `transportStreamHEVC` is the verdict the grace
    /// exists to infer, so it ends the wait; everything else leaves the timing loop as it was, because
    /// only positive evidence may reroute.
    enum CarriageEvidence: Equatable {
        /// No probe result yet, or no probe ran for this session.
        case pending
        /// The first segment's PMT declares HEVC in MPEG-TS: AVPlayer will never build a video track.
        case transportStreamHEVC
        /// Carriage AVPlayer builds itself (fMP4, or a PMT without HEVC).
        case nativeCapable
    }

    /// Per-tick state machine, armed once the item reaches readyToPlay (a dead origin never gets there,
    /// so it can never misfire on a stream that served nothing at all). Fires only on positive evidence:
    /// the master advertised a video rendition and AVPlayer still built no video track after the grace.
    /// `variantsAdvertiseVideo` nil = no master-level evidence (media-playlist-direct URL or variants not
    /// resolved yet); after the grace that disarms rather than fires, so audio-only sources whose masters
    /// we cannot judge keep their working AVPlayer session.
    struct Watchdog {
        let graceTicks: Int
        private(set) var ticksObserved = 0

        /// 8 ticks at the host's 0.5 s cadence = 4 s past readyToPlay, comfortably beyond the late
        /// video-track builds seen on slow origins while keeping the black interval short.
        init(graceTicks: Int = 8) {
            self.graceTicks = graceTicks
        }

        /// Grace still ahead of the watchdog, i.e. the wait a probe verdict removes when it ends the
        /// window early (#274: a latency fix that does not name the interval it removed leaves the
        /// reporter measuring the sum).
        func remainingGraceSeconds(tickInterval: Double) -> Double {
            Double(max(0, graceTicks - ticksObserved)) * tickInterval
        }

        mutating func tick(
            videoTrackCount: Int,
            variantsAdvertiseVideo: Bool?,
            carriageEvidence: CarriageEvidence = .pending
        ) -> Verdict {
            if videoTrackCount > 0 { return .disarm }
            if variantsAdvertiseVideo == false { return .disarm }
            // #293: the probe read the same verdict off the source itself, so the remaining grace would
            // only buy black. Master evidence is no longer required: a PMT that declares video outranks
            // an absent variant parse, which is what leaves a direct media playlist unjudgeable today.
            if carriageEvidence == .transportStreamHEVC { return .fire }
            ticksObserved += 1
            guard ticksObserved >= graceTicks else { return .keepWaiting }
            return variantsAdvertiseVideo == true ? .fire : .disarm
        }
    }

    /// #334: whether a carriage verdict that has just settled may reroute on its own, without the
    /// readiness anchor the timing loop is armed at. The anchor exists for the grace-based verdict, where
    /// "no track yet" is only meaningful once the item is otherwise healthy; a settled verdict is read off
    /// the source's own playlists or PMT and needs no grace, and waiting for readiness loses the case it
    /// was built for: a source with no audio either, where AVFoundation builds no track at all and
    /// `readyToPlay` therefore never arrives. `videoTrackCount` is still consulted so a source that
    /// contradicts the probe by building a track keeps its native session.
    static func shouldRerouteOnSettledEvidence(
        carriageEvidence: CarriageEvidence,
        videoTrackCount: Int,
        armed: Bool,
        alreadyRejected: Bool
    ) -> Bool {
        guard armed, !alreadyRejected else { return false }
        guard carriageEvidence == .transportStreamHEVC else { return false }
        return videoTrackCount == 0
    }

    /// Maps `AVAssetVariant.videoAttributes` presence per variant to the watchdog's evidence input:
    /// no variants at all = unknown (nil), any variant with video attributes = advertised, an all-audio
    /// variant set = a radio-style master where zero video tracks is the correct steady state.
    static func advertisesVideo(variantHasVideoAttributes: [Bool]) -> Bool? {
        guard !variantHasVideoAttributes.isEmpty else { return nil }
        return variantHasVideoAttributes.contains(true)
    }

    /// The watchdog runs only for live bypass sessions with the fallback enabled. Finite
    /// HEVC-in-MPEG-TS VOD uses the content-gated, seekable #268 ingest before a native mount, and hosts
    /// can opt out of this live recovery via `LoadOptions.nativeRemoteHLSIngestFallback`.
    static func shouldArm(isLive: Bool, fallbackEnabled: Bool) -> Bool {
        isLive && fallbackEnabled
    }

    /// Video sample types the HLS Authoring Spec sanctions in fMP4 carriage only. An origin that ships
    /// one of them in MPEG-TS is the #168 case: readyToPlay with audio alone and no video track ever.
    static let fragmentedMP4OnlyVideoCodecs: Set<FourCharCode> = [
        0x68766331, // 'hvc1'
        0x68657631, // 'hev1'
        0x64766831, // 'dvh1'
        0x64766865, // 'dvhe'
        0x61763031, // 'av01'
    ]

    /// #293: whether the carriage probe may spend origin connects on this session. AVFoundation's own
    /// master parse is free (it is already fetched), so a case it settles never reaches the network:
    /// an all-audio master has nothing to present, and an H.264 master is carriage AVPlayer builds
    /// itself. Probing is reserved for the two shapes AVFoundation cannot settle, an advertised codec
    /// that is fMP4-only (or unstated), and a source with no master evidence at all (a direct media
    /// playlist, which the watchdog can never judge). Per-token IPTV origins cap concurrent
    /// connections, which is why this is a gate rather than an unconditional probe.
    static func shouldProbeCarriage(
        advertisesVideo: Bool?, advertisedVideoCodecs: [FourCharCode]
    ) -> Bool {
        if advertisesVideo == false { return false }
        guard advertisesVideo == true else { return true }
        guard !advertisedVideoCodecs.isEmpty else { return true }
        return advertisesFragmentedMP4OnlyVideo(advertisedVideoCodecs)
    }

    /// #296: whether the master's own `CODECS` names a sample type the HLS Authoring Spec sanctions in
    /// fMP4 alone. Combined with a media playlist that carries no `EXT-X-MAP` (an fMP4 media segment
    /// requires one), this settles the carriage from the playlists, so the probe spends no segment fetch
    /// on the shape that produced #293 in the first place.
    static func advertisesFragmentedMP4OnlyVideo(_ advertisedVideoCodecs: [FourCharCode]) -> Bool {
        advertisedVideoCodecs.contains { fragmentedMP4OnlyVideoCodecs.contains($0) }
    }

    /// #199: a load whose master already fired the carriage verdict (`RerouteVerdictMemory`) routes
    /// straight onto the live-ingest loopback, skipping the deterministically doomed native mount and
    /// its watchdog grace. Gated exactly like the watchdog itself: the memory may only short-circuit
    /// a reroute the watchdog would have performed anyway.
    static func shouldRouteDirectlyToIngest(
        isLive: Bool, fallbackEnabled: Bool, verdictRemembered: Bool
    ) -> Bool {
        shouldArm(isLive: isLive, fallbackEnabled: fallbackEnabled) && verdictRemembered
    }
}
