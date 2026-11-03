import Foundation
import AetherLibavcodec
import AetherLibavutil

/// #151: subtitle-only forward side reader. The producer pump harvests subtitle packets only as
/// far as its own forward park (#102), so the drainer's 60 s lead window (`subtitleDrainLeadSeconds`)
/// is empty beyond a few seconds on direct-play sources and a host-applied ADVANCE sync offset
/// finds no cues, text and bitmap alike. This reader fills the same session SubtitlePacketStore
/// up to playhead + lead independently of the producer: it reads every embedded subtitle stream
/// (all other streams discarded, #104), parks on the subtitle PTS axis, and resumes as the
/// playhead advances. A packet the pump already harvested collapses onto its entry in the store on
/// a byte-identical payload (#235: not on the PTS, which distinct cues share); split-PES PGS sets
/// assemble under the `.prefetch` writer key so the pump's in-flight set is never corrupted.
///
/// This is the loop half only; positioning (bounded seek + byte-estimate fallback), lifecycle,
/// and seek re-anchoring live on the engine (`AetherEngine.startSubtitleForwardPrefetcher`),
/// mirroring the native subtitle readers (memory rule: all side readers share positioning fixes).
enum SubtitleForwardPrefetcher {

    /// How far behind the anchor a side reader starts reading, so the cue covering the anchor is
    /// not already behind the read head when the first packet arrives (#112 round 10).
    static let anchorBackscanSeconds: Double = 2.0

    /// #416: step between two coverage notes, in seconds of source. Small against every authored
    /// dwell (so a hole of subtitle size is always visible as one), large against a packet (so a
    /// dense track does not take the store's lock per packet for it).
    static let coverageNoteStepSeconds: Double = 0.5

    /// Where a positioning attempt landed. The byte estimate is a fallback, not a failure: the
    /// reader keeps working from wherever it put the cursor, it just cannot trust timestamps.
    enum Positioning: Equatable {
        case seek
        case byteEstimate
        case failed
    }

    /// Position a side-reader demuxer at `seconds`, the one place the rules live (memory rule: all
    /// side readers share every positioning fix). Bounded timestamp seek on the routed subtitle axis
    /// (#234), byte-estimate fallback with the same budget when the container cannot seek by time.
    static func reposition(
        demuxer: Demuxer,
        to seconds: Double,
        anchorStreamIndex: Int32,
        fallbackDuration: Double,
        timeout: TimeInterval
    ) -> Positioning {
        let seekTo = max(0, seconds - anchorBackscanSeconds)
        if demuxer.seekBounded(to: seekTo, anchorStreamIndex: anchorStreamIndex, timeout: timeout) {
            return .seek
        }
        demuxer.markTimestampSeekUnreliable()
        let duration = demuxer.duration > 0 ? demuxer.duration : fallbackDuration
        return demuxer.seekByteEstimate(to: seekTo, knownDuration: duration, timeout: timeout)
            ? .byteEstimate : .failed
    }

    /// #240: an anchor change handed to a RUNNING prefetch session, in place of tearing it down.
    ///
    /// A playhead jump used to rebuild the whole session: a fresh demuxer open, the Matroska
    /// cue-index prewarm (a seek to mid-file whose only purpose is to make libavformat parse the
    /// index that lives at EOF) and the positioning seek. Since the bounded ranges of #220 every one
    /// of those seeks opens a fresh 32 MiB range and the origin delivers all of it, so a rebuild
    /// costs tens of megabytes of link before a single cue is harvested, once per jump, on exactly
    /// the constrained link where a seek is already struggling. The running session already holds an
    /// open demuxer with a parsed index; moving its cursor is one seek.
    ///
    /// The anchor stream and the seek budget are captured from the session that created the box, so
    /// an in-place move cannot drift from the session-start rules (#234: a -1 seek elects the pacing
    /// stream by score and lands on a video keyframe in a different Matroska cluster).
    final class SideReaderReanchor: @unchecked Sendable {
        /// A pending move plus the seek generation that asked for it (#250). The generation rides
        /// along because the session survives the seek: a fence captured at session start goes
        /// stale on the first in-place move, and it goes stale in exactly the superseded-seek case
        /// the fence exists to resolve.
        struct Anchor: Equatable, Sendable {
            var seconds: Double
            var seekGeneration: UInt64
        }

