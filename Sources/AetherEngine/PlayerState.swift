import Foundation
import CoreGraphics

/// The playback state of a `AetherEngine` instance.
public enum PlaybackState: Sendable, Equatable {
    /// No session: pre-load, or torn down via `stop()`. Distinct from `.ended` (see below).
    case idle
    case loading
    case playing
    case paused
    case seeking
    /// The source played to completion on its own. Terminal, like `.idle`, but reached by reaching
    /// end-of-media rather than by `stop()`. Surfaced on every backend (native / software / audio) so a
    /// host can run end-of-playback handling (mark-watched, autoplay-next, dismiss) without observing the
    /// AVPlayer directly, which is impossible on the software-decode path (#63). Cleared by the next
    /// `load(...)`. Transport calls (`seek`, `togglePlayPause`) are no-ops here; reload to replay.
    case ended
    /// Terminal failure carrying a human-readable message. The text is a payload, not a classification key:
    /// part of it is the engine's own sentence naming the cause, the rest is forwarded from the failure
    /// underneath (on the native paths `AVPlayerItem.error.localizedDescription`, which AVFoundation
    /// localizes into the device language). Bucket failures by `videoRoute`, `playbackPhase` and the
    /// furthest `startupProgress` checkpoint, and keep the string for the log.
    case error(String)
}

/// Internal rendering backend. Exposed read-only for diagnostic overlays; hosts must not branch on this value.
public enum PlaybackBackend: String, Sendable, Equatable {
    case none
    /// Removed in 1.0.0; reserved for hosts that still switch on it.
    case aether
    /// HLS-fMP4 over loopback to AVPlayer + AVPlayerLayer. Default for HEVC / H.264 / VP9.
    case native
    /// FFmpeg / dav1d + AVSampleBufferDisplayLayer. Used for AV1 on tvOS (no HW decoder).
    case software
    /// FFmpeg audio + AVSampleBufferAudioRenderer. No video pipeline.
    case audio
}

/// Which pipeline is actually serving the session (#321). `LoadOptions.nativeRemoteHLS` records what the
/// host asked for; the engine can change the effective route after that, and until now only a log line
/// said so. Observe `$videoRoute` for decisions that differ per pipeline, above all who owns subtitle
/// drawing: on `.remoteBypass` AVPlayer renders the origin's own legible renditions, on `.loopback` and
/// `.software` the host's renderer does.
///
/// Derived from `playbackBackend` + the session's effective options, never assigned on its own, so it
/// cannot drift from the running session (the `playbackPhase` arrangement, #85).
///
/// Route changes the host does not request:
/// - `.remoteBypass` -> `.loopback` when the #168 carriage watchdog finds no video track on a master
///   that advertises one, when the #199 memory routes a known such master straight onto the ingest, and
///   when the AE#268 probe classifies a VOD playlist as HEVC-in-MPEG-TS;
/// - `.loopback` -> `.remoteBypass` when AE#154 / AE#246 find an HLS playlist on the loopback path.
public enum VideoRoute: String, Sendable, Equatable {
    /// Nothing loaded, or the session was torn down.
    case none
    /// AVPlayer plays the origin URL directly (`LoadOptions.nativeRemoteHLS`). No demuxer, no local
    /// server: media selection, subtitle drawing and buffering all belong to AVFoundation.
    case remoteBypass
    /// Demuxer plus local HLS-fMP4 server feeding AVPlayer. The engine owns the source connection and
    /// the subtitle pipeline; this is the default video route.
    case loopback
    /// FFmpeg / dav1d into AVSampleBufferDisplayLayer.
    case software
    /// An audio-only session. There is no video pipeline to route.
    case audio

    /// Single point where a backend and the session's effective remote-HLS bit become a route.
    static func derive(backend: PlaybackBackend, nativeRemoteHLS: Bool) -> VideoRoute {
        switch backend {
        case .none, .aether: return .none
        case .native: return nativeRemoteHLS ? .remoteBypass : .loopback
        case .software: return .software
        case .audio: return .audio
        }
    }
}

/// How the session's audio reaches the renderer, as a typed fact (AE#462).
///
/// The reason this exists is `.droppedNoPipeline`. A source whose audio can neither stream-copy into
/// fMP4 nor go through the bridge plays video-only: `state` reaches `.playing`, nothing failed by the
/// error taxonomy's lights, and before this the only account was a log line. A host with a fallback
/// ladder (a server-side transcode, a second player) could reconstruct the drop from a non-empty
/// `audioTracks` paired with a nil `activeAudioDecoder`, which was an undocumented pairing of two
/// publishers that broke in both directions: it read as a drop where a probe had merely failed to list
/// the tracks, and it read as healthy on the software path, whose label is built from the probe rather
/// than from the decoder that was opened. `audioDelivery` is the fact itself, published where the
/// pipelines decide it. **A host with a ladder should demote on `.droppedNoPipeline`**, the way it
/// demotes on `PlaybackErrorKind.audioBridgeProducedNoOutput`, which is the same user outcome reached
/// through a bridge that WAS built and then decoded nothing.
///
/// Not a `PlaybackErrorKind`: `publishError` makes a failure terminal by moving `state` to `.error`,
/// and `errorInfo` is cleared by the state's own move away from it. Video-only playback is neither
/// terminal nor an error for every host, so carrying it there would break the invariant that ties
/// those two publishers together.
///
/// Derived from `playbackBackend`, the session's effective options and the live pipeline's own
/// classification, never assigned on its own, so it cannot drift from the running session (the
/// `videoRoute` arrangement, #321). Raw values are API, like `PlaybackErrorKind`'s.
///
/// The pair with `activeAudioDecoder` still holds and is now honest on both paths: that publisher
/// names the pipeline for a human, this one classifies it for a ladder.
public enum AudioDelivery: String, Sendable, Equatable, CaseIterable {
    /// No session: pre-load, or torn down.
    case none
    /// The source carries no audio stream. Silence is the source's, not the engine's, and no ladder
    /// rung can change it. A source whose audio stream the pick passed over (its parameters left
    /// empty by the probe) is `.droppedNoPipeline`, not this (AE#641).
    case noAudioInSource
    /// The source's audio bitstream is muxed into fMP4 unchanged: Atmos, DTS-HD and every other
    /// bitstream reach the renderer exactly as authored.
    case streamCopy
    /// The audio is decoded and re-encoded (FLAC or E-AC-3) for the fMP4 pipeline, because its codec
    /// is not fMP4-legal or AVPlayer rejects it there. Lossless for the bed channels; object metadata
    /// in a TrueHD-MAT or JOC bitstream does not survive the PCM intermediate.
    case bridged
    /// libavcodec decodes the audio and the engine renders it itself (the software path and the
    /// software audio-only host).
    case decoded
    /// The source HAS audio and none of it could be delivered: no libavcodec decoder for it, the
    /// bridge could not be built or could not write its header, no stream could be picked because the
    /// probe left its parameters empty, or a live bridge was built and its decoder produced nothing,
    /// after which the engine rebuilt the session without the track (AE#641). The session plays
    /// video-only and silently. This is the one value a fallback ladder acts on.
    case droppedNoPipeline
    /// AVFoundation owns the audio: the remote-HLS bypass and the native audio-only host both hand
    /// the source to AVPlayer, which does its own media selection. The engine has no pipeline of its
    /// own to classify and does not guess on AVFoundation's behalf.
    case playerManaged

    /// Single point where a backend, the session's remote-HLS bit and a pipeline's own classification
    /// become one published fact.
    ///
    /// The routing bits alone can never produce `.droppedNoPipeline`: the drop is only ever reported
    /// by the pipeline that dropped, about itself.
    static func derive(backend: PlaybackBackend,
                       nativeRemoteHLS: Bool,
                       loopbackSession: AudioDelivery?,
                       softwareHost: AudioDelivery?,
                       audioOnlyHost: AudioDelivery?) -> AudioDelivery {
        switch backend {
        case .none, .aether:
            return .none
        case .native:
            // The bypass has no HLSVideoEngine to ask, and a leftover fact from the session before a
            // reroute must not answer for it.
            return nativeRemoteHLS ? .playerManaged : (loopbackSession ?? .none)
        case .software:
            return softwareHost ?? .none
        case .audio:
            return audioOnlyHost ?? .none
        }
    }
}

/// What playback is doing right now, as one observable (#85). Derived from `state`, `isBuffering`,
/// `isSeeking`, and the reader network phase, so it can never desync from them. Observe `$playbackPhase`
/// instead of stitching `state == .loading` + `$isBuffering` + `$isSeeking` together, and instead of
/// regex-matching `EngineLog` for stall/reconnect, which is no longer necessary.
///
/// `.stalled(reconnecting:)` reports a source-connection problem (drop / 429 / 503 backoff) distinct from
/// `.rebuffering` (a healthy-connection buffer underrun). The associated value is `true` while the reader is
/// retrying and `false` once it has spent its ladder and handed the outcome to the producer's reopen, which
/// is still a dead source but no longer one being retried (#410). Not available on the direct AVPlayer-HLS
/// live path (no demuxer / reader): a reconnect there reads as `.rebuffering`.
public enum PlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case error(String)
}

/// Source-fetch network axis feeding `PlaybackPhase` (#85). `.flowing` covers normal delivery,
/// `.reconnecting` the `AVIOReader` stall / drop / backoff loop, `.exhausted` a ladder that ran out and left
/// the read (#410): the reader is gone, the producer's reopen owns the recovery, and until some reader
/// delivers again the source is still down. `.exhausted` is deliberately NOT `.flowing`: the dying reader
/// used to claim delivery on its way out purely so the next reader's gate could not strand the phase, which
/// reported a healthy source across the whole reopen window.
enum ReaderNetworkPhase: Sendable, Equatable {
    case flowing
    case reconnecting
    case exhausted
}

extension PlaybackPhase {
    /// Pure fold of the four playback axes into one phase, with fixed precedence
    /// (highest first): error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused.
    ///
    /// The reader axis outranks `isSeeking` (#410). A seek cannot land over a source that stopped
    /// delivering, so the level stays up for the whole outage, and the seek doing it is not necessarily the
    /// host's: the producer's restart coalescer issues its own `nativeScrub` seeks while recovering, so the
    /// engine's recovery hid the outage it was recovering from, for as long as it lasted. A seek stays
    /// observable through `isSeeking` and `seekEvents`; the reader axis is observable nowhere else, which is
    /// the whole reason this phase exists. Over a delivering source nothing changes: the reader is
    /// `.flowing` and a seek reads `.seeking` exactly as before, and a seek that can land from cache over a
    /// reconnecting reader clears itself in milliseconds.
    static func derive(state: PlaybackState,
                       isBuffering: Bool,
                       isSeeking: Bool,
                       stall: ReaderNetworkPhase,
                       transportHasRolled: Bool) -> PlaybackPhase {
        switch state {
        case .error(let message): return .error(message)
        case .ended:              return .ended
        case .idle:               return .idle
        case .loading:            return .loading
        case .playing, .paused, .seeking:
            switch stall {
            case .reconnecting: return .stalled(reconnecting: true)
            case .exhausted:    return .stalled(reconnecting: false)
            case .flowing:      break
            }
            if isSeeking { return .seeking }
            // AE#440: `state` is transport INTENT, and every autostart writes it before AVPlayer has
            // rolled anything. On a live join that gap is seconds wide, so a phase of `.playing` there
            // describes a picture that is standing still. Until the transport has moved once, the
            // session is still starting, which is what `.loading` already means; `.rebuffering` is
            // reserved for an underrun after playback existed. A paused mount stays `.paused`: it is
            // honestly not playing rather than still arriving.
            if !transportHasRolled, state != .paused { return .loading }
            if isBuffering { return .rebuffering }
            return state == .paused ? .paused : .playing
        }
    }
}

