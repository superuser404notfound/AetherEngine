import Foundation
import Libavcodec
import Libavutil

/// #112 rework: session-lifetime retention of compressed subtitle packets harvested
/// from the owning host's demux pump (HLSSegmentProducer or SoftwarePlaybackHost).
/// Written on the pump thread, read by the MainActor overlay drainer; all state is
/// lock-guarded (same pattern as NativeSubtitleCueStore).
struct StoredSubtitlePacket: Sendable {
    let ptsSeconds: Double
    let durationSeconds: Double
    /// AVPacket.flags at harvest time; EmbeddedSubtitleDecoder forwards flags into its
    /// decode packet (AV_PKT_FLAG_KEY matters for bitmap acquisition points).
    let flags: Int32
    let payload: Data
}

final class SubtitlePacketStore: @unchecked Sendable {
    /// #125: byte-bounded retention is the store's PRIMARY bound. The drainer no longer time-prunes
    /// behind the playhead (a trailing playhead-relative prune evicted packets a backward seek into
    /// cache-resident content could still land on, and the pump never re-harvests that region, so
    /// cues starved permanently). Oldest entries evict first when a stream exceeds the cap: text
    /// tracks stay far below it and keep the whole session; a bitmap track keeps a wide trailing
    /// window. A backward seek past a bitmap stream's evicted edge is the deferred windowed-re-read
    /// case (#125). Forward exposure from the pump is bounded by the producer's forward park (#102);
    /// on VOD sessions the forward prefetcher (#151) extends it to the drainer's lead window.
    static let perStreamByteCap: Int = 32 * 1024 * 1024

    /// #166: the per-stream cap alone is unbounded in aggregate. Both the pump tap and the forward
    /// prefetcher harvest EVERY embedded subtitle stream (so a track switch backfills instantly,
    /// #112), so a source with many embedded tracks (99 in the field repro, mostly bitmap) climbed
    /// toward N x perStreamByteCap (~3.2GB) and the host hit the iOS jetsam limit. This is the
    /// ceiling on the SUM across all streams: the active drain targets are protected and keep their
    /// full per-stream window; the coldest non-protected streams evict oldest-first past this budget.
    /// Sized for the two drain channels (primary + secondary, up to perStreamByteCap each) plus slack
    /// so a just-switched-away track stays warm for an instant switch-back.
    static let aggregateByteCap: Int = 96 * 1024 * 1024

    /// Ceiling for one in-assembly PGS display set (a 4K set stays far below this); a pending
    /// buffer past it is malformed or mis-parsed and gets dropped rather than grown unbounded.
    static let maxPendingDisplaySetBytes: Int = 16 * 1024 * 1024

    /// #151: which reader is writing. The pump and the forward prefetcher can both feed the same
    /// stream; completed entries dedupe by PTS in appendLocked, but an in-assembly display set
    /// must stay private to its writer or the two would interleave chunks into one corrupt set.
    enum Writer: Hashable, Sendable {
        case pump
        case prefetch
    }

    /// One PGS display set being reassembled from split MPEG-TS PES chunks (see harvestChunk).
    private struct PendingDisplaySet {
        var ptsSeconds: Double
        var durationSeconds: Double
        var flags: Int32
        var payload: Data
    }

    private struct PendingKey: Hashable {
        let streamIndex: Int32
        let writer: Writer
    }

    private let lock = NSLock()
    private var entriesByStream: [Int32: [StoredSubtitlePacket]] = [:]
    private var bytesByStream: [Int32: Int] = [:]
    private var pendingSetByStream: [PendingKey: PendingDisplaySet] = [:]

    /// Instance caps (default to the static ceilings). Injectable so tests can drive eviction with
    /// tiny payloads instead of allocating gigabytes.
    private let perStreamCap: Int
    private let aggregateCap: Int

    /// #166 aggregate-budget bookkeeping. `totalBytes` mirrors the sum of `bytesByStream` (kept
    /// incrementally so the per-append check is O(1)). `protectedStreams` are the active drain
    /// targets, never evicted by aggregate pressure. `lastTouchByStream` orders non-protected
    /// streams coldest-first for eviction; a monotonic counter (no wall clock) drives it.
    private var totalBytes: Int = 0
    private var protectedStreams: Set<Int32> = []
    private var lastTouchByStream: [Int32: UInt64] = [:]
    private var touchCounter: UInt64 = 0

    init(perStreamByteCap: Int = SubtitlePacketStore.perStreamByteCap,
         aggregateByteCap: Int = SubtitlePacketStore.aggregateByteCap) {
        self.perStreamCap = perStreamByteCap
        self.aggregateCap = aggregateByteCap
    }