        let anchorStreamIndex: Int32
        let fallbackDuration: Double
        let seekTimeout: TimeInterval
        private let lock = NSLock()
        private var pending: Anchor?

        init(anchorStreamIndex: Int32, fallbackDuration: Double, seekTimeout: TimeInterval) {
            self.anchorStreamIndex = anchorStreamIndex
            self.fallbackDuration = fallbackDuration
            self.seekTimeout = seekTimeout
        }

        /// Latest request wins: a seek burst leaves one move, not one per seek.
        func request(_ seconds: Double, seekGeneration: UInt64 = 0) {
            lock.lock()
            pending = Anchor(seconds: seconds, seekGeneration: seekGeneration)
            lock.unlock()
        }

        func take() -> Anchor? {
            lock.lock()
            defer { pending = nil; lock.unlock() }
            return pending
        }

        /// #496: is a move waiting, without consuming it. Both of the loop's waits ask, because the
        /// point where the move is TAKEN sits after them: a wait that outlasts the request leaves
        /// the reader banking packets for the stretch the viewer has left.
        var hasPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return pending != nil
        }

        func clear() {
            lock.lock()
            pending = nil
            lock.unlock()
        }
    }

    /// Why a prefetch session ended (#231).
    ///
    /// The loop used to leave on the first failed read with no way to tell why, and its exit line
    /// reported `cancelled=false` for every one of those reasons. Only `.readFailed` is worth
    /// restarting: EOF is the expected end of a session, cancellation is deliberate, and a source
    /// that will not open is the documented best-effort case.
    enum Exit: Equatable {
        case endOfFile
        case cancelled
        case openFailed
        case readFailed

        var isRestartable: Bool { self == .readFailed }
    }

    struct Outcome {
        let exit: Exit
        let harvested: Int
    }

    /// #231: how many times a failing prefetch session may be restarted, and how long to wait first.
    ///
    /// Two ceilings, because two things look different on the wire. A run of failures with nothing
    /// harvested between them is a dead link, and giving up quickly is right. A session that
    /// produced cues and only then broke is a fresh transport failure, so its budget resets; the
    /// total ceiling is what stops a source that fails in a loop after one packet each time from
    /// reconnecting forever.
    struct RestartBudget {
        let maxConsecutiveFailures: Int
        let maxRestarts: Int
        let backoffNanoseconds: UInt64
        private(set) var consecutiveFailures = 0
        private(set) var restarts = 0

        init(maxConsecutiveFailures: Int, maxRestarts: Int, backoffNanoseconds: UInt64) {
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.maxRestarts = maxRestarts
            self.backoffNanoseconds = backoffNanoseconds
        }

        /// Charge one failed session to the budget. Returns how long to wait before the next
        /// attempt, or nil when the budget is spent and the prefetcher should stay down.
        mutating func chargeFailure(harvested: Int) -> UInt64? {
            consecutiveFailures = harvested > 0 ? 1 : consecutiveFailures + 1
            restarts += 1
            guard consecutiveFailures <= maxConsecutiveFailures, restarts <= maxRestarts else {
                return nil
            }
            return backoffNanoseconds << min(consecutiveFailures - 1, 3)
        }
    }

    /// Resolve a stream's packet time base, memoizing only usable results (#220).
    ///
    /// The lookup used to memoize its own failure: a nil `stream(at:)` fell back to `0/1`, that
    /// value went into the cache, and the park guard (`tb.num > 0`) then skipped every further
    /// packet on the stream, so the reader ran the rest of the session with no forward park at
    /// all. It also fed `0/1` to the store, where `pts * (num/den)` is zero and every harvested
    /// cue lands at second 0. Caching only valid values makes a failed lookup cost one packet
    /// and retry on the next.
    static func resolveTimeBase(
        streamIndex: Int32,
        cache: inout [Int32: AVRational],
        lookup: (Int32) -> AVRational?
    ) -> AVRational? {
        if let cached = cache[streamIndex] { return cached }
        guard let resolved = lookup(streamIndex), resolved.num > 0, resolved.den > 0 else {
            return nil
        }
        cache[streamIndex] = resolved
        return resolved
    }

    /// Where a packet sits on the source timeline for park purposes, or nil when it carries no
    /// usable timestamp (#230).
    ///
    /// A harvested subtitle packet is placed by PTS, its own cue time. A pacing packet is placed by
    /// DTS, the monotone read position: with B-frames a video PTS runs ahead of the bytes actually
    /// read, and it is the bytes the park exists to bound.
    static func packetSeconds(
        pts: Int64, dts: Int64, timeBase: AVRational, preferDecodeOrder: Bool
    ) -> Double? {
        let raw = preferDecodeOrder
            ? (dts != Int64.min ? dts : pts)
            : (pts != Int64.min ? pts : dts)
        guard raw != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return nil }
        return Double(raw) * Double(timeBase.num) / Double(timeBase.den)
    }

    /// Read/harvest until EOF, error, cancellation, or a nil playhead (engine gone). Returns why it
    /// stopped and how many routed subtitle packets it harvested (#231: a read error is not an EOF
    /// and the caller has to be able to tell them apart). The demuxer must be positioned by the
    /// caller.
    /// Harvest-then-park: the packet whose PTS crosses `playhead + leadSeconds` is stored before
    /// the loop parks, so the store may hold one packet past the lead edge (harmless; the drainer
    /// window decides what decodes). The playhead is snapshot at start and refreshed only inside
    /// the park loop, matching the native readers: no MainActor hop per packet during a backfill
    /// burst.
    ///
    /// #230: `pacingIndex` (-1 when the source has no usable one) names a non-subtitle stream the
    /// caller left at `AVDISCARD_NONKEY`. Its packets are freed unharvested and exist only to park
    /// the loop on the read position. Without one the park is edge-triggered on subtitle packets
    /// alone, so a stretch of the file with no cues is read at full speed however far past the lead
    /// edge it runs: bounded on a dense PGS track, unbounded on a sparse or forced one.
    static func run(
        demuxer: Demuxer,
        store: SubtitlePacketStore,
        streamIndices: Set<Int32>,
        assemblyIndices: Set<Int32>,
        pacingIndex: Int32,
        leadSeconds: Double,
        parkPollNanoseconds: UInt64,
        link: SideReaderLinkArbiter? = nil,
        reanchor: SideReaderReanchor? = nil,
        fence: SubtitleResolutionStatement.Fence = .init(),
        playhead: @Sendable () async -> Double?
    ) async -> Outcome {
        guard var playheadSnapshot = await playhead() else {
            return Outcome(exit: .cancelled, harvested: 0)
        }
        var harvested = 0
        var timeBaseCache: [Int32: AVRational] = [:]
        var timeBaseFailures = 0
        var exit = Exit.cancelled
        /// #416: the last read position reported to the store's coverage ledger. Reported in steps
        /// rather than per packet: the ledger only has to be able to tell a hole of authored size
        /// from continuous reading, and a step keeps this off the store's lock on a dense track.
        var lastCoverageNoted = -Double.infinity
        /// #240: the valve's grant window. Set when a yield hit the cap, checked before the next
        /// arbitration so the reader keeps the link for a while rather than for one packet.
        var valveGrantedUntil: DispatchTime? = nil
        /// #240: the head start after anchoring, re-armed by every in-place re-anchor. Bounded by
        /// wall time on purpose, see `SideReaderLinkPolicy.anchorGraceSeconds`.
        var anchorGraceUntil = DispatchTime.now()
            + (link?.anchorGraceSeconds ?? SideReaderLinkPolicy.anchorGraceSeconds)
        let telemetryGeneration = SubtitlePrefetchTelemetry.sessionStarted(fence: fence)
        // #220: the exit reason reaches the gauge, not just the fact that the loop stopped.
        // `defer` reads `exit` at unwind, so every break path reports the reason it set.
        defer { SubtitlePrefetchTelemetry.sessionEnded(generation: telemetryGeneration, exit: exit) }
        readLoop: while !Task.isCancelled {
            // #240: leave the link to the video path while it needs it. Asked before the read
            // because `readPacket` is what pulls bytes, and on Matroska it pulls the video and audio
            // bytes too. The lead is measured from the last read position, which is what the reader
            // has actually banked; a session that has read nothing yet counts as lead 0 and is let
            // through by the floor rule, so positioning is never blocked behind a busy pump forever.
            if let link, valveGrantedUntil.map({ DispatchTime.now() > $0 }) ?? true {
                var yielded: Double = 0
                while !Task.isCancelled,
                      link.shouldYield(
                        // #496: a pending move counts as freshly anchored. The grace exists so a
                        // reader positioned somewhere new fills against a busy video path, and a
                        // reader the viewer has just moved is in exactly that state; without this
                        // the request waits behind up to a full yield cap while the region in front
                        // of the playhead is harvested by nobody. A seek in flight still wins, that
                        // rule sits above the grace.
                        inAnchorGrace: DispatchTime.now() < anchorGraceUntil
                            || reanchor?.hasPending == true,
                        yieldedSeconds: yielded) {
                    if yielded == 0 { SubtitlePrefetchTelemetry.recordLinkYield(true) }
                    // The playhead moves while we wait, so the lead shrinks: a reader parked behind
                    // a busy pump returns to fetching on its own once it falls under the floor.
                    guard let fresh = await playhead() else { break readLoop }
                    playheadSnapshot = fresh
                    do { try await Task.sleep(nanoseconds: link.pollNanoseconds) } catch { break readLoop }
                    yielded += link.pollSeconds
                }
                if yielded > 0 { SubtitlePrefetchTelemetry.recordLinkYield(false, seconds: yielded) }
                if yielded >= link.maxYieldSeconds {
                    valveGrantedUntil = DispatchTime.now() + link.valveGrantSeconds
                    SubtitlePrefetchTelemetry.recordLinkValveGrant()
                    EngineLog.emit(
                        "[AetherEngine] #151 forward prefetch yielded the link for "
                        + "\(Int(yielded))s; taking \(Int(link.valveGrantSeconds))s of it back "
                        + "(the video path is not releasing it)",
                        category: .engine)
                }
            }

            // #240: re-anchor in place instead of tearing the session down and building a new one.
            // A rebuild pays a fresh open, the Matroska cue-index prewarm and the positioning seek,
            // and since the bounded ranges of #220 every one of those seeks costs a full 32 MiB
            // range off the link. A seek burst rebuilt the session once per jump.
            if let reanchor, let target = reanchor.take() {
                let landed = reposition(demuxer: demuxer, to: target.seconds,
                                        anchorStreamIndex: reanchor.anchorStreamIndex,
                                        fallbackDuration: reanchor.fallbackDuration,
                                        timeout: reanchor.seekTimeout)
                EngineLog.emit(
                    "[AetherEngine] #151 forward prefetch re-anchored in place at "
                    + "\(String(format: "%.2f", target.seconds))s (\(landed))",
                    category: .engine)
                // #250: the banked position is now this seek's, and the pre-seek one is void.
                // Stamped here rather than at request time so the window between the two reads
                // as unresolved instead of validating a position the seek has not reached yet.
                SubtitlePrefetchTelemetry.recordReanchor(seekGeneration: target.seekGeneration)
                // #416: the run that was reading up to here is over, and everything between where
                // it got to and this anchor is ground nobody read. Stated as the anchor the reader
                // ASKED for, not where the seek landed: a subtitle-axis seek lands at or before the
                // request, so this under-claims by up to one authored gap and never over-claims.
                store.noteHarvestAnchor(.prefetch, at: target.seconds)
                lastCoverageNoted = -Double.infinity
                anchorGraceUntil = DispatchTime.now()
                    + (link?.anchorGraceSeconds ?? SideReaderLinkPolicy.anchorGraceSeconds)
                if let fresh = await playhead() { playheadSnapshot = fresh }
            }

            let next: UnsafeMutablePointer<AVPacket>?
            do {
                next = try demuxer.readPacket()
            } catch {
                // #231: a transport failure on the side reader, a stall that exhausts the read
                // deadline, a reconnect that gives up. Distinct from EOF, and restartable.
                EngineLog.emit(
                    "[AetherEngine] #151 forward prefetch read failed after \(harvested) packets: "
                    + "\(error)",
                    category: .engine)
                exit = .readFailed
                break
            }
            guard let pkt = next else {
                // AE#955: the run read everything there is. Without this the ledger ends at the
                // last progress step, short of the duration, so a span that runs to the end of the
                // program never read as read and the OCR pre-fill in the last
                // `subtitleOCRLeadSeconds` of a film waited forever.
                store.noteHarvestReach(.prefetch, through: .greatestFiniteMagnitude)
                exit = .endOfFile
                break
            }
            let streamIdx = pkt.pointee.stream_index
            let isTarget = streamIndices.contains(streamIdx)
            guard isTarget || streamIdx == pacingIndex else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                continue
            }
            // #220: an unusable time base drops the packet rather than harvesting it against a
            // zero rate (every cue would land at second 0) and rather than parking against a
            // meaningless PTS. It is not cached, so the next packet retries the lookup.
            guard let tb = resolveTimeBase(streamIndex: streamIdx, cache: &timeBaseCache,
                                           lookup: { demuxer.stream(at: $0)?.pointee.time_base })
            else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                timeBaseFailures += 1
                SubtitlePrefetchTelemetry.recordTimeBaseFallback()
                if timeBaseFailures == 1 {
                    EngineLog.emit(
                        "[AetherEngine] #151 forward prefetch: no usable time base for stream "
                        + "\(streamIdx); packet dropped (logged once)",
                        category: .engine)
                }
                continue
            }
            if isTarget {
                store.harvest(streamIndex: streamIdx, packet: pkt, timeBase: tb,
                              assembleSplitDisplaySets: assemblyIndices.contains(streamIdx),
                              writer: .prefetch)
                harvested += 1
            }
            let position = packetSeconds(pts: pkt.pointee.pts, dts: pkt.pointee.dts,
                                         timeBase: tb, preferDecodeOrder: !isTarget)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            // Park once the read passes the lead edge; a packet without a usable timestamp
            // (split-set continuation chunks) never parks, its set's PCS anchor already did the
            // pacing.
            guard let position else { continue }
            // #220 gauge: `position` is the read position on the source axis for both packet
            // kinds, a cue PTS for a harvested one and the monotone read DTS for a pacing one,
            // which is the same quantity the park decides on. Since #230 that means
            // `prefetchLead` tracks the reader rather than the last cue, so on a sparse track it
            // now moves between cues instead of standing still.
            SubtitlePrefetchTelemetry.recordPacket(seconds: position, harvested: harvested)
            // #416: this reader has now read to here. The pacing packets are what make the claim
            // continuous over an authored silence, which is the stretch the ledger exists for.
            if position >= lastCoverageNoted + coverageNoteStepSeconds {
                store.noteHarvestProgress(.prefetch, through: position)
                lastCoverageNoted = position
            }
            var didPark = false
            while !Task.isCancelled, position > playheadSnapshot + leadSeconds {
                // #496: a backward seek leaves the read position far past the new playhead, so this
                // condition stays true for as long as the viewer stays behind it, and the loop never
                // reaches the point where the move is taken. The pending move is what voids the
                // position this park is judging.
                if reanchor?.hasPending == true { break }
                if !didPark {
                    didPark = true
                    SubtitlePrefetchTelemetry.recordPark(true)
                }
                guard let fresh = await playhead() else { break readLoop }
                playheadSnapshot = fresh
                if position <= playheadSnapshot + leadSeconds { break }
                do { try await Task.sleep(nanoseconds: parkPollNanoseconds) } catch { break readLoop }
            }
            if didPark { SubtitlePrefetchTelemetry.recordPark(false) }
        }
        return Outcome(exit: exit, harvested: harvested)
    }
}