/// Static snapshot of what the current display can present. Single source of truth shared with the host.
public struct DisplayCapabilities: Sendable, Equatable {
    public let supportsHDR: Bool
    public let supportsDolbyVision: Bool
    public let supportsHDR10: Bool
    public let supportsHLG: Bool

    public init(supportsHDR: Bool, supportsDolbyVision: Bool, supportsHDR10: Bool, supportsHLG: Bool) {
        self.supportsHDR = supportsHDR
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
    }

    /// AE#493: what a display that engages EDR on demand can present, where no per-mode table exists.
    ///
    /// `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so the macOS branch had nothing to read
    /// for the per-mode split and returned a table of `false`. That is not the same as unknown: it is an
    /// assertion, and `effectiveVideoFormat` clamps a PQ base against it, which downgraded every HDR10
    /// and HLG source to SDR before playback started (reported on a 16" XDR, macOS 26).
    ///
    /// Eligibility is the honest answer for the two that only need EDR: HDR10 and HLG are a transfer
    /// function, and a display AVFoundation calls eligible for HDR playback presents both. It is
    /// deliberately NOT the answer for Dolby Vision. Eligibility proves EDR, not that AVFoundation will
    /// accept a given DV variant on this display, and a refusal surfaces as -11868 with nothing playing.
    /// DV therefore stays unclaimed here and belongs to a host assertion instead, where the claim is made
    /// by whoever knows the hardware.
    static func onDemandEDRDisplay(hdrEligible: Bool) -> DisplayCapabilities {
        DisplayCapabilities(
            supportsHDR: hdrEligible,
            supportsDolbyVision: false,
            supportsHDR10: hdrEligible,
            supportsHLG: hdrEligible)
    }

    /// AE#459: what a platform that HAS a per-mode table may honestly claim, now that the table has been
    /// measured wrong about one of its entries.
    ///
    /// `AVPlayer.availableHDRModes` is that table on tvOS and iOS, and it is deprecated as of the 26 SDKs
    /// in favour of `eligibleForHDRPlayback`, a single boolean: Apple has already collapsed the per-mode
    /// question into "can this display do HDR at all". Measured against a display that answers for itself,
    /// the table under-reports HLG over HDMI. A Samsung S93F connected straight to an Apple TV advertises
    /// Hybrid Log-Gamma in its EDID and plays HLG in the TV's own player, while the table reports `.hlg`
    /// absent; a second Apple TV on a different Samsung reports the same; an iPhone 17 Pro running this
    /// engine on its built-in panel reports it present. So the absence is about the platform's HDMI path,
    /// not about the panel.
    ///
    /// Eligibility is therefore the floor for the two modes that need nothing but EDR. HDR10 and HLG are a
    /// transfer function, and a display AVFoundation calls eligible for HDR playback presents both, which
    /// is the identical rule `onDemandEDRDisplay` already applies where no table exists at all. The table
    /// can still ADD (a mode it names is a mode the display has), it can no longer subtract.
    ///
    /// Dolby Vision stays on the table alone, for the same reason it is unclaimed on macOS and for one
    /// more: here the table is measured RIGHT about it in both directions, `false` on a Samsung with no
    /// Dolby Vision and `true` on an iPhone 17 Pro the same day. Eligibility proves EDR, never that
    /// AVFoundation will accept a DV variant, and a wrong claim there surfaces as -11868 with nothing
    /// playing. That claim belongs to a host (`LoadOptions.panelPresentsDolbyVision`).
    ///
    /// What the HLG term actually reaches is narrow, and worth knowing before reading a bug into it:
    /// `effectiveVideoFormat` opens with a guard on Dolby Vision, so `supportsHLG` is consulted only for a
    /// DV source with an HLG base layer, meaning Profile 8.4. A plain HLG title was never clamped by any
    /// of this.
    static func observedPerModeTable(
        hdrEligible: Bool, hdr10: Bool, hlg: Bool, dolbyVision: Bool
    ) -> DisplayCapabilities {
        DisplayCapabilities(
            supportsHDR: hdrEligible,
            supportsDolbyVision: dolbyVision,
            supportsHDR10: hdr10 || hdrEligible,
            supportsHLG: hlg || hdrEligible)
    }

    /// AE#493 / AE#459: the capability a host asserts, because this one cannot be observed.
    ///
    /// `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode table to read,
    /// and eligibility deliberately does not stand in for one: it proves EDR, not that AVFoundation will
    /// accept a Dolby Vision variant on this display. Whoever knows the hardware is the host, so the claim
    /// is the host's (`LoadOptions.panelPresentsDolbyVision`).
    ///
    /// An assertion only ever ADDS. A display the system already reports DV-capable is not un-asserted by
    /// a `false`, so the flag can claim a capability and never hide one. `supportsHDR` rides along because
    /// Dolby Vision is an HDR format: a display presenting DV presents HDR, and without that term the
    /// session would build a DV master for a route `displaySupportsHDR == false` had already sent
    /// media-direct. HDR10 and HLG are NOT implied; that every DV television also takes HDR10 is a fact
    /// about the market, not an entailment of the claim.
    func assertingDolbyVision(_ asserted: Bool) -> DisplayCapabilities {
        guard asserted else { return self }
        return DisplayCapabilities(
            supportsHDR: true,
            supportsDolbyVision: true,
            supportsHDR10: supportsHDR10,
            supportsHLG: supportsHLG)
    }

    /// The same display with Dolby Vision left unclaimed: what `LoadOptions.dolbyVisionHandling =
    /// .baseLayerOnly` asks the format clamp to read, so a Dolby Vision source resolves to the HDR10 /
    /// HLG its base layer is and the criteria request follows. HDR itself is untouched: the panel still
    /// presents HDR, it is only not asked for Dolby Vision.
    func withoutDolbyVision() -> DisplayCapabilities {
        guard supportsDolbyVision else { return self }
        return DisplayCapabilities(
            supportsHDR: supportsHDR,
            supportsDolbyVision: false,
            supportsHDR10: supportsHDR10,
            supportsHLG: supportsHLG)
    }
}

/// Deinterlacer selection for the software-decode path (interlaced MPEG-2 / VC-1 / MPEG-4, and
/// interlaced H.264, which routes software because AVPlayer does not deinterlace, #107 /
/// `VideoRoutingPolicy`).
public enum DeinterlaceMode: String, Sendable, Equatable {
    /// yadif_videotoolbox (Metal compute over VideoToolbox frames) when the linked FFmpeg build
    /// ships it AND a Metal device exists at runtime; otherwise falls back to software bwdif.
    /// The hardware path also skips the sws_scale copy: the filter sink emits IOSurface-backed
    /// CVPixelBuffers that go straight to the renderer.
    case auto
    /// Force the software bwdif/yadif path (previous engine behavior).
    case software
}

/// Output cadence of the HARDWARE deinterlacer (`DeinterlaceMode.auto` when the hw graph engages).
/// The software fallback always runs frame-rate: doubling sws_scale + CPU bwdif for field-rate
/// output is the wrong trade without the GPU, and a fallback should not change cost class.
public enum DeinterlaceFieldRate: String, Sendable, Equatable {
    /// One output frame per FIELD (25i -> 50p, 29.97i -> 59.94p): full temporal resolution,
    /// smoother motion. Default for the hardware path.
    case field
    /// One output frame per FRAME (25i -> 25p): halves filter output, matches the sw path.
    case frame
}

/// Live-join latency profile for loopback live sessions (`LoadOptions.liveJoinProfile`, AetherEngine#195).
public enum LiveJoinProfile: Sendable, Equatable {
    /// Historical behavior: ~4s segment cut target, served TARGETDURATION >= 6, live-edge holdback
    /// (and with it the first-manifest startup cushion, AE#189) >= 18s. The first playlist always
    /// waits for the full advertised holdback.
    case standard
    /// Channel-zapping profile: cut live segments at every keyframe past 0.5s, so TARGETDURATION and
    /// holdback collapse to the source keyframe cadence. The first playlist prefers the full holdback,
    /// but after two finalized segments a strict-realtime source gets one observed-segment grace,
    /// clamped to 0.5...2.0s, before a shallow first window is served. That bounded start can produce
    /// one early -16832 warning or a short rebuffer.
    case fastZap
}

/// Options for `AetherEngine.load(url:options:)`. All flags default to safe values.
/// Which playback host serves a session's video (#461). See `LoadOptions.preferredDecodePath`.
public enum DecodePath: String, Sendable, Equatable, CaseIterable {
    /// The engine routes: codec support, the VideoToolbox capability probe, declared interlace,
    /// source seekability. The default, and right for every session that does not have evidence
    /// the engine cannot have.
    case automatic
    /// Serve this source through `SoftwarePlaybackHost`, whatever the routing concluded. Scoped to
    /// the session; it does not touch any other session on the shared engine.
    case software
}

/// Which layer of a Dolby Vision source a session presents. See `LoadOptions.dolbyVisionHandling`.
public enum DolbyVisionHandling: String, Sendable, Equatable, CaseIterable {
    /// Dolby Vision wherever the profile and the display allow it. The default.
    case automatic
    /// Present the HDR10 / HLG base layer and leave the Dolby Vision out of the container: `hvc1` /
    /// `av01` sample entry, `dvcC` stripped, no `SUPPLEMENTAL-CODECS`, HDR10 / HLG display criteria.
    /// The RPU NAL units stay in the bitstream and are ignored, the way a Profile 7 already plays on a
    /// display without Dolby Vision. Only for a source whose base layer is a YCbCr HDR signal: HEVC
    /// Profile 7 / 8.1 / 8.4, AV1 Profile 10.1 / 10.4, and a Profile 5 record over a VUI that declares
    /// a BT.2020 YCbCr PQ or HLG base (a mislabelled Profile 7 / 8 remux, the class this exists for).
    /// A Profile 5 or AV1 Profile 10.0 whose VUI says nothing carries IPT-PQ-c2 and has no base layer to
    /// present, so it keeps its Dolby Vision route and the engine says so in the log.
    case baseLayerOnly
}

public struct LoadOptions: Sendable, Equatable {
    /// Diagnostic lever: omit BT.2020 / transfer / YCbCr matrix from AVDisplayCriteria so AVPlayer re-reads color from the bitstream. Default off.
    public var omitCriteriaColorExtensions: Bool
    /// Skip display-criteria handshake entirely. For previews and `aetherctl` where no panel exists. Default off.
    public var suppressDisplayCriteria: Bool
    /// Extra HTTP headers for HEAD probe, Range chunks, side-demuxer fetches. On the loopback paths they are NOT forwarded to AVPlayer (it hits the local server); on `nativeRemoteHLS` they ride into the AVURLAsset so header-enforcing origins (IPTV Referer / User-Agent / Authorization) work (#119). Forwarded to `selectSidecarSubtitle` by default; pass explicit headers to override (#32). Default empty.
    public var httpHeaders: [String: String]

