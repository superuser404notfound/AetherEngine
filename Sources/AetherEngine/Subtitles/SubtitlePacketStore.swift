import Foundation

/// #112 rework: session-lifetime retention of compressed subtitle packets harvested
/// from the owning host's demux pump (HLSSegmentProducer or SoftwarePlaybackHost).
/// Written on the pump thread, read by the MainActor overlay drainer; all state is
/// lock-guarded (same pattern as NativeSubtitleCueStore).
struct StoredSubtitlePacket: Sendable {
    let ptsSeconds: Double
    let durationSeconds: Double
    let payload: Data
}

final class SubtitlePacketStore: @unchecked Sendable {
    /// Trailing retention behind the playhead; matches subtitleCueRetentionSeconds.
    static let retentionSeconds: Double = 300
    /// Safety cap per stream. Forward exposure is naturally bounded by the producer's
    /// forward-buffer park (#102); this guards pathological interleaves. Oldest entries
    /// evict first: they are already consumed by the drainer, ahead entries cannot be
    /// re-fetched.
    static let perStreamByteCap: Int = 32 * 1024 * 1024

    private let lock = NSLock()
    private var entriesByStream: [Int32: [StoredSubtitlePacket]] = [:]
    private var bytesByStream: [Int32: Int] = [:]

    func append(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        var entries = entriesByStream[streamIndex] ?? []
        var bytes = bytesByStream[streamIndex] ?? 0
        let entry = StoredSubtitlePacket(ptsSeconds: ptsSeconds,
                                         durationSeconds: durationSeconds,
                                         payload: payload)
        let insertAt = entries.firstIndex { $0.ptsSeconds >= ptsSeconds } ?? entries.count
        if insertAt < entries.count, entries[insertAt].ptsSeconds == ptsSeconds {
            bytes -= entries[insertAt].payload.count
            entries[insertAt] = entry
        } else {
            entries.insert(entry, at: insertAt)
        }
        bytes += payload.count
        while bytes > Self.perStreamByteCap, entries.count > 1 {
            bytes -= entries.removeFirst().payload.count
        }
        entriesByStream[streamIndex] = entries
        bytesByStream[streamIndex] = bytes
    }

    func entries(streamIndex: Int32, from: Double, through: Double) -> [StoredSubtitlePacket] {
        lock.lock(); defer { lock.unlock() }
        guard let entries = entriesByStream[streamIndex] else { return [] }
        return entries.filter { $0.ptsSeconds >= from && $0.ptsSeconds <= through }
    }

    func frontier(streamIndex: Int32) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return entriesByStream[streamIndex]?.last?.ptsSeconds
    }

    func prune(before cutoff: Double) {
        lock.lock(); defer { lock.unlock() }
        for (idx, entries) in entriesByStream {
            let kept = entries.drop { $0.ptsSeconds < cutoff }
            if kept.count != entries.count {
                entriesByStream[idx] = Array(kept)
                bytesByStream[idx] = kept.reduce(0) { $0 + $1.payload.count }
            }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entriesByStream.removeAll()
        bytesByStream.removeAll()
    }
}
