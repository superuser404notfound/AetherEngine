import AVFoundation
import Foundation
import MediaPlayer
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A remote command the system forwards to the engine, already decoded off the MediaPlayer event types.
enum SoftwareNowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    /// Signed: negative skips back.
    case skip(seconds: Double)
    case changePosition(to: Double)
}

/// What the Now-Playing publisher drives and reads. The engine conforms; tests use a recording stand-in.
@MainActor
protocol SoftwareNowPlayingTransport: AnyObject {
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var isLive: Bool { get }
    func play()
    func pause()
    func togglePlayPause()
    func seek(to seconds: Double) async
}

extension AetherEngine: SoftwareNowPlayingTransport {}

/// The system side of Now-Playing: an info dictionary plus command registration. Real implementation is
/// `SystemNowPlayingSink`; the controller only sees this, so the state mapping needs no MediaPlayer.
@MainActor
protocol SoftwareNowPlayingSink: AnyObject {
    func activate(skipInterval: Double, handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void)
    func setSeekingEnabled(_ enabled: Bool)
    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState)
    func deactivate()
}

/// Pure mapping from engine state to what the system card shows, and from commands to engine actions.
enum SoftwareNowPlayingPolicy {
    /// How long the clock may stand still while playing before it counts as a stall.
    static let stallThreshold: TimeInterval = 0.5

    /// A published position the system extrapolates from rate; a clock jump beyond this many seconds from
    /// that extrapolation (a seek while paused, a host-driven reposition) is republished.
    static let driftTolerance: Double = 2

    /// Rate the system extrapolates elapsed with: the requested speed while actually advancing, else 0.
    static func playbackRate(state: PlaybackState, isBuffering: Bool, requestedRate: Float) -> Double {
        guard state == .playing, !isBuffering else { return 0 }
        return Double(requestedRate > 0 ? requestedRate : 1)
    }

    /// `intendedPlaying` carries the last play/pause intent across `.loading`/`.seeking`, which say
    /// nothing about it, so the transport glyph does not flicker through a scrub.
    static func playbackState(state: PlaybackState, intendedPlaying: Bool) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing: return .playing
        case .paused: return .paused
        case .loading, .seeking: return intendedPlaying ? .playing : .paused
        // Ended keeps the card (paused, full bar) until the host reacts; only a torn-down session clears it.
        case .ended: return .paused
        case .idle, .error: return .stopped
        }
    }

    /// Whether the card shows at all. Idle and failed sessions clear it.
    static func showsCard(state: PlaybackState) -> Bool {
        switch state {
        case .idle, .error: return false
        default: return true
        }
    }

    static func info(state: PlaybackState, elapsed: Double, duration: Double, isLive: Bool,
                     isBuffering: Bool, requestedRate: Float, identity: [String: Any]) -> [String: Any]? {
        guard showsCard(state: state) else { return nil }
        var info = identity
        let finite = elapsed.isFinite ? max(0, elapsed) : 0
        let known = duration.isFinite && duration > 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (state == .ended && known) ? duration : finite
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            playbackRate(state: state, isBuffering: isBuffering, requestedRate: requestedRate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive
        if known && !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        return info
    }

    static func needsRepublish(publishedElapsed: Double, publishedRate: Double, secondsSincePublish: Double,
                               currentElapsed: Double) -> Bool {
        let expected = publishedElapsed + publishedRate * max(0, secondsSincePublish)
        return abs(currentElapsed - expected) > driftTolerance
    }

    /// Scrubbing and skipping make no sense on a live source with no DVR window; the engine refuses a
    /// live seek anyway, so the buttons are disabled instead of accepted and ignored.
    static func seekingEnabled(isLive: Bool) -> Bool { !isLive }

    @MainActor
    static func perform(_ command: SoftwareNowPlayingCommand, on transport: any SoftwareNowPlayingTransport) {
        switch command {
        case .play: transport.play()
        case .pause: transport.pause()
        case .togglePlayPause: transport.togglePlayPause()
        case .skip(let seconds):
            let target = skipTarget(current: transport.currentTime, delta: seconds, duration: transport.duration)
            Task { @MainActor in await transport.seek(to: target) }
        case .changePosition(let position):
            let target = skipTarget(current: position, delta: 0, duration: transport.duration)
            Task { @MainActor in await transport.seek(to: target) }
        }
    }

    static func skipTarget(current: Double, delta: Double, duration: Double) -> Double {
        let raw = (current.isFinite ? current : 0) + delta
        let upper = (duration.isFinite && duration > 0) ? duration : raw
        return min(max(0, raw), upper)
    }
}