    /// Diagnostic lever: force dvh1 codec tags + master playlist regardless of display capability. OFF by default: non-DV displays route DV through the media playlist (no master) so AVPlayer auto-tonemaps the HEVC base layer (only path that avoids AVFoundationErrorDomain -11868 on tvOS 26). AetherEngine#4.
    public var keepDvh1TagWithoutDV: Bool

    /// AE#455, EXPERIMENTAL, default OFF. On a display with no Dolby Vision of its own, serve a Profile 8.1
    /// source the way a Profile 5 source is served: `dvh1` sample entry, container `dvcC` rewritten to
    /// profile 5 / compatibility 0, `CODECS="dvh1.05.LL"`. AVPlayer then runs its own DV composition and
    /// applies the per-frame RPU to the pixels before they reach the panel, instead of handing the panel the
    /// static-metadata HDR10 base layer it hands it today.
    ///
    /// The bitstream is untouched: only the container's claim about it changes. What makes that survivable is
    /// that a P8.1 RPU already carries the mapping out of its HDR10 base layer, so the composer does not need
    /// the container to tell it what the base layer is. What makes it experimental is that this is not what
    /// the profile field means, and a tvOS build that reads the base layer's colorimetry from the profile
    /// rather than the RPU would render IPT out of YCbCr (the green/violet cast of AE#4 and AE#176).
    ///
    /// Ignored when the display does support Dolby Vision, and applies to HEVC Profile 8.1 only. Reported by
    /// DrHurt against a Samsung HDR10 panel.
    public var forceDolbyVisionOnNonDVDisplay: Bool

    /// A `DolbyVisionHandling`. Default `.automatic`. `.baseLayerOnly` presents the HDR10 / HLG base layer
    /// of a Dolby Vision source and leaves the Dolby Vision out of the container, on every display: the
    /// route a host offers as "Dolby Vision: off (HDR10)".
    ///
    /// The case it exists for is a source whose Dolby Vision is wrong and whose base layer is right. A
    /// remux that carries a Profile 7 RPU under a container record claiming Profile 5 is the reported
    /// shape: the record says IPT-PQ-c2, the VUI says BT.2020 YCbCr PQ, and a player that believes the
    /// record decodes YCbCr as IPT (the green / violet cast of AE#4 and AE#176). No player can tell which
    /// half is lying from the container alone, so the choice is the host's, and a host that offers it
    /// offers it per title.
    ///
    /// Applies to the profiles whose base layer is a YCbCr HDR signal (HEVC 7 / 8.1 / 8.4, AV1 10.1 /
    /// 10.4) and to a Profile 5 record whose VUI declares one; a Profile 5 or AV1 10.0 whose VUI says
    /// nothing has no base layer to present and keeps its route. A tuning field: correctable on the
    /// playing session through `reloadAtCurrentPosition(applying:)`. Takes precedence over
    /// `forceDolbyVisionOnNonDVDisplay`, which asks for the opposite. The software path decodes the base
    /// layer alone in any case, so there it only lifts the Profile 5 refusal (#176) for a record the VUI
    /// contradicts.
    public var dolbyVisionHandling: DolbyVisionHandling

    /// Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. Default `true`. When `false`, engine routes HDR sources through the media playlist (auto-tonemap path) because AVKit cannot switch the panel.
    public var matchContentEnabled: Bool

    /// Host assertion that the panel is presenting HDR right now. Default `false` (conservative SDR branch).
    /// When set, master playlist VIDEO-RANGE=PQ and SUPPLEMENTAL-CODECS=dvh1 are accepted upfront for the
    /// HDR10-to-DV upgrade.
    ///
    /// AE#459: this is an OR term over the engine's own readout, not a replacement for it, and it counts on
    /// every platform rather than only where the host suppresses display criteria. The readout it backs up
    /// is `UIScreen.currentEDRHeadroom > 1`, which answers only around a dynamic-range TRANSITION: an Apple
    /// TV whose output format is locked to HDR never makes one, so it reads as an SDR panel forever, and on
    /// tvOS 27 the property has stopped answering at all on at least one box. A host that knows the panel is
    /// in HDR (a user setting, its own probe) says so here.
    public var panelIsInHDRMode: Bool

    /// Serve the HDR master to an HDR-eligible display whose panel state is unproven, and let AVFoundation's
    /// acceptance or refusal be the readout. Default `true`, VOD only.
    ///
    /// AE#459: `UIScreen.currentEDRHeadroom` is the only tvOS property that ever reported the panel's mode,
    /// and it is measurably unreliable. On one Apple TV 4K 3rd gen on tvOS 26.6 it read a flat 1.00
    /// across 46 samples of HDR content while the TV's own info display reported HDR, and later the same
    /// day, same box, same output format, same title, it read 1.20. What moves it is not established: the
    /// output mode was blamed and then refuted by running the comparison back the other way. The cost of a
    /// wrong 1.00 is not the picture, which media-direct carries unchanged, but the manifest: the SUBTITLES rendition, the AUDIO rendition that
    /// is the only place AVFoundation reads an HLS language from, and SUPPLEMENTAL-CODECS.
    ///
    /// Refusal costs one in-place media fallback, measured at 223 ms end to end on that box (`-11868` after
    /// 54 ms, zero `errorLog` events, position kept, no visible black frame), and it is latched for the
    /// process, so a genuinely SDR panel pays it once rather than per title. A panel that proves itself
    /// through the headroom never attempts anything.
    ///
    /// Turn it off for a host that knows its display is SDR and would rather not spend that once. Live
    /// never attempts regardless of this flag: a live fallback is a rejoin at the edge rather than a
    /// restored position, and that cost is unmeasured.
    public var attemptsHDRMasterOnUnprovenPanel: Bool

    /// Host assertion that this display presents Dolby Vision. Default `false`. Not a capability the engine
    /// observed, a claim the host makes about hardware it knows.
    ///
    /// AE#493: `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode capability
    /// table at all, and `eligibleForHDRPlayback` answers HDR10 and HLG but cannot answer this one. Setting
    /// it publishes `videoFormat = .dolbyVision` and asks the tvOS display-criteria handshake for `dvh1`.
    /// HDR support rides along because DV is an HDR format; HDR10 and HLG capability are not implied.
    ///
    /// It no longer decides the PACKAGING of a Profile 5, 8.1 or 8.4 source. 6.72.0 gave the non-DV branch
    /// its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, so those three grades serve byte-identical
    /// manifests and segments either way (measured on macOS against the matched Dolby grades: master,
    /// media playlist, `init.mp4` and `seg0.mp4` md5-identical with and without the claim). Profile 7,
    /// whose RPU is converted to 8.1 per packet, and AV1 Dolby Vision, whose record is read only on a
    /// display that takes it, are still gated on it.
    ///
    /// A wrong claim is cheap on the class of failure the engine classifies, and that class is not the whole
    /// space. AVPlayer refusing the master with -11868 / -11848 fails the ITEM, and the engine falls back to
    /// the media playlist once, in place, at the same position, where AVPlayer tone-maps the base layer;
    /// correctable mid-session through `reloadAtCurrentPosition(applying:)`. Two measured limits on that:
    /// on macOS the wrong claim was not refused at all (a DV master on a Mac with no DV display plays,
    /// macOS 26.5.2), and a stall is not an item failure, so the fallback above does not fire for the
    /// -15628 an HDR10-only panel showed on the DV packaging in May 2026 (AE#4). That stall is no longer
    /// the claim's to own: since 6.72.0 / 6.73.0 the same packaging reaches such a panel with or without
    /// it, and it did not reproduce on tvOS 26.6. What the claim can still move on the route is HDR
    /// readiness, since `supportsHDR` rides along, and that is the -11848 the fallback does catch.
    ///
    /// Asserting also turns `forceDolbyVisionOnNonDVDisplay` off, since that one is gated on the display
    /// having no DV. On tvOS, DV composition on a panel without Dolby Vision is what that flag is for, and
    /// its packaging is the one device-verified on that panel class (AE#455).
    public var panelPresentsDolbyVision: Bool

    /// Bridge encoder for codecs that cannot stream-copy into fMP4 (TrueHD, DTS, DTS-HD MA, MP3, Opus, EAC3-from-MKV-without-dec3-extradata).
    ///
    /// - `.surroundCompat` (default): EAC3 128 kbps/ch. Works on soundbars (Sonos Arc, Samsung HW-Q, Bose). Lossy; caps 7.1 to 5.1.
    /// - `.lossless`: FLAC up to 7.1. Needs a sink that accepts multichannel LPCM (Denon / Marantz / NAD AVRs); stereo-only routes silently downmix.
    public var audioBridgeMode: AudioBridgeMode

    /// Treat the source as a live stream. `seek(to:)` becomes a no-op; `isLive` surface reflects this for host UIs. Set explicitly: auto-detection from `probe.durationSeconds == 0` is too noisy (VOD MKVs with broken duration headers). Default `false`.
    public var isLive: Bool

    /// Lean audio-only path (FFmpeg + AVSampleBufferAudioRenderer): skips video probe, display-criteria handshake, HLS/muxer/loopback stack. Also set automatically when the probe finds no video stream. Default `false`.
    public var audioOnly: Bool

    /// DVR rewind window in seconds; nil = live-only (seek is a no-op). Engine retains roughly this much past content disk-backed, bounded by the session disk budget (a quarter of the free space, at most 2 GiB), so a long window on a high-bitrate channel or a small volume holds less than it asks for. Suggested default: 1800. Ignored when `isLive == false`. Default nil.
    public var dvrWindowSeconds: Double?

    /// LL-HLS blocking-reload (`#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD`) override for live loopback sessions.
    /// nil (default) = auto: for a `LiveIngestSourceInfo` custom reader the engine derives eligibility from
    /// the OBSERVED upstream arrival cadence (off until sustained discipline is proven, permanently off once
    /// a burst is seen), so a relay/IPTV origin that advertises a normal TARGETDURATION but delivers segments
    /// in irregular batches no longer loops on `-15410`; for a plain-`url:` live source with no cadence signal
    /// (e.g. a Jellyfin real-time transcode) it stays on. `true`/`false` force it regardless of cadence. The
    /// TARGETDURATION floor still tracks observed cadence either way. Ignored for `nativeRemoteHLS` and VOD.
    /// Default nil (AetherEngine#167).
    public var liveBlockingReload: Bool? = nil

