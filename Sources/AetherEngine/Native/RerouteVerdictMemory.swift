import Foundation

/// #199: bounded, expiring memory of master URLs whose remote-HLS video-carriage watchdog fired
/// (#168: master advertises video, AVPlayer builds no video track for MPEG-TS carriage). The verdict
/// costs a full native mount plus the watchdog grace to discover; remembering it lets `load()` route
/// a known case straight onto the live-ingest loopback, so a host retune after an ingest death relands
/// on the working path instead of re-running the doomed native mount every lap (the #199 cycle).
///
/// Keyed on the exact absolute URL: IPTV origins distinguish channels by path or query, so any
/// normalization risks cross-channel false positives. A rotated per-session token misses the cache
/// and merely re-pays the one-time discovery, same as today. Entries expire so an origin that fixes
/// its packaging is not permanently exiled from the native bypass. Pure state, injectable clock.
struct RerouteVerdictMemory {
    private let capacity: Int
    private let ttl: TimeInterval
    private var recordedAt: [String: Date] = [:]

    init(capacity: Int = 32, ttl: TimeInterval = 6 * 60 * 60) {
        self.capacity = capacity
        self.ttl = ttl
    }

    /// Records a fired carriage verdict; re-recording refreshes the entry's age. Over capacity the
    /// oldest entry is evicted.
    mutating func record(_ url: URL, now: Date) {
        recordedAt[url.absoluteString] = now
        while recordedAt.count > capacity {
            guard let oldest = recordedAt.min(by: { $0.value < $1.value }) else { break }
            recordedAt.removeValue(forKey: oldest.key)
        }
    }

    /// True while a non-expired verdict exists for this exact URL. Prunes lazily.
    mutating func remembers(_ url: URL, now: Date) -> Bool {
        guard let stamp = recordedAt[url.absoluteString] else { return false }
        guard now.timeIntervalSince(stamp) <= ttl else {
            recordedAt.removeValue(forKey: url.absoluteString)
            return false
        }
        return true
    }
}
