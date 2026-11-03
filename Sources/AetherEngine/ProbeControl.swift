import Foundation
import AetherLibavcodec

/// Optional limits for an entire static metadata probe, including open, stream analysis and seeks.
/// Input counts bytes delivered by the reader, including rereads, not network traffic or prefetch.
public struct ProbeLimits: Sendable, Equatable {
    public var maxInputBytes: Int64
    /// Packets returned by the demuxer for inspection, across all detail passes and streams.
    /// FFmpeg's internal open/seek packets are bounded by input and time instead.
    public var maxPackets: Int
    /// Reject larger demuxed packets before inspection/decode. Not a native allocation ceiling.
    public var maxPacketBytes: Int
    /// Monotonic deadline from before the first input operation. Interrupts cooperative I/O.
    public var timeBudget: TimeInterval

    public init(
        maxInputBytes: Int64 = 8 * 1024 * 1024,
        maxPackets: Int = 128,
        maxPacketBytes: Int = 2 * 1024 * 1024,
        timeBudget: TimeInterval = 5
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxPackets = maxPackets
        self.maxPacketBytes = maxPacketBytes
        self.timeBudget = timeBudget
    }
}

/// A controlled probe throws rather than publishing a partial or late positive after a whole-probe stop.
public enum ProbeError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case inputLimit
    case packetLimit
    case packetSizeLimit
    case timedOut
    case invalidReaderResult
    case unsupportedURL
    case sourceBusy

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Probe limits must be nonnegative, with a finite time budget."
        case .inputLimit: "Probe input byte limit reached."
        case .packetLimit: "Probe packet limit reached."
        case .packetSizeLimit: "Probe packet exceeds the inspection size limit."
        case .timedOut: "Probe deadline reached."
        case .invalidReaderResult: "Probe reader returned more bytes than requested."
        case .unsupportedURL: "Controlled probes support file, HTTP and HTTPS URLs, or a custom IOReader."
        case .sourceBusy: "No HTTP origin request slot is available for this probe."
        }
    }
}

/// One-shot, thread-safe cancellation for synchronous probes. Cancellation requests interruption;
/// the probe has ended only when its call returns. Custom readers remain caller-owned.
public final class ProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: ProbeInterruption] = [:]

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let pending = lock.withLock {
            cancelled = true
            return Array(handlers.values)
        }
        for handler in pending { handler.fire() }
    }

    fileprivate func register(_ handler: ProbeInterruption) -> UUID {
        let id = UUID()
        let fire = lock.withLock {
            handlers[id] = handler
            return cancelled
        }
        if fire { handler.fire() }
        return id
    }

    fileprivate func remove(_ id: UUID) {
        let handler = lock.withLock { handlers.removeValue(forKey: id) }
        handler?.invalidate()
    }

    fileprivate func completing<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            return try body()
        }
    }
}

/// Invalidating joins an already-running callback, so it cannot touch a reused caller reader after return.
private final class ProbeInterruption: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        let action = self.action
        self.action = nil
        action?()
    }

    func invalidate() {
        lock.lock()
        action = nil
        lock.unlock()
    }
}

/// Retained by the demuxer until every native call has returned; the watchdog only interrupts, never frees.
final class ProbeControl: @unchecked Sendable {
    let limits: ProbeLimits?
    private let cancellation: ProbeCancellation?
    private let now: @Sendable () -> TimeInterval
    private let deadline: TimeInterval?
    private let lock = NSLock()
    private var failure: (any Error)?
    private var completed = false
    private var inputBytes: Int64 = 0
    private var packets = 0
    private var interruption: ProbeInterruption?
    private var cancellationID: UUID?
    private var timer: DispatchSourceTimer?