    /// Live-join latency profile for loopback live sessions (raw TS over HTTP, live ingest). `.standard`
    /// (default) cuts ~4s segments, so the served TARGETDURATION lands at >= 6 and the spec-mandated
    /// live-edge holdback (`HOLD-BACK` >= 3 x TARGETDURATION, RFC 8216bis) the first manifest is gated on
    /// (AE#189) becomes >= 18s, which a strict-realtime origin can only fill in wall-clock time (10-18s of
    /// black on an IPTV zap). `.fastZap` cuts at every keyframe past 0.5s instead: segments quantize to the
    /// source keyframe cadence, TARGETDURATION follows the real GOP length with 1.5x headroom over the
    /// longest GOP seen before the seal (a broadcast's GOPs are irregular and each segment is one whole
    /// GOP, AE#670), and the holdback shrinks with it: 1 s GOPs serve TARGETDURATION 2, a 6 s holdback.
    /// The first serve still prefers the full holdback, but after two finalized segments a
    /// strict-realtime source gets one observed-segment grace clamped to 0.5...2.0s, then may serve a
    /// shallow first window. This bounds black-screen startup but may produce one early `-16832` or a
    /// short rebuffer. `.standard` retains the full-holdback guarantee. A smaller TARGETDURATION also
    /// tightens AVPlayer's unchanged-playlist patience and live-edge buffer, so an origin that stalls or
    /// bursts mid-stream is likelier to rebuffer or error; opt in for zapping UX, keep `.standard` for
    /// lean-back viewing. Ignored for `nativeRemoteHLS` and VOD. Default `.standard`
    /// (AetherEngine#195/#208).
    public var liveJoinProfile: LiveJoinProfile = .standard

    /// Cut AVPlayer's stall-avoidance wait short at the live join, once it is holding on media it has
    /// already buffered. Live sessions on the AVPlayer-backed paths only. Default `false` (AE#440).
    ///
    /// A live join can present its first frame and then hold it still. AVPlayer decides for itself how
    /// much cushion it wants before letting the rate roll (`AVPlayerWaitingToMinimizeStallsReason`), and
    /// against a source delivered at 1x that cushion can only be bought in wall-clock time. Measured by a
    /// host on an Apple TV 4K over 11 consecutive tunes of a raw MPEG-TS channel: 1.5 to 2.8 s of
    /// bit-static picture on 9 of them, with the engine's clock advancing and `state` already `.playing`
    /// throughout. Nothing set on the item shortens it (`preferredForwardBufferDuration` measured inert),
    /// because the wait is a rate evaluation and not a buffer target.
    ///
    /// Set, the first such hold of a session is cut short with `playImmediately(atRate:)`, which starts on
    /// the media already buffered. It fires at most once per load, only while the item's buffer is
    /// non-empty (`AVPlayer.h`: over an empty buffer that call behaves as a stall instead, which is the
    /// shape that leaves rate parked at 0), and never for the `EvaluatingBufferingRate` reason, which is
    /// the brief monitoring period Apple documents as not worth showing a spinner for. Every later hold in
    /// the session keeps AVPlayer's own policy, so a mid-stream rebuffer is untouched.
    ///
    /// The trade is the one `.fastZap` already prices, from the other end: playback starts on a thinner
    /// cushion, so a source that hiccups right after the join rebuffers where it would otherwise have
    /// started later and played through.
    ///
    /// Default `true` since 6.55.0, on a device A/B rather than an argument. Two runs of ten channel
    /// changes on the reported stack: press-to-moving-picture fell from 6.4 / 6.5 / 7.2 s to
    /// 4.3 / 4.8 / 5.1 / 5.6 s, first PICTURE was unchanged at 3.4 to 3.9 s in both arms (so what it
    /// removes is exactly the frozen tail), and stalls and dropped frames stayed at zero in both. The
    /// buffer was sampled across every hold in the control arm and read non-empty with 3.7 to 4.9 s
    /// ahead throughout: on that stack the hold is always AVPlayer waiting on its own rate estimate,
    /// never starvation, which is why cutting it short cost nothing. Cold joins were identical in both
    /// arms, the guards keeping the lever out of the starved case as designed. Set `false` to keep
    /// AVPlayer's own policy for the join.
    public var liveJoinStartsImmediately: Bool = true

    /// [MovieClaw patch P2] The AE#440 one-shot for VOD starts: when AVPlayer holds a VOD start in
    /// `ToMinimizeStalls` over a proven, non-empty buffer of at least
    /// `minimumLiveJoinBufferAhead` seconds, cut the hold short once with `playImmediately`.
    /// The loopback producer runs far ahead of 1x, so the rate estimate AVPlayer waits on only
    /// delays a start whose cushion is already there (0.2 to 0.6 s on device). Same four guards as
    /// the live lever; default `false`.
    public var vodStartsImmediately: Bool = false

    /// [MovieClaw patch P11] 起播音轨按「第几条音轨」指定（容器里音轨的顺序，从 0 数）：探测完换成流下标，
    /// 首帧就是这条轨，不用起播后再 `selectAudioTrack` 重载一次（真机蓝光镜像为此起播 2.5 → 4.2 秒）。
    /// 宿主记着的是与服务端同口径的 embedded:N，事先不知道流下标，所以按序号给。显式的
    /// `audioSourceStreamIndex`（换轨、重建时恢复当前轨）照旧优先；序号越界时不起作用。默认 nil
    public var audioTrackOrdinal: Int? = nil

    /// [MovieClaw P22] 片源字节缓存的键（见 `SourceByteCache`）：同一个片源在这一场里每个字节只下一次——
    /// 换音轨、回前台的整场重建，往回跳的重产，都从本机拿已下过的字节。取流地址每次带新令牌，所以由宿主
    /// 给一个稳定的键（MovieClaw 用「文件 id + 大小」）；nil = 不缓存（上游行为）。只作用于 URL 片源
    public var sourceCacheKey: String? = nil

    /// [MovieClaw P58] 服务端给的 Matroska 精简索引（只含视频轨索引点，见 `MatroskaHostCues`）：主播放的解复用器读
    /// Cues 时直接给它，不再下载原索引。nil = 照旧（上游行为）。只作用于 URL 片源的主播放读取器
    public var matroskaCues: MatroskaHostCues? = nil

    /// Whether `play()` may move a behind-live playhead by itself. Default `true`, which is the historical
    /// behaviour (AE#444).
    ///
    /// Resuming a live session that has fallen behind, the engine seeks: to the live edge when the source
    /// has no DVR window and the playhead is more than 45 s back (a live-only source retains seconds, and
    /// the position is simply gone), and to the bottom of `seekableLiveRange` plus a margin when a DVR
    /// window has slid past the playhead. Both are recoveries from a position that no longer exists.
    ///
    /// A host with live-pause semantics of its own has its own answer to the same question, and the
    /// implicit seek makes that answer unreachable: it runs inside `play()` and lands before the host can
    /// decide. Set `false` and `play()` moves nothing. The engine still publishes `behindLiveSeconds`,
    /// `seekableLiveRange` and `isAtLiveEdge`, and `seekToLiveEdge()` performs the same recovery on
    /// request, so the policy moves to the host rather than disappearing.
    ///
    /// The trade is that nothing then rescues a playhead the window has evicted: resuming there plays
    /// from wherever the source can still serve, so a host that turns this off owns the eviction case too.
    public var clampsLiveResumeToWindow: Bool = true

    /// AVPlayer item from the remote URL directly: no demuxer probe, no loopback. AVPlayer manages live
    /// edge / reconnect. Built for live (`isLive: true`, Jellyfin live `master.m3u8`); a remote HLS VOD
    /// URL lands here too, whatever this says, because the loopback path reroutes it (AE#154). Default
    /// `false`.
    ///
    /// On this route the clock is AVPlayer's item time, and that is not always the media time of the
    /// frame on screen (AE#616). An origin whose playlist places a segment at its slot while the segment
    /// starts at the keyframe before it (a Jellyfin transcode restarted by a seek) makes item time lead
    /// the picture by that gap. `clock.sourceTime` subtracts the gap while one of the renditions the
    /// engine injects for `LoadOptions.externalSubtitles` (#316) is selected and presenting; without one
    /// it is item time. `clock.currentTime` and `seek(to:)` stay on item time either way.
    public var nativeRemoteHLS: Bool

    /// Reroute a live `nativeRemoteHLS` session onto the loopback live-ingest path when AVPlayer reaches
    /// readyToPlay but never builds a video track for a master that advertises one. That signature means
    /// the master delivers HEVC in MPEG-TS segments, which AVFoundation's HLS demuxer does not support
    /// (the HLS Authoring Spec sanctions HEVC only in fMP4); the ingest path remuxes TS to fMP4 and plays
    /// the same stream. Live-only; finite HEVC-in-MPEG-TS VOD is classified before the native mount and
    /// uses the seekable #268 ingest instead. `httpHeaders` ride along onto the ingest fetches. Default
    /// `true` (AetherEngine#168).
    ///
    /// AE#293: the same verdict is also read off the source while the mount runs (the playlist plus the
    /// head of one segment), so the reroute no longer waits out the watchdog grace and a media playlist
    /// URL with no master to judge is covered as well. That read is gated on the master advertising a
    /// codec sanctioned in fMP4 only, so an H.264 channel never spends the requests; this flag disables
    /// it along with the watchdog.
    public var nativeRemoteHLSIngestFallback: Bool

    /// Emit raw ASS event lines (`ReadOrder,Layer,Style,...,Text` including override tags) instead of plain-text extraction. Opt-in for hosts that render ASS styling themselves; pair with `TrackInfo.assHeader`. Only affects ASS / SSA codecs, on embedded and sidecar tracks alike: libavcodec normalises SubRip, WebVTT and mov_text through `ff_ass_add_rect` as well, so those carry an ASS payload the engine could emit but never does, and a session that mixes an ASS track with a SubRip one needs no reload to cross between them (AE#587). Default `false` (AetherEngine#30).
    public var preserveASSMarkup: Bool

    /// Declare a mov_text track in the init moov so text subtitles survive PiP / AirPlay / external display via AVMediaSelection. Bitmap codecs (PGS / DVB / DVD) excluded automatically. Default `false` (#55).
    public var prepareNativeSubtitles: Bool = false

    /// Start the native WebVTT subtitle readers eagerly at load (instead of lazily on `setNativeSubtitleSelected`), so the `/subs_N_M.vtt` segments are already populated when AVKit fetches them under a host-independent selection (e.g. an `EXT-X-MEDIA ... DEFAULT=YES` rendition that AVKit auto-selects). Equivalent to a fully-populated static VOD subtitle file. Only meaningful with `prepareNativeSubtitles`. Default `false` (Sodalite#32 probe).
    public var eagerNativeSubtitleReaders: Bool = false

    /// Serve an I-frame rendition (`EXT-X-I-FRAME-STREAM-INF`) next to the master, so a stock `AVPlayerViewController` shows its own scrub thumbnails and can scan on I-frames, with no host code (AE#682). One keyframe per served segment, at the source's full resolution. Costs a second reader on the source for the whole session, opened shortly after load because AVKit asks for the first keyframe before anyone scrubs. Silently absent, with one log line naming the reason, when the session cannot answer every listed keyframe: live, a source without a trustworthy keyframe index (MPEG-TS), `sequentialOrigin`, `heldSourceConnection`, an origin limited to one request, a disc source, a custom reader that cannot clone, or media-playlist routing. A host with its own transport bar wants `scrubThumbnail` instead. A tuning field: correctable through `reloadAtCurrentPosition(applying:)`. Default `false`.
    public var serveIFramePlaylist: Bool = false

    /// Confirm E-AC-3 JOC (Dolby Atmos) on this session's audio tracks, so `audioTracks` carries an honest
    /// `TrackInfo.isAtmos` for a badge instead of the pre-decode guess. No container reliably declares JOC, so
    /// this runs the same bounded decode pass as `AetherEngine.probeDetectingAtmos` (see `AtmosDetectionOptions`
    /// for the caps) on a second handle to the source, once per E-AC-3 track, and republishes `audioTracks` as
    /// tracks confirm. It starts only after the session is up and runs at utility priority, so it never delays
    /// the first frame. Skipped for live sources and for forward-only custom readers, which cannot be re-read.
    /// Default `false` (#214 follow-up).
    public var confirmAtmos: Bool = false

