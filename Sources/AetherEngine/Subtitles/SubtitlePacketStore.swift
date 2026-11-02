import Foundation
import AetherLibavcodec
import AetherLibavutil

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
    /// #233: `AV_PKT_DATA_WEBVTT_SETTINGS` as attached by the demuxer. WebVTT cue settings live
    /// only in packet side data (the decoder never puts them in the ASS line), so a rebuilt packet
    /// loses the cue's placement unless the string rides along with the payload.
    let webvttSettings: String?
    /// #362: when this entry was harvested, on the store's own monotonic append counter. A harvest
    /// reads a stream forwards, so within one run PTS and sequence rise together; a PTS-ascending
    /// pair whose sequence DESCENDS is two different runs meeting, and the span between them is one
    /// nobody has read. That is the only signal that separates a hole in the harvest from a silence
    /// in the source, and the drain needs it to decide whether waiting can bring anything.
    let sequence: UInt64

    init(ptsSeconds: Double, durationSeconds: Double, flags: Int32, payload: Data,
         webvttSettings: String? = nil, sequence: UInt64 = 0) {
        self.ptsSeconds = ptsSeconds
        self.durationSeconds = durationSeconds
        self.flags = flags
        self.payload = payload
        self.webvttSettings = webvttSettings
        self.sequence = sequence
    }
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
    /// Audit SUB-111: pending sets also count toward the aggregate cap, so 16 MiB per set was
    /// room for 16 MiB x 2 writers x every PID of a crafted transport stream.
    static let maxPendingDisplaySetBytes: Int = 4 * 1024 * 1024

    /// #151: which reader is writing. The pump and the forward prefetcher can both feed the same
    /// stream; a completed entry re-harvested by the other collapses on a byte-identical payload in
    /// appendLocked (#235: the PTS alone does not identify it), but an in-assembly display set must
    /// stay private to its writer or the two would interleave chunks into one corrupt set.
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
    /// Audit SUB-103: same-PTS runs longer than `linearDedupeRun` answer "was this payload already
    /// stored here" from a hash set instead of comparing against every packet of the run. The set is
    /// only a filter: it may hold hashes of evicted packets (a stale hit costs one scan) but never
    /// lacks one of a live packet, since every append to the run inserts its hash.
    private var payloadHashesByRun: [Int32: [UInt64: Set<Int>]] = [:]
    private static let linearDedupeRun = 8
    private static let maxCachedRunsPerStream = 4096

    /// Instance caps (default to the static ceilings). Injectable so tests can drive eviction with
    /// tiny payloads instead of allocating gigabytes.
    private let perStreamCap: Int
    private let aggregateCap: Int

    /// #166 aggregate-budget bookkeeping. `totalBytes` mirrors the sum of `bytesByStream` plus the
    /// display sets still in assembly (audit SUB-111), kept incrementally so the per-append check is
    /// O(1). `protectedStreams` are the active drain
    /// targets, never evicted by aggregate pressure. `lastTouchByStream` orders non-protected
    /// streams coldest-first for eviction; a monotonic counter (no wall clock) drives it.
    private var totalBytes: Int = 0
    /// #362: monotonic harvest order, stamped on every appended entry. See `StoredSubtitlePacket`.
    private var appendCounter: UInt64 = 0
    /// #416: which spans of the source the readers have actually read. Lives here because this is
    /// the object whose EMPTINESS gets interpreted: every "no packet between here and there" answer
    /// this store gives is only as good as the reading behind it. See `SubtitleHarvestCoverage`.
    private var coverage = SubtitleHarvestCoverage()
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

    // MARK: - #416: harvest coverage

    /// #416: a reader has positioned at `seconds` and reads forwards from there. Announced by every
    /// reposition of every reader that writes here, because an unannounced one would let the run
    /// below be extended across ground nobody read.
    func noteHarvestAnchor(_ writer: Writer, at seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        coverage.noteAnchor(writer, at: seconds)
    }

    /// #416: that reader's current run has read one step further, through `seconds`.
    func noteHarvestProgress(_ writer: Writer, through seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        coverage.noteProgress(writer, through: seconds)
    }

    /// #416: that reader's current run has REACHED `seconds` from its anchor, however far that is
    /// in one note. For a claim resting on an invariant rather than on observed steps; see
    /// `SubtitleHarvestCoverage.noteReach`.
    func noteHarvestReach(_ writer: Writer, through seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        coverage.noteReach(writer, through: seconds)
    }

    /// #416: was the whole span between `from` and `through` read by some run this session?
    ///
    /// True when nothing has ever been noted. A path whose readers do not report coverage must keep
    /// behaving exactly as it did before this existed: the caller's alternative to a proof is a
    /// refusal, and refusing on ignorance would dark landings that are perfectly sound.
    func hasReadSpan(from: Double, through: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return coverage.isEmpty || coverage.covers(from: from, through: through)
    }

    /// #941: `hasReadSpan` as a snapshot, for a drain tick that asks once per stored pair and
    /// should not take the lock for each. Same answer on a silent ledger: everything reads as read.
    func harvestReadCheck() -> @Sendable (Double, Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !coverage.isEmpty else { return { _, _ in true } }
        let spans = coverage.sortedSpans()
        return { SubtitleHarvestCoverage.covers(spans, from: $0, through: $1) }
    }

    /// Introspection for tests and diagnostics.
    var harvestCoverageSpans: [SubtitleHarvestCoverage.Span] {
        lock.lock(); defer { lock.unlock() }
        return coverage.sortedSpans()
    }

    func append(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                flags: Int32 = 0, payload: Data, webvttSettings: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(streamIndex: streamIndex, ptsSeconds: ptsSeconds,
                     durationSeconds: durationSeconds, flags: flags, payload: payload,
                     webvttSettings: webvttSettings)
    }

    private func appendLocked(streamIndex: Int32, ptsSeconds: Double, durationSeconds: Double,
                              flags: Int32, payload: Data, webvttSettings: String? = nil) {
        let before = bytesByStream[streamIndex] ?? 0
        // Audit SUB-103: taken out of the dictionary before it is mutated. Left in, the dictionary
        // holds the second reference and the insert below copied every retained packet per append,
        // 10k appends took 0.65 s and 40k took 10.9 s.
        var entries = entriesByStream.removeValue(forKey: streamIndex) ?? []
        var bytes = before
        // #362: a re-harvest of a packet already stored takes the FRESH sequence. It is a new
        // observation of that position by the run doing the writing, and that is exactly what the
        // drain reads it for: the run has now covered this PTS, so the span behind it is no longer
        // a hole. Keeping the old sequence would leave a boundary the drain waits at forever.
        appendCounter &+= 1
        let entry = StoredSubtitlePacket(ptsSeconds: ptsSeconds,
                                         durationSeconds: durationSeconds,
                                         flags: flags,
                                         payload: payload,
                                         webvttSettings: webvttSettings,
                                         sequence: appendCounter)
        // #235: several packets legitimately share a PTS. ASS/SSA authors overlapping lines on
        // identical Start/End, and a karaoke or layered-style track puts a whole burst of distinct
        // Dialogue events on one timestamp. Only a byte-identical payload is the pump and the
        // prefetcher re-harvesting the same packet (#151), and only that collapses. Anything else
        // joins the end of the run, so a shared timestamp reaches the drainer in harvest order:
        // the drainer decodes a window in array order and later events layer over earlier ones.
        let run = Self.lowerBound(entries, ptsSeconds)..<Self.upperBound(entries, ptsSeconds)
        if let duplicateIndex = duplicateIndexLocked(in: entries, run: run, payload: payload,
                                                     streamIndex: streamIndex, ptsSeconds: ptsSeconds) {
            bytes -= entries[duplicateIndex].payload.count
            entries[duplicateIndex] = entry
        } else {
            entries.insert(entry, at: run.upperBound)
        }
        bytes += payload.count
        if bytes > perStreamCap {
            // Audit SUB-103: evict to a low-water mark in one move. Dropping just enough made every
            // append at the cap shift the whole array for one packet.
            let lowWater = perStreamCap - perStreamCap / 10
            var dropped = 0
            while bytes > lowWater, dropped < entries.count - 1 {
                bytes -= entries[dropped].payload.count
                dropped += 1
            }
            entries.removeFirst(dropped)
            payloadHashesByRun[streamIndex] = nil
        }
        entriesByStream[streamIndex] = entries
        bytesByStream[streamIndex] = bytes
        totalBytes += bytes - before
        touchCounter &+= 1
        lastTouchByStream[streamIndex] = touchCounter
        enforceAggregateCapLocked(justTouched: streamIndex)
    }

    /// Index within `run` of the packet `payload` duplicates, nil when it is new. A long run is
    /// screened through `payloadHashesByRun` first; see there.
    private func duplicateIndexLocked(in entries: [StoredSubtitlePacket], run: Range<Int>, payload: Data,
                                      streamIndex: Int32, ptsSeconds: Double) -> Int? {
        guard !run.isEmpty else { return nil }
        func scan() -> Int? {
            run.first { entries[$0].payload.count == payload.count && entries[$0].payload == payload }
        }
        guard run.count > Self.linearDedupeRun else { return scan() }
        let key = (ptsSeconds + 0.0).bitPattern
        var runs = payloadHashesByRun.removeValue(forKey: streamIndex) ?? [:]
        var hashes = runs.removeValue(forKey: key) ?? Set(run.map { entries[$0].payload.hashValue })
        let seenBefore = !hashes.insert(payload.hashValue).inserted
        if runs.count >= Self.maxCachedRunsPerStream { runs.removeAll() }
        runs[key] = hashes
        payloadHashesByRun[streamIndex] = runs
        return seenBefore ? scan() : nil
    }

    /// First index at or past `ptsSeconds` in a PTS-sorted run. Harvest is near-monotonic, but the
    /// forward prefetcher (#151) backfills far behind the frontier, so the position is searched
    /// rather than assumed. Searched in log time rather than scanned from the front: the scan made
    /// one append O(n) and a session's harvest O(n^2) in retained packets, which #235 turned from
    /// academic into load-bearing, since a dense ASS track now keeps every event on a shared
    /// timestamp instead of collapsing the burst to one entry.
    static func lowerBound(_ entries: [StoredSubtitlePacket], _ ptsSeconds: Double) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].ptsSeconds < ptsSeconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// First index whose PTS is greater than `ptsSeconds`; `lowerBound` and this bracket a same-PTS run.
    static func upperBound(_ entries: [StoredSubtitlePacket], _ ptsSeconds: Double) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].ptsSeconds <= ptsSeconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// #166: bound retained bytes across ALL streams. Evict oldest entries from the coldest
    /// (least-recently-touched) NON-protected stream first, then the next coldest, until the total
    /// is back under `aggregateCap` or only protected streams remain. Protected streams (the active
    /// drain targets) and the stream just written keep their per-stream window; a fully drained
    /// cold stream is dropped and re-harvested from the pump/prefetcher if it is selected later.
    private func enforceAggregateCapLocked(justTouched: Int32) {
        guard totalBytes > aggregateCap else { return }
        // Audit SUB-103: down to a low-water mark, so the pass does not rerun on the next append, and
        // each victim loses its leading packets in one `removeFirst(k)`.
        let lowWater = aggregateCap - aggregateCap / 10
        var streams = Set(bytesByStream.keys)
        for key in pendingSetByStream.keys { streams.insert(key.streamIndex) }
        let candidates = streams
            .filter { !protectedStreams.contains($0) && $0 != justTouched }
            .sorted { (lastTouchByStream[$0] ?? 0) < (lastTouchByStream[$1] ?? 0) }
        for idx in candidates {
            guard totalBytes > lowWater else { break }
            // Audit SUB-111: an unfinished display set of a cold stream goes before anything complete.
            for writer in [Writer.pump, Writer.prefetch] {
                _ = takePendingLocked(PendingKey(streamIndex: idx, writer: writer))
            }
            guard totalBytes > lowWater, var entries = entriesByStream.removeValue(forKey: idx) else {
                if entriesByStream[idx] == nil { lastTouchByStream[idx] = nil }
                continue
            }
            var bytes = bytesByStream[idx] ?? 0
            var dropped = 0
            while totalBytes > lowWater, dropped < entries.count {
                let removed = entries[dropped].payload.count
                bytes -= removed
                totalBytes -= removed
                dropped += 1
            }
            entries.removeFirst(dropped)
            payloadHashesByRun[idx] = nil
            if entries.isEmpty {
                bytesByStream[idx] = nil
                lastTouchByStream[idx] = nil
            } else {
                entriesByStream[idx] = entries
                bytesByStream[idx] = bytes
            }
        }
    }

    /// A display set in assembly leaves the dictionary while it is worked on, so appending to it is in
    /// place, and its bytes leave the aggregate count with it. `putPendingLocked` is the way back.
    private func takePendingLocked(_ key: PendingKey) -> PendingDisplaySet? {
        guard let pending = pendingSetByStream.removeValue(forKey: key) else { return nil }
        totalBytes -= pending.payload.count
        return pending
    }

    private func putPendingLocked(_ pending: PendingDisplaySet, _ key: PendingKey) {
        pendingSetByStream[key] = pending
        totalBytes += pending.payload.count
        touchCounter &+= 1
        lastTouchByStream[key.streamIndex] = touchCounter
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
                     writer: writer,
                     webvttSettings: WebVTTCueSettings.settings(onPacket: packet))
    }

    /// Testable core of `harvest`. ptsSeconds nil = packet carried no PTS (AV_NOPTS_VALUE):
    /// dropped on the per-packet path, folded into the pending set on the assembly path.
    func harvestChunk(streamIndex: Int32, ptsSeconds: Double?, durationSeconds: Double,
                      flags: Int32, payload: Data, assembleSplitDisplaySets: Bool,
                      writer: Writer = .pump, webvttSettings: String? = nil) {
        // Audit FEA-101: the pump, the software-host tap and the prefetcher all store through here,
        // and the drain scales these seconds back into Int64 milliseconds. Same rule as the
        // demuxer's bound: an implausible time is unset, an implausible duration is 0.
        let bound = SourceTimestampBounds.maxPlausibleSeconds
        let ptsSeconds = ptsSeconds.flatMap { $0.isFinite && abs($0) < bound ? $0 : nil }
        let durationSeconds = durationSeconds.isFinite && durationSeconds < bound ? Swift.max(0, durationSeconds) : 0
        lock.lock(); defer { lock.unlock() }
        // #416: a harvested packet is a position its writer demonstrably read, so the run reaches
        // it. This is what gives the pump the forward lookahead its playhead-based note cannot
        // state, which is the region a backward seek into already-produced content lands in.
        if let ptsSeconds { coverage.noteReach(writer, through: ptsSeconds) }
        guard assembleSplitDisplaySets else {
            guard let ptsSeconds else { return }
            appendLocked(streamIndex: streamIndex, ptsSeconds: ptsSeconds,
                         durationSeconds: durationSeconds, flags: flags, payload: payload,
                         webvttSettings: webvttSettings)
            return
        }
        // The assembly path below is PGS display sets; those carry no WebVTT settings.
        // Mirror the decoder's SUP-wrapper rule: strip a leading "PG" 10-byte header so
        // concatenated chunks form one clean [type][len BE][body] segment run.
        var chunk = payload
        if chunk.count > 10, chunk[chunk.startIndex] == 0x50, chunk[chunk.startIndex + 1] == 0x47 {
            chunk = chunk.dropFirst(10)
        }
        let key = PendingKey(streamIndex: streamIndex, writer: writer)
        while !chunk.isEmpty {
            var pending = takePendingLocked(key)
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
                    return   // No anchor for this set; skip its chunks until the next PCS.
                }
                pending = PendingDisplaySet(ptsSeconds: pts, durationSeconds: durationSeconds,
                                            flags: flags, payload: Data())
            }
            guard var open = pending else {
                // Mid-set start (backfill landed between PCS and END): not decodable, drop.
                return
            }
            pending = nil
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
                return
            }
            if endBoundary != nil {
                appendLocked(streamIndex: streamIndex, ptsSeconds: open.ptsSeconds,
                             durationSeconds: open.durationSeconds, flags: open.flags,
                             payload: open.payload)
            } else {
                putPendingLocked(open, key)
                enforceAggregateCapLocked(justTouched: streamIndex)
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
        // The run is PTS-sorted, so the window is found by search instead of a scan of the session.
        return Array(entries[Self.lowerBound(entries, from)...].prefix { $0.ptsSeconds <= through })
    }

    /// #362: PTS of the first stored packet on `streamIndex` strictly after `ptsSeconds`.
    ///
    /// A PGS display set has no end of its own and is closed by whatever packet follows it on the
    /// stream, its own clear or the next composition alike. So this IS the authored end of a set,
    /// available from the harvest long before the drain window's forward edge reaches it. Strictly
    /// after, because one display set can reach the store as several same-PTS chunks (raw SUP, split
    /// MPEG-TS PES) and closing a set at its own start would render nowhere.
    func firstPTS(streamIndex: Int32, after ptsSeconds: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let entries = entriesByStream[streamIndex] else { return nil }
        let index = Self.upperBound(entries, ptsSeconds)
        guard index < entries.count else { return nil }
        // Deliberately answered even across a harvest hole, where the next stored packet belongs to
        // an older run and the real successor is still on its way. The answer is then too late, but
        // it is BOUNDED and self-correcting: the clear that lands when the hole fills trims the cue
        // to its authored end. Refusing to answer leaves the cue carrying the open placeholder, and
        // the next seek launders that into #357's window boundary, which nothing ever corrects.
        // Measured both ways on the fixture: answering, 0 to 2 sets ended late; refusing, 4 to 5,
        // the worst by 74 s. Measured again in round 2 against a boundary 15 s behind a landing:
        // still worse than the island, and by more (+46 s against +37 s on the same cue).
        //
        // Round 2: the CALLER bounds how far this may reach, and it has to, because nothing here
        // can. Whether the ground between the set and this packet was ever read is not a property
        // of the packets that arrived: a reader restarted BEHIND leaves a descending sequence at the
        // boundary, and a reader re-anchored FORWARD leaves an ascending one (measured on the
        // fixture: sequence 19, then 20, with 46 s of unread source between them). Only the drain
        // knows how far the harvest is designed to have reached by now, so the horizon lives there.
        return entries[index].ptsSeconds
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
                payloadHashesByRun[idx] = nil
            }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entriesByStream.removeAll()
        bytesByStream.removeAll()
        pendingSetByStream.removeAll()
        payloadHashesByRun.removeAll()
        lastTouchByStream.removeAll()
        protectedStreams.removeAll()
        totalBytes = 0
        touchCounter = 0
        appendCounter = 0
        coverage = SubtitleHarvestCoverage()
    }
}
