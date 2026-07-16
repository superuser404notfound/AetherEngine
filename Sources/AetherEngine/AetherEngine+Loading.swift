import Foundation
import AVFoundation
import Combine
import Libavformat
import Libavcodec
import Libavutil

extension AetherEngine {

    /// Apply an AVPlayer clock tick (native VOD/live path) to the engine clock. `nativeClockSeconds`
    /// (the raw pre-shift clock, re-derived against by `onPlaylistShiftChanged`) and the active seam
    /// shift always track it. The UI scrub clock (`clock.currentTime`) is HELD while a recovery seek is
    /// pending (#37 wedge resurface): the original seek's `seekInFlight` clears when it reconciles, so
    /// the 100ms periodic observer resumes publishing, but the recovery nudges (`reengageStalledConsumer`
    /// issues raw AVPlayer seeks to the target) bounce AVPlayer's reported clock between the frozen
    /// position and the transient nudge target (device: engineClock 824 -> 634 -> 824 -> 634 while
    /// avpClock holds). Holding the scrub clock at the reconciled position until the recovery lands
    /// (`pendingRecoverySeekClockTarget` cleared) stops the scrubber from bouncing. `sourceTime` is owned
    /// by the `$renderedTime` sink and is unaffected here (issue #49).
    func applyNativeHostClockTick(_ value: Double) {
        // nativeClockSeconds preserves the raw AVPlayer clock for onPlaylistShiftChanged to re-derive against.
        nativeClockSeconds = value
        // Newest seam at or before the raw clock wins: activates seams on forward play, re-applies pre-seam shift on backward DVR seeks.
        if let active = liveShiftSeams.last(where: { value >= $0.activateAt }) {
            playlistShiftSeconds = active.shift
        }
        if pendingRecoverySeekClockTarget == nil {
            // AE#105: fold the disc's clip-0 STC base back out so the published playhead sits on the same
            // 0-based axis as the MPLS duration (origin 0 for normal/live -> no-op).
            clock.currentTime = PresentationAxis.display(sourcePTS: value + playlistShiftSeconds,
                                                         origin: sourcePresentationOrigin)
        }
        // Live edge must fold with the same playlistShiftSeconds as the playhead; opposite sign would make behindLiveSeconds meaningless.
        if isLive {
            publishLiveWindow(edgeSessionTime: (nativeHost?.seekableEnd ?? 0) + playlistShiftSeconds)
        }
    }

    /// #123: publish `sourceTime` at seek finalize. `sourceTime` is the on-screen frame (#49), not the
    /// scrub target. Settle it onto the landed `target` (source PTS) only when the frame is actually
    /// presented; while the player is still buffering toward the target (a queued-burst chase on heavy
    /// 4K, `bufferingTowardTarget`) the picture is frozen behind it, so leave `sourceTime` on the frame
    /// the `$renderedTime` sink last published. Stamping the target while buffering parks `sourceTime`
    /// tens of seconds ahead of the picture for the whole chase, because the 100 ms periodic observer is
    /// silent while waiting and cannot walk it back, so a host pacing cues off `sourceTime` draws them
    /// over a stale frame (rrgomes' #123 report). The sink settles `sourceTime` onto the target when
    /// playback resumes and the frame is delivered. Extracted from `seek(to:)`'s finalize so the
    /// hold-vs-settle decision is unit-testable without driving a live AVPlayer.
    func applySeekFinalizeSourceTime(target: Double, bufferingTowardTarget: Bool) {
        if Self.seekLandingSettlesToTarget(bufferingTowardTarget: bufferingTowardTarget) {
            clock.sourceTime = target
        }
    }

