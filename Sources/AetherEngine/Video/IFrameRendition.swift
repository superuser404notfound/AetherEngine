// Sources/AetherEngine/Video/IFrameRendition.swift
import Foundation

/// What the segment provider needs from an I-frame rendition (AE#682).
protocol IFrameSegmentSource: AnyObject, Sendable {
    var format: IFrameRenditionFormat { get }
    func initSegment() -> Data?
    /// `isAbandoned` is true once the client that asked has hung up; such a request reads nothing.
    func fragment(at index: Int, isAbandoned: @escaping () -> Bool) -> Data?
}

extension IFrameSegmentSource {
    func fragment(at index: Int) -> Data? { fragment(at: index, isAbandoned: { false }) }
}

/// What the I-frame rendition carries, and so what the master declares for it.
enum IFrameRenditionFormat: Equatable, Sendable {
    /// The source's own keyframes; the master repeats the variant's codec, range and size.
    case keyframes
    /// One SDR Motion JPEG still per keyframe (`IFrameJPEGBuilder`), for HDR and Dolby Vision sources.
    case jpeg(width: Int, height: Int, bandwidth: Int)

    var logName: String {
        switch self {
        case .keyframes: return "keyframes"
        case .jpeg: return "jpeg"
        }
    }
}

/// AE#682: answers `iframe_init.mp4` and `iframe{N}.mp4`. One request at a time: there is one side
/// demuxer, and AVKit asks for up to five keyframes at once. Who goes next is `IFrameRequestGate`'s
/// call: the newest request first, the ladder's prefetch only when no request waits.
final class IFrameRendition: IFrameSegmentSource, @unchecked Sendable {
    struct Entry {
        let startPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }

    let format: IFrameRenditionFormat
    private let entries: [Entry]
    private let cache: IFramePayloadCache
    private let readPayload: (Entry) -> Data?
    private let buildFragment: (Data, Int, Entry) -> IFrameFragmentBuilder.Output?
    private let waitForLink: (_ shouldStop: () -> Bool) -> Void
    private let sourceReadsAllowed: () -> Bool
    private let interruptReads: () -> Void
    private let closeReader: () -> Void

    private let gate = IFrameRequestGate()
    private let stateLock = NSLock()
    private var isShutDown = false
    private var capturedInit: Data?
    private var failureLog = IFrameLogThrottle()
    private var abandonedLog = IFrameLogThrottle()
    private var abandonedSkips = 0

    init(entries: [Entry],
         cache: IFramePayloadCache,
         format: IFrameRenditionFormat = .keyframes,
         readPayload: @escaping (Entry) -> Data?,
         buildFragment: @escaping (Data, Int, Entry) -> IFrameFragmentBuilder.Output?,
         waitForLink: @escaping (_ shouldStop: () -> Bool) -> Void = { _ in },
         sourceReadsAllowed: @escaping () -> Bool = { true },
         interruptReads: @escaping () -> Void = {},
         closeReader: @escaping () -> Void = {}) {
        self.format = format
        self.entries = entries
        self.cache = cache
        self.readPayload = readPayload
        self.buildFragment = buildFragment
        self.waitForLink = waitForLink
        self.sourceReadsAllowed = sourceReadsAllowed
        self.interruptReads = interruptReads
        self.closeReader = closeReader
    }

    /// Calls waiting for their turn on the side reader, for tests.
    var waitingTurns: Int { gate.waitingCount }

