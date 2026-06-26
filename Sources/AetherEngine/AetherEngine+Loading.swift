import Foundation
import AVFoundation
import Combine
import Libavformat
import Libavcodec
import Libavutil

extension AetherEngine {

    /// Wire `$duration`, `$isReady`, `$failureMessage`, `$didReachEnd` into the cancellable set. Pass `isReady: nil` for paths that skip the readiness -> .paused waypoint (e.g. loadRemoteHLS).
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
        didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in self?.state = .ended }
            .store(in: &cancellables)
    }

    /// Lean native-HLS live path: AVPlayerItem from the remote URL on the reused NativeAVPlayerHost. No Demuxer, no HLSVideoEngine, no loopback, no display-criteria handshake (AVKit drives match-content). Live-window surfaces come from `host.seekableEnd`.
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
        // No loopback producer; playhead is the raw AVPlayer clock. Shift stays 0.
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
                // sourceTime owned by $renderedTime to track the picture across a seek (issue #49); shift=0 here so it equals currentTime in steady play.
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd)
                }
            }
            .store(in: &nativeCancellables)
        host.$renderedTime
            .sink { [weak self] value in
                self?.clock.sourceTime = value
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
        // isReady: nil deliberately: autostart already called host.play(), so readyToPlay is only a waypoint. Flipping to .paused here would drop the spinner during Jellyfin's ~10 s transcode spin-up. timeControlStatus sink holds .loading until AVPlayer renders.
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: nil,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &nativeCancellables
        )
        // Track AVPlayer's REAL transport state. Eager .playing caused a ~10 s black screen during Jellyfin transcode spin-up.
        host.$timeControlStatus
            .sink { [weak self] status in
                guard let self = self else { return }
                if case .error = self.state { return }
                // .ended is terminal like .idle: a late .waitingToPlayAtSpecifiedRate from AVPlayer parked at
                // end must not flip it back to .loading (live HLS can reach real end-of-media).
                if self.state == .idle || self.state == .ended { return }
                // isBuffering only once playing (not during live startup spin-up).
                self.isBuffering = self.state == .playing && status == .waitingToPlayAtSpecifiedRate
                switch status {
                case .playing:
                    if self.state != .playing { self.state = .playing }
                case .waitingToPlayAtSpecifiedRate:
                    // Hold .loading through startup (hasStartedPlaying gate on the host side).
                    if self.state != .playing { self.state = .loading }
                case .paused:
                    // Only an explicit user pause; ignore transient pre-roll paused at load.
                    if self.state == .playing { self.state = .paused }
                @unknown default:
                    break
                }
            }
            .store(in: &nativeCancellables)

        // Jellyfin HLS URL carries auth (ApiKey / PlaySessionId / LiveStreamId) as query params; no extra headers needed.
        // forwardBufferDuration: 0 = system-adaptive; the 4 s VOD floor caused a 3-4 s black screen on live startup.
        host.load(url: url,
                  startPosition: nil,
                  perFrameHDR: true,
                  skipInitialSeek: true,
                  forwardBufferDuration: 0,
                  // This lean path has no live-reopen / readiness watchdog; let AVPlayer's "gave up"
                  // signal surface a dead upstream (segment 404 / token expiry) so the host can retune.
                  surfaceEndFailures: true)

        // VOD path triggers play() at the tail of load(); this lean path early-returns, so self-start here. AVKit drives match-content; automaticallyWaitsToMinimizeStalling handles play-before-ready. Without this call the item reaches readyToPlay but timeControlStatus stays .paused.
        // State stays .loading; flips to .playing only when timeControlStatus sink sees AVPlayer rendering.
        host.play()
        startMemoryProbe()
        // No startLiveTelemetrySampler: all sampler counters read the loopback pipeline (demuxer / producer / cache / server), none of which exists on this bypass.
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
        // Both values are set by the reader's resolver before any main-stream byte flows, so they are final by the time loadNative runs.
        // HLSVideoEngine uses liveSourceCadenceHint for playlist shaping (TARGETDURATION floor, blocking-reload eligibility).
        // companionAudioReader: side demuxer for demuxed-audio ingest; nil means muxed audio.
        let liveSourceCadenceHint = (customReader as? LiveIngestSourceInfo)?.upstreamTargetDuration
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
            companionAudioReader: companionAudioReader,
            // Caller-bounded probe budget (#68) for the fallback open / live reopen; the happy path reuses preopenedDemuxer.
            probesize: loadedOptions.probesize,
            maxAnalyzeDuration: loadedOptions.maxAnalyzeDuration
        )
        session.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        session.onPlaylistShiftChanged = { [weak self] seconds in
            Task { @MainActor in
                guard let self = self else { return }
                let prevShift = self.playlistShiftSeconds
                let delta = seconds - prevShift
                self.playlistShiftSeconds = seconds
                // Seed seam history: activateAt=-.infinity covers the full output timeline from the start.
                self.liveShiftSeams = [(activateAt: -.infinity, shift: seconds)]
                // Re-fold immediately so currentTime (source PTS) doesn't lag the next periodic tick.
                self.clock.currentTime = self.nativeClockSeconds + seconds
                // sourceTime re-folds on next $renderedTime tick; keeping it there tracks the rendered picture, not the optimistic clock (#49).
                // #65 diag: every VOD producer (re)start collapses the seam history to one entry here. If `delta`
                // is non-zero while AVPlayer still holds old-epoch buffer (avBufAhead > 0), the buffered bytes
                // keep folding with the NEW shift, so the picture leads the folded clock by ~delta. A burst that
                // logs two distinct shift= values confirms the cross-epoch divergence (Root A); an invariant
                // shift across the burst points at the orthogonal playlist-startSeconds-vs-tfdt root (Root B).
                EngineLog.emit(
                    "[AetherEngine] #65 VOD shift published: \(String(format: "%.3f", seconds))s "
                    + "(prev \(String(format: "%.3f", prevShift))s, delta \(String(format: "%.3f", delta))s, "
                    + "changed=\(abs(delta) > 0.001 ? "YES" : "no")) seams->1 "
                    + "rawClock=\(String(format: "%.2f", self.nativeClockSeconds))s "
                    + "avBufAhead=\(String(format: "%.2f", self.avPlayerBufferAheadSeconds()))s",
                    category: .session
                )
            }
        }
        session.onSeekStateChanged = { [weak self] inFlight, playlistTime in
            Task { @MainActor in
                guard let self = self else { return }
                // Fold playlist-axis segment time onto source-PTS axis for seekTarget/currentTime (#38). nil clears without disturbing the last value.
                let target = playlistTime.map { $0 + self.playlistShiftSeconds }
                self.setNativeScrubSeek(inFlight: inFlight, target: target)
            }
        }
        // #65: let the producer read AVPlayer's real position off-main when it re-anchors on a backpressure wedge.
        session.currentPlaybackPositionProvider = { [renderedPositionMirror] in renderedPositionMirror.get() }
        session.onPlaylistShiftRebased = { [weak self] seconds, seamOutputSeconds in
            Task { @MainActor in
                guard let self = self else { return }
                // Program boundary: producer rebased but AVPlayer is still rendering old program (buffer + holdback). Record the seam so $currentTime resolves the active shift from history, keeping currentTime/sourceTime behind what is on screen. Backward DVR seeks re-apply the pre-seam shift. Seams append in output-timeline order (continuation dts is monotonic).
                self.liveShiftSeams.append(
                    (activateAt: seamOutputSeconds, shift: seconds)
                )
                if self.liveShiftSeams.count > 64 {
                    // Cap history; losing the oldest only reduces fidelity for DVR positions past 60+ program boundaries.
                    self.liveShiftSeams.removeFirst(self.liveShiftSeams.count - 64)
                }
            }
        }
        session.onLiveSourceReset = { [weak self, weak session] in
            Task { @MainActor in
                // Stale session (superseded by a zap) must not retune the current channel.
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
        // prepareNativeSubtitles + non-bitmap text tracks: flag gates allocateMuxer SubtitleConfig; must be set before start() (#55).
        // TrackInfo.codec is the lower-case libavcodec name (e.g. "subrip", "ass"). Bitmap codecs excluded:
        let bitmapCodecNames: Set<String> = [
            "hdmv_pgs_subtitle", "dvb_subtitle", "dvd_subtitle", "xsub"
        ]
        // Each text track becomes one mov_text track in the init moov (#55, all-tracks). Sidecar entries append at runtime; this table is embedded-only.
        let textTracks = subtitleTracks.filter { !bitmapCodecNames.contains($0.codec) }
        nativeSubtitleTrackTable = textTracks.map { track in
            NativeSubtitleTrackEntry(sourceStreamIndex: track.id, language: track.language)
        }
        // displayName = locale's language name or "Subtitle <n>" (1-based). Uses Locale.current like AVKit's built-in labels.
        nativeSubtitleTracks = nativeSubtitleTrackTable.enumerated().map { ordinal, entry in
            let name: String
            if let lang = entry.language,
               let localizedName = Locale.current.localizedString(forIdentifier: lang) {
                name = localizedName
            } else {
                name = "Subtitle \(ordinal + 1)"
            }
            return NativeSubtitleTrack(ordinal: ordinal, language: entry.language, displayName: name)
        }
        let hasTextSubtitleTrack = !nativeSubtitleTrackTable.isEmpty
        session.enableNativeSubtitleTrackForSession = loadedOptions.prepareNativeSubtitles && hasTextSubtitleTrack

        // session.start() opens its own Demuxer + prewarm seek (~1-3 s on slow CDN); detach so @MainActor doesn't block.
        let playbackURL = try await Task.detached(priority: .userInitiated) { [session] in
            try session.start()
        }.value
        // Superseded while starting: stop and unwind before touching shared state.
        if loadGeneration != generation {
            session.stop()
            try checkLoadCurrent(generation)
        }
        self.nativeVideoSession = session

        // #55 all-tracks: one cue store per text track, wired to the session + producer so makeProducer re-threads them across restarts. SEPARATE from the inline selectSubtitleTrack path (which owns subtitleCues / host overlay).
        if session.enableNativeSubtitleTrackForSession, !nativeSubtitleTrackTable.isEmpty {
            let stores = nativeSubtitleTrackTable.map { _ in NativeSubtitleCueStore() }
            let shift = session.playlistShiftSeconds
            stores.forEach { $0.setShiftSeconds(shift) }
            let languages = nativeSubtitleTrackTable.map { $0.language }
            session.nativeSubtitleCueStoresForSession = stores
            session.nativeSubtitleLanguagesForSession = languages
            session.producer?.subtitleCueStores = stores
            session.producer?.nativeSubtitleLanguages = languages
            startNativeSubtitleReaders(url: url, stores: stores)
        }

        // Reuse the existing host across native->native reloads (issue #15): a fresh AVPlayer breaks AVKit's MediaRemote re-registration ("Code=14 client callback"), blanking the Control Center widget. stopInternal kept the host alive (keepNativeHost).
        let host: NativeAVPlayerHost
        if let existing = nativeHost {
            host = existing
        } else {
            host = NativeAVPlayerHost()
        }
        host.playerLayer.videoGravity = _videoGravity
        // Forward pre-load externalMetadata so the AVPlayerItem picks it up before AVPlayer assigns it.
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        applyDesiredVolume(to: host)
        // Publish before wiring mirrors so subscribers see the AVPlayer before the first time update. Only emit on change: re-publishing the same instance retriggers the AVKit re-registration this reuse path avoids.
        if currentAVPlayer !== host.avPlayer {
            self.currentAVPlayer = host.avPlayer
        }

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                // nativeClockSeconds preserves the raw AVPlayer clock for onPlaylistShiftChanged to re-derive against.
                self.nativeClockSeconds = value
                // Newest seam at or before the raw clock wins: activates seams on forward play, re-applies pre-seam shift on backward DVR seeks.
                if let active = self.liveShiftSeams.last(where: { value >= $0.activateAt }) {
                    self.playlistShiftSeconds = active.shift
                }
                self.clock.currentTime = value + self.playlistShiftSeconds
                // sourceTime owned by $renderedTime: tracks the picture across a seek, not the optimistic scrub clock (issue #49).
                // Live edge must fold with the same playlistShiftSeconds as the playhead; opposite sign would make behindLiveSeconds meaningless.
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
                }
            }
            .store(in: &nativeCancellables)
        // sourceTime = AVPlayer's rendered position folded onto source PTS (same seam shift as playhead). Published during seeks so subtitle/scrub consumers follow the picture, not the scrub target (issue #49).
        host.$renderedTime
            .sink { [weak self] value in
                guard let self = self else { return }
                // #65: mirror AVPlayer's rendered (playlist-axis) position for off-main wedge re-anchoring.
                self.renderedPositionMirror.set(value)
                let shift = self.liveShiftSeams.last(where: { value >= $0.activateAt })?.shift
                    ?? self.playlistShiftSeconds
                self.clock.sourceTime = value + shift
                // bufferedPosition = end of AVPlayer's contiguous loadedTimeRanges, folded the same way. Clamp so it never trails the rendered frame (#54).
                self.clock.bufferedPosition = max(value + shift, host.bufferedEnd + shift)
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
                // Reconcile state with external transport commands (AVKit bar, Control Center, hardware button); without this togglePlayPause() is a no-op (swallowed press). .waitingToPlayAtSpecifiedRate maps to .playing so the icon doesn't flicker on rebuffer.
                // isBuffering only once playback has started (not during initial load spin-up).
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

        // appliesPerFrameHDRDisplayMetadata unconditionally true: DV P5 has no HDR10 base layer, so the per-frame RPU is what AVPlayer's tone-mapper needs on a non-DV panel (DrHurt #4 2026-05-26). Prior servingMasterPlaylist gate broke P5. Apple's default is also true; explicit write surfaces the live value in diagnostics.
        // forwardBufferDuration default (4 s): deep buffer lets AVPlayer race to the live edge and hit the transcode warm-up gap head-on (-12888); 4 s PACES consumption. Verified: 8 s worsened startup pause (8-10 s vs ~1 s).
        // Live REJOIN: skip initial seek so AVPlayer picks edge-minus-holdback instead; seek-to-0 against the re-served backlog wedged the reloaded item in waitingToPlay (device repro: tvOS 26, Jellyfin stream.ts). See LiveReloadPolicy.
        host.load(url: playbackURL,
                  startPosition: startPosition,
                  perFrameHDR: true,
                  skipInitialSeek: LiveReloadPolicy.skipInitialSeek(
                      isLive: isLive, isRejoin: liveRejoin))
    }

    /// Activate AVAudioSession for renderer paths (SoftwarePlaybackHost, audio hosts) that have no AVPlayerViewController. Native path deliberately skips this: AVKit activates per playback so tvOS can auto-negotiate the HDMI route (issue #24).
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
        // SW host provides session-relative edge on each tick; publishLiveWindow is a no-op when liveWindow is nil.
        host.onLiveEdge = { [weak self] edge in
            self?.publishLiveWindow(edgeSessionTime: edge)
        }
        self.softwareHost = host
        applyDesiredVolume(to: host)
        // SW path tracks source PTS directly; no AVPlayer-clock fold needed.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        softwareCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
                // bufferedPosition = newest demuxed source PTS, clamped to never trail the playhead (#54).
                self.clock.bufferedPosition = max(value, host.bufferedSessionTime)
            }
            .store(in: &softwareCancellables)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &softwareCancellables
        )

        // Reuse probe demuxer when present (avoids second avformat_open_input; also required for forward-only custom sources). Detach the open so @MainActor keeps ticking.
        // Capture the caller's probe budget (#68) before the detach: loadedOptions is @MainActor-isolated and unreachable inside the closure. Only used on the fallback open (probe absent).
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, isLive, dvrWindowSeconds, probesize, maxAnalyzeDuration] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, profile: .playback.withProbeBudget(probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration), isLive: isLive)
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex,
                isLive: isLive,
                dvrWindowSeconds: dvrWindowSeconds
            )
        }.value
        // Superseded: stop idempotently to tear down the demuxer the detached closure opened, then unwind.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open `AudioPlaybackHost` for an audio-only source. No HLS pipeline, display layer, or display-criteria handshake. Same lifecycle as `loadSoftware`.
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
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        audioCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
                // No buffer-ahead surface on this path; mirror playhead so bufferedPosition stays defined (#54).
                self.clock.bufferedPosition = value
            }
            .store(in: &audioCancellables)
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            failureMessage: host.$failureMessage,
            didReachEnd: host.$didReachEnd,
            storeIn: &audioCancellables
        )

        // Reuse probe demuxer (required for custom sources; no URL to reopen). Detach so @MainActor keeps ticking.
        // Caller's probe budget (#68) captured before the detach; only used on the fallback open (probe absent).
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, probesize, maxAnalyzeDuration] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, profile: .playback.withProbeBudget(probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration))
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
        }.value
        // Superseded: re-stop detached host, then throw.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open `AudioAVPlayerHost` for AVPlayer-decodable audio. Energy-efficient native default; `loadAudio` (FFmpeg) is the fallback. Same lifecycle as `loadAudio`.
    func loadAudioNative(
        url: URL,
        startPosition: Double?,
        httpHeaders: [String: String],
        generation: UInt64
    ) async throws {
        // Reuse the persistent host (MPNowPlayingSession survives across tracks). host.load() swaps the item via replaceCurrentItem.
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
        #if os(iOS) || os(tvOS)
        host.setNowPlayingInfo(pendingAudioNowPlayingInfo)
        #endif

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
        // No timeControlStatus reconciliation on the audio path: all transport flows through engine play()/pause(). Feeding it back mis-latched a TRANSIENT .paused AVFoundation emits on background transition as a real pause, zeroing MPNowPlayingInfoPropertyPlaybackRate and breaking Now-Playing badge + Siri Remote routing.

        // No detached hop: AudioAVPlayerHost.load is MainActor + replaceCurrentItem-based (no blocking I/O), and the host is SHARED. Detaching opened a reorder window where a superseded load A's body ran after successor B, putting A's item back on the shared AVPlayer.
        try checkLoadCurrent(generation)
        try await host.load(url: url, startPosition: startPosition, httpHeaders: httpHeaders)
        // Superseded: don't tear the shared host down (successor may be using it); just unwind before play()/state writes.
        try checkLoadCurrent(generation)
    }

    /// Reconcile published audio state with what the session ACTUALLY plays. Probe diverges in two live shapes: (1) demuxed-audio side demuxer (probe sees no audio), (2) live TS with empty codecpar (av_find_best_stream skips it, engine's codecpar repair picks it). Without this a host calling selectAudioTrack for the already-live track triggers a pointless stall-prone reload.
    func syncPublishedAudioStateFromNativeSession() {
        guard let session = nativeVideoSession else { return }
        // Demuxed-audio: publish the side demuxer's list so picker and active index share one stream numbering.
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

    /// Rebuild the pipeline at the current playhead with an optional audio stream override (nil = keep auto-picked). Re-arms the active subtitle source. Called by `selectAudioTrack` and `reloadAtCurrentPosition`. Snapshots subtitle + playhead INSIDE the task body: a chained `selectSubtitleTrack` lands on MainActor before the body runs; snapshotting at call-site would miss it.
    func reloadWithAudioOverride(
        url: URL,
        audioStreamIndex: Int32?,
        expectedGeneration: UInt64,
        discTitleIDOverride: Int? = nil,
        resumeOverride: Double? = nil
    ) async {
        // Liveness guard: a stop()/load() between scheduling and here would resurrect a dismissed session or kill the successor. Generation captured at schedule time; both stop() and load() invalidate it.
        guard loadGeneration == expectedGeneration, loadedURL != nil else {
            EngineLog.emit("[AetherEngine] reload superseded before start; ignored", category: .engine)
            return
        }
        // Disc title to reopen with: an explicit override (selectTitle on a custom disc) wins, else the title
        // already playing so an audio switch / background-resume doesn't silently revert to the main title (#67).
        let titleToReopen = discTitleIDOverride ?? activeDiscTitleID
        // resumeOverride 0 restarts a title switch at the new title's head; nil keeps the current playhead.
        let resumeAt = resumeOverride ?? currentTime
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
        // Snapshot before stopInternal wipes state. Must reload on the same backend: loadNative on a SW-routed AV1 source throws unsupportedCodec (HLSVideoEngine only accepts HEVC / H.264 / VP9 / probed-AV1).
        let wasOnSoftwarePath = (playbackBackend == .software)
        // Preserve codec so the decoder label can be reconstructed without re-probing.
        let preservedVideoCodec = lastDetectedVideoCodec
        let reloadStart = DispatchTime.now()
        EngineLog.emit("[AetherEngine] reload: stopInternal start", category: .engine)
        // resetDisplayCriteria: false: video format is unchanged; resetting triggers a 5 s waitForSwitch Stage 2 timeout (device test 2026-05-26, Bose SLIII A2DP + 4K HDR10 PQ: each switch added ~12 s black-screen). On the same route a panel SDR drop during the reset window failed the PQ variant with AVFoundationErrorDomain -11868 / CoreMediaErrorDomain -17223.
        // keepNativeHost: !wasOnSoftwarePath preserves the AVPlayer across the switch (issue #15).
        stopInternal(resetDisplayCriteria: false, keepNativeHost: !wasOnSoftwarePath, keepCustomReader: true)
        EngineLog.emit("[AetherEngine] reload: stopInternal done (\(elapsedMs(since: reloadStart))ms)", category: .engine)
        let gen = loadGeneration
        loadedURL = url
        lastDetectedVideoCodec = preservedVideoCodec

        // Custom sources: no URL to reopen; rebuild on the retained reader. Demuxer opens at byte 0; loadSoftware/loadNative seek to startPosition.
        // Preserve the caller's probe budget (#68) across the reopen so an audio/title switch doesn't re-incur the full find_stream_info cost the caller paid to avoid.
        let reloadProfile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: loadedOptions.probesize, maxAnalyzeDuration: loadedOptions.maxAnalyzeDuration)
        var customPreopened: Demuxer? = nil
        if isCustomSource, let reader = customReader {
            let hint = customFormatHint
            do {
                let isLiveReload = loadedOptions.isLive
                customPreopened = try await Task.detached(priority: .userInitiated) {
                    let d = Demuxer()
                    // isLive preserved: a live custom source must not trigger SEEK_END on reopen.
                    // selectTitleID rebuilds the disc concat stream for the chosen title (#67).
                    try d.open(reader: reader, formatHint: hint, profile: reloadProfile, isLive: isLiveReload, selectTitleID: titleToReopen)
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
        } else if titleToReopen != nil {
            // URL/local disc audio switch: the backend would otherwise reopen by URL with no title id and
            // silently revert to the main title. Preopen the disc demuxer with the title so the selection
            // survives the reload (#67). Non-disc URL sources keep customPreopened nil and reopen by URL.
            let headers = loadedOptions.httpHeaders
            do {
                customPreopened = try await Task.detached(priority: .userInitiated) {
                    let d = Demuxer()
                    try d.open(url: url, extraHeaders: headers, profile: reloadProfile, selectTitleID: titleToReopen)
                    return d
                }.value
            } catch {
                EngineLog.emit("[AetherEngine] reload: disc URL reopen failed: \(error)", category: .engine)
                activeAudioTrackIndex = previousAudioIndex
                state = .error("Reload failed: \(error.localizedDescription)")
                return
            }
            if loadGeneration != gen {
                customPreopened?.markClosed()
                if let d = customPreopened {
                    Task.detached { d.close() }
                }
                EngineLog.emit("[AetherEngine] reload superseded after disc URL reopen; unwinding", category: .engine)
                return
            }
        }

        // Capture the reopened title's disc + track metadata before the backend consumes the demuxer
        // (start() nils preopenedDemuxer). Republished after the reload succeeds so a title switch updates
        // the picker; an audio switch / non-disc reload re-publishes identical values, a harmless no-op (#67).
        var reopenedDiscTitles: [TitleInfo] = []
        var reopenedDiscChapters: [ChapterInfo] = []
        var reopenedSelectedTitleID: Int? = nil
        var reopenedAudioTracks: [TrackInfo] = []
        var reopenedSubtitleTracks: [TrackInfo] = []
        var reopenedStartSeconds: Double = 0
        if let pre = customPreopened {
            reopenedDiscTitles = pre.discTitleInfos()
            if !reopenedDiscTitles.isEmpty {
                reopenedDiscChapters = pre.discChapterInfos()
                reopenedSelectedTitleID = pre.selectedDiscTitleID
                reopenedAudioTracks = pre.audioTrackInfos()
                reopenedSubtitleTracks = pre.subtitleTrackInfos()
                // stopInternal zeroed sourceStartSeconds; recapture the software-path chapter-seek base from
                // the reopened demuxer so a DVD chapter seek after an audio switch / custom reload still lands
                // (the native base self-heals via onPlaylistShiftChanged, this one does not). (#67)
                let st = pre.formatStartTime
                reopenedStartSeconds = st > 0 ? Double(st) / Double(AV_TIME_BASE) : 0
            }
        }

        do {
            let loadStart = DispatchTime.now()
            if wasOnSoftwarePath {
                EngineLog.emit("[AetherEngine] reload: loadSoftware enter audio=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
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
                    // isLive required: without it the reload rebuilds as VOD and HLSVideoEngine fails "cannot build segment plan" (device repro: KiKA).
                    isLive: loadedOptions.isLive,
                    dvrWindowSeconds: loadedOptions.dvrWindowSeconds,
                    // Live reload = live REJOIN: skip initial seek so AVPlayer joins at edge-minus-holdback, not the stale rebuilt start. See LiveReloadPolicy.
                    liveRejoin: loadedOptions.isLive,
                    preopenedDemuxer: customPreopened,
                    generation: gen
                )
                EngineLog.emit("[AetherEngine] reload: loadNative done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .native
                // Publish the session's actual pick (invalid override falls back to auto; demuxed-audio resolves in side-demuxer numbering).
                syncPublishedAudioStateFromNativeSession()
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: false
                )
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                presentCurrentLayer()
                // Wait for pending AVKit display-criteria handshake before resuming (first frame must not hit a mid-transition panel).
                await displayCriteria.waitForSwitch()
                try checkLoadCurrent(gen)
                nativeHost?.play()
            }
            try checkLoadCurrent(gen)
            state = .playing
            // Re-arm samplers: stopInternal nilled them, and the reload path bypasses public load() that normally restarts them. Without this, liveTelemetry stays nil and the stats overlay shows "-" after every audio switch.
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

        // Reload succeeded (failure paths returned above). Re-establish disc state stopInternal wiped.
        // Gate the plain id on the same non-empty check as the published picker so the two can never disagree
        // (a non-disc reload leaves both cleared); selectedDiscTitleID is non-nil whenever titles exist (#67).
        if !reopenedDiscTitles.isEmpty {
            activeDiscTitleID = reopenedSelectedTitleID
            discTitles = reopenedDiscTitles
            discChapters = reopenedDiscChapters
            selectedDiscTitle = reopenedSelectedTitleID.flatMap { id in reopenedDiscTitles.first { $0.id == id } }
            sourceStartSeconds = reopenedStartSeconds
            // A title switch changes the title's stream set. The native path already republished the session's
            // real list via syncPublishedAudioStateFromNativeSession above; only the software path, which does
            // not reconcile tracks post-load, needs the probe-derived lists re-applied here.
            if wasOnSoftwarePath {
                audioTracks = reopenedAudioTracks
                subtitleTracks = reopenedSubtitleTracks
            }
        } else {
            activeDiscTitleID = nil
        }

        // Re-arm subtitle: sidecar branch wins because loadedSidecarURL is set only for sidecar sources.
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

    private func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Watchdog for live RELOAD only (not initial joins). Guards the device-verified wedge where the rebuilt AVPlayer item fetched init.mp4 + all segments but never reached `readyToPlay`, leaving a frozen frame forever. Polls 1 Hz; 10 s readiness budget starts only once liveSegmentCount >= 2 AND serverLifetimeBytesSent > 0 (so slow upstreams never misfire). On expiry: stopInternal + state = .error. Hard 60 s lifetime.
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
                guard self.loadGeneration == generation else { return }
                guard self.playbackBackend == .native,
                      let host = self.nativeHost else { return }
                if case .error = self.state { return }
                if self.state == .idle || self.state == .ended { return }
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

    /// Called once per session on T.35 detection. Only upgrades .hdr10 states: a DV / HLG / SDR-clamped session that carries HDR10+ metadata stays on its current format (no evidence the panel is rendering an HDR10 base layer).
    @MainActor
    private func handleHDR10PlusDetected() {
        // sourceVideoFormat upgrade is unconditional: a T.35 payload is a source property even when the panel clamps the output to SDR.
        if sourceVideoFormat == .hdr10 {
            sourceVideoFormat = .hdr10Plus
        }
        guard videoFormat == .hdr10 else { return }
        EngineLog.emit("[AetherEngine] HDR10+ T.35 detected, upgrading videoFormat .hdr10 → .hdr10Plus", category: .engine)
        videoFormat = .hdr10Plus
    }
}
