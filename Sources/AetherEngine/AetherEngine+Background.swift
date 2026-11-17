import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The app lifecycle: what the engine does when the app goes to the background, comes back, loses its
// media services or has its audio session interrupted. The pure policy it applies
// (`backgroundAction`, `backgroundStep`, the keepalive rules) is declared next to the state it reads.
extension AetherEngine {

    // MARK: - App Lifecycle

    func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Tear the VIDEO pipeline down on background. Pausing left live sessions frozen across multi-hour
        // tvOS suspension: AVPlayer decode session in mediaserverd + loopback sockets + AVIO connection all
        // stayed allocated; on resume that wedged mediaserverd system-wide until reboot. teardownVideoForBackground()
        // releases the decode session synchronously so nothing crosses into suspension.
        //
        // AUDIO (music) keeps playing in the background (UIBackgroundModes audio). Flipping state to .paused
        // while AVPlayer keeps playing desyncs MPNowPlayingInfoPropertyPlaybackRate, breaking the Now-Playing
        // badge + Siri Remote routing. Skip teardown for audio backends.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.noteDidEnterBackground()
                await self.runBackgroundDecision(.enteredBackground)
            }
        }
        retainLifecycleObserver(bgObserver)
        let fgObserver = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if os(iOS)
                self.cancelBackgroundGraceWindow()
                self.softwareHost?.exitBackgroundAudioOnly()
                #endif
                // AE#588: read the flag before clearing it. `didBecomeActive` also follows a resign that
                // never backgrounded the app (a system alert, a volume HUD), and the user cannot have
                // reached the output format in that gap, so only a real return forgets the refusal.
                let returnedFromBackground = self.isBackgrounded
                self.isBackgrounded = false
                if returnedFromBackground { Self.clearPanelRefusalOnForegroundReturn() }
                self.backgroundActionOwed = false
                self.noteVideoPresentationToHost()
            }
        }
        retainLifecycleObserver(fgObserver)

        // AE#597: mediaserverd can reset or be lost underneath a running process, and the platform
        // contract is that every audio and video object the process holds is invalid afterwards and
        // must be rebuilt. Nothing here observed that, so a session came back from a suspension,
        // reused the AVPlayer it had deliberately kept (Sodalite#149), and spent its whole recovery
        // ladder reloading onto an object that could no longer work: item after item reaching
        // readyToPlay with no usable tracks and failing with CoreMedia 'nope'.
        //
        // The flag is consumed by the next load rather than acted on here, because a reset says
        // nothing about whether anyone still wants to watch: the host decides that, and the engine
        // only has to stop pretending its old objects survived.
        for name in [AVAudioSession.mediaServicesWereResetNotification,
                     AVAudioSession.mediaServicesWereLostNotification] {
            let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let lost = note.name == AVAudioSession.mediaServicesWereLostNotification
                Task { @MainActor in self?.noteMediaServicesReset(lost: lost) }
            }
            retainLifecycleObserver(observer)
        }

        #if os(iOS) || os(tvOS)
        AudioRouteDescription.changeLogger
        #endif

        #if os(iOS) || os(tvOS)
        installRouteRemovalObserver()
        installChannelCountChangeObserver()
        #endif

        #if os(iOS)
        let routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recomputeAirPlayPictureStaysLocal()
                self?.recheckInterlaceRouteForAirPlayReceiver()
            }
        }
        retainLifecycleObserver(routeObserver)
        #endif

        // Foreign-session interruption handling (Sodalite device-verify 2026-07-15): a live-camera
        // PiP re-claims the audio session on every play() and the system pauses AVPlayer ~10ms after
        // .playing (interruption BEGAN reason=default). The system pause never goes through pause(),
        // so the native host's durable playIntent (#122) survives the interruption and anchors the
        // resume decision. Resume fires on ENDED only when the system explicitly grants .shouldResume
        // (calls, Siri); sessions that end without it (the camera PiP closing) stay paused by design,
        // the user resumes manually. An explicit user pause() disarms the resume.
        let interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let began = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            #if os(iOS)
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "n/a"
            #else
            let reason = "n/a"
            #endif
            Task { @MainActor in
                guard let self else { return }
                let session = AVAudioSession.sharedInstance()
                if began {
                    let intent = self.nativeHost?.transportIntentIsPlaying ?? (self.state == .playing)
                    let stateEligible: Bool
                    switch self.state {
                    case .idle, .error: stateEligible = false
                    default: stateEligible = true
                    }
                    self.resumeAfterInterruption = intent && stateEligible
                    // An idle or failed session has no playback to protect, and a stale BEGAN must not
                    // leave a later session unplayable.
                    if stateEligible { self.noteAudioInterruptionBegan() }
                    EngineLog.emit("[AetherEngine] AVAudioSession interruption BEGAN reason=\(reason) resumeArmed=\(self.resumeAfterInterruption) otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint)", category: .engine)
                } else {
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                    #if os(iOS)
                    let backgroundSafe = Self.interruptionResumeIsBackgroundSafe(
                        isBackgrounded: self.isBackgrounded,
                        isAudioBackend: self.audioAVPlayerActive || self.audioHost != nil,
                        backgroundPlaybackEnabled: self.backgroundPlaybackEnabled,
                        hasSoftwareHost: self.softwareHost != nil,
                        nativeSessionKeptForAudio: self.nativeSessionKeptForBackgroundAudio)
                    #else
                    let backgroundSafe = true
                    #endif
                    let deferredPlay = self.noteAudioInterruptionEnded()
                    let firing = Self.interruptionEndShouldPlay(
                        armed: self.resumeAfterInterruption, shouldResume: shouldResume,
                        deferredPlay: deferredPlay, backgroundSafe: backgroundSafe)
                    let pausesBefore = self.userPauseCount
                    let loadBefore = self.loadGeneration
                    EngineLog.emit("[AetherEngine] AVAudioSession interruption ENDED shouldResume=\(shouldResume) otherAudio=\(session.isOtherAudioPlaying) resumeArmed=\(self.resumeAfterInterruption) autoResume=\(firing) deferredPlay=\(deferredPlay)", category: .engine)
                    if firing {
                        self.resumeAfterInterruption = false
                        // AE#549: the native path gets its session back from AVFoundation, the renderer
                        // paths own theirs and nothing reactivated it for them. An interrupted session
                        // that is not made active again stops the audio device, and with it the
                        // synchronizer timebase every software and audio-only session reads as its
                        // master clock: the field log resumed on paper (`autoResume=true`) and stood
                        // still for two minutes. Awaited, so the session is active before play() runs.
                        if self.softwareHost != nil || self.audioHost != nil {
                            EngineLog.emit("[AetherEngine] AE#549: reactivating the renderer audio session before the resume",
                                           category: .engine)
                            await self.activateRendererAudioSession()
                        }
                        // A pause pressed while the session was being reactivated wins.
                        guard self.userPauseCount == pausesBefore, self.loadGeneration == loadBefore else { return }
                        self.play()
                    }
                }
            }
        }
        retainLifecycleObserver(interruptionObserver)
        #endif
    }

    // MARK: Owed background decision (audit CORE-2, LIF-101)

    /// Audit LIF-101: whether a background decision can be made now. Not while a load is in flight:
    /// a teardown there unwinds the host's `load()` with the `CancellationError` that means "a newer
    /// load or stop took over", and the host treats it as a supersede (no observers, no start report,
    /// a spinner that never clears).
    nonisolated static func backgroundDecisionSettles(state: PlaybackState, loadInFlight: Bool) -> Bool {
        !loadInFlight && !backgroundActionIsOwed(state: state)
    }

    var backgroundDecisionMustWait: Bool {
        !Self.backgroundDecisionSettles(state: state, loadInFlight: loadInFlight)
    }

    var loadInFlight: Bool { loadInFlightGeneration == loadGeneration }

    /// AE#1061: a track or title pick that lands while a load is still running waits for that load to
    /// return before it rebuilds. The load publishes `audioTracks` before its display handshake, and a
    /// rebuild that superseded it there found none of the load's panel answers (they are stored only
    /// once the handshake settles), so it routed a Dolby Vision title media-direct onto a panel that
    /// was mid-switch into DV, and left `videoFormat` at `.sdr` for the session. It also unwound the
    /// host's `load()` with a `CancellationError`, which a host reads as a supersede (LIF-101). Waiting
    /// costs the pick the rest of the load; a host that knows its track up front passes it to `load`
    /// as `audioSourceStreamIndex` and pays nothing.
    ///
    /// Returns as soon as the load the caller saw is no longer the one in flight: it returned, or a
    /// stop() or newer load took over (both move the generation), which the caller's own generation
    /// guard then turns away.
    func awaitLoadInFlightSettled(pick: String) async {
        guard loadInFlight else { return }
        let generation = loadGeneration
        EngineLog.emit(
            "[AetherEngine] \(pick) waits for the load in flight to settle its route before it rebuilds (#1061)",
            category: .engine)
        while loadInFlightGeneration == generation, loadGeneration == generation, !Task.isCancelled {
            await withCheckedContinuation { loadSettleWaiters.append($0) }
        }
    }

    func resumeLoadSettleWaiters() {
        guard !loadSettleWaiters.isEmpty else { return }
        let waiters = loadSettleWaiters
        loadSettleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func beginLoadInFlight(_ generation: UInt64) {
        loadInFlightGeneration = generation
        // Audit LIF-201: a load that runs in the background (next-episode autoplay, a playlist advance)
        // settles into a state nothing has judged yet, paused included. It owes the decision.
        if isBackgrounded { backgroundActionOwed = true }
    }

    /// Called from the load's own exit, which is the settle point a state it passes through is not.
    func endLoadInFlight(_ generation: UInt64) {
        guard loadInFlightGeneration == generation else { return }
        loadInFlightGeneration = nil
        settleOwedBackgroundAction()
        settleOwedUpscaleNativeReturn()
    }

    /// didEnterBackground's bookkeeping. Audit CORE-2: a load or seek in flight has a pipeline
    /// (loopback server, AVIO connection, the item) but no settled state to judge it by, and it
    /// settles into `.playing` in the background with nothing left to look again. Owe it the decision.
    func noteDidEnterBackground() {
        isBackgrounded = true
        backgroundActionOwed = backgroundDecisionMustWait
        noteVideoPresentationToHost()
    }

    /// Tells the software host whether a refused video rebuild may be retried now. A backgrounded app with
    /// picture-in-picture on still shows the picture, and the software host keeps decoding for it, so only
    /// a background with no picture window counts as "nothing is showing video". Also called when a load
    /// installs a new host, which would otherwise start out believing it is on screen.
    func noteVideoPresentationToHost() {
        softwareHost?.noteAppInBackground(isBackgrounded && !pictureInPictureActive)
    }

    /// Audit LIF-105: the PiP window closed while backgrounded, so nothing keeps the app running and
    /// the wedge-safe teardown is due. Through the owed funnel, so a load or seek in flight in the
    /// window is torn down once it settles instead of never.
    func settleBackgroundDecisionAfterPictureInPictureClosed() {
        requestBackgroundDecision(.pictureInPictureClosed)
    }

    /// Called from the `state` didSet and from a load's exit. A decision owed since the app went to
    /// the background is made once the session has settled into a transport state.
    func settleOwedBackgroundAction() {
        guard backgroundActionOwed, !backgroundDecisionMustWait else { return }
        backgroundActionOwed = false
        guard isBackgrounded, state == .playing || state == .paused else { return }
        EngineLog.emit(
            "[AetherEngine] background: an owed decision settled (a load or seek in flight, or a "
            + "retained paused session resuming, AE#870; state=\(state)); applying the background "
            + "policy now (audit CORE-2)",
            category: .engine)
        Task { @MainActor [weak self] in await self?.runBackgroundDecision(.owedDecisionSettled) }
    }

    // MARK: One background decision (audit LIF-R201)

    /// What asks for a background decision. Only the grace-window expiries change the answer: they
    /// perform the action instead of deferring it a second time.
    enum BackgroundTrigger: Equatable, Sendable {
        case enteredBackground
        /// A load or seek that owed the decision settled (CORE-2, LIF-101, AE#870).
        case owedDecisionSettled
        /// A pause while backgrounded, from `pause()` or from the player itself (LIF-201, LIF-202).
        case paused
        /// tvOS: the PiP window closed while backgrounded (LIF-105).
        case pictureInPictureClosed
        /// #127: the grace window ran out.
        case graceWindowExpired
        /// #127: the system reclaimed the grace assertion early. Nothing can wait any more.
        case graceAssertionReclaimed
    }

    /// Everything a background decision reads, so the whole policy is one pure function.
    struct BackgroundDecisionInputs: Equatable, Sendable {
        var isTV = false
        var isBackgrounded = true
        var loadInFlight = false
        var state: PlaybackState = .playing
        /// The background teardown already ran and nothing reloaded since (`needsForegroundVideoRestore`).
        var pipelineReleased = false
        var isAudioBackend = false
        var hasSoftwareHost = false
        var softwareHostHasAudio = false
        var pipActive = false
        var backgroundPlaybackEnabled = true
        var retainsPausedVideoPipeline = false
        var graceSeconds: Double = 15
    }

    enum BackgroundDecision: Equatable, Sendable {
        /// Not backgrounded, or nothing is left to release.
        case none
        /// A load or seek is still deciding the state; settled from its exit.
        case owe
        case step(BackgroundStep)
    }

    nonisolated static func backgroundKeepsVideoAlive(_ i: BackgroundDecisionInputs) -> Bool {
        i.isTV
            ? shouldKeepVideoAliveTV(enabled: i.backgroundPlaybackEnabled, pipActive: i.pipActive)
            : shouldKeepVideoAlive(enabled: i.backgroundPlaybackEnabled, pipActive: i.pipActive, state: i.state)
    }

    /// The one background decision every entry point asks (audit LIF-R201). Before it, `pause()`
    /// carried its own copy, which skipped the owed rule and tore a load down under itself (LIF-201),
    /// and a pause the player took on its own reached no copy at all (LIF-202).
    ///
    /// An interruption gets no hold of its own (review R-P5-1). A session a call paused gets the grace
    /// window like any other paused one, and an ENDED with `shouldResume` inside it resumes in place.
    /// The window's assertion is the only thing keeping the app running meanwhile: the open-ended hold
    /// that was here armed none, iOS does not promise an ENDED, and the app suspended with the whole
    /// pipeline (AE#597). It also held tvOS sessions, which background entry always released.
    nonisolated static func backgroundDecision(
        _ i: BackgroundDecisionInputs, trigger: BackgroundTrigger
    ) -> BackgroundDecision {
        guard i.isBackgrounded else { return .none }
        if trigger != .graceAssertionReclaimed,
           !backgroundDecisionSettles(state: i.state, loadInFlight: i.loadInFlight) { return .owe }
        if i.pipelineReleased { return .none }
        let action = backgroundAction(
            isAudioBackend: i.isAudioBackend,
            hasSoftwareHost: i.hasSoftwareHost,
            softwareHostHasAudio: i.softwareHostHasAudio,
            keepVideoAlive: backgroundKeepsVideoAlive(i),
            pipActive: i.pipActive,
            state: i.state,
            retainPausedVideoPipeline: i.retainsPausedVideoPipeline)
        switch trigger {
        case .graceWindowExpired, .graceAssertionReclaimed:
            return .step(.perform(action))
        default:
            return .step(backgroundStep(
                action: action, state: i.state, supportsGraceWindow: !i.isTV, graceSeconds: i.graceSeconds))
        }
    }

    var backgroundDecisionInputs: BackgroundDecisionInputs {
        #if os(tvOS)
        let isTV = true
        #else
        let isTV = false
        #endif
        return BackgroundDecisionInputs(
            isTV: isTV,
            isBackgrounded: isBackgrounded,
            loadInFlight: loadInFlight,
            state: state,
            pipelineReleased: backgroundTeardownSelection != nil,
            isAudioBackend: audioAVPlayerActive || audioHost != nil,
            hasSoftwareHost: softwareHost != nil,
            softwareHostHasAudio: softwareHost?.deliversAudio == true,
            pipActive: pictureInPictureActive,
            backgroundPlaybackEnabled: backgroundPlaybackEnabled,
            retainsPausedVideoPipeline: retainsVideoPipelineWhenBackgrounded,
            graceSeconds: backgroundTeardownGraceSeconds)
    }

    /// Whether a state change is a pause that owes the background decision. Whoever paused: the
    /// engine's `pause()`, AVPlayer on a removed route, AVKit on its own controls (LIF-202).
    nonisolated static func stateChangeRequestsBackgroundDecision(from: PlaybackState, to: PlaybackState) -> Bool {
        from == .playing && to == .paused
    }

    /// Audit LIF-203: whether the end of an interruption may restart playback while backgrounded.
    /// Audio backends always could. A video session may when the background policy keeps it playing:
    /// the software host in audio-only mode, and since AE#1080 a native session kept for its audio,
    /// unless the background teardown already released it. Neither with background playback off
    /// (review R-P5-1): the policy would release a playing video there, so a resume only restarts
    /// sound until the grace window runs out.
    nonisolated static func interruptionResumeIsBackgroundSafe(
        isBackgrounded: Bool, isAudioBackend: Bool, backgroundPlaybackEnabled: Bool, hasSoftwareHost: Bool,
        nativeSessionKeptForAudio: Bool
    ) -> Bool {
        !isBackgrounded || isAudioBackend
            || (backgroundPlaybackEnabled && (hasSoftwareHost || nativeSessionKeptForAudio))
    }

    /// A native session the background policy keeps for its audio: the AVPlayer is up, nothing
    /// released it, and background playback is on (which is what lets iOS keep the item playing).
    var nativeSessionKeptForBackgroundAudio: Bool {
        playbackBackend == .native && nativeHost != nil && backgroundTeardownSelection == nil
            && backgroundPlaybackEnabled
    }

    /// The synchronous entry. A decision that has to wait for a load or seek is owed right here, so
    /// the load's own exit settles it (LIF-101); everything else is decided on the next main-actor turn.
    func requestBackgroundDecision(_ trigger: BackgroundTrigger) {
        guard isBackgrounded else { return }
        if backgroundDecisionMustWait {
            backgroundActionOwed = true
            return
        }
        Task { @MainActor [weak self] in await self?.runBackgroundDecision(trigger) }
    }

    func runBackgroundDecision(_ trigger: BackgroundTrigger) async {
        let inputs = backgroundDecisionInputs
        let decision = Self.backgroundDecision(inputs, trigger: trigger)
        backgroundDecisionObserverForTesting?(trigger, decision)
        switch decision {
        case .none:
            return
        case .owe:
            backgroundActionOwed = true
        case .step(let step):
            if let policy = backgroundPolicyForTesting {
                await policy(self)
                return
            }
            #if os(iOS) || os(tvOS)
            await performBackgroundStep(step, trigger: trigger, inputs: inputs)
            #endif
        }
    }

    /// The synchronous half of the background teardown. stopInternal's replaceCurrentItem(nil) +
    /// VTDecompressionSession invalidation frees the shared mediaserverd decode session.
    /// keepNativeHost=true preserves the NativeAVPlayerHost shell for AVKit's Now-Playing registration
    /// (issue #15); keepCustomReader=true retains the byte-source reader.
    /// clock.currentTime/loadedURL/loadedOptions are preserved so reloadAtCurrentPosition() resumes correctly.
    func releaseVideoPipelineForBackground() {
        // #357: park the selection first. The foreground reload snapshots at reload time, which on
        // this path is long after stopInternal wiped what it wants.
        captureBackgroundTeardownSelection()
        // AE#597: this path emitted nothing at all, so a field log could not say whether the
        // session was released before a suspension or carried through it whole. Which of the two
        // happened is the first question every wake-from-sleep report asks.
        EngineLog.emit(
            "[AetherEngine] #597 background teardown: releasing the video pipeline "
            + "(backend=\(playbackBackend), state=\(state))",
            category: .engine)
        let teardownStart = DispatchTime.now()
        stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCustomReader: true)
        releaseSubtitleProxyForBackground()
        // Session torn down; host will reload + repause on foreground return.
        state = .paused
        let teardownMs = Double(
            DispatchTime.now().uptimeNanoseconds - teardownStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[AetherEngine] #597 background teardown done in "
            + "\(String(format: "%.0f", teardownMs))ms; the audio session and the native host "
            + "shell stay",
            category: .engine)
    }

    /// AE#597: `stopInternal` does not touch the proxy, so without this its loopback socket rides
    /// the suspension. Both background teardowns call it, the awaited one and the synchronous
    /// backstop the system takes when it reclaims the grace assertion early.
    private func releaseSubtitleProxyForBackground() {
        guard Self.shouldReleaseSubtitleProxyForBackground(
            hasProxy: remoteHLSSubtitleProxy != nil, isCustomSource: isCustomSource) else { return }
        remoteHLSSubtitleProxy?.tearDown()
        remoteHLSSubtitleProxy = nil
        injectedSubtitleRenditionNames = [:]
        detachRemoteHLSCueClock()   // AE#616
        EngineLog.emit(
            "[AetherEngine] #597 background teardown: remote-HLS subtitle proxy released",
            category: .engine)
    }

    #if os(iOS) || os(tvOS)
    private func performBackgroundStep(
        _ step: BackgroundStep, trigger: BackgroundTrigger, inputs: BackgroundDecisionInputs
    ) async {
        switch step {
        case .perform(.doNothing):
            if trigger == .graceWindowExpired {
                EngineLog.emit("[AetherEngine] background grace window expired, session now kept alive (#127)", category: .engine)
            }
        case .perform(.enterSoftwareAudioOnly):
            softwareHost?.enterBackgroundAudioOnly()
        case .perform(.teardownVideo):
            if trigger == .graceWindowExpired {
                EngineLog.emit("[AetherEngine] background grace window expired, tearing down paused pipeline (#127)", category: .engine)
            } else if inputs.hasSoftwareHost && Self.backgroundKeepsVideoAlive(inputs) {
                EngineLog.emit("[AetherEngine] AE#739 the software host renders no audio, releasing it "
                               + "instead of entering background audio-only", category: .engine)
            }
            await teardownVideoForBackground()
        case .deferTeardown(let seconds):
            #if os(iOS)
            scheduleBackgroundGraceTeardown(afterSeconds: seconds)
            #endif
        }
    }

    /// Release the video pipeline before tvOS suspension (`releaseVideoPipelineForBackground`).
    ///
    /// A UIApplication background-task assertion is held across teardown so the loopback server's detached
    /// socket close (HLSVideoEngine.stop drains the producer up to 3 s) completes before suspension.
    func teardownVideoForBackground() async {
        let app = UIApplication.shared
        let bgTask = app.beginBackgroundTask(withName: "AetherEngine.bgVideoTeardown")
        releaseVideoPipelineForBackground()
        // Wait for the loopback server's detached cleanup (<=3 s producer drain + socket shutdown) before releasing.
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        if bgTask != .invalid { app.endBackgroundTask(bgTask) }
    }

    #if os(iOS)
    // MARK: #127 paused-background grace window

    /// Hold the paused pipeline alive under a background-task assertion for the grace window, then
    /// re-evaluate and tear down. didBecomeActive cancels the window, making a quick app switch free.
    func scheduleBackgroundGraceTeardown(afterSeconds seconds: Double) {
        guard backgroundGraceTask == nil else { return }  // window already armed
        let app = UIApplication.shared
        // The handler needs the identifier the call returns, so it reads it from a box filled after.
        let identity = GraceAssertionIdentity()
        let assertion = app.beginBackgroundTask(withName: "AetherEngine.bgGraceWindow") { [weak self] in
            // System reclaimed the window early. UIKit calls this on the main thread; the synchronous
            // stopInternal releases the decode session, the 3.5 s socket drain is skipped (no time).
            MainActor.assumeIsolated {
                self?.expireBackgroundGraceNow(identity.value)
            }
        }
        identity.value = assertion
        guard assertion != .invalid else {
            // Background execution unavailable: fall back to the immediate teardown.
            Task { @MainActor in await self.teardownVideoForBackground() }
            return
        }
        backgroundGraceAssertion = assertion
        // Clamp: the system allowance is ~30 s; longer values would just move the work into the
        // expiration backstop (and an unbounded host value must not overflow the ns conversion).
        let window = min(max(0, seconds), 60)
        EngineLog.emit("[AetherEngine] background grace window armed (\(String(format: "%.0f", window))s) before paused teardown (#127)", category: .engine)
        backgroundGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.fireBackgroundGraceTeardown(assertion)
        }
    }

    @MainActor
    private final class GraceAssertionIdentity {
        var value: UIBackgroundTaskIdentifier = .invalid
    }

    /// Grace expiry: re-evaluate the background action (PiP can start and lock-screen play can resume
    /// mid-window) and perform it without further deferral. A load the host started inside the window
    /// gets the decision at its exit (audit LIF-101).
    ///
    /// Audit LIF-206: ends only the assertion this window armed. The teardown drains for 3.5 s, and a
    /// foreground return plus a new background trip inside that drain arms a second window whose
    /// assertion this one must not end.
    private func fireBackgroundGraceTeardown(_ assertion: UIBackgroundTaskIdentifier) async {
        backgroundGraceTask = nil
        await runBackgroundDecision(.graceWindowExpired)
        endBackgroundGraceAssertion(assertion)
    }

    /// Expiration-handler backstop: synchronous minimal teardown before the assertion is force-ended.
    private func expireBackgroundGraceNow(_ assertion: UIBackgroundTaskIdentifier) {
        guard backgroundGraceAssertion == assertion, assertion != .invalid else { return }
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        if Self.backgroundDecision(backgroundDecisionInputs, trigger: .graceAssertionReclaimed)
            == .step(.perform(.teardownVideo)) {
            EngineLog.emit("[AetherEngine] background grace assertion expired early, synchronous teardown (#127)", category: .engine)
            captureBackgroundTeardownSelection()   // #357, as in teardownVideoForBackground
            stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCustomReader: true)
            releaseSubtitleProxyForBackground()
            state = .paused
        }
        endBackgroundGraceAssertion(assertion)
    }

    private func cancelBackgroundGraceWindow() {
        guard backgroundGraceTask != nil || backgroundGraceAssertion != .invalid else { return }
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        endBackgroundGraceAssertion(backgroundGraceAssertion)
        EngineLog.emit("[AetherEngine] background grace window cancelled, session survives the app switch (#127)", category: .engine)
    }

    private func endBackgroundGraceAssertion(_ assertion: UIBackgroundTaskIdentifier) {
        guard assertion != .invalid, backgroundGraceAssertion == assertion else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        backgroundGraceAssertion = .invalid
    }
    #endif
    #endif
}
