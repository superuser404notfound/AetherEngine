import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine plays a rendered object-audio bed (APAC or
/// PCM, `SpatialBedFormat`), or compressed E-AC-3 JOC on the software host: through its `AVPlayer`,
/// or through the software host's sample-buffer audio renderer (the Dolby Vision FEL route).
///
/// tvOS hands APAC to the receiver as Dolby MAT, and some sinks show Dolby Atmos for that on their own.
/// Not all do: a Samsung HW-Q990C fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing
/// Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player looping
/// a silent E-AC-3 stream signalled as Dolby Atmos brought it to Atmos before the first frame and kept
/// it there across a seek. Nothing the app can read tracked the indicator; only the sink shows it.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts (and for a short grace after a pause,
/// see #848), and is released otherwise, since a prerolled E-AC-3 stream would compete with other audio.
///
/// It runs only for TrueHD Atmos rendered to APAC: a DTS:X programme is not Dolby Atmos, and the
/// receiver must not say it is.
///
/// #834: it runs only while every output port is HDMI. On an AirPlay route there is no sink indicator
/// to light, and a second unmuted player restarting beside the programme on every resume left a
/// HomePod pair silent after a pause, then froze the picture after the second one.
///
/// #848: a host pause no longer pauses it at once. Stopping the stream let the output leave Dolby
/// Atmos, and a Samsung HW-Q990H re-locked on every resume and scrub, sometimes with a short dropout.
/// It keeps playing for `pauseGrace` and pauses only if the host is still paused then. The grace is
/// bounded because a playing player keeps the receiver busy and counts as audio playing, and a long
/// pause re-locking once on resume is the lesser cost; it ends before tvOS's shortest screen saver
/// delay of two minutes.
///
/// The software host plays APAC (TrueHD Atmos, DTS:X) or compressed E-AC-3 JOC through an
/// `AVSampleBufferAudioRenderer`, and an Apple TV 4K (tvOS 26.6) whose receiver showed Atmos for the
/// AVPlayer route's APAC did not show it for the same title's APAC on that renderer. There the activator
/// follows the host's transport instead of a player (`attachRenderer`).
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    /// Set by `attachRenderer`: whether the renderer path is playing (or waiting to), nil once it is gone.
    private var rendererIsPlaying: (@MainActor () -> Bool?)?
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private let outputPortTypes: @MainActor () -> [String]
    private var loggedRouteVerdict: Bool?
    private let pauseGrace: Duration
    private var pauseAfterGrace: Task<Void, Never>?

    nonisolated static let defaultPauseGrace: Duration = .seconds(60)

    init(
        outputPortTypes: @escaping @MainActor () -> [String] = AtmosOutputActivator.currentOutputPortTypes,
        pauseGrace: Duration = AtmosOutputActivator.defaultPauseGrace
    ) {
        self.outputPortTypes = outputPortTypes
        self.pauseGrace = pauseGrace
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// True only for a route whose every output is HDMI: the sink the stream exists for. An empty
    /// route is one in transition, and the route change that ends it re-evaluates.
    nonisolated static func routeTakesActivator(outputPortTypes: [String]) -> Bool {
        !outputPortTypes.isEmpty && outputPortTypes.allSatisfy { $0 == hdmiPortType }
    }

    /// `AVAudioSession.Port.HDMI.rawValue`, spelled out so the rule is testable where there is no session.
    nonisolated static let hdmiPortType = "HDMIOutput"

    static func currentOutputPortTypes() -> [String] {
        #if os(iOS) || os(tvOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        #else
        []
        #endif
    }

    /// Follows `host`: its item, its audio selection and whether it is playing.
    func attach(to host: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool) {
        detach()
        self.host = host
        self.playsAPAC = playsAPAC
        // A host play() changes timeControlStatus synchronously on the main thread, so the stream
        // starts inside that call, ahead of the APAC output.
        observations = [
            host.observe(\.currentItem, options: [.initial]) { [weak self] _, _ in
                Self.onMain { self?.follow(self?.host?.currentItem) }
            },
            host.observe(\.timeControlStatus) { [weak self] _, _ in
                Self.onMain { self?.update() }
            },
        ]
        observeRoute()
    }

    /// Follows a renderer path that plays object audio. `isPlaying` answers true while it plays or waits
    /// to, false while paused, and nil once the session is gone; the engine calls `refresh()` whenever its
    /// transport state changes, since a renderer has nothing to observe.
    func attachRenderer(isPlaying: @escaping @MainActor () -> Bool?) {
        detach()
        rendererIsPlaying = isPlaying
        observeRoute()
        update()
    }

    /// Re-reads the renderer path's transport (see `attachRenderer`). A no-op for an attached player.
    func refresh() {
        guard rendererIsPlaying != nil else { return }
        update()
    }

    private func observeRoute() {
        #if os(iOS) || os(tvOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.update() }
        }
        #endif
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        host = nil
        rendererIsPlaying = nil
        loggedRouteVerdict = nil
        follow(nil)
    }

    private func follow(_ item: AVPlayerItem?) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = item.map {
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: $0, queue: .main
            ) { [weak self] _ in
                Self.onMain { self?.update() }
            }
        }
        update()
    }

    private func update() {
        let playing: Bool
        if let rendererIsPlaying {
            guard let state = rendererIsPlaying() else {
                // The session is gone: drop the route observer with the stream, not just the stream.
                detach()
                return
            }
            playing = state
        } else {
            guard let host, let item = host.currentItem, playsAPAC(item) else {
                release()
                return
            }
            playing = host.timeControlStatus != .paused
        }
        let ports = outputPortTypes()
        let routeTakesIt = Self.routeTakesActivator(outputPortTypes: ports)
        if loggedRouteVerdict != routeTakesIt {
            loggedRouteVerdict = routeTakesIt
            EngineLog.emit(
                "[AtmosOutputActivator] \(routeTakesIt ? "active" : "off") on route ports=[\(ports.joined(separator: ", "))]",
                category: .session
            )
        }
        guard routeTakesIt else {
            release()
            return
        }
        guard playing else {
            holdThroughPause()
            return
        }
        pauseAfterGrace?.cancel()
        pauseAfterGrace = nil
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    /// True while the silent stream is playing.
    var isPlayingStream: Bool { player.rate != 0 }

    private func holdThroughPause() {
        guard isPlayingStream, pauseAfterGrace == nil else { return }
        pauseAfterGrace = Task { [weak self, pauseGrace] in
            try? await Task.sleep(for: pauseGrace)
            guard !Task.isCancelled, let self else { return }
            self.pauseAfterGrace = nil
            self.player.pause()
        }
    }

    private func release() {
        pauseAfterGrace?.cancel()
        pauseAfterGrace = nil
        guard let looper else { return }
        player.pause()
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

extension AetherEngine {
    /// tvOS only: the switch is an HDMI one, and on iOS and macOS a second unmuted player beside the
    /// engine's would compete with it for Now Playing and the audio session for no gain. Follows the
    /// engine's `AVPlayer` while it plays TrueHD Atmos as APAC, or else a software host whose renderer
    /// receives Dolby Atmos (TrueHD Atmos as APAC, or compressed E-AC-3 JOC). DTS:X rendered to APAC is
    /// not Dolby Atmos and the PCM decode has no Atmos, so neither brings the receiver to Dolby Atmos.
    func followAtmosOutput() {
        #if os(tvOS)
        if let player = currentAVPlayer {
            let activator = atmosOutputActivator ?? AtmosOutputActivator()
            atmosOutputActivator = activator
            activator.attach(to: player) { [weak self] _ in
                guard let session = self?.nativeVideoSession else { return false }
                return session.audioIsRenderedBed && session.audioBedIsFromDolbyAtmos
            }
        } else if let host = softwareHost, host.audioRouteCarriesDolbyAtmos {
            let activator = atmosOutputActivator ?? AtmosOutputActivator()
            atmosOutputActivator = activator
            activator.attachRenderer { [weak self, weak host] in
                guard let self, let host, self.softwareHost === host,
                      let playing = Self.softwareAtmosOutputPlaying(self.state) else { return nil }
                // `setRate(0)` parks the host without moving `state` off `.playing`.
                return playing && (self.state != .playing || host.isPlaying)
            }
        } else {
            atmosOutputActivator?.detach()
        }
        #endif
    }

    /// The software host's transport as the activator reads it: true while playing or about to (a seek,
    /// the load's own start), false while paused, nil once the session has ended or failed.
    nonisolated static func softwareAtmosOutputPlaying(_ state: PlaybackState) -> Bool? {
        switch state {
        case .playing, .seeking, .loading: return true
        case .paused: return false
        case .idle, .ended, .error: return nil
        }
    }

    /// #597: a media services reset invalidates the activator's own `AVQueuePlayer` along with the engine's,
    /// and the engine only rebuilds its own. Dropped here, the next `currentAVPlayer` builds a fresh one.
    func dropAtmosOutputActivator() {
        atmosOutputActivator?.detach()
        atmosOutputActivator = nil
    }
}