/// Publishes the software host's Now-Playing card and routes the system's remote commands to the engine.
/// The AVPlayer paths get both from their player; the software host has none, so this fills the same
/// role by hand. Elapsed time is only published on discontinuities (state, rate, duration, a clock jump):
/// the system extrapolates between them from the published rate.
@MainActor
final class SoftwareNowPlayingController {
    private let sink: SoftwareNowPlayingSink
    private weak var transport: (any SoftwareNowPlayingTransport)?
    private var identity: [String: Any] = [:]
    private var intendedPlaying = false
    private var published: (elapsed: Double, rate: Double, at: TimeInterval)?
    private let uptime: () -> TimeInterval

    init(sink: SoftwareNowPlayingSink, transport: any SoftwareNowPlayingTransport,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.transport = transport
        self.uptime = uptime
    }

    func start(skipInterval: Double = 10) {
        sink.activate(skipInterval: skipInterval) { [weak self] command in
            guard let transport = self?.transport else { return }
            SoftwareNowPlayingPolicy.perform(command, on: transport)
        }
    }

    func stop() {
        sink.deactivate()
        published = nil
    }

    /// Per-item identity (title, artwork, ...). Empty clears it.
    /// Identity loads are async and can finish out of order: take a ticket before starting one and pass it
    /// back, and only the latest ticket's result is applied.
    func beginIdentityUpdate() -> Int {
        identitySeq += 1
        return identitySeq
    }

    func setIdentity(_ info: [String: Any], ticket: Int? = nil) {
        if let ticket, ticket != identitySeq { return }
        identity = info
        refresh(requestedRate: nil, isBuffering: engineBuffering)
    }

    /// A state, rate, duration, buffering or live change: always republishes. `isBuffering` is the
    /// engine's own flag; a stall this controller detected from the clock is folded in on top of it.
    /// `elapsed` lets the clock sink pass the value it was handed, since the transport's own
    /// `currentTime` still holds the previous one while a @Published change is being delivered.
    func refresh(requestedRate: Float?, isBuffering: Bool, elapsed: Double? = nil) {
        guard let transport else { return }
        let state = transport.state
        if state == .playing { intendedPlaying = true } else if state == .paused { intendedPlaying = false }
        if state != .playing { stalled = false }
        let rate = requestedRate ?? lastRequestedRate
        lastRequestedRate = rate
        engineBuffering = isBuffering
        let position = elapsed ?? transport.currentTime
        // A republish is a fresh baseline: a play press must not read the idle time before it as a stall.
        lastTickElapsed = position
        lastAdvanceAt = uptime()
        let info = SoftwareNowPlayingPolicy.info(
            state: state, elapsed: position, duration: transport.duration,
            isLive: transport.isLive, isBuffering: isBuffering || stalled, requestedRate: rate, identity: identity)
        sink.setSeekingEnabled(SoftwareNowPlayingPolicy.seekingEnabled(isLive: transport.isLive))
        sink.publish(info: info,
                     playbackState: SoftwareNowPlayingPolicy.playbackState(state: state,
                                                                          intendedPlaying: intendedPlaying))
        if let info {
            published = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
                         info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0, uptime())
        } else {
            published = nil
        }
    }

    /// The clock, ticking at 4 Hz (the host's 0.25 s timer; ticks pause while a seek is in flight). The software path never reports buffering, so a clock that stands still while
    /// playing is the stall signal: rate goes to 0 until it advances again. Otherwise republish only
    /// when the position left the extrapolation the system holds (a seek while paused, a reposition).
    func clockTick(_ elapsed: Double) {
        guard let published, let transport else { return }
        let now = uptime()
        if transport.state == .playing {
            // Either direction is the clock moving; a backward reposition is not a stall.
            if abs(elapsed - lastTickElapsed) > 0.001 {
                lastTickElapsed = elapsed
                lastAdvanceAt = now
                if stalled {
                    stalled = false
                    refresh(requestedRate: nil, isBuffering: engineBuffering, elapsed: elapsed)
                    return
                }
            } else if !stalled, now - lastAdvanceAt >= SoftwareNowPlayingPolicy.stallThreshold {
                stalled = true
                refresh(requestedRate: nil, isBuffering: engineBuffering, elapsed: elapsed)
                return
            }
        }
        if SoftwareNowPlayingPolicy.needsRepublish(
            publishedElapsed: published.elapsed, publishedRate: published.rate,
            secondsSincePublish: now - published.at, currentElapsed: elapsed) {
            refresh(requestedRate: nil, isBuffering: engineBuffering, elapsed: elapsed)
        }
    }

    private var identitySeq = 0
    private var lastRequestedRate: Float = 1
    private var engineBuffering = false
    private var stalled = false
    private var lastTickElapsed: Double = 0
    private var lastAdvanceAt: TimeInterval = 0
}