    /// Wire `$duration`, `$isReady`, `$failureMessage`, `$didReachEnd` into the cancellable set.
    /// `isReady` always feeds the public `isSessionReady` mirror and replays a deferred pre-ready host
    /// seek (#127); pass `settlePausedAtReadiness: false` for paths that skip the readiness -> .paused
    /// waypoint (autostarting loadRemoteHLS, where the terminal play() runs and readiness is a waypoint).
    private func wireCommonHostSinks(
        duration: Published<Double>.Publisher,
        isReady: Published<Bool>.Publisher,
        settlePausedAtReadiness: Bool = true,
        failureMessage: Published<String?>.Publisher,
        didReachEnd: Published<Bool>.Publisher,
        storeIn cancellables: inout Set<AnyCancellable>
    ) {
        duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &cancellables)
        isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                self.isSessionReady = ready
                if ready, settlePausedAtReadiness, self.state == .loading {
                    self.state = .paused
                }
                // #127: replay the latest host seek that arrived while the item was pre-ready.
                if ready, let pending = self.pendingPreReadySeekSeconds {
                    self.pendingPreReadySeekSeconds = nil
                    EngineLog.emit("[AetherEngine] replaying deferred pre-ready seek to \(String(format: "%.2f", pending))s (#127)", category: .engine)
                    Task { @MainActor in await self.seek(to: pending) }
                }
            }
            .store(in: &cancellables)
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
        // A surface bound BEFORE load ran presentCurrentLayer() while nativeHost was still nil
        // (no-op); without this re-present nothing ever attaches host.playerLayer and AVPlayer
        // plays audio into a black view (#120). Mirrors loadNative's post-host call.
        presentCurrentLayer()
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
                // Feed the playhead mirror the remote-HLS audio tap (#95) reads off its ingest task;
                // shift 0 on this path, so the rendered position is the source-PTS playhead.
                self?.renderedPositionMirror.set(value)
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
        // settlePausedAtReadiness off when autostarting: the terminal host.play() runs, so readyToPlay is only a waypoint. Flipping to .paused here would drop the spinner during Jellyfin's ~10 s transcode spin-up. timeControlStatus sink holds .loading until AVPlayer renders.
        // #124: a paused mount (autoplay=false) skips that play(), so the readiness sink settles .loading -> .paused.
        wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            settlePausedAtReadiness: !Self.loadPerformsAutostart(options),
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

        // Jellyfin HLS URLs carry auth (ApiKey / PlaySessionId / LiveStreamId) as query params, but
        // generic live HLS origins (IPTV / Stremio add-on channels) enforce per-stream Referer /
        // User-Agent / Authorization headers, so LoadOptions.httpHeaders rides into the AVURLAsset (#119).
        // forwardBufferDuration: 0 = system-adaptive; the 4 s VOD floor caused a 3-4 s black screen on live startup.
        host.load(url: url,
                  startPosition: nil,
                  perFrameHDR: true,
                  skipInitialSeek: true,
                  forwardBufferDuration: 0,
                  // This lean path has no live-reopen / readiness watchdog; let AVPlayer's "gave up"
                  // signal surface a dead upstream (segment 404 / token expiry) so the host can retune.
                  surfaceEndFailures: true,
                  httpHeaders: options.httpHeaders)

        // VOD path triggers play() at the tail of load(); this lean path early-returns, so self-start here. AVKit drives match-content; automaticallyWaitsToMinimizeStalling handles play-before-ready. Without this call the item reaches readyToPlay but timeControlStatus stays .paused.
        // State stays .loading; flips to .playing only when timeControlStatus sink sees AVPlayer rendering.
        // #124: a paused mount skips the self-start; the wired isReady waypoint settles .loading -> .paused.
        if Self.loadPerformsAutostart(options) {
            host.play()
        }
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
            maxAnalyzeDuration: loadedOptions.maxAnalyzeDuration,
            forwardBufferSegments: loadedOptions.forwardBufferSegments
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
                // AE#105: a disc title's raw source PTS starts at clip 0's STC base (= this constant VOD shift)
                // while its duration is the 0-based MPLS/IFO playlist length. Anchor the display origin to that
                // base so the published playhead is 0-based like the total. Normal/live sources keep origin 0
                // (their public axis already equals source PTS), so this whole change is a no-op off disc.
                self.sourcePresentationOrigin = (!self.discTitles.isEmpty && !self.isLive) ? seconds : 0
                // Seed seam history: activateAt=-.infinity covers the full output timeline from the start.
                self.liveShiftSeams = [(activateAt: -.infinity, shift: seconds)]
                // Re-fold immediately so currentTime doesn't lag the next periodic tick (origin-corrected).
                self.clock.currentTime = PresentationAxis.display(sourcePTS: self.nativeClockSeconds + seconds,
                                                                  origin: self.sourcePresentationOrigin)
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
                    + "presentationOrigin=\(String(format: "%.3f", self.sourcePresentationOrigin))s "
                    + "rawClock=\(String(format: "%.2f", self.nativeClockSeconds))s "
                    + "avBufAhead=\(String(format: "%.2f", self.avPlayerBufferAheadSeconds()))s",
                    category: .session
                )
            }
        }
        session.onSeekStateChanged = { [weak self] inFlight, playlistTime in
            Task { @MainActor in
                guard let self = self else { return }
                // Fold playlist-axis segment time onto the published display axis (#38); the origin keeps a disc
                // scrub target 0-based like currentTime (0 off disc). nil clears without disturbing the last value.
                let target = playlistTime.map {
                    PresentationAxis.display(sourcePTS: $0 + self.playlistShiftSeconds, origin: self.sourcePresentationOrigin)
                }
                self.setNativeScrubSeek(inFlight: inFlight, target: target)
                // #112: a producer restart settles here (out-of-range fetch on a fast-forward, or a wedge reconcile)
                // without going through seek()'s landing, so the embedded PGS side reader is never re-armed. Give it
                // a debounced re-anchor once the restart run drains; it no-ops unless the retained store fails to
                // cover the playhead. onSeekStateChanged is emitted only from the restart path, never for an ordinary
                // in-budget seek, so this does not disturb the normal seek re-arm.
            }
        }
        session.onNetworkPhaseChanged = { [weak self] phase in
            Task { @MainActor in self?.setReaderNetworkPhase(phase) }
        }
        // #65: let the producer read AVPlayer's real position off-main when it re-anchors on a backpressure wedge.
        session.currentPlaybackPositionProvider = { [renderedPositionMirror] in renderedPositionMirror.get() }
        // #65 pause false-positive: let the producer read AVPlayer's play intent off-main so its backpressure
        // wedge detector suspends while the consumer is paused. Set before start() so makeProducer captures it.
        session.playIntentProvider = { [playIntentMirror] in playIntentMirror.get() }
        // #35/#93 cold-startup: let the producer read whether the first frame has landed, so its wedge
        // detector stays suspended through a slow DV-master pre-roll instead of re-anchoring and livelocking.
        session.hasStartedRenderingProvider = { [hasRenderedFirstFrameMirror] in hasRenderedFirstFrameMirror.get() }
        // #93 retest: let the wedge re-anchor aim the producer at a pending unlanded user seek target
        // instead of the frozen clock (same decision the nudge and stage-2 reload apply).
        session.recoverySeekTargetProvider = { [recoverySeekTargetMirror] in recoverySeekTargetMirror.get() }
        // #93 residual: after a wedge re-anchor with a consumer that stopped requesting entirely,
        // nudge AVPlayer: a zero-tolerance seek to its own position rebuilds AVFoundation's loading
        // pipeline (the effect a manual back-out had). Opens the spurious-pause window too, since
        // the nudge can bounce the transport state.
        session.onConsumerReengageNeeded = { [weak self] position in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reengageStalledConsumer(position: position, trigger: "wedge re-anchor")
                // #93 startup: a loader that died BEFORE the first frame never posts
                // playbackStalled, so this path arms its own stage-2 escalation instead of
                // relying on the stall watchdog. Same contract as the watchdog's stage 2:
                // fetches still frozen after the grace window while waitingToPlay on a
                // healthy item means only a fresh AVPlayerItem revives the loader.
                let fetchesAfterNudge = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                self.stallReengageTask?.cancel()
                self.stallReengageTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.stallReengageGraceSeconds * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    let fetchesFinal = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                    guard fetchesFinal == fetchesAfterNudge,
                          let player = self.currentAVPlayer,
                          player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          player.currentItem?.status != .failed else { return }
                    // #115: read the position at reload time, same as the stall watchdog's
                    // stage 2; the wedge-trip capture is two grace windows stale by now.
                    self.reloadStalledConsumerItem(position: player.currentTime().seconds)
                }
            }
        }
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
        // #126: zero-progress VOD pump death (readError before any packet/segment). Without this
        // the host sees isPlayable=true, tracks=0, waitingToPlay until its own first-frame timeout.
        session.onVODSourceFailed = { [weak self, weak session] code in
            Task { @MainActor in
                guard let self, let session, self.nativeVideoSession === session else {
                    EngineLog.emit(
                        "[AetherEngine] onVODSourceFailed dropped: session superseded or deallocated",
                        category: .session
                    )
                    return
                }
                self.state = .error("Source read failed before any media was produced (code \(code))")
            }
        }
        // prepareNativeSubtitles + non-bitmap text tracks: builds the native subtitle table; must be set before start().
        // Each text track becomes one WebVTT rendition served by HLSLocalServer (#15 / Sodalite#32, all-tracks; NOT
        // muxed into the A/V segments). Load-declared external tracks are already merged into subtitleTracks and join
        // the table (#88); VOD only, a live program's renditions cannot cover an unbounded timeline. Runtime sidecar
        // selections stay table-less.
        // Bitmap codecs excluded via the shared decoder-name classifier (a prior exact-match Set used descriptor
        // names that never matched TrackInfo.codec's decoder names, so PGS/DVB/DVD leaked in).
        // Exclude in-band CEA-608/708 (#77): no demuxable packets for a text rendition; served by the CC tap.
        var textTracks = subtitleTracks.filter {
            !Self.isBitmapSubtitleCodec($0.codec) && !Self.isEmbeddedClosedCaptionCodec($0.codec)
                && (!$0.isExternal || !loadedOptions.isLive)
        }
        // Sodalite#32: AVKit reliably renders only the FIRST native subtitle rendition (ordinal 0 / subs_0);
        // device-confirmed that a programmatic selection of a later rendition is fetched then dropped after one
        // segment. So move the preferred-language track to ordinal 0 and have the host select ordinal 0.
        if !loadedOptions.nativeSubtitlePreferredLanguages.isEmpty {
            for pref in loadedOptions.nativeSubtitlePreferredLanguages {
                if let idx = textTracks.firstIndex(where: { AetherEngine.languageMatches($0.language, pref) }) {
                    if idx != 0 { textTracks.insert(textTracks.remove(at: idx), at: 0) }
                    break
                }
            }
        }
        nativeSubtitleTrackTable = textTracks.map { track in
            NativeSubtitleTrackEntry(sourceStreamIndex: track.isExternal ? nil : track.id,
                                     externalID: track.isExternal ? track.id : nil,
                                     language: track.language,
                                     isForced: track.isForced)
        }
        // Rendition metadata built ONCE (unique NAMEs + FORCED); the published track list and the
        // master's EXT-X-MEDIA tags must agree, and duplicate names collapse AVFoundation's
        // legible options (device: 3 declared renditions, 2 options, wrong-language selection).
        let renditionInfos = Self.nativeSubtitleRenditionInfos(for: nativeSubtitleTrackTable)
        nativeSubtitleTracks = renditionInfos.enumerated().map { ordinal, info in
            NativeSubtitleTrack(ordinal: ordinal, language: info.language, displayName: info.name)
        }
        let hasTextSubtitleTrack = !nativeSubtitleTrackTable.isEmpty
        // #98: an in-band CEA-608 track (no text track needed) also warrants the native path so its
        // decoded cues can ride a WebVTT rendition (survives PiP/AirPlay) instead of overlay-only.
        let hasCC608 = subtitleTracks.contains { Self.isEmbeddedClosedCaptionCodec($0.codec) }
        session.enableNativeSubtitleTrackForSession = loadedOptions.prepareNativeSubtitles && (hasTextSubtitleTrack || hasCC608)
        // Sodalite#32 Phase 2: tap decoders honor the host's markup preference (overlay renders styled
        // ASS; the WebVTT rendition strips at serve). #112 rework: the overlay itself is fed by the
        // packet-store drainer, not by tap-event forwarding.
        session.preserveASSMarkupForSubtitleTap = loadedOptions.preserveASSMarkup
        EngineLog.emit("[AetherEngine] native subtitles: prepare=\(loadedOptions.prepareNativeSubtitles) eager=\(loadedOptions.eagerNativeSubtitleReaders) textTracks=\(nativeSubtitleTrackTable.count) enable=\(session.enableNativeSubtitleTrackForSession)", category: .engine)

        // #77: arm the in-band CC tap before start() so the first producer keeps the CC stream.
        setupClosedCaptionTapIfNeeded(session: session)

        // #15: create the native subtitle cue stores BEFORE start() so the VideoSegmentProvider receives the
        // references at init (the WebVTT rendition master tags + /subs endpoints read them; readers fill them
        // lazily on selection). The shift is applied after start() once the playlist shift is known.
        if session.enableNativeSubtitleTrackForSession, (!nativeSubtitleTrackTable.isEmpty || hasCC608) {
            session.nativeSubtitleCueStoresForSession = nativeSubtitleTrackTable.map { _ in NativeSubtitleCueStore() }
            session.nativeSubtitleLanguagesForSession = nativeSubtitleTrackTable.map { $0.language }
            session.nativeSubtitleRenditionInfosForSession = renditionInfos
            // Sodalite#32: stream indices arm the producer's subtitle pump tap, which harvests cue packets
            // from the main pump's existing read (no side-channel bandwidth) for the produced region.
            session.nativeSubtitleSourceStreamIndicesForSession = nativeSubtitleTrackTable.map { $0.sourceStreamIndex.map(Int32.init) }
            // Sodalite#32: the native rendition matching the preferred subtitle language must be the master's
            // DEFAULT=YES one, because a host-selected legible track only renders if it is the group default
            // (AVKit hides a non-default selection as mute-only). Resolved here, before start() builds the
            // master, so the default is correct on AVKit's first fetch; the host selects this same ordinal.
            var defaultOrdinal = 0
            for pref in loadedOptions.nativeSubtitlePreferredLanguages {
                if let idx = nativeSubtitleTrackTable.firstIndex(where: { AetherEngine.languageMatches($0.language, pref) }) {
                    defaultOrdinal = idx
                    break
                }
            }
            session.nativeSubtitleDefaultOrdinal = defaultOrdinal
            nativeSubtitleDefaultOrdinal = defaultOrdinal
            // #98: bridge the in-band CEA-608 track into a native rendition. Its cues come from the
            // ClosedCaptionTap (no FFmpeg decoder, so the side-demuxer reader self-skips it), so we
            // append a store the tap fills and expose it as the last native subtitle ordinal. Never
            // the default: 608 is user-selected.
            if let ccTrack = subtitleTracks.first(where: { Self.isEmbeddedClosedCaptionCodec($0.codec) }) {
                let ccStore = NativeSubtitleCueStore()
                self.ccNativeStore = ccStore
                let ccOrdinal = session.nativeSubtitleCueStoresForSession.count
                let ccName = ccTrack.language.map { "CC (\($0))" } ?? "Closed Captions"
                session.nativeSubtitleCueStoresForSession.append(ccStore)
                session.nativeSubtitleLanguagesForSession.append(ccTrack.language)
                session.nativeSubtitleRenditionInfosForSession.append(
                    NativeSubtitleRenditionInfo(language: ccTrack.language, name: ccName, isForced: false))
                session.nativeSubtitleSourceStreamIndicesForSession.append(Int32(ccTrack.id))
                nativeSubtitleTrackTable.append(
                    NativeSubtitleTrackEntry(sourceStreamIndex: ccTrack.id, language: ccTrack.language))
                nativeSubtitleTracks.append(
                    NativeSubtitleTrack(ordinal: ccOrdinal, language: ccTrack.language, displayName: ccName))
            }
            // Sodalite#32: with eager readers the whole cue set is available up front, so serve the rendition as
            // one whole-program .vtt (the AVPlayer-reliable shape). VOD only (a live program has no fixed end).
            // Sodalite#32: whole-program renders reliably but is anchored to the stream start, so it breaks on
            // scrub (the loopback producer-restarts + re-anchors the video on seek, but AVKit keeps the cached
            // VOD .vtt). Use the WINDOWED shape (per-segment, 1:1 with the video segments) which AVKit re-fetches
            // at each position and is seek-robust; combined now with a COMPLETE store (read-to-EOF) so no window
            // is served empty (the earlier windowed sparse-fetch was tested with an incomplete parking reader).
            session.nativeSubtitleWholeProgram = false
            session.subtitleStreamStartSeconds = startPosition ?? 0
            EngineLog.emit("[AetherEngine] native subtitle default ordinal=\(defaultOrdinal) wholeProgram=\(session.nativeSubtitleWholeProgram) prefLangs=\(loadedOptions.nativeSubtitlePreferredLanguages) trackLangs=\(nativeSubtitleTrackTable.map { $0.language ?? "?" })", category: .engine)
        }

        // #93 residual: hand the resume position to the session so the FIRST producer anchors at
        // the matching segment instead of producing seg0 into an immediate teardown.
        session.initialStartSeconds = startPosition

        // session.start() opens its own Demuxer + prewarm seek (~1-3 s on slow CDN); detach so @MainActor doesn't block.
        var playbackURL = try await Task.detached(priority: .userInitiated) { [session] in
            try session.start()
        }.value
        #if os(iOS)
        // AirPlay (#86): while external playback is active, serve the loopback over the device's LAN IP and
        // force the media playlist, so the receiver reaches the engine-processed stream (DV/Atmos/subtitles
        // preserved) and isn't handed a DV/HDR master it rejects on an SDR panel (DrHurt). Reverts on the
        // reload when AirPlay ends.
        if airPlayActive, let lanURL = airPlayPlaybackURL(base: playbackURL) {
            EngineLog.emit("[AirPlay] loadNative serving via \(lanURL.absoluteString)", category: .engine)
            playbackURL = lanURL
        }
        #endif
        // Superseded while starting: stop and unwind before touching shared state.
        if loadGeneration != generation {
            session.stop()
            try checkLoadCurrent(generation)
        }
        self.nativeVideoSession = session
        nativeSubtitleRenditionsServed = session.servingMasterPlaylist
        extractorYieldState.activate(session: session)

        // #15: the stores were created before start() (above) so the VideoSegmentProvider got the references at
        // init for the WebVTT rendition. Now that the playlist shift is known, apply it, and arm the lazy
        // readers (started only when a native track is selected / PiP). The producer no longer muxes subtitles.
        if session.enableNativeSubtitleTrackForSession {
            let stores = session.nativeSubtitleCueStoresForSession
            if !stores.isEmpty {
                let shift = session.playlistShiftSeconds
                stores.forEach { $0.setShiftSeconds(shift) }
                nativeSubtitleReaderParams = (url: url, stores: stores)
                // #88: load-declared external tracks fill their stores with one whole-file decode
                // each (no side demuxer); embedded tracks keep the pump-tap / reader paths below.
                startExternalNativeStoreFill(session: session)
                // Sodalite#32: the producer's pump tap fills these stores for the whole produced region at
                // zero side-channel bandwidth, so the eager at-load readers (which competed with playback
                // for the remote link at startup) are only a fallback for sessions whose tap could not arm
                // (no demuxable stream indices, e.g. all-sidecar). The lazy reader on PiP selection stays:
                // it covers AVKit's ~240s forward .vtt prefetch burst beyond the produced region.
                let tapArmed = session.nativeSubtitleSourceStreamIndicesForSession.contains { $0 != nil }
                if loadedOptions.eagerNativeSubtitleReaders && !tapArmed {
                    // Anchor at the SESSION START POSITION (resume), not 0, and read straight to EOF (no
                    // read-ahead parking). A from-0 read behind a resume position spent the whole session
                    // catching up over a remote link and never covered the playhead (device: readMax 48s vs
                    // playhead 304s, every .vtt served empty).
                    let readEOF = !loadedOptions.isLive
                    startNativeSubtitleReaders(url: url, stores: stores,
                                               readToEOF: readEOF, startAtSeconds: startPosition ?? 0)
                    EngineLog.emit("[AetherEngine] native subtitle eager readers started: stores=\(stores.count) readToEOF=\(readEOF) startAt=\(String(format: "%.1f", startPosition ?? 0))", category: .engine)
                } else if tapArmed {
                    EngineLog.emit("[AetherEngine] pump tap active; eager readers skipped (lazy reader covers the select burst)", category: .engine)
                }
            }
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
                self?.applyNativeHostClockTick(value)
            }
            .store(in: &nativeCancellables)
        // sourceTime = AVPlayer's rendered position folded onto source PTS (same seam shift as playhead). Published during seeks so subtitle/scrub consumers follow the picture, not the scrub target (issue #49).
        host.$renderedTime
            .sink { [weak self] value in
                guard let self = self else { return }
                // #93 PiP skips: AVKit-side seeks never reach the engine seek API; a far rendered-
                // time jump is the engine-visible signal to re-anchor the subtitle readers.
                if Self.isSubtitleReanchorJump(from: self.renderedPositionMirror.get(), to: value) {
                    self.scheduleNativeSubtitleReanchor()
                }
                // #93 retest: retire the pending recovery seek target when it lands (rendered
                // reaches its neighbourhood) or goes stale (organic progress far from it, i.e.
                // AVPlayer abandoned the seek and playback runs elsewhere).
                if let pending = self.pendingRecoverySeekClockTarget {
                    if Self.pendingSeekLanded(rendered: value, target: pending) {
                        self.setPendingRecoverySeekTarget(nil)
                    } else {
                        let prev = self.lastRenderedForPendingSeek
                        if value > prev, value - prev < 1.0 {
                            self.pendingSeekProgressAccum += (value - prev)
                            if Self.isPendingSeekStale(progressWhilePending: self.pendingSeekProgressAccum) {
                                EngineLog.emit(
                                    "[AetherEngine] pending recovery seek target "
                                    + String(format: "%.2f", pending)
                                    + "s dropped (playback resumed elsewhere)",
                                    category: .engine
                                )
                                self.setPendingRecoverySeekTarget(nil)
                            }
                        }
                        self.lastRenderedForPendingSeek = value
                    }
                }
                // #65: mirror AVPlayer's rendered (playlist-axis) position for off-main wedge re-anchoring.
                self.renderedPositionMirror.set(value)
                let shift = self.liveShiftSeams.last(where: { value >= $0.activateAt })?.shift
                    ?? self.playlistShiftSeconds
                self.clock.sourceTime = value + shift
                // bufferedPosition = the disk SegmentCache read-ahead frontier (origin -> disk), which is
                // what the Network Buffer setting controls, expressed on the display axis as the playhead
                // plus the seconds of contiguously cached-ahead content. Replaces AVPlayer's shallow ~4 s
                // loadedTimeRanges end (pinned by preferredForwardBufferDuration), which did not move with
                // the setting. readAhead >= 0 keeps the #54 contract that bufferedPosition never trails the
                // rendered frame. Drawn against the 0-based duration, so map onto the display axis to keep
                // the buffer bar aligned with currentTime (0 off disc). AE#105. See docs issue #33 follow-up.
                let renderedDisplay = PresentationAxis.display(
                    sourcePTS: value + shift, origin: self.sourcePresentationOrigin)
                let readAhead = self.nativeVideoSession?
                    .contiguousForwardReadAheadSeconds(playlistSeconds: value) ?? 0
                self.clock.bufferedPosition = renderedDisplay + max(0, readAhead)
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
            .sink { [weak self, weak host] status in
                guard let self = self else { return }
                // #93 residual: during active stall recovery AVPlayer can drop a SPURIOUS .paused
                // (rate 0, no wait reason, no user action). Latching it kills both recovery paths,
                // so re-assert play() within the bounded window instead (see stallRecoveryWindowUntil).
                if Self.shouldReassertPlayDuringRecovery(
                    statusIsPaused: status == .paused,
                    engineStateIsPlaying: self.state == .playing,
                    now: Date(), windowUntil: self.stallRecoveryWindowUntil,
                    reasserts: self.stallRecoveryReasserts
                ) {
                    self.stallRecoveryReasserts += 1
                    EngineLog.emit(
                        "[AetherEngine] #65 spurious pause during stall recovery; re-asserting play "
                        + "(\(self.stallRecoveryReasserts)/\(Self.maxStallRecoveryReasserts))",
                        category: .engine
                    )
                    host?.play()
                    return
                }
                // #65 pause false-positive: mirror AVPlayer's play intent for the off-main producer wedge detector.
                // != .paused covers both .playing and .waitingToPlay, so a deep rebuffer (wants to play, starved)
                // still reads as play-intent and can legitimately trip the breaker; only a real pause suspends it.
                self.playIntentMirror.set(status != .paused)
                // #35/#93 startup latch: the first true .playing (rate running, not .waitingToPlay) means
                // pre-roll is over and a frame is presenting. Arms the backpressure wedge detector, which
                // stays suspended before this so a slow DV-master pre-roll is never re-anchored. Latched
                // for the item (reset only by load()), so a later backward-seek wedge (#93) still trips.
                if status == .playing { self.hasRenderedFirstFrameMirror.set(true) }
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

        // #93 residual: every stall opens the spurious-pause recovery window (a fresh stall resets
        // the re-assert budget; the pause can trail the stall by tens of seconds while fetches stay
        // silent) AND arms the fast re-engage watchdog: the producer-wedge chain needs ~60 s before
        // its nudge, but a dead consumer pipeline (-15628 signature: stall, then ZERO media fetches
        // while waitingToPlay) is detectable within seconds of the notification.
        host.$stallCount
            .dropFirst()
            .sink { [weak self, weak host] count in
                guard let self = self else { return }
                self.stallRecoveryWindowUntil = Date().addingTimeInterval(Self.stallRecoveryWindowSeconds)
                self.stallRecoveryReasserts = 0
                let fetchesAtStall = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                self.stallReengageTask?.cancel()
                self.stallReengageTask = Task { @MainActor [weak self, weak host] in
                    // Stage 1: nudge seek. Device-proven to reach AVPlayer (rate re-asserts)
                    // but NOT always to revive its loader; stage 2 covers that.
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.stallReengageGraceSeconds * 1_000_000_000))
                    guard !Task.isCancelled, let self, let host,
                          host.stallCount == count else { return }
                    let fetchesNow = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                    guard fetchesNow == fetchesAtStall,
                          let player = self.currentAVPlayer,
                          player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          player.currentItem?.status != .failed else { return }
                    self.reengageStalledConsumer(
                        position: player.currentTime().seconds,
                        trigger: "stall + \(Int(Self.stallReengageGraceSeconds))s without fetches")
                    // Stage 2: the -15628 loader poison ignores seeks; only a fresh item resets
                    // it. Escalate when the consumer stays silent through a second grace window.
                    let fetchesAfterNudge = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.stallReengageGraceSeconds * 1_000_000_000))
                    guard !Task.isCancelled, host.stallCount == count else { return }
                    let fetchesFinal = self.nativeVideoSession?.mediaFetchCountSnapshot ?? 0
                    guard fetchesFinal == fetchesAfterNudge,
                          let player2 = self.currentAVPlayer,
                          player2.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                          player2.currentItem?.status != .failed else { return }
                    self.reloadStalledConsumerItem(position: player2.currentTime().seconds)
                }
            }
            .store(in: &nativeCancellables)

        // #93 round 3: accumulated -12889 media timeouts (a wedge-window segment outliving
        // AVPlayer's ~3.5 s time-to-first-byte watchdog) fire failedToPlayToEndTime and park the
        // item at rate 0 / tcs .paused with item.status often still readyToPlay. Every recovery
        // layer above reads that pause as user intent and disarms (producer wedge detector
        // suspends, nudge and stage-2 guard on .paused), which made the session terminal from the
        // couch. Item death is categorically NOT user intent: confirm it survived the deferred
        // window (a transient that resumes self-clears, same contract as the .failed KVO), then
        // reload through the stage-2 chain with the pause guard bypassed, bounded by the revive
        // gate (a frozen position across deaths exhausts; progress or a user seek restores).
        host.$endFailureCount
            .dropFirst()
            .sink { [weak self, weak host] count in
                guard let self, let host else { return }
                let clockAtFailure = host.renderedTime
                self.itemDeathConfirmTask?.cancel()
                self.itemDeathConfirmTask = Task { @MainActor [weak self, weak host] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.itemDeathConfirmSeconds * 1_000_000_000))
                    guard !Task.isCancelled, let self, let host,
                          host.endFailureCount == count else { return }
                    guard NativeAVPlayerHost.shouldSurfaceDeferredFailure(
                        isPlaying: host.timeControlStatus == .playing,
                        clockAtFailure: clockAtFailure,
                        clockNow: host.renderedTime) else { return }
                    let position = host.renderedTime
                    guard self.itemDeathReviveGate.admit(position: position) else {
                        EngineLog.emit(
                            "[AetherEngine] #93 item death (failedToPlayToEndTime) at "
                            + "\(String(format: "%.2f", position))s; revive budget exhausted, giving up",
                            category: .engine)
                        return
                    }
                    EngineLog.emit(
                        "[AetherEngine] #93 item death (failedToPlayToEndTime) at "
                        + "\(String(format: "%.2f", position))s; reloading item through stage-2 "
                        + "recovery (attempt \(self.itemDeathReviveGate.attempts), pause guard bypassed)",
                        category: .engine)
                    self.reloadStalledConsumerItem(position: position, allowPausedConsumer: true)
                }
            }
            .store(in: &nativeCancellables)

        // #98: a display rejecting the served master fails the item at startup; reload the media
        // playlist in place instead of hard-failing. Gated + single-shot in fallBackToMediaPlaylist.
        host.$pendingDisplayRejection
            .compactMap { $0 }
            .sink { [weak self] rejection in
                Task { @MainActor [weak self] in self?.fallBackToMediaPlaylist(rejection) }
            }
            .store(in: &nativeCancellables)

        // appliesPerFrameHDRDisplayMetadata unconditionally true: DV P5 has no HDR10 base layer, so the per-frame RPU is what AVPlayer's tone-mapper needs on a non-DV panel (DrHurt #4 2026-05-26). Prior servingMasterPlaylist gate broke P5. Apple's default is also true; explicit write surfaces the live value in diagnostics.
        // forwardBufferDuration default (4 s): deep buffer lets AVPlayer race to the live edge and hit the transcode warm-up gap head-on (-12888); 4 s PACES consumption. Verified: 8 s worsened startup pause (8-10 s vs ~1 s).
        // Live REJOIN: skip initial seek so AVPlayer picks edge-minus-holdback instead; seek-to-0 against the re-served backlog wedged the reloaded item in waitingToPlay (device repro: tvOS 26, Jellyfin stream.ts). See LiveReloadPolicy.
        lastNativeVideoStartPosition = startPosition ?? 0
        host.load(url: playbackURL,
                  startPosition: startPosition,
                  perFrameHDR: true,
                  skipInitialSeek: LiveReloadPolicy.skipInitialSeek(
                      isLive: isLive, isRejoin: liveRejoin))
        forceNativeLegibleDeselectedUntilHostSelects()
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
        // #112 rework: SW-host subtitle tap feeds a session packet store; the shared
        // playhead-paced drainer reads it exactly like the HLS session's store.
        let packetStore = SubtitlePacketStore()
        self.softwareSubtitlePacketStore = packetStore
        host.preserveASSMarkupForSubtitleTap = loadedOptions.preserveASSMarkup
        host.subtitleTapSink = { idx, pkt, tb, assembleSplitSets in
            packetStore.harvest(streamIndex: idx, packet: pkt, timeBase: tb,
                                assembleSplitDisplaySets: assembleSplitSets)
        }
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
        // Built on the main actor, captured into the detach: surfaces source stall/reconnect to playbackPhase (#85).
        let networkPhaseSink: @Sendable (ReaderNetworkPhase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.setReaderNetworkPhase(phase) }
        }
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, isLive, dvrWindowSeconds, probesize, maxAnalyzeDuration, networkPhaseSink] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, profile: .playback.withProbeBudget(probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration), isLive: isLive)
            }
            dem.onNetworkPhaseChanged = networkPhaseSink
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
        // Built on the main actor, captured into the detach: surfaces source stall/reconnect to playbackPhase (#85).
        let networkPhaseSink: @Sendable (ReaderNetworkPhase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.setReaderNetworkPhase(phase) }
        }
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, probesize, maxAnalyzeDuration, networkPhaseSink] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, profile: .playback.withProbeBudget(probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration))
            }
            dem.onNetworkPhaseChanged = networkPhaseSink
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
        // #112 full umbau: an audio-track switch does not move the playhead, so the PGS line already on screen is
        // still valid. Snapshot the visible bitmap cues before stopInternal wipes them; they are restored after the
        // subtitle re-arm so the line stays up while the re-armed reader re-primes forward (old path reconstructed
        // from scratch and the line vanished for the reconstruct duration).
        //
        // #112 (audio-switch reanchor): the re-arm anchor is the source PTS at the resume position, mapped the same
        // way the seek landing maps its target (PresentationAxis.source). Do NOT read `clock.sourceTime` here: on the
        // native path it is written only by the $renderedTime sink and discrete seek landings, never by the
        // $currentTime tick (issue #49), so after a fast-forward that landed via a producer restart it stays pinned
        // at the fast-forward's landing PTS while currentTime moves on. ijuniorfu's device log: switch at
        // currentTime 1292.3 s (true source ~1304 s), but clock.sourceTime still 1211.7 s (the earlier FF landing),
        // ~92 s behind, so the re-armed PGS reader anchored ~92 s back, reconstructed a region already passed
        // (nothing showed) and flooded stale open-ended cues. resumeAt (== currentTime, or an explicit resume
        // override) is fresh, so map it onto the source axis for the true playhead. The switch does not move the
        // playhead, so this is the correct anchor for the reader re-arm and the preserved-cue snapshot.
        let preSwitchSourceTime = PresentationAxis.source(displayTime: resumeAt, origin: sourcePresentationOrigin)
        let preservedActiveImageCues = Self.activeImageCues(in: subtitleCues, at: preSwitchSourceTime)
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
        // resetDisplayCriteria: false: video format is unchanged; resetting triggers a full waitForSwitch Stage 2 timeout (5 s at the 2026-05-26 device test, ~2 s cap since #117; Bose SLIII A2DP + 4K HDR10 PQ: each switch added ~12 s black-screen). On the same route a panel SDR drop during the reset window failed the PQ variant with AVFoundationErrorDomain -11868 / CoreMediaErrorDomain -17223.
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
                let discCacheKey = url.absoluteString
                customPreopened = try await Task.detached(priority: .userInitiated) {
                    let d = Demuxer()
                    // isLive preserved: a live custom source must not trigger SEEK_END on reopen.
                    // selectTitleID rebuilds the disc concat stream for the chosen title (#67).
                    // discCacheKey reuses the disc recognition cached at load so an audio switch on a
                    // remote ISO does not re-parse the UDF directory / playlists (#76).
                    try d.open(reader: reader, formatHint: hint, profile: reloadProfile, isLive: isLiveReload, selectTitleID: titleToReopen, discCacheKey: discCacheKey)
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
            // #112 (audio-switch reanchor): pass the pre-stopInternal source PTS explicitly; the parameterless form
            // reads the live sourceTime, which has collapsed to the playlist axis here (shift reset, not yet
            // republished) and would re-arm the reader ~shift seconds behind the line.
            selectSubtitleTrack(index: Int(embeddedStreamToResume), startAt: preSwitchSourceTime)
            // #112 full umbau: re-seed the on-screen bitmap line the switch would otherwise drop. selectSubtitleTrack
            // cleared subtitleCues and spawned a fresh reader; restore the pre-switch visible cues so the line stays
            // up until the reader's reconstruction pass republishes it (its first composition trims these cleanly).
            if !preservedActiveImageCues.isEmpty, subtitleCues.isEmpty {
                subtitleCues = preservedActiveImageCues
            }
        }
        if let secondarySidecar = secondarySidecarToResume {
            selectSecondarySidecarSubtitle(url: secondarySidecar)
        } else if secondaryEmbeddedToResume >= 0 {
            // #112 (audio-switch reanchor): same collapsed-sourceTime slip on the secondary channel.
            selectSecondarySubtitleTrack(index: Int(secondaryEmbeddedToResume), startAt: preSwitchSourceTime)
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