    private var shutDown: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isShutDown
    }

    func initSegment() -> Data? {
        gate.withTurn(.request) {
            guard !shutDown else { return nil }
            if capturedInit == nil { _ = buildLocked(at: 0) }
            return capturedInit
        }
    }

    func fragment(at index: Int, isAbandoned: @escaping () -> Bool) -> Data? {
        gate.withTurn(.request) {
            guard !shutDown else { return nil }
            return buildLocked(at: index, isAbandoned: isAbandoned)
        }
    }

    /// The keyframe that opens segment `index`, from the cache or the side reader, and never a
    /// neighbour's in its place: a scrub preview names the span it shows, so a stand-in would put
    /// the wrong picture over the right time. `isStale` is asked before the source is touched, so a
    /// queue of superseded requests costs no reads.
    func keyframePayload(at index: Int, isStale: () -> Bool = { false }) -> Data? {
        gate.withTurn(.request) {
            guard !shutDown, entries.indices.contains(index) else { return nil }
            if let cached = cache.payload(for: index) { return cached }
            guard !isStale() else { return nil }
            return readLocked(at: index)
        }
    }

    /// Reads the keyframe for `index` ahead of AVKit's request. With `buildsFragment` it also builds
    /// the fragment, which for a JPEG rendition is the decode, tone map and encode a request would
    /// otherwise wait for. Never stands a neighbour in: a miss is nil, and the ladder counts it.
    func prefetch(at index: Int, buildsFragment: Bool) -> Data? {
        gate.withTurn(.prefetch) {
            guard !shutDown, entries.indices.contains(index) else { return nil }
            guard let payload = cache.payload(for: index) ?? readLocked(at: index) else { return nil }
            if buildsFragment, !shutDown { _ = buildLocked(at: index) }
            return payload
        }
    }

    /// A keyframe already read, without waiting for a turn: a scrub must not wait behind a read in flight.
    func cachedKeyframePayload(at index: Int) -> Data? {
        guard !shutDown, entries.indices.contains(index) else { return nil }
        return cache.payload(for: index)
    }

    /// Reads and caches one keyframe. nil when the origin has no room for it, teardown interrupted
    /// it, or the read failed.
    private func readLocked(at index: Int) -> Data? {
        // An origin that went serial or started metering mid-session has one slot and a few
        // tokens, and the pump needs them; AVKit's overview burst would take them all.
        guard sourceReadsAllowed() else { return nil }
        waitForLink { self.shutDown }
        guard !shutDown else { return nil }
        let started = DispatchTime.now()
        let read = readPayload(entries[index])
        // A read that teardown aborted is not a miss to paper over.
        guard !shutDown, let read else { return nil }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[IFrameRendition] read idx=\(index) bytes=\(read.count) "
                       + "ms=\(String(format: "%.0f", ms))", category: .session, level: .verbose)
        cache.store(read, for: index)
        return read
    }

    private func buildLocked(at index: Int, isAbandoned: () -> Bool = { false }) -> Data? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        var payload = cache.payload(for: index)
        if payload == nil {
            // AVKit gave up on it while it waited its turn; the read would only delay the next one.
            if isAbandoned() {
                abandonedSkips += 1
                if let suppressed = abandonedLog.shouldEmit(now: Date()) {
                    EngineLog.emit("[IFrameRendition] skipped idx=\(index), its request was abandoned "
                                   + "(\(abandonedSkips) so far, \(suppressed) since the last line)",
                                   category: .session)
                }
                return nil
            }
            if let read = readLocked(at: index) {
                payload = read
            } else if shutDown {
                return nil
            } else if let neighbour = cache.nearestIndex(to: index),
                      let substitute = cache.payload(for: neighbour) {
                // AVKit keeps the last good picture for a keyframe it cannot fetch, and rate trick
                // play wedges on a 404, so a near keyframe at the right time beats no answer.
                payload = substitute
                if let suppressed = failureLog.shouldEmit(now: Date()) {
                    EngineLog.emit("[IFrameRendition] no keyframe for idx=\(index), serving idx=\(neighbour) "
                                   + "in its place (\(suppressed) more since the last line)", category: .session)
                }
            } else {
                if let suppressed = failureLog.shouldEmit(now: Date()) {
                    EngineLog.emit("[IFrameRendition] no keyframe for idx=\(index) and nothing cached to stand in "
                                   + "(\(suppressed) more since the last line)", category: .session)
                }
                return nil
            }
        }
        guard let payload, let output = buildFragment(payload, index, entry) else { return nil }
        if capturedInit == nil { capturedInit = output.initSegment }
        return output.fragment
    }

    /// Idempotent, and every call drains: the session frees the codec parameters the builder reads
    /// as soon as its own call returns, so a second caller must not come back while the first is
    /// still waiting for a request to finish.
    func shutdown() {
        stateLock.lock()
        let first = !isShutDown
        isShutDown = true
        stateLock.unlock()
        if first { interruptReads() }
        gate.withTurn(.request) {
            guard first else { return }
            closeReader()
            cache.removeAll()
        }
    }
}

/// One turn at a time on the rendition's side reader. A free gate goes to the newest waiting
/// request: when a scrub moves on, the frame under the finger is the one to answer, not the ones it
/// passed on the way. The ladder's prefetch goes only when no request waits, so a request waits for
/// at most the one read already in flight.
final class IFrameRequestGate: @unchecked Sendable {
    enum Priority { case prefetch, request }

    private let condition = NSCondition()
    private var busy = false
    private var nextTicket: UInt64 = 0
    private var waiting: [UInt64: Priority] = [:]

    /// Callers waiting for a turn, for tests.
    var waitingCount: Int {
        condition.lock(); defer { condition.unlock() }
        return waiting.count
    }

    func withTurn<T>(_ priority: Priority, _ body: () -> T) -> T {
        condition.lock()
        let ticket = nextTicket
        nextTicket += 1
        waiting[ticket] = priority
        while busy || chosenLocked() != ticket { condition.wait() }
        waiting[ticket] = nil
        busy = true
        condition.unlock()
        defer {
            condition.lock()
            busy = false
            condition.broadcast()
            condition.unlock()
        }
        return body()
    }

    private func chosenLocked() -> UInt64? {
        waiting.filter { $0.value == .request }.keys.max() ?? waiting.keys.max()
    }
}

/// One line per window for a failure that repeats on every request (AVKit retries a missing
/// keyframe several times a second), with the count of the ones it swallowed.
struct IFrameLogThrottle {
    var windowSeconds: TimeInterval = 5
    private var lastEmit = Date.distantPast
    private var suppressed = 0

    /// The number of lines swallowed since the last one, when this one should be written.
    mutating func shouldEmit(now: Date) -> Int? {
        guard now.timeIntervalSince(lastEmit) >= windowSeconds else {
            suppressed += 1
            return nil
        }
        defer { suppressed = 0; lastEmit = now }
        return suppressed
    }
}