/// Identity keys for the card, taken from the AVKit `externalMetadata` the host already stages for the
/// AVPlayer path, so one staging call serves whichever host plays.
enum SoftwareNowPlayingIdentity {
    /// The value loads suspend rather than block; only the artwork decode is moved off the main actor.
    @MainActor
    static func make(from items: [AVMetadataItem]) async -> [String: Any] {
        var info: [String: Any] = [:]
        for item in items {
            switch item.identifier {
            case .commonIdentifierTitle:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyTitle] = v }
            case .commonIdentifierArtist:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyArtist] = v }
            case .commonIdentifierAlbumName:
                if let v = try? await item.load(.stringValue) { info[MPMediaItemPropertyAlbumTitle] = v }
            case .commonIdentifierArtwork:
                if let data = try? await item.load(.dataValue) {
                    let decoded = await BlockingWork.detached { ArtworkBox(artwork: artwork(from: data)) }.value
                    if let art = decoded.artwork { info[MPMediaItemPropertyArtwork] = art }
                }
            default: break
            }
        }
        return info
    }

    /// Decoded once up front: the request handler may run off the main thread, and a lazy decode there
    /// is what the staged-dictionary contract on the AVPlayer paths also avoids.
    static func artwork(from data: Data) -> MPMediaItemArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let box = UncheckedImage(image: image)
        return MPMediaItemArtwork(boundsSize: size) { _ in box.platformImage }
    }

    private struct ArtworkBox: @unchecked Sendable {
        let artwork: MPMediaItemArtwork?
    }

    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage
        #if canImport(UIKit)
        var platformImage: UIImage { UIImage(cgImage: image) }
        #else
        var platformImage: NSImage { NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        #endif
    }
}

/// The slice of `MPNowPlayingInfoCenter` the sink writes, so a test can stand in for the shared center.
protocol NowPlayingInfoStore: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoStore {}

/// The slice of `MPRemoteCommand` the sink drives.
protocol RemoteCommandHandle: AnyObject {
    var isEnabled: Bool { get set }
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any
    func removeTarget(_ target: Any?)
}

extension MPRemoteCommand: RemoteCommandHandle {}

/// The commands the software host serves, plus the skip distance. `MPRemoteCommandCenter` cannot be
/// built by a test, so the sink talks to this instead.
protocol RemoteCommandSurface: AnyObject {
    var play: any RemoteCommandHandle { get }
    var pause: any RemoteCommandHandle { get }
    var togglePlayPause: any RemoteCommandHandle { get }
    var skipForward: any RemoteCommandHandle { get }
    var skipBackward: any RemoteCommandHandle { get }
    var changePosition: any RemoteCommandHandle { get }
    func setSkipInterval(_ seconds: Double)
}

final class SharedRemoteCommandSurface: RemoteCommandSurface {
    private var center: MPRemoteCommandCenter { .shared() }
    var play: any RemoteCommandHandle { center.playCommand }
    var pause: any RemoteCommandHandle { center.pauseCommand }
    var togglePlayPause: any RemoteCommandHandle { center.togglePlayPauseCommand }
    var skipForward: any RemoteCommandHandle { center.skipForwardCommand }
    var skipBackward: any RemoteCommandHandle { center.skipBackwardCommand }
    var changePosition: any RemoteCommandHandle { center.changePlaybackPositionCommand }
    func setSkipInterval(_ seconds: Double) {
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
    }
}