    /// Total retained compressed subtitle bytes across every stream. Introspection for the
    /// aggregate-budget invariant (and available to `memprobe`-style diagnostics).
    var totalRetainedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    /// #166: mark the currently selected drain targets (primary + secondary). Protected streams are
    /// exempt from aggregate eviction, so a switch back to them still backfills from a full window.
    /// The engine calls this whenever `subtitleDrainTargets` changes.
    func setProtectedStreams(_ indices: Set<Int32>) {
        lock.lock(); defer { lock.unlock() }
        protectedStreams = indices
    }

    func append(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                flags: Int32 = 0, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(streamIndex: streamIndex, ptsSeconds: ptsSeconds,
                     durationSeconds: durationSeconds, flags: flags, payload: payload)
    }

    private func appendLocked(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                              flags: Int32, payload: Data) {
        let before = bytesByStream[streamIndex] ?? 0
        var entries = entriesByStream[streamIndex] ?? []
        var bytes = before
        let entry = StoredSubtitlePacket(ptsSeconds: ptsSeconds,
                                         durationSeconds: durationSeconds,
                                         flags: flags,
                                         payload: payload)
        let insertAt = entries.firstIndex { $0.ptsSeconds >= ptsSeconds } ?? entries.count
        if insertAt < entries.count, entries[insertAt].ptsSeconds == ptsSeconds {
            bytes -= entries[insertAt].payload.count
            entries[insertAt] = entry
        } else {
            entries.insert(entry, at: insertAt)
        }
        bytes += payload.count
        while bytes > perStreamCap, entries.count > 1 {
            bytes -= entries.removeFirst().payload.count
        }
        entriesByStream[streamIndex] = entries
        bytesByStream[streamIndex] = bytes
        totalBytes += bytes - before
        touchCounter &+= 1
        lastTouchByStream[streamIndex] = touchCounter
        enforceAggregateCapLocked(justTouched: streamIndex)
    }

    /// #166: bound retained bytes across ALL streams. Evict oldest entries from the coldest
    /// (least-recently-touched) NON-protected stream first, then the next coldest, until the total
    /// is back under `aggregateCap` or only protected streams remain. Protected streams (the active
    /// drain targets) and the stream just written keep their per-stream window; a fully drained
    /// cold stream is dropped and re-harvested from the pump/prefetcher if it is selected later.
    private func enforceAggregateCapLocked(justTouched: Int32) {
        guard totalBytes > aggregateCap else { return }
        let candidates = bytesByStream.keys
            .filter { !protectedStreams.contains($0) && $0 != justTouched }
            .sorted { (lastTouchByStream[$0] ?? 0) < (lastTouchByStream[$1] ?? 0) }
        for idx in candidates {
            guard totalBytes > aggregateCap else { break }
            guard var entries = entriesByStream[idx] else { continue }
            var bytes = bytesByStream[idx] ?? 0
            while totalBytes > aggregateCap, !entries.isEmpty {
                let removed = entries.removeFirst().payload.count
                bytes -= removed
                totalBytes -= removed
            }
            if entries.isEmpty {
                entriesByStream[idx] = nil
                bytesByStream[idx] = nil
                lastTouchByStream[idx] = nil
            } else {
                entriesByStream[idx] = entries
                bytesByStream[idx] = bytes
            }
        }
    }

    /// Shared pump-side harvest for both hosts: convert a raw AVPacket into a stored entry on
    /// the source PTS axis (raw pts x time_base, matching what EmbeddedSubtitleDecoder computes
    /// for tap packets; no start_time subtraction) and append it. Copies synchronously; the
    /// packet pointer never escapes the calling thread.
    ///
    /// `assembleSplitDisplaySets` (PGS in MPEG-TS): one display set arrives as several PES
    /// chunks (PCS|WDS|PDS|ODS|END), some without a PTS and some sharing one; per-packet
    /// storage would drop or collapse the palette/object segments and every set would fail
    /// with "Invalid palette id" at its END. Armed streams route through the reassembler.
    func harvest(streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational,
                 assembleSplitDisplaySets: Bool = false, writer: Writer = .pump) {
        let pts = packet.pointee.pts
        guard let data = packet.pointee.data, packet.pointee.size > 0,
              timeBase.den != 0 else { return }
        let tbSeconds = Double(timeBase.num) / Double(timeBase.den)
        harvestChunk(streamIndex: streamIndex,
                     ptsSeconds: pts == Int64.min ? nil : Double(pts) * tbSeconds,
                     durationSeconds: max(0, Double(packet.pointee.duration) * tbSeconds),
                     flags: packet.pointee.flags,
                     payload: Data(bytes: data, count: Int(packet.pointee.size)),
                     assembleSplitDisplaySets: assembleSplitDisplaySets,
                     writer: writer)
    }

