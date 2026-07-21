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

        mutating func tick(videoTrackCount: Int, variantsAdvertiseVideo: Bool?) -> Verdict {
            if videoTrackCount > 0 { return .disarm }
            if variantsAdvertiseVideo == false { return .disarm }
            ticksObserved += 1
            guard ticksObserved >= graceTicks else { return .keepWaiting }
            return variantsAdvertiseVideo == true ? .fire : .disarm
        }
    }

    /// Maps `AVAssetVariant.videoAttributes` presence per variant to the watchdog's evidence input:
    /// no variants at all = unknown (nil), any variant with video attributes = advertised, an all-audio
    /// variant set = a radio-style master where zero video tracks is the correct steady state.
    static func advertisesVideo(variantHasVideoAttributes: [Bool]) -> Bool? {
        guard !variantHasVideoAttributes.isEmpty else { return nil }
        return variantHasVideoAttributes.contains(true)
    }

    /// The watchdog runs only for live bypass sessions with the fallback enabled: VOD remote HLS is the
    /// AE#154 reroute target (ingesting it back would ping-pong), and hosts can opt out via
    /// `LoadOptions.nativeRemoteHLSIngestFallback`.
    static func shouldArm(isLive: Bool, fallbackEnabled: Bool) -> Bool {
        isLive && fallbackEnabled
    }
}
