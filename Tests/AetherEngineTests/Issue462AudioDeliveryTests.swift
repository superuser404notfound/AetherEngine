import Testing
@testable import AetherEngine

/// AE#462: a source whose audio can neither stream-copy into fMP4 nor go through the bridge plays
/// video-only, and until now nothing typed said so. `state` reached `.playing`, no `PlaybackErrorKind`
/// was published (by the taxonomy's lights nothing had failed), and the only account was a log line.
/// A host with a fallback ladder could infer the drop from a non-empty `audioTracks` paired with a nil
/// `activeAudioDecoder`, which is an undocumented pairing of two publishers, and on the software path
/// it is not even true: that label is built from the probe, so it named a decoder that never opened.
@Suite("AudioDelivery.derive (AE#462)")
struct AudioDeliveryDeriveTests {

    @Test("no backend delivers nothing, whatever the pipelines still hold")
    func noBackendDeliversNothing() {
        for stale in AudioDelivery.allCases {
            #expect(AudioDelivery.derive(backend: .none,
                                         nativeRemoteHLS: false,
                                         loopbackSession: stale,
                                         softwareHost: stale,
                                         audioOnlyHost: stale) == AudioDelivery.none)
        }
    }

    @Test("the retired .aether backend delivers nothing")
    func retiredBackendDeliversNothing() {
        #expect(AudioDelivery.derive(backend: .aether,
                                     nativeRemoteHLS: false,
                                     loopbackSession: .streamCopy,
                                     softwareHost: nil,
                                     audioOnlyHost: nil) == AudioDelivery.none)
    }

    @Test("the loopback session's own outcome is what the host reads")
    func loopbackPassesItsOutcomeThrough() {
        for outcome: AudioDelivery in [.streamCopy, .bridged, .droppedNoPipeline, .noAudioInSource] {
            #expect(AudioDelivery.derive(backend: .native,
                                         nativeRemoteHLS: false,
                                         loopbackSession: outcome,
                                         softwareHost: nil,
                                         audioOnlyHost: nil) == outcome)
        }
    }

    /// The remote bypass has no `HLSVideoEngine`, so reading the loopback slot there would report
    /// `.none` for a session that is playing audio perfectly well. AVFoundation owns the media
    /// selection on that route and the engine has nothing truer to say than who owns it.
    @Test("the remote bypass reports who owns the audio, not an absent pipeline")
    func remoteBypassIsPlayerManaged() {
        #expect(AudioDelivery.derive(backend: .native,
                                     nativeRemoteHLS: true,
                                     loopbackSession: nil,
                                     softwareHost: nil,
                                     audioOnlyHost: nil) == .playerManaged)
    }

    /// A loopback fact left over from the session before the reroute must not survive it.
    @Test("the bypass answer does not read a stale loopback fact")
    func remoteBypassIgnoresStaleLoopbackFact() {
        #expect(AudioDelivery.derive(backend: .native,
                                     nativeRemoteHLS: true,
                                     loopbackSession: .droppedNoPipeline,
                                     softwareHost: nil,
                                     audioOnlyHost: nil) == .playerManaged)
    }

    @Test("a native backend with no session yet delivers nothing")
    func nativeWithoutSessionDeliversNothing() {
        #expect(AudioDelivery.derive(backend: .native,
                                     nativeRemoteHLS: false,
                                     loopbackSession: nil,
                                     softwareHost: nil,
                                     audioOnlyHost: nil) == AudioDelivery.none)
    }

    @Test("the software host's own outcome is what the host reads")
    func softwarePassesItsOutcomeThrough() {
        for outcome: AudioDelivery in [.decoded, .droppedNoPipeline, .noAudioInSource] {
            #expect(AudioDelivery.derive(backend: .software,
                                         nativeRemoteHLS: false,
                                         loopbackSession: nil,
                                         softwareHost: outcome,
                                         audioOnlyHost: nil) == outcome)
        }
    }

    @Test("the remote-HLS bit cannot reach the software path")
    func softwareIgnoresTheRemoteBit() {
        #expect(AudioDelivery.derive(backend: .software,
                                     nativeRemoteHLS: true,
                                     loopbackSession: nil,
                                     softwareHost: .decoded,
                                     audioOnlyHost: nil) == .decoded)
    }

    @Test("an audio-only session reports the host serving it")
    func audioOnlyReportsItsHost() {
        #expect(AudioDelivery.derive(backend: .audio,
                                     nativeRemoteHLS: false,
                                     loopbackSession: nil,
                                     softwareHost: nil,
                                     audioOnlyHost: .playerManaged) == .playerManaged)
        #expect(AudioDelivery.derive(backend: .audio,
                                     nativeRemoteHLS: false,
                                     loopbackSession: nil,
                                     softwareHost: nil,
                                     audioOnlyHost: .decoded) == .decoded)
    }

    /// The drop is the one value a ladder acts on, so the fold must never be able to invent it: it
    /// only ever arrives from a pipeline that reported it about itself.
    @Test("no combination of routing bits produces a drop on its own")
    func theDropCannotBeInvented() {
        for backend: PlaybackBackend in [.none, .aether, .native, .software, .audio] {
            for remote in [true, false] {
                #expect(AudioDelivery.derive(backend: backend,
                                             nativeRemoteHLS: remote,
                                             loopbackSession: nil,
                                             softwareHost: nil,
                                             audioOnlyHost: nil) != .droppedNoPipeline)
            }
        }
    }

    /// Rot brake, the AE#460 inventory pattern: a new case has to be routed by the fold and
    /// documented for hosts before it can ship, rather than appearing in a publisher unannounced.
    @Test("the case set is pinned")
    func caseSetIsPinned() {
        #expect(AudioDelivery.allCases == [.none, .noAudioInSource, .streamCopy,
                                           .bridged, .decoded, .droppedNoPipeline, .playerManaged])
    }

    /// Raw values are API (the `PlaybackErrorKind` rule): they ride analytics buckets unchanged.
    @Test("raw values are stable")
    func rawValuesAreStable() {
        #expect(AudioDelivery.none.rawValue == "none")
        #expect(AudioDelivery.noAudioInSource.rawValue == "noAudioInSource")
        #expect(AudioDelivery.streamCopy.rawValue == "streamCopy")
        #expect(AudioDelivery.bridged.rawValue == "bridged")
        #expect(AudioDelivery.decoded.rawValue == "decoded")
        #expect(AudioDelivery.droppedNoPipeline.rawValue == "droppedNoPipeline")
        #expect(AudioDelivery.playerManaged.rawValue == "playerManaged")
    }
}