    /// Testable core of `harvest`. ptsSeconds nil = packet carried no PTS (AV_NOPTS_VALUE):
    /// dropped on the per-packet path, folded into the pending set on the assembly path.
    func harvestChunk(streamIndex: Int32, ptsSeconds: Double?, durationSeconds: Double,
                      flags: Int32, payload: Data, assembleSplitDisplaySets: Bool,
                      writer: Writer = .pump) {
        lock.lock(); defer { lock.unlock() }
        guard assembleSplitDisplaySets else {
            guard let ptsSeconds else { return }
            appendLocked(streamIndex: streamIndex, ptsSeconds: ptsSeconds,
                         durationSeconds: durationSeconds, flags: flags, payload: payload)
            return
        }
        // Mirror the decoder's SUP-wrapper rule: strip a leading "PG" 10-byte header so
        // concatenated chunks form one clean [type][len BE][body] segment run.
        var chunk = payload
        if chunk.count > 10, chunk[chunk.startIndex] == 0x50, chunk[chunk.startIndex + 1] == 0x47 {
            chunk = chunk.dropFirst(10)
        }
        let key = PendingKey(streamIndex: streamIndex, writer: writer)
        while !chunk.isEmpty {
            var pending = pendingSetByStream[key]
            // A backward pts jump under an open set means the pump re-anchored mid-set;
            // the stale partial buffer must not swallow the fresh set's segments.
            if let pts = ptsSeconds, let open = pending, pts < open.ptsSeconds - 1.0 {
                pending = nil
            }
            let firstType = Self.pgsFirstSegmentType(in: chunk)
            if firstType == 0x16 {
                // PCS opens a display set; an unfinished predecessor (missing END, or the
                // restart overlap above) is undecodable on its own and gets dropped.
                pending = nil
                guard let pts = ptsSeconds else {
                    pendingSetByStream[key] = nil
                    return   // No anchor for this set; skip its chunks until the next PCS.
                }
                pending = PendingDisplaySet(ptsSeconds: pts, durationSeconds: durationSeconds,
                                            flags: flags, payload: Data())
            }
            guard var open = pending else {
                // Mid-set start (backfill landed between PCS and END): not decodable, drop.
                pendingSetByStream[key] = nil
                return
            }
            let endBoundary = Self.pgsEndBoundary(in: chunk)
            let consumed: Data
            if let endBoundary {
                consumed = chunk.prefix(endBoundary)
                chunk = chunk.dropFirst(endBoundary)
            } else {
                consumed = chunk
                chunk = Data()
            }
            open.payload.append(consumed)
            open.flags |= flags
            if open.payload.count > Self.maxPendingDisplaySetBytes {
                pendingSetByStream[key] = nil
                return
            }
            if endBoundary != nil {
                appendLocked(streamIndex: streamIndex, ptsSeconds: open.ptsSeconds,
                             durationSeconds: open.durationSeconds, flags: open.flags,
                             payload: open.payload)
                pendingSetByStream[key] = nil
            } else {
                pendingSetByStream[key] = open
            }
        }
    }

    // MARK: - PGS segment walk (defensive, mirrors EmbeddedSubtitleDecoder's walks)

    /// Type byte of the first segment, or nil when the chunk is too short.
    static func pgsFirstSegmentType(in payload: Data) -> UInt8? {
        payload.count >= 3 ? payload[payload.startIndex] : nil
    }

    /// Byte offset just past the first END (0x80) segment, or nil when the walk finds none.
    /// Payload layout: a run of `[type:1][length:2 BE][body:length]`; a malformed length ends
    /// the scan without reading past the chunk.
    static func pgsEndBoundary(in payload: Data) -> Int? {
        let bytes = [UInt8](payload)
        var i = 0
        while i + 3 <= bytes.count {
            let type = bytes[i]
            let len = (Int(bytes[i + 1]) << 8) | Int(bytes[i + 2])
            let next = i + 3 + len
            if type == 0x80 { return min(next, bytes.count) }
            if next <= i { break }
            i = next
        }
        return nil
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
                let newBytes = kept.reduce(0) { $0 + $1.payload.count }
                totalBytes += newBytes - (bytesByStream[idx] ?? 0)
                entriesByStream[idx] = Array(kept)
                bytesByStream[idx] = newBytes
            }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entriesByStream.removeAll()
        bytesByStream.removeAll()
        pendingSetByStream.removeAll()
        lastTouchByStream.removeAll()
        protectedStreams.removeAll()
        totalBytes = 0
        touchCounter = 0
    }
}
