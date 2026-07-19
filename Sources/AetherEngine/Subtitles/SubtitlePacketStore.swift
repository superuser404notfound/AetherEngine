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

    func append(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                flags: Int32 = 0, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(streamIndex: streamIndex, ptsSeconds: ptsSeconds,
                     durationSeconds: durationSeconds, flags: flags, payload: payload)
    }

    private func appendLocked(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                              flags: Int32, payload: Data) {
        var entries = entriesByStream[streamIndex] ?? []
        var bytes = bytesByStream[streamIndex] ?? 0
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
        while bytes > Self.perStreamByteCap, entries.count > 1 {
            bytes -= entries.removeFirst().payload.count
        }
        entriesByStream[streamIndex] = entries
        bytesByStream[streamIndex] = bytes
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
                entriesByStream[idx] = Array(kept)
                bytesByStream[idx] = kept.reduce(0) { $0 + $1.payload.count }
            }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entriesByStream.removeAll()
        bytesByStream.removeAll()
        pendingSetByStream.removeAll()
    }
}