/// The classification each pipeline makes about itself, pinned where it is made rather than through
/// a whole session. Both tails are reached by two different sources of silence, and telling them
/// apart is the entire ask: a source with no audio track is not a source whose audio was dropped.
@Suite("Pipeline audio-delivery classification (AE#462)")
struct AudioDeliveryClassificationTests {

    @Test("the loopback video-only tail separates an absent track from a dropped one")
    func loopbackTailSeparatesAbsentFromDropped() {
        #expect(HLSVideoEngine.videoOnlyAudioDelivery(hadSourceAudioStream: true) == .droppedNoPipeline)
        #expect(HLSVideoEngine.videoOnlyAudioDelivery(hadSourceAudioStream: false) == .noAudioInSource)
    }

    /// `AudioDecoder.open` failing leaves the software host at `audioStreamIndex = -1` and playing
    /// video-only, exactly like the loopback tail and just as silently.
    @Test("the software host separates an absent track from a decoder that would not open")
    func softwareHostSeparatesAbsentFromDropped() {
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: true,
                                                   sourceCarriesAudio: true) == .decoded)
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: false,
                                                   sourceCarriesAudio: true) == .droppedNoPipeline)
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: -1, decoderOpened: false,
                                                   sourceCarriesAudio: false) == .noAudioInSource)
        // AE#641: a stream the pick passed over (empty parameters) is still the source's audio.
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: -1, decoderOpened: false,
                                                   sourceCarriesAudio: true) == .droppedNoPipeline)
    }

    /// The label is the second half of the same lie: it was built from the probe's track list, so a
    /// software session that dropped its audio still published "libavcodec AC3 → CoreAudio". Asking
    /// the host's own resolved index instead makes a dropped session say nothing, which is what a
    /// host reading the pair `audioTracks` + `activeAudioDecoder` was told it could rely on.
    @Test("the decoder label goes quiet when the host has no audio stream")
    func labelIsSilentWithoutAnOpenDecoder() {
        let tracks = [TrackInfo(id: 1, name: "English", codec: "ac3", language: "eng",
                                channels: 6, isDefault: true)]
        #expect(AetherEngine.softwareAudioDecoderLabel(audioTracks: tracks, activeIndex: 1)
                == "libavcodec AC3 → CoreAudio")
        #expect(AetherEngine.softwareAudioDecoderLabel(audioTracks: tracks, activeIndex: -1) == nil)
    }

    /// On a device the Dolby Vision FEL route's details read "libavcodec TRUEHD → CoreAudio" and
    /// "Decoded" while the log said the TrueHD Atmos track went to the renderer as APAC 7.1.4.
    @Test("the software host's Atmos routes report what reaches the renderer")
    func atmosRoutesReportTheirDelivery() {
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: true,
                                                   sourceCarriesAudio: true, route: .apac(.l714)) == .bridged)
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: true,
                                                   sourceCarriesAudio: true, route: .compressedEAC3JOC) == .streamCopy)
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: false,
                                                   sourceCarriesAudio: true, route: .apac(.l714)) == .droppedNoPipeline)
        let trueHD = [TrackInfo(id: 1, name: "English", codec: "truehd", language: "eng", channels: 8, isDefault: true)]
        let dts = [TrackInfo(id: 1, name: "English", codec: "dts", language: "eng", channels: 8, isDefault: true)]
        #expect(AetherEngine.softwareAudioDecoderLabel(audioTracks: trueHD, activeIndex: 1, route: .apac(.l714))
                == "TRUEHD Atmos → APAC 7.1.4")
        #expect(AetherEngine.softwareAudioDecoderLabel(audioTracks: dts, activeIndex: 1, route: .apac(.l916))
                == "DTS:X → APAC 9.1.6")
        #expect(AetherEngine.softwareAudioDecoderLabel(audioTracks: trueHD, activeIndex: 1)
                == "libavcodec TRUEHD → CoreAudio")
    }
}