    init(
        limits: ProbeLimits?,
        cancellation: ProbeCancellation?,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        scheduleDeadline: Bool = true
    ) throws {
        if let limits {
            guard limits.maxInputBytes >= 0, limits.maxPackets >= 0, limits.maxPacketBytes >= 0,
                  limits.timeBudget.isFinite, limits.timeBudget >= 0 else { throw ProbeError.invalidLimits }
        }
        self.limits = limits
        self.cancellation = cancellation
        self.now = now
        deadline = limits.map { now() + $0.timeBudget }
        if let cancellation {
            cancellationID = cancellation.register(ProbeInterruption { [weak self] in
                self?.stop(CancellationError())
            })
        }
        if scheduleDeadline, let limits {
            let timer = DispatchSource.makeTimerSource()
            timer.setEventHandler { [weak self] in self?.stop(ProbeError.timedOut) }
            let dispatchLimit = Double(Int.max / 1_000_000_000)
            timer.schedule(deadline: limits.timeBudget >= dispatchLimit
                           ? .distantFuture : .now() + limits.timeBudget)
            self.timer = timer
            timer.resume()
        }
    }

    func interrupt(using action: @escaping @Sendable () -> Void) {
        let handler = ProbeInterruption(action)
        let stopped = lock.withLock {
            interruption = handler
            return failure != nil
        }
        if stopped { handler.fire() }
    }

    func stop(_ error: any Error) {
        let handler: ProbeInterruption? = lock.withLock {
            guard !completed else { return nil }
            if failure == nil { failure = error }
            return interruption
        }
        handler?.fire()
    }

    func check() throws {
        if cancellation?.isCancelled == true { stop(CancellationError()) }
        if let deadline, now() >= deadline { stop(ProbeError.timedOut) }
        if let error = lock.withLock({ failure }) { throw error }
    }

    var isStopped: Bool {
        do { try check(); return false }
        catch { return true }
    }

    /// Seconds left on the deadline, or nil when no numeric limits were installed. For the one wait the
    /// watchdog cannot interrupt (an origin request slot), so it can be bounded by the deadline instead.
    var remainingTime: TimeInterval? {
        deadline.map { max(0, $0 - now()) }
    }

    /// Input the probe may still consume, or nil when no numeric limits were installed.
    var remainingInputBytes: Int64? {
        limits.map { limits in lock.withLock { max(0, limits.maxInputBytes - inputBytes) } }
    }

    func inputAllowance(_ requested: Int32) throws -> Int32 {
        try check()
        guard let limits else { return requested }
        let remaining = lock.withLock { limits.maxInputBytes - inputBytes }
        guard remaining > 0 else {
            stop(ProbeError.inputLimit)
            throw ProbeError.inputLimit
        }
        return Int32(min(Int64(requested), remaining))
    }

    func consumedInput(_ count: Int32, requested: Int32) throws {
        guard count <= requested else {
            stop(ProbeError.invalidReaderResult)
            throw ProbeError.invalidReaderResult
        }
        if count > 0 { lock.withLock { inputBytes += Int64(count) } }
        try check()
    }

    func willReadPacket() throws {
        try check()
        if let limits, lock.withLock({ packets >= limits.maxPackets }) {
            stop(ProbeError.packetLimit)
            throw ProbeError.packetLimit
        }
    }

    func receivedPacket(_ packet: UnsafePointer<AVPacket>) throws {
        try check()
        if let limits, Int(packet.pointee.size) > limits.maxPacketBytes {
            stop(ProbeError.packetSizeLimit)
            throw ProbeError.packetSizeLimit
        }
        lock.withLock { packets += 1 }
    }

    /// The result's linearization point: cancellation before this wins, cancellation afterwards is too late.
    func complete() throws {
        func commit() throws {
            try lock.withLock {
                if let deadline, now() >= deadline, failure == nil { failure = ProbeError.timedOut }
                if let failure { throw failure }
                completed = true
            }
        }
        if let cancellation { try cancellation.completing(commit) }
        else { try commit() }
    }

    func finish() {
        timer?.cancel()
        timer = nil
        if let cancellationID {
            cancellation?.remove(cancellationID)
            self.cancellationID = nil
        }
        let handler = lock.withLock {
            completed = true
            let handler = interruption
            interruption = nil
            return handler
        }
        handler?.invalidate()
    }
}
