import Foundation

/// AE#958: a ranged reconnect that starts inside bytes the reader already holds, checked against
/// them before anything it delivers is kept.
///
/// Some origins (IPTV timeshift archives are the field case) answer every `Range: bytes=X-` with a
/// `206` whose `Content-Range` names X while the body starts on the origin's own chunk boundary.
/// Nothing in the headers gives that away, the bytes do: the reconnect is asked a few KB early, and
/// those KB have to equal what the reader already has for the same offsets. Delivery is held back
/// until the comparison is complete, so a fabricated body never reaches the window, and the
/// re-read overlap never does either: the window continues at the offset that was wanted.
struct RangeHonestyProbe {
    enum Outcome: Equatable {
        /// Fewer bytes than the check needs have arrived; nothing is released yet.
        case pending
        /// The overlap matched. `released` is what arrived past it, to be appended as usual; the
        /// overlap itself is already held and is dropped.
        case honoured(released: Data)
        /// The body is not the bytes at the offset the origin claimed. `received` is what it sent.
        case fabricated(received: Data)
    }

    let generation: Int
    /// The offset the request was actually sent for (the overlap's first byte).
    let start: Int64
    let expected: Data
    private var held = Data()

    init(generation: Int, start: Int64, expected: Data) {
        self.generation = generation
        self.start = start
        self.expected = expected
    }

    mutating func absorb(_ data: Data) -> Outcome {
        held.append(data)
        guard held.count >= expected.count else { return .pending }
        if held.prefix(expected.count) == expected {
            defer { held = Data() }
            return .honoured(released: Data(held.dropFirst(expected.count)))
        }
        return .fabricated(received: held)
    }
}

/// AE#958: the sources whose origin was caught answering a range with other bytes, so the session
/// that fails on it can say why instead of reporting a source that merely stopped reading.
/// Process-wide because the reader that catches it and the session that reports it do not share an
/// object; URL-keyed and time-stamped like the rate-limit verdict, so it only explains failures
/// that follow it closely.
enum FabricatedRangeOrigins {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caughtAt: [String: Date] = [:]
    private static let capacity = 8

    static func record(_ url: URL, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if caughtAt[url.absoluteString] == nil, caughtAt.count >= capacity,
           let oldest = caughtAt.min(by: { $0.value < $1.value })?.key {
            caughtAt[oldest] = nil
        }
        caughtAt[url.absoluteString] = now
    }

    static func caughtRecently(_ url: URL, within seconds: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = caughtAt[url.absoluteString] else { return false }
        return now.timeIntervalSince(at) <= seconds
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        caughtAt.removeAll()
    }
}
