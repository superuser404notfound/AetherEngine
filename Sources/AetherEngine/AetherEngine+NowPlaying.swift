import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// The playback route a Now-Playing publisher serves, which decides where its card and commands go.
enum NowPlayingRouteKind: Equatable {
    case softwareVideo
    case nativeVideo
    case audioAVPlayer
    case audioFFmpeg

    var isAudio: Bool { self == .audioAVPlayer || self == .audioFFmpeg }
}

/// What the engine does for one route. `sessionCommands`: the route's `MPNowPlayingSession` publishes the
/// card from its player and the engine only binds the transport commands on that session's center.
/// `sharedCenter`: there is no session (the software and FFmpeg hosts, every host on macOS), so the engine
/// writes the shared info center itself and, with `commands`, answers the shared command center.
enum NowPlayingPublisherPlan: Equatable {
    case none
    case sessionCommands
    case sharedCenter(commands: Bool)

    var usesSharedSurface: Bool {
        if case .sharedCenter = self { return true }
        return false
    }
}

/// The host's opt-ins, read when a route starts.
struct NowPlayingOptIns: Equatable {
    var software = false
    var videoSession = false
    var videoCommands = false
    var audio = false
}

extension AetherEngine: SharedNowPlayingClient {

    /// Pure routing decision, kept free of MediaPlayer so every branch is testable on any platform.
    /// A secondary `sharedOutputRole` never publishes (Sodalite#175).
    nonisolated static func nowPlayingPlan(for kind: NowPlayingRouteKind, hasSession: Bool,
                                           optIns: NowPlayingOptIns, role: SharedOutputRole) -> NowPlayingPublisherPlan {
        guard role == .primary else { return .none }
        switch kind {
        case .softwareVideo:
            return optIns.software ? .sharedCenter(commands: true) : .none
        case .nativeVideo:
            guard optIns.videoSession else { return .none }
            if hasSession { return optIns.videoCommands ? .sessionCommands : .none }
            return .sharedCenter(commands: optIns.videoCommands)
        case .audioAVPlayer:
            guard optIns.audio else { return .none }
            return hasSession ? .sessionCommands : .sharedCenter(commands: true)
        case .audioFFmpeg:
            return optIns.audio ? .sharedCenter(commands: true) : .none
        }
    }

    var nowPlayingOptIns: NowPlayingOptIns {
        NowPlayingOptIns(software: ownsSoftwareNowPlaying, videoSession: ownsVideoNowPlayingSession,
                         videoCommands: ownsVideoNowPlayingCommands, audio: ownsAudioNowPlaying)
    }

    /// The software host's publisher (the original route; kept as the entry point its load site and the
    /// tests use).
    func startSoftwareNowPlaying() {
        startNowPlayingPublisher(.softwareVideo, sessionCenter: nil)
    }

    /// Builds the publisher for a freshly loaded route. Called at every host creation or reuse, also for a
    /// route the engine does not own, so a card kept across the previous item's teardown is cleared.
    func startNowPlayingPublisher(_ kind: NowPlayingRouteKind, sessionCenter: MPRemoteCommandCenter?) {
        stopNowPlayingPublisher(clearCard: false)
        let plan = Self.nowPlayingPlan(for: kind, hasSession: sessionCenter != nil,
                                       optIns: nowPlayingOptIns, role: loadedOptions.sharedOutputRole)
        guard plan != .none else {
            dropRetainedNowPlayingCard(clear: true)
            nowPlayingArbiter.release(self)
            return
        }
        let sink = makeNowPlayingSink(plan, sessionCenter)
        let controller = SoftwareNowPlayingController(sink: sink, transport: self)
        nowPlayingController = controller
        nowPlayingRoute = (kind, plan)
        controller.setTracks(nowPlayingTrackAvailability)
        if kind == .softwareVideo { softwareNowPlayingActive = true }

        // @Published emits before the stored value changes, so a synchronous read in the sink would see the
        // previous state; the hop lets the controller read the settled values.
        Publishers.CombineLatest4($state, $isBuffering, $duration, $isLive)
            .sink { [weak self] _ in
                Task { @MainActor in self?.nowPlayingStateChanged() }
            }
            .store(in: &nowPlayingCancellables)
        clock.$currentTime
            .sink { [weak self] elapsed in self?.nowPlayingController?.clockTick(elapsed) }
            .store(in: &nowPlayingCancellables)
        #if os(tvOS)
        // tvOS renders the Home overlay from a recent entry and drops a stale one: without a periodic
        // write the badge lags behind the last one, and a pause drops the overlay and the remote's play
        // route with it (measured on Sodalite's music path, which carried this 2 s refresh until the
        // engine took it over). A session route needs none, the session publishes from its player.
        if plan.usesSharedSurface {
            Timer.publish(every: 2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.refreshSoftwareNowPlaying() }
                .store(in: &nowPlayingCancellables)
        }
        #endif

        if plan.usesSharedSurface {
            if nowPlayingArbiter.enlist(self) {
                activateNowPlayingController()
            } else {
                dropRetainedNowPlayingCard(clear: true)
            }
        } else {
            nowPlayingArbiter.release(self)
            dropRetainedNowPlayingCard(clear: true)
            activateNowPlayingController()
        }
    }