    /// Preferred subtitle languages (ISO 639-1/2) used ONLY to choose which native WebVTT rendition is marked DEFAULT=YES in the master, so a host-selected legible track renders (AVKit hides a non-default legible selection as mute-only). Read back as `nativeSubtitleDefaultOrdinal`. Unlike `preferredSubtitleLanguages` this does NOT auto-activate the host-overlay subtitle path, so it won't double up with the native render. Default empty (Sodalite#32).
    public var nativeSubtitlePreferredLanguages: [String] = []

    /// The origin fabricates range answers: any `Range: bytes=X-` gets a plausible-looking
    /// `206 Content-Range: bytes X-.../total`, but the body is positioned on a coarse internal
    /// chunk boundary rather than byte X (IPTV timeshift/catch-up archives are the motivating
    /// case; a device trace showed ~1.9 s of content lost at every 32 MB range rotation, heard
    /// as a once-a-minute audio desync). Headers cannot expose the lie, so this is a caller
    /// declaration, not a probe. Only byte 0 is addressable: the reader runs its forward-only
    /// streaming mode on one long-lived unranged GET - no bounded-range windowing, no
    /// suffix/tail probes, no detour fills, no byte-offset reconnects - and the demuxer's pb is
    /// non-seekable, so byte seeking is unavailable and a dropped connection surfaces as a read
    /// error (EOF would read as end-of-media) for the host to re-request. FFmpeg's tail-read
    /// duration estimate is skipped with the rest of the ranged reads; pair with
    /// `declaredDurationSeconds` on VOD or the load fails with `zeroDuration`. Default `false`.
    public var sequentialOrigin: Bool = false

    /// Most requests the reader may have open against this source's origin at once, across every
    /// path it fetches on (the pump's ranges, detour blocks, size probes, the tail prefetch and the
    /// subtitle side reader), AE#377.
    ///
    /// nil (default) means the engine counts but does not cap, and lowers the ceiling on its own if
    /// the origin answers 429/503/509. Set it when the provider states a limit: some CDNs meter
    /// concurrency per signed link and document it ("one connection for large downloads"), and
    /// being told beats being refused a few times first. `1` serialises everything and additionally
    /// switches off the speculative parallel paths, which exist only to overlap with the pump.
    ///
    /// Not a `URLSession` connection cap, deliberately. `httpMaximumConnectionsPerHost` bounds TCP
    /// connections per session, and over HTTP/2 every request of a session is multiplexed onto one
    /// of them, so such a cap bounds nothing while the origin still counts the requests. This
    /// counts requests. The engine logs the negotiated protocol once per origin, so a report can
    /// say which case an origin is.
    ///
    /// #450: it is also the ONLY ceiling now. The reader's long-lived transport pool used to allow
    /// two connections per host, process-wide across every reader and every playback surface, which
    /// made `nil` here ("count, do not cap") untrue from the third concurrent open-ended read on,
    /// and untrue in silence: a parked request has no callback, no error and no metrics. Several
    /// engines on one origin are bounded by this value and by what the origin refuses, nothing else.
    public var maxConcurrentSourceRequests: Int? = nil

    /// Ask the source ONCE and pull it, instead of ending the connection at the reader's window
    /// high water and asking again every 8 to 16 MB of drain (#377).
    ///
    /// Set it when the origin punishes repeated requests rather than concurrency. Some CDNs refuse
    /// new requests for minutes at a stretch while serving an already open connection at full
    /// rate; against one of those, a reader that asks per drain cycle will ask inside a refusal
    /// window on any long file, however large its ranges are (measured at the reporting origin:
    /// 32 MB ranges raised to 256 MB, eight times fewer requests, the refusals unchanged). Holding
    /// the connection is the only lever that removes the ask, which is why this exists as well as
    /// `maxConcurrentSourceRequests`: that one bounds how many requests are in flight, this one
    /// stops there being a second request at all.
    ///
    /// What it costs, and why it is opt in rather than the default:
    ///
    /// - **HTTP/1.1 only.** The framing is the engine's own over a demand-driven stream task, with
    ///   no ALPN negotiation, so an origin that serves only HTTP/2 is out of scope for it.
    /// - **The system proxy configuration is not in this read path.** A stream task connects to a
    ///   host and port; `URLRequest` proxy handling does not apply.
    /// - TLS is the OS's, through the same host trust decision as every other engine session, but
    ///   it has not been exercised against a self-signed origin.
    /// - A viewer who pauses ends the connection after five seconds, and resuming costs one
    ///   request at the frontier. A held flow that nobody reads is the process-wide Network
    ///   .framework starvation of #310, and a pause is where its worst episode came from.
    ///
    /// Applies to the playback reader. The subtitle and enrichment side readers keep the default
    /// transport: they park deliberately for minutes, which is the one shape a held connection
    /// must not take.
    ///
    /// Names the session rather than tuning it: the transport is chosen when the source is opened,
    /// so a reload cannot change it. Default false, which is every reader shipped so far.
    public var heldSourceConnection: Bool = false

    /// Trusted media duration in seconds, overriding the container/estimate-derived value (same
    /// trust family as the disc MPLS/IFO override, AE#105). Required alongside
    /// `sequentialOrigin` for VOD sources: with the tail read gone the demuxer resolves no
    /// duration, and the caller usually knows the real one (an IPTV catch-up request names its
    /// window length outright). nil keeps the demuxer's own value. Default nil.
    public var declaredDurationSeconds: Double? = nil

    /// Caller-bounded demux probe budget in bytes, mapped to `AVFormatContext.probesize` for the main playback open. nil keeps the engine default (50 MB). A smaller value speeds `find_stream_info` on slow remote sources whose sparse streams (PGS, mjpeg cover art) would otherwise read to the full budget. An over-tight budget fails OPEN only while some stream resolves inside it: `find_stream_info` then returns success with a logged warning, and the session loads with late-resolving tracks silently missing. When NO stream resolves inside the budget it returns an error (`-1`, rendered "Operation not permitted") and the load throws. `[Demuxer] open timings` prints the connect / open_input / find_stream_info split of every open, which is the measurement to take before and after tightening it (AE#678). The value is written to the context verbatim (FFmpeg's AVOption floor of 32 is bypassed), so validate track presence after load if you set this aggressively. The routing `probe(url:)` API and still extraction keep the full budget; the embedded subtitle side-demuxer caps its own probe (it only needs codec ids, not resolved sparse tracks) and tightens to this value when it is smaller (#76). Default nil (#68).
    public var probesize: Int64?

    /// Caller-bounded demux probe budget in microseconds, mapped to `AVFormatContext.max_analyze_duration` for the main playback open. nil keeps the engine default (60 s). Pass a positive value to set an explicit cap; do NOT pass `0` expecting "no cap": FFmpeg maps `0` to a container-dependent heuristic (~5-7 s for MPEG-TS, longer elsewhere) that is SHORTER than the engine's 60 s default. Same scope and fail-open trade-off as `probesize`. Default nil (#68).
    public var maxAnalyzeDuration: Int64?

    /// Ordered audio-language preference (ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`). When non-empty and no explicit `audioSourceStreamIndex` is passed to `load`, the engine resolves the first-frame audio track from its single internal probe: the first track whose language matches an entry (preferences scanned in order, case-insensitive, ISO 639-1/2 B+T and English-name synonyms), falling back to the container default when none match. This lets a host honor a saved language preference on the first frame from one open, instead of probing separately or reloading via `selectAudioTrack` after load (#72). An explicit `audioSourceStreamIndex` still wins. Default empty.
    public var preferredAudioLanguages: [String]

    /// Ordered subtitle-language preference (ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`).
    /// When non-empty, at the end of a successful load the engine activates the best subtitle track whose
    /// language matches a preference (preferences scanned in order, case-insensitive, ISO 639-1/2 B+T and
    /// English-name synonyms; within the matched preference, full subtitles rank over SDH / forced /
    /// commentary and text over bitmap, from container dispositions); no match leaves subtitles OFF (the
    /// default). This drives the host-overlay
    /// path (`subtitleCues`, equivalent to a `selectSubtitleTrack` call) and publishes the resolved track
    /// via `activeSubtitleTrackIndex`. Where `preferredAudioLanguages` saves a real cost (its track is muxed
    /// into the loopback HLS at the first frame, so a late pick forces a pre-probe or reload), this is pure
    /// convenience: subtitles are activated post-load by a side demuxer at no reload or pre-probe cost, so it
    /// only spares a host from language-matching `subtitleTracks` itself. A later host `selectSubtitleTrack`
    /// / `clearSubtitle` overrides
    /// it. Independent of `prepareNativeSubtitles`, whose default selection stays host-driven via
    /// `setNativeSubtitleSelected`. Default empty (#73).
    public var preferredSubtitleLanguages: [String]

    /// External subtitle files to register at load (AetherEngine#88). Each appears in
    /// `subtitleTracks` (id = `externalSubtitleTrackIDBase` + array index, `isExternal == true`),
    /// participates in `preferredSubtitleLanguages` ranking, and, with `prepareNativeSubtitles`,
    /// joins the native WebVTT rendition (PiP). Tracks added later via `addExternalSubtitleTrack`
    /// are overlay-only until the next load. Default empty.
    public var externalSubtitles: [ExternalSubtitleTrack]

    /// Forward-buffer window of the loopback HLS session, in segments (one segment ~ 4 s): how far the
    /// producer may race ahead of the playhead AND how many forward segments the on-disk cache keeps
    /// resident (the two are coupled by construction, see `SegmentCache`). Larger values buffer more of
    /// the source up front (network-dropout robustness) at the cost of disk (segments are disk-backed,
    /// mmap reads) and ahead-of-time demux work: 4K HEVC runs ~ 10 MB per segment, so 150 segments can
    /// occupy ~ 1.5 GB on disk. The engine clamps to 4...2700 (below 4 AVPlayer's own ~ 5-7-segment
    /// prefetch would starve, see `LiveWindowSizing.minSafeSegments`; 2700 ~ 3 h is a sanity bound that
    /// covers a whole feature film, so a host's "buffer without limit" option can pass `Int.max`).
    /// Beyond the historical 150 the real bound is bytes, not segments: the prefetch runs until it
    /// fills the session retention budget (a quarter of the tmp volume's free space, see
    /// `HLSVideoEngine.sessionRetentionBudgetBytes`) and then tracks the playhead, so a large window
    /// buffers as much of the source as safely fits rather than a fixed count (#207). nil keeps the
    /// historical default of 10 (~ 40 s). Ignored for `nativeRemoteHLS`, where AVPlayer talks to the
    /// remote server directly.
    public var forwardBufferSegments: Int?

    /// [MovieClaw P25] 分片缓存的后方窗口（段数），nil = 默认 20。存储紧张时由宿主和 `forwardBufferSegments`
    /// 一起收小，让自研引擎在剩余空间不多时照样能放（最少 2 段，见 `HLSVideoEngine.clampedBackwardWindow`）
    public var backwardBufferSegments: Int?