/// Engine-level wiring: the published fact is derived from `playbackBackend`, the session options and
/// the live pipeline, never assigned on its own, so it cannot drift from the session it describes
/// (the `videoRoute` arrangement, #321).
@Suite("AetherEngine.audioDelivery wiring (AE#462)")
@MainActor
struct AudioDeliveryEngineTests {

    @Test("an idle engine delivers nothing")
    func idleEngineDeliversNothing() throws {
        let engine = try AetherEngine()
        #expect(engine.audioDelivery == AudioDelivery.none)
    }

    @Test("a declared bypass is not a delivery until a backend exists")
    func requestAloneIsNotADelivery() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        #expect(engine.audioDelivery == AudioDelivery.none)

        engine.playbackBackend = .native
        #expect(engine.audioDelivery == .playerManaged)
    }

    /// #168 / #199 / AE#268 take a declared bypass onto the loopback mid-session. The delivery has to
    /// follow the route: on the loopback the engine owns the audio pipeline again, and with no session
    /// built yet it says so rather than keeping the bypass answer.
    @Test("a reroute off the bypass stops claiming AVFoundation owns the audio")
    func rerouteOffTheBypassRepublishes() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        engine.playbackBackend = .native
        #expect(engine.audioDelivery == .playerManaged)

        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: false))
        #expect(engine.audioDelivery == AudioDelivery.none)
    }

    @Test("teardown clears the delivery with the backend")
    func teardownClearsTheDelivery() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        engine.playbackBackend = .native
        #expect(engine.audioDelivery == .playerManaged)

        engine.playbackBackend = .none
        #expect(engine.audioDelivery == AudioDelivery.none)
    }
}