    private func activateNowPlayingController() {
        guard let controller = nowPlayingController, !controller.isActive else { return }
        controller.start(skipInterval: remoteSkipInterval)
        refreshSoftwareNowPlaying()
        // The fresh card is on the center now, over whatever the previous item left there.
        dropRetainedNowPlayingCard(clear: false)
        refreshNowPlayingIdentity()
    }

    /// `clearCard` false keeps the card on the shared center through the seam between two items: the next
    /// route publishes over it, and `stop()` or a route the engine does not own clears it. Without that,
    /// the card blinks out on every track change of a playlist.
    func stopNowPlayingPublisher(clearCard: Bool = true) {
        if let controller = nowPlayingController {
            if !clearCard, controller.isActive, nowPlayingRoute?.plan.usesSharedSurface == true {
                retainedNowPlayingSink = controller.sink
            }
            controller.stop(clearCard: clearCard)
        }
        nowPlayingController = nil
        nowPlayingRoute = nil
        nowPlayingCancellables.removeAll()
        if softwareNowPlayingActive { softwareNowPlayingActive = false }
    }

    func stopSoftwareNowPlaying() {
        stopNowPlayingPublisher()
    }

    /// Public `stop()`: the session is over, so nothing is kept and the surface is handed on.
    func finishNowPlaying() {
        stopNowPlayingPublisher(clearCard: true)
        dropRetainedNowPlayingCard(clear: true)
        nowPlayingArbiter.release(self)
    }

    private func dropRetainedNowPlayingCard(clear: Bool) {
        if clear { retainedNowPlayingSink?.clearCard() }
        retainedNowPlayingSink = nil
    }

    private func nowPlayingStateChanged() {
        if state == .playing, nowPlayingRoute?.plan.usesSharedSurface == true {
            nowPlayingArbiter.claim(self)
        }
        refreshSoftwareNowPlaying()
    }

    func sharedNowPlayingOwnershipChanged(isOwner: Bool) {
        guard let controller = nowPlayingController, nowPlayingRoute?.plan.usesSharedSurface == true else { return }
        if isOwner {
            activateNowPlayingController()
        } else {
            controller.stop(clearCard: true)
        }
    }

    /// Republish after a state-independent change such as a speed change.
    func refreshSoftwareNowPlaying() {
        nowPlayingController?.refresh(requestedRate: desiredRate, isBuffering: isBuffering)
    }

    /// Identity from the staged `externalMetadata`, overlaid by the staged info dictionary of the route
    /// (`setNowPlayingInfo`, or the video or audio variant) where both name a key, so the explicit
    /// dictionary wins. A session route needs none: its session publishes the item's own `nowPlayingInfo`.
    func refreshNowPlayingIdentity() {
        guard let controller = nowPlayingController, let route = nowPlayingRoute,
              route.plan.usesSharedSurface else { return }
        let items = pendingExternalMetadata
        let explicit = route.kind.isAudio ? pendingAudioNowPlayingInfo : pendingVideoNowPlayingInfo
        let generation = loadGeneration
        // Loads finish out of order when metadata is restaged quickly; only the latest ticket applies.
        let ticket = controller.beginIdentityUpdate()
        Task { @MainActor [weak self] in
            var identity = await SoftwareNowPlayingIdentity.make(from: items)
            identity.merge(explicit) { _, new in new }
            guard let self, self.loadGeneration == generation, self.nowPlayingController === controller else { return }
            controller.setIdentity(identity, ticket: ticket)
        }
    }

    var nowPlayingTrackAvailability: NowPlayingTrackAvailability {
        NowPlayingTrackAvailability(next: nowPlayingNextTrackHandler != nil,
                                    previous: nowPlayingPreviousTrackHandler != nil)
    }

    // MARK: SoftwareNowPlayingTransport (remote side)

    func playFromRemote() {
        #if os(iOS) || os(tvOS)
        // The system may have deactivated the session during the pause; AVPlayer resumed on an inactive
        // session plays nothing. Synchronous on purpose: play() must not race ahead of the activation.
        if rendererAudioSessionActivationEnabled, state != .playing {
            do { try AVAudioSession.sharedInstance().setActive(true) }
            catch { EngineLog.emit("[NowPlaying] audio session reactivation failed: \(error)", category: .engine) }
        }
        #endif
        play()
    }

    func togglePlayPauseFromRemote() {
        if state == .paused { playFromRemote() } else { togglePlayPause() }
    }

    func interceptRemoteCommand(_ command: NowPlayingRemoteCommand) -> Bool {
        nowPlayingCommandInterceptor?(command) ?? false
    }

    func performTrackCommand(next: Bool) {
        (next ? nowPlayingNextTrackHandler : nowPlayingPreviousTrackHandler)?()
    }
}
