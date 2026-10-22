import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine's `AVPlayer` plays an APAC track.
///
/// tvOS hands APAC to the receiver as Dolby MAT, and some sinks show Dolby Atmos for that on their own.
/// Not all do: a Samsung HW-Q990C fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing
/// Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player looping
/// a silent E-AC-3 stream signalled as Dolby Atmos brought it to Atmos before the first frame and kept
/// it there across a seek. Nothing the app can read tracked the indicator; only the sink shows it.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts, and is released otherwise, since a
/// prerolled E-AC-3 stream would compete with other audio.
///
/// #834: it runs only while every output port is HDMI. On an AirPlay route there is no sink indicator
/// to light, and a second unmuted player restarting beside the programme on every resume left a
/// HomePod pair silent after a pause, then froze the picture after the second one.
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private let outputPortTypes: @MainActor () -> [String]
    private var loggedRouteVerdict: Bool?

    init(outputPortTypes: @escaping @MainActor () -> [String] = AtmosOutputActivator.currentOutputPortTypes) {
        self.outputPortTypes = outputPortTypes
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// True only for a route whose every output is HDMI: the sink the stream exists for. An empty
    /// route is one in transition, and the route change that ends it re-evaluates.
    nonisolated static func routeTakesActivator(outputPortTypes: [String]) -> Bool {
        !outputPortTypes.isEmpty && outputPortTypes.allSatisfy { $0 == hdmiPortType }
    }

    /// `AVAudioSession.Port.HDMI.rawValue`, spelled out so the rule is testable where there is no session.
    /// That value is "HDMIOutput", not "HDMI": spelled "HDMI", no HDMI route ever took the activator
    /// (`off on route ports=[HDMIOutput]`, Apple TV 4K 3rd gen, tvOS 27.0).
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
        guard let host, let item = host.currentItem, playsAPAC(item) else {
            release()
            return
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
        guard host.timeControlStatus != .paused else {
            player.pause()
            return
        }
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    private func release() {
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
    /// engine's would compete with it for Now Playing and the audio session for no gain.
    func followAtmosOutput() {
        #if os(tvOS)
        guard let player = currentAVPlayer else {
            atmosOutputActivator?.detach()
            return
        }
        let activator = atmosOutputActivator ?? AtmosOutputActivator()
        atmosOutputActivator = activator
        activator.attach(to: player) { [weak self] _ in self?.nativeVideoSession?.audioIsAPAC == true }
        #endif
    }

    /// #597: a media services reset invalidates the activator's own `AVQueuePlayer` along with the engine's,
    /// and the engine only rebuilds its own. Dropped here, the next `currentAVPlayer` builds a fresh one.
    func dropAtmosOutputActivator() {
        atmosOutputActivator?.detach()
        atmosOutputActivator = nil
    }
}