/// MediaPlayer-backed sink on the shared info and command centers. `MPNowPlayingSession` is not used:
/// it asserts on an empty player list, and this host has no `AVPlayer` to give it.
///
/// The centers are process-wide, so the sink is a polite tenant: `deactivate` removes only its own
/// targets, restores each command's `isEnabled` to what it was at `activate`, and clears the info and
/// playback state only while the center still holds what this sink last published (another owner that
/// took over in the meantime keeps its card).
@MainActor
final class SystemNowPlayingSink: SoftwareNowPlayingSink {
    private let infoCenter: any NowPlayingInfoStore
    private let commands: any RemoteCommandSurface
    private var tokens: [(any RemoteCommandHandle, Any)] = []
    private var priorEnabled: [(any RemoteCommandHandle, Bool)] = []
    /// Our last `isEnabled` write per command; restored only while the command still holds it.
    private var written: [ObjectIdentifier: Bool] = [:]
    private var lastPublished: [String: Any]?

    init(infoCenter: any NowPlayingInfoStore = MPNowPlayingInfoCenter.default(),
         commands: any RemoteCommandSurface = SharedRemoteCommandSurface()) {
        self.infoCenter = infoCenter
        self.commands = commands
    }

    private var allCommands: [any RemoteCommandHandle] {
        [commands.play, commands.pause, commands.togglePlayPause,
         commands.skipForward, commands.skipBackward, commands.changePosition]
    }

    func activate(skipInterval: Double, handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void) {
        priorEnabled = allCommands.map { ($0, $0.isEnabled) }
        written.removeAll()
        // MediaPlayer delivers commands on a queue of its own (not the main actor), so the target is
        // explicitly @Sendable and hops to the main actor itself instead of inheriting this isolation.
        func add(_ command: any RemoteCommandHandle,
                 _ make: @escaping @Sendable (MPRemoteCommandEvent) -> SoftwareNowPlayingCommand?) {
            setEnabled(command, true)
            let token = command.addTarget { @Sendable event in
                guard let decoded = make(event) else { return .commandFailed }
                Task { @MainActor in handler(decoded) }
                return .success
            }
            tokens.append((command, token))
        }
        add(commands.play) { _ in .play }
        add(commands.pause) { _ in .pause }
        add(commands.togglePlayPause) { _ in .togglePlayPause }
        commands.setSkipInterval(skipInterval)
        add(commands.skipForward) { ($0 as? MPSkipIntervalCommandEvent).map { .skip(seconds: $0.interval) } }
        add(commands.skipBackward) { ($0 as? MPSkipIntervalCommandEvent).map { .skip(seconds: -$0.interval) } }
        add(commands.changePosition) {
            ($0 as? MPChangePlaybackPositionCommandEvent).map { .changePosition(to: $0.positionTime) }
        }
    }

    func setSeekingEnabled(_ enabled: Bool) {
        setEnabled(commands.skipForward, enabled)
        setEnabled(commands.skipBackward, enabled)
        setEnabled(commands.changePosition, enabled)
    }

    private func setEnabled(_ command: any RemoteCommandHandle, _ enabled: Bool) {
        command.isEnabled = enabled
        written[ObjectIdentifier(command)] = enabled
    }

    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
        lastPublished = info
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = playbackState
    }

    func deactivate() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens.removeAll()
        for (command, enabled) in priorEnabled where written[ObjectIdentifier(command)] == command.isEnabled {
            command.isEnabled = enabled
        }
        priorEnabled.removeAll()
        written.removeAll()
        if let last = lastPublished, Self.sameCard(infoCenter.nowPlayingInfo, last) {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
        }
        lastPublished = nil
    }

    /// Whether the center still holds our card. Every publish writes an elapsed value and `lastPublished`
    /// is refreshed on each one, while the center's elapsed value changes only when someone writes it, so
    /// a foreign write differs in elapsed (or rate) even when title and duration happen to agree. A card
    /// with no elapsed value on either side never matches, and scalars are compared rather than the
    /// dictionaries, whose equality over artwork objects is not dependable.
    static func sameCard(_ held: [String: Any]?, _ ours: [String: Any]) -> Bool {
        guard let held,
              let heldElapsed = held[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
              let ourElapsed = ours[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        else { return false }
        return heldElapsed == ourElapsed
            && held[MPNowPlayingInfoPropertyPlaybackRate] as? Double == ours[MPNowPlayingInfoPropertyPlaybackRate] as? Double
            && held[MPMediaItemPropertyTitle] as? String == ours[MPMediaItemPropertyTitle] as? String
            && held[MPMediaItemPropertyPlaybackDuration] as? Double == ours[MPMediaItemPropertyPlaybackDuration] as? Double
    }
}