    /// Autostart at load completion. Default `true`: every load path ends in `host.play()` and a
    /// `.playing` state (current behavior, byte-identical). Set `false` to mount PAUSED: a host that
    /// holds a pause at mount (synchronized-start lobby that loads several devices and starts them on
    /// a signal, or a hold-at-mount / resume prompt) no longer eats an engine-initiated resume it has
    /// to claw back. With `false` the load skips the terminal `host.play()` (and, on the native VOD
    /// path, the SDR->HDR cold-start readiness gate, which is an autostart-path recovery), leaves
    /// `playIntent` false, and settles `.loading -> .paused` via the existing `host.$isReady`
    /// waypoint; the host resumes later with `play()`. Same declared-vs-real family as #122/#123 (#124).
    public var autoplay: Bool = true

    /// AE#464: audio presentation offset for this session, in seconds. Positive presents audio
    /// LATER relative to video, negative earlier. Default 0.
    ///
    /// A lip-sync correction belongs to the viewer's chain, not to the file, so this is the value a
    /// host sets once per setup and the engine honours for the session (and across the rebuilds a
    /// session makes on its own). Applied on `.loopback` and `.software`; on `.remoteBypass` and
    /// audio-only sessions the engine does not hold the timestamps and says so rather than pretending.
    /// Clamped to `AudioDelayPolicy.maxAbsSeconds`. Correct it mid-session with
    /// `AetherEngine.setAudioDelay(_:)`, which is the same value seen from the other end.
    public var audioDelaySeconds: Double = 0

    /// Teletext caption page for `dvb_teletext` subtitle decode. nil (default) = libzvbi auto-detect
    /// (`txt_page=subtitle`); an explicit page (e.g. 801 for AU) targets channels whose caption page
    /// libzvbi does not flag as a subtitle page. Only affects teletext streams (#107).
    public var teletextPage: Int? = nil

    /// Deinterlacer for the software-decode path: `.auto` (default) tries the Metal/VideoToolbox
    /// hardware graph and falls back to software bwdif; `.software` forces the CPU path. See
    /// `DeinterlaceMode`.
    public var deinterlaceMode: DeinterlaceMode = .auto

    /// Cadence of the hardware deinterlacer: `.field` (default) doubles output to field rate
    /// (50/60 fps), `.frame` keeps frame rate. Ignored by the software fallback (always frame
    /// rate). See `DeinterlaceFieldRate`.
    public var deinterlaceFieldRate: DeinterlaceFieldRate = .field

    /// AE#461: which decode path this session runs on when the host needs to overrule the engine's
    /// own routing. `.automatic` (default) leaves the routing alone. `.software` serves the source
    /// through `SoftwarePlaybackHost` (libavcodec / dav1d) whatever the routing concluded, scoped to
    /// this session, and without costing the source anything: seeks, the mid-session audio switch and
    /// the title switch all still work, unlike the forward-only reader that was previously the only
    /// way onto that host.
    ///
    /// The lever exists because `VTCapabilityProbe.canHardwareDecode` FAILS OPEN by design (four
    /// classes it cannot classify keep the native path), which is the right default and occasionally
    /// wrong: if VideoToolbox then cannot build a decoder for what arrives, the item reaches
    /// `readyToPlay` and renders nothing. In-band parameter sets (`hev1` / `avc1` with an empty
    /// config record) are the class where the deciding evidence genuinely is not present at load
    /// time, and a stream whose parameter sets turn undecodable mid-play has no other in-place
    /// answer. Pair with `reloadAtCurrentPosition(applying:)` (#460) to correct a running session.
    ///
    /// One-way on purpose: there is no `.native`. Every route the engine sends to software it sends
    /// there because the native path cannot serve it (AV1 without hardware decode, VP9, a
    /// forward-only source, MVC carriage), so forcing native past those buys a black screen.
    ///
    /// `.software` does not suspend the guards downstream of the routing decision, and must not: a
    /// source whose only signal is IPT-PQ-c2 (Dolby Vision HEVC P5, AV1 P10.0) still fails the load
    /// with `dolbyVisionUnplayableOnSoftwarePath` rather than decoding as YCbCr and rendering
    /// green/purple, and a demuxed-audio live source still fails rather than playing silent.
    /// `nativeRemoteHLS` is a different route entirely (AVPlayer plays the remote playlist, nothing
    /// is demuxed), so this has nothing to act on there and the engine says so in the log.
    public var preferredDecodePath: DecodePath = .automatic

    /// Whether a native session AVPlayer refuses on its merits may be rebuilt on the software path
    /// (AE#561). Default `true`.
    ///
    /// When AVPlayer fails the item with a verdict on the MEDIA (`CoreMediaErrorDomain`), every native
    /// recovery answers the same bytes again, so the engine spends one rebuild per session on
    /// `SoftwarePlaybackHost`, whose libavcodec skips the frame Apple's parser refused. `false`
    /// declines that rung: the failure surfaces as `.error` with `PlaybackErrorKind.nativeItemFailed`,
    /// the way it did before 7.9.0, for a host that re-plans a failing title with a ladder of its own
    /// (AE#629). Either way `softwarePathEscalations` says when the rung is taken.
    ///
    /// A tuning field: correctable on a playing session through `reloadAtCurrentPosition(applying:)`.
    public var escalatesToSoftwarePath: Bool = true

    /// Sodalite#175: `.secondary` for an engine running beside the one that owns the panel. Default `.primary`.
    public var sharedOutputRole: SharedOutputRole

    /// ENGINE-INTERNAL: marks this load as a live REJOIN (`reloadAtCurrentPosition`). Not settable from the public initializer. When true, the native load path skips its explicit initial seek so AVPlayer picks edge-minus-holdback (see `LiveReloadPolicy`); without it the reloaded item can wedge in `waitingToPlay` against Jellyfin's re-served backlog. Meaningful only when `isLive` is true.
    var isLiveRejoin: Bool = false

    /// ENGINE-INTERNAL (#170): subtitle session state a session-preserving reload
    /// (`reloadAtCurrentPosition`) carries into this load. Not settable from the public
    /// initializer. When present, the #88 registration point seeds the previous session's
    /// external registry id-exactly instead of re-registering `externalSubtitles`, and the
    /// host's subtitle authority flag carries over. Consumed by the load; never persisted.
    var subtitleSessionCarryover: SubtitleSessionCarryover? = nil

    public init(
        omitCriteriaColorExtensions: Bool = false,
        suppressDisplayCriteria: Bool = false,
        httpHeaders: [String: String] = [:],
        keepDvh1TagWithoutDV: Bool = false,
        forceDolbyVisionOnNonDVDisplay: Bool = false,
        dolbyVisionHandling: DolbyVisionHandling = .automatic,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        attemptsHDRMasterOnUnprovenPanel: Bool = true,
        panelPresentsDolbyVision: Bool = false,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLive: Bool = false,
        audioOnly: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveBlockingReload: Bool? = nil,
        liveJoinProfile: LiveJoinProfile = .standard,
        liveJoinStartsImmediately: Bool = true,
        clampsLiveResumeToWindow: Bool = true,
        nativeRemoteHLS: Bool = false,
        nativeRemoteHLSIngestFallback: Bool = true,
        preserveASSMarkup: Bool = false,
        prepareNativeSubtitles: Bool = false,
        eagerNativeSubtitleReaders: Bool = false,
        serveIFramePlaylist: Bool = false,
        confirmAtmos: Bool = false,
        nativeSubtitlePreferredLanguages: [String] = [],
        sequentialOrigin: Bool = false,
        maxConcurrentSourceRequests: Int? = nil,
        heldSourceConnection: Bool = false,
        declaredDurationSeconds: Double? = nil,
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        externalSubtitles: [ExternalSubtitleTrack] = [],
        forwardBufferSegments: Int? = nil,
        backwardBufferSegments: Int? = nil,
        autoplay: Bool = true,
        teletextPage: Int? = nil,
        audioDelaySeconds: Double = 0,
        deinterlaceMode: DeinterlaceMode = .auto,
        deinterlaceFieldRate: DeinterlaceFieldRate = .field,
        preferredDecodePath: DecodePath = .automatic,
        escalatesToSoftwarePath: Bool = true,
        sharedOutputRole: SharedOutputRole = .primary
    ) {
        self.omitCriteriaColorExtensions = omitCriteriaColorExtensions
        self.suppressDisplayCriteria = suppressDisplayCriteria
        self.httpHeaders = httpHeaders
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.forceDolbyVisionOnNonDVDisplay = forceDolbyVisionOnNonDVDisplay
        self.dolbyVisionHandling = dolbyVisionHandling
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.attemptsHDRMasterOnUnprovenPanel = attemptsHDRMasterOnUnprovenPanel
        self.panelPresentsDolbyVision = panelPresentsDolbyVision
        self.audioBridgeMode = audioBridgeMode
        self.isLive = isLive
        self.audioOnly = audioOnly
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveBlockingReload = liveBlockingReload
        self.liveJoinProfile = liveJoinProfile
        self.liveJoinStartsImmediately = liveJoinStartsImmediately
        self.clampsLiveResumeToWindow = clampsLiveResumeToWindow
        self.nativeRemoteHLS = nativeRemoteHLS
        self.nativeRemoteHLSIngestFallback = nativeRemoteHLSIngestFallback
        self.preserveASSMarkup = preserveASSMarkup
        self.prepareNativeSubtitles = prepareNativeSubtitles
        self.eagerNativeSubtitleReaders = eagerNativeSubtitleReaders
        self.serveIFramePlaylist = serveIFramePlaylist
        self.confirmAtmos = confirmAtmos
        self.nativeSubtitlePreferredLanguages = nativeSubtitlePreferredLanguages
        self.sequentialOrigin = sequentialOrigin
        self.maxConcurrentSourceRequests = maxConcurrentSourceRequests
        self.heldSourceConnection = heldSourceConnection
        self.declaredDurationSeconds = declaredDurationSeconds
        self.probesize = probesize
        self.maxAnalyzeDuration = maxAnalyzeDuration
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.externalSubtitles = externalSubtitles
        self.forwardBufferSegments = forwardBufferSegments
        self.backwardBufferSegments = backwardBufferSegments
        self.autoplay = autoplay
        self.teletextPage = teletextPage
        self.audioDelaySeconds = audioDelaySeconds
        self.deinterlaceMode = deinterlaceMode
        self.deinterlaceFieldRate = deinterlaceFieldRate
        self.preferredDecodePath = preferredDecodePath
        self.escalatesToSoftwarePath = escalatesToSoftwarePath
        self.sharedOutputRole = sharedOutputRole
    }
}

/// Detected video dynamic range format. `hdr10Plus` shares the HDR10 base layer with `hdr10`; the distinction is the per-frame ST 2094-40 metadata forwarded via `kCMSampleAttachmentKey_HDR10PlusPerFrameData`. Both map to PQ + BT.2020 in AVDisplayCriteria; the split is for badge accuracy.
public enum VideoFormat: Sendable, Equatable {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}

/// A Dolby Vision profile rewrite the engine applies to the served stream (`AetherEngine.dolbyVisionConversion`).
public enum DolbyVisionConversion: Sendable, Equatable {
    /// Dual-layer Profile 7 rewritten per packet to single-layer Profile 8.1 for a display presenting Dolby
    /// Vision. The enhancement layer is discarded: a MEL carries next to nothing, a FEL loses its refinement.
    case profile7ToProfile81
}

