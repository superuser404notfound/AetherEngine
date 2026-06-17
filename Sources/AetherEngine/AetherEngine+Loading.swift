import Foundation
import AVFoundation
import Combine
import Libavformat
import Libavcodec
import Libavutil

extension AetherEngine {

    /// Wire the host publisher sinks every loader duplicates verbatim
    /// (`$duration`, `$failureMessage`, `$didReachEnd`, and, where the
    /// loader uses the readiness waypoint, `$isReady`) into the given
    /// cancellable set. Loader-specific sinks (the per-path
    /// `$currentTime` folds, the native paths' `$timeControlStatus`
    /// reconciliation) stay at the call sites. Pass `isReady: nil` for
    /// paths that deliberately skip the readiness -> .paused waypoint
    /// (see loadRemoteHLS).
    private func wireCommonHostSinks(
        duration: Published<Double>.Publisher,
        isReady: Published<Bool>.Publisher?,
        failureMessage: Published<String?>.Publisher,
        didReachEnd: Published<Bool>.Publisher,
        storeIn cancellables: inout Set<AnyCancellable>
    ) {
        duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &cancellables)
        if let isReady {
            isReady
                .sink { [weak self] ready in
                    guard let self = self else { return }
                    if ready, self.state == .loading {
                        self.state = .paused
                    }
                }
                .store(in: &cancellables)
        }
        failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &cancellables)
        // Host reached end-of-stream. Flip to .idle so the host app's
        // end-of-content flow fires.
        didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in self?.state = .idle }
            .store(in: &cancellables)
    }

    /// Open HLSVideoEngine against the source, wire NativeAVPlayerHost
    /// to its loopback URL, forward host @Published into the engine's
    /// own published mirrors. `audioSourceStreamIndex` overrides the
    /// auto-picked audio stream when non-nil; used by the mid-playback
    /// audio-track-switch path so the new pipeline picks up the host's
    /// chosen language without a separate API entry point.
    /// Lean native-HLS live path: build an `AVPlayerItem` from the remote
    /// URL on the (reused) `NativeAVPlayerHost` and wire its @Published
    /// mirrors into the engine surface. No Demuxer, no HLSVideoEngine, no
    /// producer, no loopback server, no display-criteria handshake (AVKit
    /// drives match-content for the AVPlayerViewController). The live-window
    /// surfaces are published off `host.seekableEnd`, which reflects the
    /// remote HLS playlist's seekable range. Mirrors `loadNative`'s host +
    /// publisher wiring, minus everything loopback-specific.
    func loadRemoteHLS(url: URL, options: LoadOptions) async throws {
        playbackBackend = .native

        let host: NativeAVPlayerHost
        if let existing = nativeHost {
            host = existing
        } else {
            host = NativeAVPlayerHost()
        }
        host.playerLayer.videoGravity = _videoGravity
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        applyDesiredVolume(to: host)
        // No producer on this path, so the playhead carries the AVPlayer
        // clock directly (no source-PTS fold). Keep the shift at 0.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()
        if currentAVPlayer !== host.avPlayer {
            self.currentAVPlayer = host.avPlayer
        }

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.nativeClockSeconds = value
                self.clock.currentTime = value
                self.clock.sourceTime = value
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd)
                }
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
        // Intentionally do NOT flip to .paused on readiness for this path
        // (isReady: nil). The live autostart has already called host.play(),
        // so readyToPlay is just a waypoint to .playing: the AVPlayer item
        // is ready but is still filling its initial buffer (the Jellyfin
        // live transcode spin-up can leave it in waitingToPlay for ~10 s
        // AFTER readiness). Flipping to .paused here would drop the host's
        // loading spinner and show a black 'paused' frame for that whole
        // window. The timeControlStatus sink below instead holds .loading
        // until AVPlayer actually renders, then flips to .playing.
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: nil,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &nativeCancellables
        )
        // Drive the host's loading/playing UI off AVPlayer's REAL transport
        // state. Critical for live: the stream stays in .loading (spinner up)
        // through the whole transcode spin-up + initial buffer, and only
        // reaches .playing when AVPlayer genuinely starts rendering. Setting
        // state = .playing eagerly at load() time (as a prior revision did)
        // dropped the spinner immediately and showed a ~10 s black screen
        // while AVPlayer was still in waitingToPlay.
        host.$timeControlStatus
            .sink { [weak self] status in
                guard let self = self else { return }
                // .error / .idle are terminal; don't resurrect them.
                if case .error = self.state { return }
                if self.state == .idle { return }
                // Mid-playback rebuffer: only once playback has begun, so
                // the live startup spin-up (state == .loading) is excluded.
                self.isBuffering = self.state == .playing && status == .waitingToPlayAtSpecifiedRate
                switch status {
                case .playing:
                    if self.state != .playing { self.state = .playing }
                case .waitingToPlayAtSpecifiedRate:
                    // Bringing the stream up, or a mid-playback rebuffer.
                    // Hold .loading so the spinner shows during startup; once
                    // playback has begun the host treats .loading as a no-op
                    // for the full-screen spinner (hasStartedPlaying gate).
                    if self.state != .playing { self.state = .loading }
                case .paused:
                    // Only an explicit pause after playback began. The
                    // transient pre-roll paused at load (state == .loading)
                    // must not be mistaken for a user pause.
                    if self.state == .playing { self.state = .paused }
                @unknown default:
                    break
                }
            }
            .store(in: &nativeCancellables)

        // Start at AVPlayer's natural live edge (skipInitialSeek). AVPlayer
        // hits the remote server directly here (not the loopback); the
        // Jellyfin HLS URL carries its own auth (ApiKey / PlaySessionId /
        // LiveStreamId) as query params, so no extra HTTP headers are needed.
        host.load(url: url,
                  startPosition: nil,
                  perFrameHDR: true,
                  skipInitialSeek: true,
                  // System-adaptive buffering for fast live startup. The
                  // 4 s VOD floor forced a 3-4 s black screen pulling the
                  // buffer from the remote Jellyfin transcode before play.
                  forwardBufferDuration: 0)

        // Self-start playback. The VOD native path triggers play() at the
        // tail of load() (after loadNative returns + the display-criteria
        // handshake); this lean path early-returns from load() before that
        // code, so it must start the AVPlayer itself. No criteria handshake
        // here: AVKit drives match-content from the live AVPlayerItem on the
        // AVPlayerViewController. AVPlayer's `automaticallyWaitsToMinimize-
        // Stalling = true` handles "play before ready" — it sits in
        // `waitingToPlayAtSpecifiedRate`, buffers the first segments, then
        // plays. Without this the item loads to `readyToPlay` but stays at
        // `timeControlStatus == .paused` (one frame, never advances).
        //
        // State is left at .loading (set by load() before dispatch). It flips
        // to .playing only when the timeControlStatus sink sees AVPlayer
        // actually rendering, so the host keeps its loading spinner up through
        // the transcode spin-up instead of showing a premature black screen.
        host.play()
        startMemoryProbe()
        // No startLiveTelemetrySampler() here, deliberately: the sampler's
        // counters all read the loopback pipeline (demuxer / producer /
        // cache / server), none of which exists on this AVPlayer-direct
        // bypass. Its fields are nil-safe, but a sampler emitting all-zero
        // rows would only mislead.
    }

    func loadNative(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32? = nil,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveRejoin: Bool = false,
        preopenedDemuxer: Demuxer? = nil,
        generation: UInt64
    ) async throws {
        // Upstream cadence hint for ingest sessions (nil for URL sources).
        // Safe to read here: the load probe's demuxer open blocked on the
        // reader's first bytes, and HLSLiveIngestReader publishes its
        // upstreamTargetDuration before any segment byte enters the FIFO
        // (see the ordering guarantee on that property), so by the time
        // loadNative runs the value is set for any reader that knows it.
        // HLSVideoEngine derives the playlist shaping (blocking-reload
        // eligibility, TARGETDURATION floor) from the hint itself.
        let liveSourceCadenceHint = (customReader as? LiveIngestSourceInfo)?.upstreamTargetDuration
        // Demuxed-audio companion (same ordering guarantee as the cadence
        // hint: installed by the reader's resolver before any main-stream
        // byte flowed, so it is final by the time the probe returned).
        // HLSVideoEngine opens a side demuxer over it when the main
        // demuxer has no audio stream; nil means muxed audio as before.
        let companionAudioReader = (customReader as? LiveIngestSourceInfo)?.companionAudioReader
        let session = HLSVideoEngine(
            url: url,
            sourceHTTPHeaders: sourceHTTPHeaders,
            dvModeAvailable: Self.displayCapabilities.supportsDolbyVision,
            displaySupportsHDR: Self.displayCapabilities.supportsHDR,
            keepDvh1TagWithoutDV: keepDvh1TagWithoutDV,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode,
            audioSourceStreamIndexOverride: audioSourceStreamIndex,
            audioBridgeMode: audioBridgeMode,
            isLiveSession: isLive,
            dvrWindowSeconds: dvrWindowSeconds,
            liveSourceCadenceHint: liveSourceCadenceHint,
            preopenedDemuxer: preopenedDemuxer,
            sourceReopenableByURL: !isCustomSource,
            companionAudioReader: companionAudioReader
        )
        session.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        session.onPlaylistShiftChanged = { [weak self] seconds in
            Task { @MainActor in
                guard let self = self else { return }
                self.playlistShiftSeconds = seconds
                // Gate-open / restart shift = the session baseline of the
                // seam history (valid from the beginning of the output
                // timeline). Boundary seams append after it.
                self.liveShiftSeams = [(activateAt: -.infinity, shift: seconds)]
                // Re-fold against the raw clock so the published source-PTS
                // currentTime tracks the new shift immediately (e.g. after a
                // restart that landed past the planned keyframe), rather than
                // lagging until the next periodic time tick.
                self.clock.currentTime = self.nativeClockSeconds + seconds
                self.clock.sourceTime = self.currentTime
            }
        }
        session.onSeekStateChanged = { [weak self] inFlight, playlistTime in
            Task { @MainActor in
                guard let self = self else { return }
                // Fold the playlist-axis segment time onto the source-PTS
                // axis the published seekTarget/currentTime use (#38), the
                // same fold as the $currentTime sink. nil target while
                // clearing leaves the last value untouched until both seek
                // sources settle.
                let target = playlistTime.map { $0 + self.playlistShiftSeconds }
                self.setNativeScrubSeek(inFlight: inFlight, target: target)
            }
        }
        session.onPlaylistShiftRebased = { [weak self] seconds, seamOutputSeconds in
            Task { @MainActor in
                guard let self = self else { return }
                // Live program boundary: the producer rebased its timeline,
                // but AVPlayer is still rendering ~buffer + holdback of OLD
                // program. Record the seam and let the $currentTime sink
                // resolve the active shift from the history, so the
                // published currentTime/sourceTime never jump ahead of what
                // is actually on screen, and a backward DVR seek across a
                // crossed seam folds with the pre-seam shift again. Seams
                // append in output-timeline order by construction (the
                // continuation dts is monotonic even for backward source
                // jumps).
                self.liveShiftSeams.append(
                    (activateAt: seamOutputSeconds, shift: seconds)
                )
                if self.liveShiftSeams.count > 64 {
                    // Bound the history; dropping the oldest only loses
                    // shift fidelity for DVR positions older than 60+
                    // program boundaries, far outside any real window.
                    self.liveShiftSeams.removeFirst(self.liveShiftSeams.count - 64)
                }
            }
        }
        session.onLiveSourceReset = { [weak self, weak session] in
            Task { @MainActor in
                // A stale session (superseded by a zap) must not trigger a
                // retune of whatever is playing now.
                guard let self, let session else {
                    EngineLog.emit(
                        "[AetherEngine] onLiveSourceReset dropped: self/session deallocated",
                        category: .session
                    )
                    return
                }
                guard self.nativeVideoSession === session else {
                    EngineLog.emit(
                        "[AetherEngine] onLiveSourceReset dropped: session superseded (not current)",
                        category: .session
                    )
                    return
                }
                EngineLog.emit(
                    "[AetherEngine] onLiveSourceReset → publishing liveSourceReset to host",
                    category: .session
                )
                self.liveSourceReset.send()
            }
        }
        // AVPlayer HLS playback over the loopback HTTP server. Detach
        // the synchronous network I/O inside `session.start()` (opens
        // its own Demuxer + prewarm seek = another ~1-3 s on slow CDN)
        // so the @MainActor doesn't block. See the probe-detach comment
        // above for the rationale.
        let playbackURL = try await Task.detached(priority: .userInitiated) { [session] in
            try session.start()
        }.value
        // Superseded while the session was starting? The session is this
        // load's local: stop it (its teardown detaches internally) and
        // unwind before touching the shared host or registering it.
        if loadGeneration != generation {
            session.stop()
            try checkLoadCurrent(generation)
        }
        self.nativeVideoSession = session

        // Reuse the existing native host across a native->native reload
        // (episode change, audio-track switch) so the AVPlayer instance,
        // and AVKit's MediaRemote system Now-Playing registration bound to
        // it, survives the seam. Building a fresh AVPlayer here makes AVKit
        // fail to re-register ("Code=14 client callback") and the iPhone
        // Control Center widget goes blank (issue #15). stopInternal kept
        // the host alive (keepNativeHost) and unloaded its old item; a
        // brand-new host is built only on a cold load or after a
        // native->SW transition released the previous one.
        let host: NativeAVPlayerHost
        if let existing = nativeHost {
            host = existing
        } else {
            host = NativeAVPlayerHost()
        }
        host.playerLayer.videoGravity = _videoGravity
        // Replay any pre-load externalMetadata onto the host so its
        // AVPlayerItem picks it up before AVPlayer assigns the item. Hosts
        // that called `engine.setExternalMetadata` before `engine.load`
        // rely on this transfer.
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        applyDesiredVolume(to: host)
        // Publish before wiring up the @Published mirrors below so any host
        // that subscribes via the same Combine sink sees the AVPlayer
        // instance before the first time / state update lands. Only emit
        // when the instance actually changed: re-publishing the same player
        // would drive the host's currentAVPlayer sink to reassign
        // AVPlayerViewController.player to the same instance, re-triggering
        // the exact AVKit re-registration this reuse path exists to avoid.
        if currentAVPlayer !== host.avPlayer {
            self.currentAVPlayer = host.avPlayer
        }

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                // Fold the producer's shift into the published clock so
                // currentTime carries source PTS, unifying it with the
                // SW / audio paths. nativeClockSeconds keeps the raw value
                // for onPlaylistShiftChanged to re-derive against.
                self.nativeClockSeconds = value
                // Resolve the shift for the playhead's position from the
                // seam history (see onPlaylistShiftRebased above): newest
                // seam at or before the raw clock wins, so forward
                // playback activates seams as they're crossed AND a
                // backward DVR seek re-applies the pre-seam shift.
                if let active = self.liveShiftSeams.last(where: { value >= $0.activateAt }) {
                    self.playlistShiftSeconds = active.shift
                }
                self.clock.currentTime = value + self.playlistShiftSeconds
                self.clock.sourceTime = self.currentTime
                // Live: publish the DVR window surfaces on every tick. The
                // edge must sit on the SAME session axis as the playhead. The
                // playhead is folded as host.currentTime + playlistShiftSeconds
                // above, so the edge (host.seekableEnd in the AVPlayer clock)
                // folds the same way: seekableEnd + playlistShiftSeconds. Using
                // the opposite sign would put edge and playhead on different
                // axes and behindLiveSeconds would be meaningless.
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
                }
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &nativeCancellables
        )
        host.$timeControlStatus
            .sink { [weak self] status in
                guard let self = self else { return }
                // Reconcile `state` when something other than the engine's
                // own play()/pause() drives the AVPlayer: AVKit's transport
                // bar (kept active for Control Center skip routing), CC's
                // play/pause, or the hardware play/pause button AVKit handles
                // internally. Without this `state` goes stale and the host's
                // togglePlayPause() resolves to a no-op (swallowed press).
                // Only reconcile between the two steady transport states;
                // never clobber loading/seeking/error/idle.
                // `.waitingToPlayAtSpecifiedRate` is a buffer stall while the
                // user still intends to play, so it maps to .playing and the
                // play/pause icon doesn't flicker on a rebuffer.
                //
                // Mid-playback rebuffer detection (independent of the
                // play/pause reconciliation below): only count it as
                // buffering once playback has begun, never during the
                // initial load spin-up (state == .loading).
                let startedPlaying = self.state == .playing || self.state == .paused
                self.isBuffering = startedPlaying && status == .waitingToPlayAtSpecifiedRate
                guard startedPlaying else { return }
                switch status {
                case .paused:
                    if self.state != .paused { self.state = .paused }
                case .playing, .waitingToPlayAtSpecifiedRate:
                    if self.state != .playing { self.state = .playing }
                @unknown default:
                    break
                }
            }
            .store(in: &nativeCancellables)

        // appliesPerFrameHDRDisplayMetadata = true unconditionally.
        // The earlier `session.servingMasterPlaylist` gating was a
        // speculative memory-leak mitigation (~3 MB/sec RSS growth on
        // long DV 8.1 sessions, never measurement-validated). DrHurt #4
        // 2026-05-26 correctly flagged that DV Profile 5 is pure DV with
        // no HDR10 base layer — the per-frame DV RPU is what AVPlayer's
        // tone-mapper needs to render anything at all on a non-DV panel
        // routed via the media playlist (`dv5OnSdrLockedNonDVPanel`
        // path). Setting the flag to false on that path was breaking
        // P5 playback entirely. Apple's default for the property is
        // also true (so setting it true explicitly is a no-op against
        // an unset property anyway; we keep the explicit write so
        // diagnostics surface the live value).
        // Loopback live deliberately keeps the 4 s forwardBufferDuration
        // default rather than a deeper buffer. A deep buffer is actively
        // harmful for live: against the instant-delivering loopback server
        // AVPlayer pulls the entire visible playlist up front, races to the
        // live edge, and then hits the one-time transcode warm-up gap (the
        // ~8 s before the producer cuts the next segment) head-on at the
        // edge, stalling for the full gap on -12888. A 4 s buffer instead
        // PACES AVPlayer's consumption to match production, so it plays
        // through its lead while the producer rides out the warm-up, leaving
        // only a brief startup hiccup. Verified on device: 8 s made the
        // startup pause far worse (8-10 s) than the 4 s default (~1 s).
        // Live REJOIN (audio-switch reload, background-return reopen):
        // skip the host's explicit initial seek and let AVPlayer pick
        // its standard live join (edge minus holdback). The rejoined
        // playlist can present a multi-segment backlog (the upstream
        // re-serves its buffer at I/O speed), and the zero-tolerance
        // seek-to-0 against that backlog wedged the reloaded item in
        // waitingToPlay without ever reaching readyToPlay (device
        // repro: tvOS 26, Jellyfin live stream.ts, audio-switch reload
        // froze the frame permanently). Initial live joins keep the
        // seek: their first manifest is held to the 2-segment cushion,
        // where seg0 IS the intended start. See LiveReloadPolicy.
        host.load(url: playbackURL,
                  startPosition: startPosition,
                  perFrameHDR: true,
                  skipInitialSeek: LiveReloadPolicy.skipInitialSeek(
                      isLive: isLive, isRejoin: liveRejoin))
    }

    /// Open a `SoftwarePlaybackHost` against the source and wire its
    /// @Published mirror into the engine's own surface. Used when the
    /// source's video codec isn't decodable by AVPlayer on the active
    /// platform (today: AV1 on Apple TV). Same lifecycle shape as
    /// `loadNative`: host loads the URL itself (no HLS-fMP4 wrapper —
    /// the SW pipeline reads the source directly through its own
    /// Demuxer).
    /// Activate the shared audio session for the renderer paths that have
    /// no AVPlayerViewController to own activation: SoftwarePlaybackHost
    /// (FFmpeg decode -> AVSampleBufferAudioRenderer) and the audio-only
    /// hosts. The native AVPlayer video path deliberately does NOT call
    /// this — AVKit activates per playback so tvOS can auto-negotiate the
    /// HDMI route (issue #24). Restores the preferred-channel hint the
    /// init path used to set, now scoped to the renderer paths.
    private func activateRendererAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do { try session.setActive(true) }
        catch {
            EngineLog.emit("[AetherEngine] activateRendererAudioSession error: \(error)", category: .engine)
        }
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 { try? session.setPreferredOutputNumberOfChannels(maxCh) }
        EngineLog.emit("[AetherEngine] renderer audio session active: maxChannels=\(maxCh) preferred=\(session.preferredOutputNumberOfChannels) output=\(session.outputNumberOfChannels)", category: .engine)
        #endif
    }

    func loadSoftware(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        preopenedDemuxer: Demuxer?,
        generation: UInt64
    ) async throws {
        activateRendererAudioSession()
        let host = SoftwarePlaybackHost()
        host.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        // Live edge publishing: the SW host calls this on its time tick
        // with the session-relative edge; the engine publishes the same
        // four live surfaces it does for the native path. No-op when the
        // session is not live (liveWindow nil -> publishLiveWindow no-ops).
        host.onLiveEdge = { [weak self] edge in
            self?.publishLiveWindow(edgeSessionTime: edge)
        }
        self.softwareHost = host
        applyDesiredVolume(to: host)
        // SW path's currentTime tracks source PTS directly, so the
        // AVPlayer-clock shift is 0 and sourceTime mirrors currentTime.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        softwareCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
            }
            .store(in: &softwareCancellables)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &softwareCancellables
        )

        // Reuse the probe demuxer when present (no second avformat_open_input;
        // also what makes forward-only sources work here, no seek(0) reopen).
        // Fall back to a fresh open only when the probe failed to open.
        // The (possibly blocking) open stays detached so the @MainActor
        // runloop keeps ticking, matching the probe / session.start pattern.
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, isLive, dvrWindowSeconds] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, isLive: isLive)
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex,
                isLive: isLive,
                dvrWindowSeconds: dvrWindowSeconds
            )
        }.value
        // Superseded while the host was loading? The successor's
        // stopInternal already detached this host from the engine;
        // stop it again (idempotent) so the demuxer the detached
        // closure opened is torn down, then unwind.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open an `AudioPlaybackHost` against an audio-only source and wire
    /// its @Published mirror into the engine's surface. The lean path:
    /// no HLS pipeline, no display layer, no display-criteria handshake.
    /// Same lifecycle shape as `loadSoftware`.
    func loadAudio(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        preopenedDemuxer: Demuxer?,
        generation: UInt64
    ) async throws {
        activateRendererAudioSession()
        let host = AudioPlaybackHost()
        self.audioHost = host
        applyDesiredVolume(to: host)
        // Audio path tracks source PTS directly: no AVPlayer-clock shift.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        audioCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
            }
            .store(in: &audioCancellables)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &audioCancellables
        )

        // Reuse the probe demuxer when present (custom sources require it,
        // since they have no URL to reopen; URL sources just skip a redundant
        // open). Fall back to a fresh open only when the probe failed.
        // The (possibly blocking) open stays detached so the @MainActor
        // runloop keeps ticking.
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders)
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
        }.value
        // Superseded while the host was loading? Same unwind as
        // loadSoftware: re-stop the detached host, then throw.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open an `AudioAVPlayerHost` against an audio-only source AVPlayer can
    /// decode natively, and wire its @Published mirror into the engine's
    /// surface. The native, energy-efficient default for audio-only; the
    /// FFmpeg `loadAudio` path is the fallback for codecs AVPlayer cannot
    /// decode. Same lifecycle shape as loadAudio.
    func loadAudioNative(
        url: URL,
        startPosition: Double?,
        httpHeaders: [String: String],
        generation: UInt64
    ) async throws {
        // Reuse the persistent host (and its MPNowPlayingSession) across
        // tracks; only create it the first time. host.load() below swaps the
        // item via replaceCurrentItem on the same AVPlayer.
        activateRendererAudioSession()
        let host = audioAVPlayerHost ?? AudioAVPlayerHost()
        self.audioAVPlayerHost = host
        applyDesiredVolume(to: host)
        self.audioAVPlayerActive = true
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()
        // Reclaim Now-Playing ownership for this session on each track start,
        // so the Home badge + remote commands stay bound across a pause.
        host.becomeActiveNowPlaying()
        host.setExternalMetadata(pendingExternalMetadata)

        audioNativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
            }
            .store(in: &audioNativeCancellables)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &audioNativeCancellables
        )
        // NOTE: deliberately NO reconciliation of `state` from the host's
        // `timeControlStatus` on the audio path. All audio transport flows
        // through the engine's own play()/pause() (driven host-side by
        // MPRemoteCommandCenter handlers, the in-app .onPlayPauseCommand, and
        // the queue logic), so those are the single source of truth for
        // `state`. Feeding timeControlStatus back into `state` mis-latched a
        // TRANSIENT `.paused` that AVFoundation emits during the app's
        // background transition as a real pause: the engine flipped to
        // paused while audio kept playing, the published now-playing rate
        // went to 0, and tvOS (which reads MPNowPlayingInfoPropertyPlaybackRate
        // to infer play-vs-pause) then believed we were paused-while-playing,
        // breaking the system Now-Playing badge and the Siri Remote routing.
        // timeControlStatus is advisory display state, not a command source.

        // No detached hop here, deliberately: AudioAVPlayerHost.load has
        // no blocking work (all MainActor, replaceCurrentItem-based), and
        // the host is SHARED across loads. Detaching opened a reorder
        // window where a superseded load A's detached body ran after its
        // successor B had already loaded, putting A's item back on the
        // shared AVPlayer while the engine published B's state. Staying
        // in the same MainActor slice makes the generation check below
        // and the load atomic with respect to other loads.
        try checkLoadCurrent(generation)
        try await host.load(url: url, startPosition: startPosition, httpHeaders: httpHeaders)
        // Superseded while the (persistent, shared) host was loading?
        // Don't tear the host down, the successor may be using it; just
        // unwind before play()/state writes.
        try checkLoadCurrent(generation)
    }

    /// Align the published audio surface with what the native session
    /// ACTUALLY plays. The load-time publish came from the main probe,
    /// which diverges from the session in two live shapes:
    ///
    /// - Demuxed-audio sources: the audio lives in the SIDE demuxer, so
    ///   the probe saw no audio stream at all (`audioTracks` empty,
    ///   `activeAudioTrackIndex` nil) while the session plays the side
    ///   rendition.
    /// - Live TS probes with empty audio codecpar: av_find_best_stream
    ///   skips those streams, so the probe's default pick came back
    ///   "none" while the engine's by-type fallback + codecpar repair
    ///   picked (and plays) the stream.
    ///
    /// A host that compares its preferred track against
    /// `activeAudioTrackIndex` after load must see the engine's real
    /// pick, or it calls `selectAudioTrack` for the very track that is
    /// already on air and triggers a pointless (and for live,
    /// stall-prone) pipeline reload. Also the truth source after an
    /// audio-switch reload: an invalid override falls back to the auto
    /// pick inside the engine, and the published index must follow.
    func syncPublishedAudioStateFromNativeSession() {
        guard let session = nativeVideoSession else { return }
        // Demuxed-audio: publish the side demuxer's track list so the
        // host's picker and the active index share one stream numbering
        // (the main probe contributed no audio tracks by precondition).
        let sideTracks = session.companionAudioTracks
        if !sideTracks.isEmpty {
            audioTracks = sideTracks
        }
        let active = session.activeAudioSourceStreamIndex
        let resolved: Int? = active >= 0 ? Int(active) : nil
        if activeAudioTrackIndex != resolved {
            EngineLog.emit(
                "[AetherEngine] published active audio reconciled to the session's real pick: "
                + "\(resolved.map(String.init) ?? "nil") "
                + "(was \(activeAudioTrackIndex.map(String.init) ?? "nil"))",
                category: .engine
            )
            activeAudioTrackIndex = resolved
        }
    }

    /// Perform a pipeline rebuild at the current playhead. Tears the current
    /// session down, brings a fresh pipeline up with an optional audio source
    /// stream override (nil keeps the auto-picked track), resumes at the
    /// current position, and re-arms whichever subtitle source was active when
    /// this task actually began executing. Called by `selectAudioTrack` (with a
    /// concrete index) and by `reloadAtCurrentPosition` for custom sources
    /// (with nil to keep the current track). For custom sources the rebuild
    /// reuses the retained `customReader` (see the `customPreopened` block);
    /// for URL sources `loadSoftware`/`loadNative` reopen the URL.
    ///
    /// Subtitle and playhead state are snapshotted INSIDE the task body
    /// rather than at the call site, because hosts commonly chain a
    /// `selectSubtitleTrack` call right after `selectAudioTrack` (e.g.
    /// auto-subs-for-foreign-audio): the chained call lands on the
    /// MainActor before this task body runs, and snapshotting at call
    /// time would miss it, leaving the picker showing a subtitle that
    /// the post-reload state never actually re-armed.
    func reloadWithAudioOverride(
        url: URL,
        audioStreamIndex: Int32?,
        expectedGeneration: UInt64
    ) async {
        // Liveness guard: this runs from a scheduled Task, so a stop()
        // (player dismissed) or a fresh load() can land between the
        // scheduling site and here. Without the check the reload
        // resurrected the stopped session (state/.loadedURL restored,
        // pipeline rebuilt, audio playing after dismiss) or killed the
        // successor load at its first suspension point and played the
        // OLD url instead. The generation is captured at scheduling
        // time; stop()/load() both invalidate it.
        guard loadGeneration == expectedGeneration, loadedURL != nil else {
            EngineLog.emit("[AetherEngine] reload superseded before start; ignored", category: .engine)
            return
        }
        let resumeAt = currentTime
        let embeddedStreamToResume: Int32 = activeEmbeddedSubtitleStreamIndex
        let sidecarToResume: URL? = isSubtitleActive && activeEmbeddedSubtitleStreamIndex < 0
            ? loadedSidecarURL
            : nil
        let secondaryEmbeddedToResume: Int32 = activeSecondaryEmbeddedSubtitleStreamIndex
        let secondarySidecarToResume: URL? = isSecondarySubtitleActive && activeSecondaryEmbeddedSubtitleStreamIndex < 0
            ? loadedSecondarySidecarURL
            : nil
        EngineLog.emit(
            "[AetherEngine] reload begin: audioStream=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s embeddedSub=\(embeddedStreamToResume) sidecar=\(sidecarToResume?.lastPathComponent ?? "nil")",
            category: .engine
        )

        state = .loading
        let previousAudioIndex = activeAudioTrackIndex
        // Snapshot the active backend BEFORE stopInternal wipes it.
        // The reload has to land on whichever pipeline currently owns
        // playback — calling loadNative on a SW-routed source would
        // throw `unsupportedCodec` (HLSVideoEngine accepts HEVC / H.264
        // / VP9 / probed-AV1, not SW-only AV1) and leave the user
        // staring at a "playback stopped" error after picking a
        // different audio track.
        let wasOnSoftwarePath = (playbackBackend == .software)
        // Snapshot the video codec before stopInternal wipes it. The
        // reload re-uses the same source, so the decoder identity
        // label can be reconstructed without re-probing the demuxer.
        let preservedVideoCodec = lastDetectedVideoCodec
        let reloadStart = DispatchTime.now()
        EngineLog.emit("[AetherEngine] reload: stopInternal start", category: .engine)
        // Keep the active display criteria intact across the audio-track
        // switch. The video format isn't changing — `reloadWithAudioOverride`
        // only swaps the audio source stream inside the same HLS engine —
        // so a `displayCriteria.reset()` here is at best a no-op and at
        // worst triggers a 5 s `waitForSwitch` Stage 2 timeout on every
        // reload (Vincent test 2026-05-26, Bose SLIII A2DP route + 4K
        // HDR10 PQ source: each audio switch added ~12 s of black-screen
        // latency because the post-RESET handshake never re-settled,
        // even though the panel never actually left HDR mode). Preserving
        // the criteria also fixes a separate failure mode on the same
        // route: when the panel briefly dropped to SDR during the RESET
        // window, the new AVPlayer asset's PQ variant failed item open
        // with `AVFoundationErrorDomain -11868 / CoreMediaErrorDomain
        // -17223` at variant selection.
        // Keep the native AVPlayer host alive across the audio-track switch
        // (issue #15) unless playback is on the software path, where there
        // is no native host to preserve.
        stopInternal(resetDisplayCriteria: false, keepNativeHost: !wasOnSoftwarePath, keepCustomReader: true)
        EngineLog.emit("[AetherEngine] reload: stopInternal done (\(elapsedMs(since: reloadStart))ms)", category: .engine)
        // Same supersede contract as load(): a newer load/stop bumps the
        // generation and this reload unwinds at the next checkpoint.
        let gen = loadGeneration
        loadedURL = url
        lastDetectedVideoCodec = preservedVideoCodec

        // Custom sources have no URL to reopen; rebuild the pipeline on the
        // retained reader. Build the demuxer off-main (find_stream_info
        // blocks) and hand it through the existing preopenedDemuxer channel.
        // The reader is seekable here (forward-only custom reload entry points
        // no-op). The demuxer opens at byte 0; loadSoftware/loadNative then
        // seek to the resume position via their startPosition argument.
        var customPreopened: Demuxer? = nil
        if isCustomSource, let reader = customReader {
            let hint = customFormatHint
            do {
                let isLiveReload = loadedOptions.isLive
                customPreopened = try await Task.detached(priority: .userInitiated) {
                    let d = Demuxer()
                    // isLive preserved across audio-track reload: a live
                    // custom source must not trigger SEEK_END on reopen.
                    try d.open(reader: reader, formatHint: hint, isLive: isLiveReload)
                    return d
                }.value
            } catch {
                EngineLog.emit("[AetherEngine] reload: custom reader reopen failed: \(error)", category: .engine)
                activeAudioTrackIndex = previousAudioIndex
                state = .error("Reload failed: \(error.localizedDescription)")
                return
            }
            if loadGeneration != gen {
                customPreopened?.markClosed()
                if let d = customPreopened {
                    Task.detached { d.close() }
                }
                EngineLog.emit("[AetherEngine] reload superseded after reader reopen; unwinding", category: .engine)
                return
            }
        }

        do {
            let loadStart = DispatchTime.now()
            if wasOnSoftwarePath {
                EngineLog.emit("[AetherEngine] reload: loadSoftware enter audio=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    // Live rejoins at the live edge; a stale playhead
                    // resume position is meaningless against the fresh
                    // source connection (see LiveReloadPolicy).
                    startPosition: LiveReloadPolicy.resumePosition(
                        isLive: loadedOptions.isLive, currentTime: resumeAt),
                    audioSourceStreamIndex: audioStreamIndex,
                    isLive: loadedOptions.isLive,
                    dvrWindowSeconds: loadedOptions.dvrWindowSeconds,
                    preopenedDemuxer: customPreopened,
                    generation: gen
                )
                EngineLog.emit("[AetherEngine] reload: loadSoftware done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .software
                activeAudioTrackIndex = audioStreamIndex.map { Int($0) }
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: true
                )
                activeAudioDecoder = Self.softwareAudioDecoderLabel(
                    audioTracks: audioTracks, activeIndex: audioStreamIndex ?? -1
                )
                presentCurrentLayer()
                softwareHost?.play()
            } else {
                EngineLog.emit("[AetherEngine] reload: loadNative enter audio=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    // Live rejoins at the live edge (see loadSoftware above).
                    startPosition: LiveReloadPolicy.resumePosition(
                        isLive: loadedOptions.isLive, currentTime: resumeAt),
                    audioSourceStreamIndex: audioStreamIndex,
                    keepDvh1TagWithoutDV: loadedOptions.keepDvh1TagWithoutDV,
                    matchContentEnabled: loadedOptions.matchContentEnabled,
                    panelIsInHDRMode: loadedOptions.panelIsInHDRMode,
                    audioBridgeMode: loadedOptions.audioBridgeMode,
                    // Without these the audio-switch reload of a LIVE session
                    // rebuilt the pipeline as VOD: the demuxer opened in
                    // streaming mode (no live reconnect machinery) and
                    // HLSVideoEngine ran the duration guard against a 0-length
                    // source, failing the whole switch with "cannot build
                    // segment plan" (device repro: KiKA).
                    isLive: loadedOptions.isLive,
                    dvrWindowSeconds: loadedOptions.dvrWindowSeconds,
                    // A reload of a live session is a live REJOIN: the host
                    // must skip its initial seek so AVPlayer joins at its own
                    // live edge instead of the rebuilt playlist's (possibly
                    // 60 s stale) start. See LiveReloadPolicy + the device
                    // repro documented there.
                    liveRejoin: loadedOptions.isLive,
                    preopenedDemuxer: customPreopened,
                    generation: gen
                )
                EngineLog.emit("[AetherEngine] reload: loadNative done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .native
                // Publish what the rebuilt session ACTUALLY plays, not
                // the requested override: an invalid override falls back
                // to the engine's auto pick (see HLSVideoEngine.start),
                // and demuxed-audio sessions resolve in side-demuxer
                // stream numbering.
                syncPublishedAudioStateFromNativeSession()
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: false
                )
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                presentCurrentLayer()
                // Same play-gate as the initial load path: wait for any
                // pending AVKit auto-criteria handshake before resuming,
                // so the first decoded frame after the audio-track reload
                // doesn't hit a mid-transition panel.
                await displayCriteria.waitForSwitch()
                try checkLoadCurrent(gen)
                nativeHost?.play()
            }
            try checkLoadCurrent(gen)
            state = .playing
            // Re-arm the diagnostic samplers. stopInternal nilled the
            // sampler instance + diagnostics.liveTelemetry, and the
            // reload path bypasses the public load() that would
            // otherwise restart them, so without this the host's
            // stats overlay sees liveTelemetry stuck at nil and
            // renders "-" for every field after the first audio
            // track switch in a session.
            startMemoryProbe()
            startLiveTelemetrySampler()
            // Safety net for the live rejoin: if the rebuilt AVPlayer item
            // never reaches readyToPlay although the producer is serving,
            // fail the reload like a load error instead of leaving the user
            // on an indefinitely frozen frame. Scoped to live reloads on the
            // native path; initial joins and VOD reloads never arm it.
            if loadedOptions.isLive, !wasOnSoftwarePath {
                armLiveReloadWatchdog(generation: gen)
            }
            EngineLog.emit("[AetherEngine] reload: state=.playing total=\(elapsedMs(since: reloadStart))ms", category: .engine)
        } catch is CancellationError {
            // Superseded by a newer load/stop: it owns the engine state.
            return
        } catch {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack reload failed: \(error), playback stopped",
                category: .engine
            )
            activeAudioTrackIndex = previousAudioIndex
            state = .error("Audio track switch failed: \(error.localizedDescription)")
            return
        }

        // Resume whichever subtitle source the host had active when
        // this task started running. The sidecar branch wins because
        // `loadedSidecarURL` is set only when the active source is
        // sidecar; the embedded branch restarts the side-demuxer at
        // the new playhead.
        if let sidecar = sidecarToResume {
            selectSidecarSubtitle(url: sidecar)
        } else if embeddedStreamToResume >= 0 {
            selectSubtitleTrack(index: Int(embeddedStreamToResume))
        }
        if let secondarySidecar = secondarySidecarToResume {
            selectSecondarySidecarSubtitle(url: secondarySidecar)
        } else if secondaryEmbeddedToResume >= 0 {
            selectSecondarySubtitleTrack(index: Int(secondaryEmbeddedToResume))
        }
    }

    /// Milliseconds since a captured DispatchTime, rounded. Used by
    /// the reload-path diagnostic markers so each step's duration is
    /// visible without having to do mental arithmetic from absolute
    /// timestamps.
    private func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Arm the live-RELOAD readiness watchdog. Called only from the
    /// reload entry points (`reloadWithAudioOverride` native branch,
    /// `reloadAtCurrentPosition` after a live URL reopen), never from
    /// an initial load, so a slow-but-progressing first join can never
    /// trip it.
    ///
    /// What it guards: the device-verified live-reload wedge where the
    /// rebuilt AVPlayer item fetched init.mp4 and every listed segment
    /// but never published `readyToPlay`, sitting in `waitingToPlay`
    /// (EvaluatingBufferingRate -> WaitingToMinimizeStalls) with a
    /// frozen frame forever. The engine believed the reload succeeded
    /// (`state == .playing`), so nothing upstream ever recovered.
    ///
    /// Semantics:
    /// - Polls once per second. Exits silently (no-op) when the reload
    ///   generation is superseded, the session left the native
    ///   backend, the state went terminal, or the task is cancelled
    ///   (stopInternal cancels it on every teardown).
    /// - Exits successfully the moment the host publishes readiness.
    /// - The 10 s readiness budget starts only once the pipeline is
    ///   demonstrably SERVING: the producer has cut at least the
    ///   2-segment startup cushion AND the loopback server has written
    ///   bytes to AVPlayer. A reload against a slow upstream (segments
    ///   not produced yet) therefore never misfires; genuinely dead
    ///   sources keep failing through the existing manifest-hold
    ///   timeout / -12888 machinery instead.
    /// - On expiry it fails the reload exactly like a load error:
    ///   tears the pipeline down and publishes `state = .error`, so
    ///   the host's existing fallback / retune path takes over.
    /// - Hard 60 s lifetime so an inconclusive watchdog (producer
    ///   never served) cannot linger across a long session.
    func armLiveReloadWatchdog(generation: UInt64) {
        liveReloadWatchdogTask?.cancel()
        liveReloadWatchdogTask = Task { @MainActor [weak self] in
            let readinessBudget: TimeInterval = 10
            let overallBudget: TimeInterval = 60
            let started = Date()
            var servingSince: Date? = nil
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                // Superseded by a newer load/stop: that owner's state
                // machine is authoritative now.
                guard self.loadGeneration == generation else { return }
                // Only the native AVPlayer path has the readyToPlay
                // contract this watchdog checks.
                guard self.playbackBackend == .native,
                      let host = self.nativeHost else { return }
                if case .error = self.state { return }
                if self.state == .idle { return }
                // Success: the item became ready; normal playback owns
                // the session from here.
                if host.isReady { return }
                if servingSince == nil,
                   let session = self.nativeVideoSession,
                   session.liveSegmentCount >= 2,
                   session.serverLifetimeBytesSent > 0 {
                    servingSince = Date()
                }
                if let serving = servingSince,
                   Date().timeIntervalSince(serving) >= readinessBudget {
                    EngineLog.emit(
                        "[AetherEngine] live reload watchdog: AVPlayer item never reached "
                        + "readyToPlay \(Int(readinessBudget))s after the producer started "
                        + "serving (segments=\(self.nativeVideoSession?.liveSegmentCount ?? -1), "
                        + "serverBytes=\(self.nativeVideoSession?.serverLifetimeBytesSent ?? -1)); "
                        + "failing the reload so the host can retune",
                        category: .engine
                    )
                    self.stopInternal()
                    self.state = .error("Live reload failed: player never became ready")
                    return
                }
                if Date().timeIntervalSince(started) >= overallBudget { return }
            }
        }
    }

    /// Called (once per session) when either backend's HDR10+ scan
    /// catches a T.35 metadata payload. The host's badge tracks
    /// `videoFormat`, so flipping `.hdr10 → .hdr10Plus` here is what
    /// gets the badge to read "HDR10+". Guarded against upgrading
    /// non-HDR10 states: a DV / HLG / SDR-clamped session that also
    /// happens to carry HDR10+ metadata stays on its current format
    /// because we have no evidence the panel is rendering an HDR10
    /// base layer in those cases.
    @MainActor
    private func handleHDR10PlusDetected() {
        // Source upgrade runs independently of the panel guard below:
        // a T.35 payload in the stream is a property of the file, so an
        // HDR10 source that's currently clamped to .sdr for an SDR panel
        // still has its sourceVideoFormat correctly bumped to .hdr10Plus.
        if sourceVideoFormat == .hdr10 {
            sourceVideoFormat = .hdr10Plus
        }
        guard videoFormat == .hdr10 else { return }
        EngineLog.emit("[AetherEngine] HDR10+ T.35 detected, upgrading videoFormat .hdr10 → .hdr10Plus", category: .engine)
        videoFormat = .hdr10Plus
    }
}