/// One-shot container + stream metadata from `AetherEngine.probe(url:options:)`. No HLS server, no decoders.
public struct SourceProbe: Sendable {
    public let url: URL
    /// 0 for live streams / pipes.
    public let durationSeconds: Double
    /// `.sdr` when no HDR signaling or no video track.
    ///
    /// Settable inside the module so the `.hdr10Plus` upgrade from `probe(url:detecting: .hdr10Plus)` lands
    /// here rather than rebuilding the struct field by field.
    public internal(set) var videoFormat: VideoFormat
    /// FFmpeg AVCodecID raw value; 0 (AV_CODEC_ID_NONE) when no video track.
    public let videoCodecID: Int32
    /// Codec name from libavcodec (e.g. "hevc", "h264", "av1"). nil when unavailable.
    public let videoCodecName: String?
    /// 0 when no video track.
    public let videoWidth: Int32
    /// 0 when no video track.
    public let videoHeight: Int32
    /// Snapped to a standard rate (23.976, 24, 25, ...). nil when not advertised.
    public let videoFrameRate: Double?
    public let isDolbyVision: Bool
    /// Dolby Vision profile number (5, 7, 8, 10) read from the dvcC/dvvC configuration record; nil when not DV.
    public let dvProfile: Int?
    /// AE#658: pixel format, bit depth, colour description and profile of the video stream; nil when
    /// the source has no video.
    public let videoStreamFormat: VideoStreamFormat?
    /// HDR10+ (ST 2094-40) dynamic metadata was SEEN in this source's video.
    ///
    /// Always `false` unless the probe was asked for `.hdr10Plus` (the container carries no such declaration,
    /// so there is nothing to read without looking at packets). `false` therefore means "not asked, or not
    /// seen inside the scan budget", never "proven absent": a positive is evidence, a negative is not.
    ///
    /// Separate from `videoFormat == .hdr10Plus` because a Dolby Vision source can carry an HDR10+ layer too
    /// (Blu-ray Profile 7 and the 8.1 remuxes of it), and that source keeps reading `.dolbyVision`.
    public internal(set) var carriesHDR10PlusMetadata: Bool
    /// HDR Vivid (CUVA T/UWA 005.1) dynamic metadata was SEEN in this source's HEVC video (#699).
    ///
    /// Same contract as `carriesHDR10PlusMetadata`: always `false` unless the probe was asked for
    /// `.hdrVivid`, and `false` never means "proven absent". `videoFormat` does not move: HDR Vivid rides
    /// an HLG or PQ base layer, the display is switched for that base, and the label keeps saying
    /// `.hlg` / `.hdr10`. Apple platforms do not apply the dynamic metadata; the flag exists so a host can
    /// label the source.
    public internal(set) var carriesHDRVividMetadata: Bool
    /// Settable inside the module so `probeDetectingAtmos` can enrich one track without rebuilding the struct field by field.
    public internal(set) var audioTracks: [TrackInfo]
    /// Includes both text and bitmap (PGS / DVB) variants.
    public let subtitleTracks: [TrackInfo]
    public let metadata: MediaMetadata
    /// Heuristic: no duration + network scheme (http / https / udp / rtp / rtsp). False positives possible (VOD MKVs with broken duration). Hosts decide the final `LoadOptions.isLive`.
    public let isLive: Bool

    public init(
        url: URL,
        durationSeconds: Double,
        videoFormat: VideoFormat,
        videoCodecID: Int32,
        videoCodecName: String?,
        videoWidth: Int32,
        videoHeight: Int32,
        videoFrameRate: Double?,
        isDolbyVision: Bool,
        dvProfile: Int? = nil,
        carriesHDR10PlusMetadata: Bool = false,
        carriesHDRVividMetadata: Bool = false,
        audioTracks: [TrackInfo],
        subtitleTracks: [TrackInfo],
        metadata: MediaMetadata = MediaMetadata(title: nil, artist: nil, album: nil, artworkData: nil),
        isLive: Bool = false,
        videoStreamFormat: VideoStreamFormat? = nil
    ) {
        self.videoStreamFormat = videoStreamFormat
        self.url = url
        self.durationSeconds = durationSeconds
        self.videoFormat = videoFormat
        self.videoCodecID = videoCodecID
        self.videoCodecName = videoCodecName
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.isDolbyVision = isDolbyVision
        self.dvProfile = dvProfile
        self.carriesHDR10PlusMetadata = carriesHDR10PlusMetadata
        self.carriesHDRVividMetadata = carriesHDRVividMetadata
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.metadata = metadata
        self.isLive = isLive
    }
}

/// Result of `AetherEngine.swDecodeProbe(url:)`. Distinguishes open-failure, open-but-no-frames, and healthy decode without a render layer.
public struct SoftwareDecodeProbeResult: Sendable {
    public let codecName: String
    public let codecID: Int32
    public let width: Int32
    public let height: Int32
    public let openSucceeded: Bool
    public let openError: String?
    public let packetsRead: Int
    public let packetsFedToDecoder: Int
    public let framesDecoded: Int
    public let firstFramePixelFormat: String?
    public let firstFrameWidth: Int
    public let firstFrameHeight: Int
    public let firstError: String?
    /// #407: presentation timestamps of the decoded pictures, in the order the decoder handed them
    /// out. A healthy reordering stream produces a strictly ascending, evenly spaced ladder here; a
    /// container that withheld its PTS and had one invented from decode order produces a sawtooth,
    /// which is the one shape no packet-level or renderer-level counter can see.
    public let frameTimesSeconds: [Double]
    /// AE#654: the colour tags the first picture reached the display layer with, as
    /// `primaries / transfer / matrix` in CoreVideo's names, `-` for a missing one. An untagged source
    /// reads `ITU_R_709_2` in all three here, the same as VideoToolbox's own output for it.
    public let firstFrameColor: String?

    public init(
        codecName: String,
        codecID: Int32,
        width: Int32,
        height: Int32,
        openSucceeded: Bool,
        openError: String?,
        packetsRead: Int,
        packetsFedToDecoder: Int,
        framesDecoded: Int,
        firstFramePixelFormat: String?,
        firstFrameWidth: Int,
        firstFrameHeight: Int,
        firstError: String?,
        frameTimesSeconds: [Double] = [],
        firstFrameColor: String? = nil
    ) {
        self.frameTimesSeconds = frameTimesSeconds
        self.firstFrameColor = firstFrameColor
        self.codecName = codecName
        self.codecID = codecID
        self.width = width
        self.height = height
        self.openSucceeded = openSucceeded
        self.openError = openError
        self.packetsRead = packetsRead
        self.packetsFedToDecoder = packetsFedToDecoder
        self.framesDecoded = framesDecoded
        self.firstFramePixelFormat = firstFramePixelFormat
        self.firstFrameWidth = firstFrameWidth
        self.firstFrameHeight = firstFrameHeight
        self.firstError = firstError
    }
}

/// Audio or subtitle track metadata.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// FFmpeg AVStream index.
    public let id: Int
    public let name: String
    /// Lower-case libavcodec name (e.g. "aac", "ac3", "subrip").
    public let codec: String
    public let language: String?
    /// 2=stereo, 6=5.1, 8=7.1. 0 for non-audio.
    public let channels: Int
    /// Declared stream bitrate in bits per second from `codecpar.bit_rate`, or 0 when the container
    /// leaves it unset (common for lossless VBR audio and many MKV audio tracks). For Stats-for-Nerds.
    public let bitrate: Int64
    public let isDefault: Bool
    /// Container disposition `FORCED` (subtitles meant to show without the user enabling subtitles, e.g.
    /// foreign-dialogue or signs tracks). Drives the subtitle-language ranking in `selectSubtitleIndex`.
    public let isForced: Bool
    /// Container disposition `HEARING_IMPAIRED` (SDH / closed-caption tracks with sound descriptions).
    public let isHearingImpaired: Bool
    /// Container disposition `COMMENT` (director / cast commentary tracks). Applies to audio and subtitle.
    public let isCommentary: Bool
    /// EAC3 with JOC profile (Dolby Atmos). Lets the UI surface "Atmos" instead of the bed channel count (typically 5.1).
    /// Settable inside the module so `probeDetectingAtmos` can confirm it post-decode without rebuilding the struct field by field.
    public internal(set) var isAtmos: Bool

    /// ASS / SSA tracks only: `[Script Info]` + `[V4+ Styles]` + `[Events]` format line from codec extradata. Hosts rendering ASS styling themselves (see `LoadOptions.preserveASSMarkup`) need it to resolve style references. nil for all other track kinds.
    public let assHeader: String?

    /// True for host-registered external subtitle tracks (AetherEngine#88); their `id` is synthetic
    /// (`AetherEngine.externalSubtitleTrackIDBase` + ordinal), not an AVStream index.
    public let isExternal: Bool
    /// True when the playback backend, rather than `subtitleCues`, renders this
    /// track. Hosts can avoid presenting overlay controls that cannot affect it.
    public let isNativelyRenderedSubtitle: Bool

    /// AE#658, audio only: sample rate in Hz, 0 when undeclared.
    public let sampleRate: Int
    /// AE#658, audio only: bits per sample the stream carries (`bits_per_raw_sample`), 0 where the codec
    /// has no fixed depth (AAC, AC-3, E-AC-3, Opus decode to float and have none to report).
    public let bitsPerSample: Int
    /// AE#658, audio only: the decoder's output sample format in libav's names ("fltp", "s32p", "s16"),
    /// nil when the probe had no decoder for the stream.
    public let sampleFormat: String?
    /// AE#658, audio only: the channel layout as libav describes it ("stereo", "5.1(side)", "7.1").
    public let channelLayout: String?
    /// AE#658: codec profile as libavcodec names it ("LC", "DTS-HD MA + DTS:X", "Dolby TrueHD + Dolby Atmos"),
    /// nil when undeclared. This is where DTS:X and TrueHD Atmos show up; `isAtmos` covers E-AC-3 JOC only.
    public let profile: String?

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, bitrate: Int64 = 0, isDefault: Bool, isForced: Bool = false, isHearingImpaired: Bool = false, isCommentary: Bool = false, isAtmos: Bool = false, assHeader: String? = nil, isExternal: Bool = false, isNativelyRenderedSubtitle: Bool = false, sampleRate: Int = 0, bitsPerSample: Int = 0, sampleFormat: String? = nil, channelLayout: String? = nil, profile: String? = nil) {
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.sampleFormat = sampleFormat
        self.channelLayout = channelLayout
        self.profile = profile
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.bitrate = bitrate
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.isAtmos = isAtmos
        self.assHeader = assHeader
        self.isExternal = isExternal
        self.isNativelyRenderedSubtitle = isNativelyRenderedSubtitle
    }
}

/// MKV attachment filtered to font payloads. Anime releases embed TTF/OTF fonts for their ASS styles; pass to the renderer's font directory (AetherEngine#30).
public struct FontAttachment: Sendable, Equatable {
    public let filename: String
    /// Empty when the container does not carry a MIME type.
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    private static let fontMIMEs: Set<String> = [
        "font/ttf", "font/otf", "font/sfnt", "font/collection",
        "application/x-truetype-font", "application/vnd.ms-opentype",
        "application/font-sfnt", "application/x-font-ttf",
        "application/x-font-otf",
    ]

    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// True when MIME type or (as fallback for absent / generic MIME) filename extension identifies a font.
    static func isFontPayload(mimeType: String?, filename: String?) -> Bool {
        if let mime = mimeType?.lowercased(), fontMIMEs.contains(mime) {
            return true
        }
        if let ext = filename.flatMap({ ($0 as NSString).pathExtension.lowercased() }),
           fontExtensions.contains(ext) {
            let mime = mimeType?.lowercased() ?? ""  // A declared non-font MIME wins over the extension.
            return mime.isEmpty || mime == "application/octet-stream"
        }
        return false
    }
}

/// Container-level tags + embedded cover art. Fields are optional; video files usually have none. `from(...)` applies album-artist fallback and drops empty strings.
public struct MediaMetadata: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    /// Raw cover-art bytes (typically JPEG or PNG); no format validation.
    public let artworkData: Data?

    public init(title: String?, artist: String?, album: String?, artworkData: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }

    /// True when at least one text field is present; lets hosts decide between a metadata layout and a filename fallback.
    public var hasDisplayMetadata: Bool {
        title != nil || artist != nil || album != nil
    }

    /// Trim whitespace, map empty to nil, fall back to `albumArtist` when `artist` is absent.
    public static func from(
        title: String?, artist: String?, album: String?,
        albumArtist: String?, artworkData: Data?
    ) -> MediaMetadata {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }
        return MediaMetadata(
            title: clean(title),
            artist: clean(artist) ?? clean(albumArtist),
            album: clean(album),
            artworkData: artworkData
        )
    }
}

/// Straight (non-premultiplied) RGB for a coloured subtitle run. Reusable for teletext (#107)
/// and future ASS colour work. nil on a run means "inherit the host's foreground preference".
public struct SubtitleColor: Sendable, Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// One contiguous same-styling span of a rich-text cue.
///
/// #233: libavcodec converts every text subtitle format to an ASS event line before the engine
/// sees it, so SRT (`<b>`, `<font color/size/face>`), WebVTT (`<i>/<b>/<u>`), teletext and ASS
/// itself all arrive carrying the same override tags and populate the same fields here. A run
/// with no attribute set is plain text; those cues stay `.text` rather than becoming `.richText`.
public struct SubtitleTextRun: Sendable, Equatable {
    public let text: String
    public let color: SubtitleColor?
    public let isBold: Bool
    public let isItalic: Bool
    public let isUnderlined: Bool
    public let isStruckThrough: Bool
    /// Face requested by `\fn` (SRT `<font face=>`); nil means the host's default.
    public let fontName: String?
    /// Size requested by `\fs` (SRT `<font size=>`), in ASS play-resolution points, so it is a
    /// relative hint rather than a pixel size; nil means the host's default.
    public let fontSize: Int?

    public init(text: String, color: SubtitleColor?,
                isBold: Bool = false, isItalic: Bool = false,
                isUnderlined: Bool = false, isStruckThrough: Bool = false,
                fontName: String? = nil, fontSize: Int? = nil) {
        self.text = text
        self.color = color
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStruckThrough = isStruckThrough
        self.fontName = fontName
        self.fontSize = fontSize
    }

    /// True when the run asks for anything beyond plain text. Drives the `.text` / `.richText`
    /// choice, so an unstyled track keeps the body it has always had.
    public var isStyled: Bool {
        color != nil || isBold || isItalic || isUnderlined || isStruckThrough
            || fontName != nil || fontSize != nil
    }
}

/// Where a text cue asks to be drawn, from the ASS `\an` / `\pos` overrides (#233).
///
/// Bitmap cues carry their own geometry on `SubtitleImage`; this is the text equivalent and is nil
/// for the overwhelming majority of cues, which simply want the host's default placement.
public struct SubtitleTextPlacement: Sendable, Equatable {
    /// ASS numpad alignment from `\an`: 1 bottom-left through 9 top-right, 5 centred.
    public let alignment: Int?
    /// Anchor from `\pos`, normalized against the script's declared play resolution the same way
    /// `SubtitleImage.position` is, with y measured from the top. Usually in [0, 1], but not
    /// guaranteed: a script may anchor outside the frame on purpose, so a host that cannot draw
    /// off-picture should decide for itself what to do with such a cue rather than assume the
    /// range (#261).
    public let position: CGPoint?

    public init(alignment: Int?, position: CGPoint?) {
        self.alignment = alignment
        self.position = position
    }
}

/// Decoded subtitle cue (start/end in container seconds). Payload is plain text (SubRip / ASS / SSA / WebVTT / mov_text), coloured rich text (teletext / ASS colour tags), or a rendered bitmap (PGS / DVB / HDMV) with position normalized against the source video frame.
/// Both paths land in the same `subtitleCues` array, so the host renders
/// them with one switch in the overlay view.
public struct SubtitleCue: Identifiable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let body: Body
    /// #233: placement the source asked for, from ASS `\an` / `\pos`. nil means the host places the
    /// cue itself, which is the case for nearly every cue. Text cues only; a bitmap cue carries its
    /// geometry on `SubtitleImage`.
    public let placement: SubtitleTextPlacement?

    public enum Body: Sendable {
        case text(String)
        case image(SubtitleImage)
        case richText([SubtitleTextRun])
    }

    public init(id: Int, startTime: Double, endTime: Double, body: Body,
                placement: SubtitleTextPlacement? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.body = body
        self.placement = placement
    }

    /// Plain text for text and rich-text cues (rich runs concatenated); nil for bitmap cues.
    public var text: String? {
        switch body {
        case .text(let s): return s
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }

    /// True for a bitmap cue the disc flags as forced (PGS/DVD forced captions: signs, foreign
    /// dialogue). Per cue, so a display set mixing a forced sign with regular dialogue is
    /// distinguishable (#146); track-level forcedness stays on `TrackInfo.isForced`.
    public var isForced: Bool {
        if case .image(let image) = body { return image.isForced }
        return false
    }
}

extension SubtitleCue {
    /// Copy of this cue with only the named fields changed; everything else is carried across.
    ///
    /// #233 follow-up (tresby): the store operations rebuild a cue to change one field, and every
    /// one of them did it by calling the memberwise initializer with the fields it happened to know
    /// about. `placement` is defaulted there for source compatibility, so each of those call sites
    /// dropped it and still compiled, and `insertCueSorted` stamps every cue entering the retained
    /// store, which meant no embedded track could ever deliver a placement to a host. Rebuilding
    /// through here instead makes the carry-over the default and the drop impossible to write by
    /// accident, including for whatever field is added to the cue next.
    func with(id: Int? = nil, endTime: Double? = nil, body: Body? = nil) -> SubtitleCue {
        SubtitleCue(id: id ?? self.id,
                    startTime: startTime,
                    endTime: endTime ?? self.endTime,
                    body: body ?? self.body,
                    placement: placement)
    }
}

extension SubtitleCue: Equatable {
    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        // ID monotonic per session; sufficient for SwiftUI diffing without comparing CGImage refs.
        lhs.id == rhs.id
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
    }
}

/// Decoded PGS / HDMV PGS / DVB / DVD bitmap subtitle. CGImage is fully rendered (RGBA, premultiplied alpha). Position is [0, 1] against the source video frame; multiply by the on-screen video rect to place it.
public struct SubtitleImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let position: CGRect
    /// Coded pixel size of the subtitle canvas `position` is normalized against (PGS/DVB
    /// composition canvas, e.g. 1920x1080). A cropped-video rip can have a canvas taller
    /// than the coded video; hosts map the canvas width-aligned and center-anchored onto
    /// the video rect so cues land where the disc authored them (incl. the lower bar).
    /// .zero when unknown (pre-canvas cues): hosts fall back to treating canvas == video.
    public let canvasSize: CGSize
    /// AV_SUBTITLE_FLAG_FORCED from the decoded rect (#146): the disc authored this object as a
    /// forced caption (sign / foreign-dialogue overlay shown even with subtitles off).
    public let isForced: Bool

    public init(cgImage: CGImage, position: CGRect, canvasSize: CGSize = .zero, isForced: Bool = false) {
        self.cgImage = cgImage
        self.position = position
        self.canvasSize = canvasSize
        self.isForced = isForced
    }
}

// MARK: - Audio Utilities

import CoreAudio
import AetherLibavutil

/// #401: this tag has to describe the channel order the RESAMPLER writes, or the renderer places
/// the audio somewhere the decoder never put it. It is one buffer with two descriptions of it,
/// and the two must not drift, which is why `makeResamplerOutputLayout` sits directly below.
///
/// The old table agreed only for 5.0 and 5.1, which is most likely why it survived: 5.1 is the
/// common multichannel case. Measured per channel against a layout built from the resampler's own
/// order, on 7.1 EVERY channel moved and the LFE, a bass-only channel, was placed hard left at
/// full gain; on 4.0 the centre, which carries dialogue, went hard left; on 2.1 the LFE was mixed
/// into both channels at -3 dB instead of being dropped.
///
/// 7.1 is also where the mistake came from: the old comment here called `AAC_7_1` "MPEG_7_1_C,
/// Hollywood L R C LFE Ls Rs Lsr Rsr", but those are two different layouts. The Hollywood order IS
/// MPEG_7_1_C; `AAC_7_1` is FC FLc FRc FL FR BL BR LFE. The tag never matched the prose.
///
/// Every tag below was verified channel by channel against the resampler's order through a real
/// downmix: all of them place all channels identically.
func audioChannelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
    switch channels {
    case 1:  return kAudioChannelLayoutTag_Mono            // FC, and a mono track is not a centre
    case 2:  return kAudioChannelLayoutTag_Stereo          // FL FR
    case 3:  return kAudioChannelLayoutTag_WAVE_2_1        // FL FR LFE
    case 4:  return kAudioChannelLayoutTag_MPEG_4_0_A      // FL FR FC BC
    case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A      // FL FR FC BL BR
    case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A      // FL FR FC LFE BL BR
    case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A      // FL FR FC LFE BL BR BC
    case 8:  return kAudioChannelLayoutTag_MPEG_7_1_C      // FL FR FC LFE BL BR Ls Rs
    default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
    }
}

/// The layout `AudioDecoder` resamples INTO, i.e. the order the bytes are actually in. The
/// counterpart of `audioChannelLayoutTag` above; a test holds the two against each other.
///
/// Everything is FFmpeg's own default except 7 channels: 6.1's default order (FL FR FC LFE BC SL
/// SR) is the one count no CoreAudio tag describes, so the resampler is pointed at 6.1(back)
/// instead, which MPEG_6_1_A does describe. Cheaper and safer than a UseChannelDescriptions
/// layout, which would leave the well-trodden tags behind on tvOS.
func makeResamplerOutputLayout(_ channels: Int32, into layout: inout AVChannelLayout) {
    if channels == 7, av_channel_layout_from_string(&layout, "6.1(back)") >= 0 { return }
    if channels == 7 {
        EngineLog.emit("[AudioDecoder] no 6.1(back) layout; 7ch falls back to the default order, "
                       + "which no CoreAudio tag matches (#401)", category: .swPlayback)
    }
    av_channel_layout_default(&layout, channels)
}
