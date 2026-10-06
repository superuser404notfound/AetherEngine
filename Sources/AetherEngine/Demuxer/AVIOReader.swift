import Foundation
import os
import AetherLibavformat
import AetherLibavutil

/// Custom AVIO context feeding FFmpeg via URLSession. Three modes:
/// - **Persistent** (known size + prefetch=true, playback path): single long-lived
///   `Range: bytes=<pos>-` GET into a sliding window; reconnects on drop/429/503/509.
///   Fix for AetherEngine#25 (CDN stutter collapsing playback). See `readPersistent`.
/// - **Seekable chunked** (known size + prefetch=false, still/frame-extraction):
///   discrete Range chunks for random access. See `readSeekable`.
/// - **Streaming** (size=-1): single sequential GET, no reconnect. See `readStreaming`.
///
/// AVIO callbacks run on the demux queue; prefetch/delivery on background queues.
/// Shared state protected by locks.

/// Dedupes `ReaderNetworkPhase` emissions so a flapping origin does not spam the callback (#85).
/// Held under the reader's `networkPhaseLock` together with the sink it deduplicates for (#433).
///
/// The first statement always goes out, `.flowing` included (#410). The gate is per reader INSTANCE while
/// the phase it feeds is per engine, so a reader installed by a reopen starts with no opinion rather than
/// with the assumption that it already reported delivery: assuming it is what let a fresh reader recover in
/// silence and strand the engine on the previous reader's last word.
struct NetworkPhaseGate {
    private var last: ReaderNetworkPhase?
    mutating func shouldEmit(_ next: ReaderNetworkPhase) -> Bool {
        guard next != last else { return false }
        last = next
        return true
    }

    /// A listener that just attached has heard nothing, whatever this reader said before it arrived (#433).
    /// The gate deduplicates emissions to a SINK, and the restart's reopen forms its opinion during
    /// `open()`, one wiring step before the sink exists: without this, the reader that now serves the
    /// session has nothing left to say and the axis keeps describing the reader that was aborted.
    mutating func forgetForNewListener() {
        last = nil
    }
}

final class AVIOReader: AVIOProvider, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    /// [MovieClaw P22] 本片源在字节缓存里的键（主机装载时登记过才有；只用于点播的持久连接播放路径）
    private let byteCacheKey: String?
    /// [MovieClaw P22] 这次打开接管的是字节缓存里的文件头（不是主机预热的）：打开阶段不发请求，
    /// 读到缓存没有的位置才按那个位置连源站
    private var warmFromByteCache = false
    /// #450: connections the BOUNDED pool may hold to one host. A throttle, and it is allowed to be
    /// one: every request on that pool ends (a 4 MB detour block, a size probe, the tail prefetch),
    /// so a request that waits here waits for one that is finishing.
    static let boundedConnectionsPerHost = 2

    /// #450: connections the LONG-LIVED pool may hold to one host. Deliberately above any plausible
    /// reader count rather than a limit, because the same number that throttles the bounded pool
    /// deadlocks this one. See `makeSessionConfig`.
    static let longLivedConnectionsPerHost = 64

    struct HopTiming {
        let host: String
        let port: Int
        let status: Int?
        let ttfbMs: Double
        let totalMs: Double
    }

    /// #377 follow-up: 32 MB at 100 Mbps takes about 3 seconds after a healthy first byte, while
    /// measured stalls waited 5.3 and 9.5 seconds before one; trigger on summed redirect-hop TTFB.
    static func slowFirstByteLine(taskSeconds: TimeInterval, hops: [HopTiming]) -> String? {
        let firstByteMs = hops.reduce(0) { $0 + $1.ttfbMs }
        guard firstByteMs > 1_000 else { return nil }
        let taskMs = Int((taskSeconds * 1_000).rounded())
        let summary = hops.map { hop in
            var fields = ["\(hop.host):\(hop.port)"]
            if let status = hop.status { fields.append("status=\(status)") }
            fields.append("ttfb=\(Int(hop.ttfbMs.rounded()))ms")
            fields.append("total=\(Int(hop.totalMs.rounded()))ms")
            return fields.joined(separator: " ")
        }.joined(separator: " -> ")
        return "[AVIOReader] slow first byte: task=\(taskMs)ms over \(hops.count) hops: \(summary)"
    }

    /// Signed redirect paths and queries carry tokens, so only host and port cross this adapter.
    static func hopTiming(_ transaction: URLSessionTaskTransactionMetrics) -> HopTiming? {
        guard let url = transaction.request.url,
              let host = url.host,
              let fetchStart = transaction.fetchStartDate,
              let responseStart = transaction.responseStartDate,
              let responseEnd = transaction.responseEndDate else { return nil }
        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else if url.scheme?.lowercased() == "https" {
            port = 443
        } else if url.scheme?.lowercased() == "http" {
            port = 80
        } else {
            return nil
        }
        return HopTiming(
            host: host,
            port: port,
            status: (transaction.response as? HTTPURLResponse)?.statusCode,
            ttfbMs: responseStart.timeIntervalSince(fetchStart) * 1_000,
            totalMs: responseEnd.timeIntervalSince(fetchStart) * 1_000
        )
    }

    /// Session config factory. Short-lived probes/chunks get a 60s resource timeout;
    /// long-lived persistent/streaming connections omit it (fires mid-stream, NSURLError
    /// -1001; stall detection is handled by `connStallTimeout`). `urlCache = nil` avoids
    /// the "N URLCaches racing async invalidation" leak (reverted in fef8ef4).
    ///
    /// #450: the two pools carry different requests, so they carry different cap policies.
    ///
    /// `persistentSession` is a `static let`, so its cap is not a per-reader allowance, it is the
    /// whole PROCESS's allowance to one origin, shared by every reader in it: the pump, the
    /// subtitle side reader, the forward prefetcher, and one more pump per playback surface. Its
    /// requests are open-ended by design, a live pump holding its connection for the whole session,
    /// so the request that arrives on top of the cap is not slowed, it is parked behind connections
    /// that are not going to end. URLSession parks it with no callback, no error and no metrics, so
    /// the wait is not even observable as a wait: `awaitFirstPersistentData` spends its full 15 s
    /// and the load reports a source that would not open, for a queue the engine built itself
    /// (measured, reporter of #450: four live tiles on one origin, tiles 3 and 4 zero bytes, while
    /// three concurrent `curl` pulls of the same endpoints flowed at full rate).
    ///
    /// What the engine asks of one origin is bounded by `OriginRequestBudget` (#377) instead. That
    /// one counts requests rather than connections, which is what an origin meters and the only
    /// thing that means anything over h2, it waits with a budget, it says that it waited, and it
    /// lowers itself when the origin answers 429/503/509. A second ceiling underneath it, silent
    /// and unyielding, made the documented contract of `LoadOptions.maxConcurrentSourceRequests ==
    /// nil` ("counts but does not cap") false from the third concurrent long-lived read on. A
    /// declared ceiling is a lie for as long as a lower one is silent.
    static func makeSessionConfig(longLived: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !longLived {
            config.timeoutIntervalForResource = 60
        }
        config.httpMaximumConnectionsPerHost =
            longLived ? longLivedConnectionsPerHost : boundedConnectionsPerHost
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance, kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// Typed source-fetch network phase, pushed on every stall/reconnect/recovery transition (#85).
    /// Mirrors `HLSVideoEngine.onSeekStateChanged`. `@Sendable`: invoked from the demux thread, the
    /// consumer hops to the main actor. Set only on the MAIN playback reader, never the subtitle side reader.
    ///
    /// #433: the sink and its dedupe history are one thing, under one leaf lock. The sink is installed from
    /// whichever thread runs the handover (a producer restart, a live reopen) while the demux thread is the
    /// one emitting, and attaching a listener CLEARS the history: a listener that just arrived has heard
    /// nothing, whatever this reader said into a nil sink during its own `open()`.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)? {
        get {
            networkPhaseLock.lock(); defer { networkPhaseLock.unlock() }
            return _onNetworkPhaseChanged
        }
        set {
            networkPhaseLock.lock()
            _onNetworkPhaseChanged = newValue
            networkPhaseGate.forgetForNewListener()
            networkPhaseLock.unlock()
        }
    }

    /// Whether the consumer intends to play, mirrored from the same source the segment producer
    /// reads (`HLSVideoEngine.playIntentProvider`). Nil is an intent nobody reported, and that is
    /// read as stopped rather than as playing: every path that plays wires this, so the reader
    /// left without it is one whose consumer the engine cannot vouch for, and the safe answer
    /// there is the bounded one. Choosing "playing" would let such a reader hold a dormant flow
    /// for as long as it lives, which is the #310 exposure this flag is supposed to bound.
    ///
    /// Behind a leaf lock like the phase sink below, and for the same reason: the demuxer forwards
    /// it whenever the engine assigns it, which may be after `open()`, while the held connection's
    /// pump thread reads it. Taken UNDER `winCond`, never the other way round.
    var playIntentProvider: (@Sendable () -> Bool)? {
        get {
            playIntentLock.lock()
            defer { playIntentLock.unlock() }
            return _playIntentProvider
        }
        set {
            playIntentLock.lock()
            _playIntentProvider = newValue
            playIntentLock.unlock()
        }
    }
    private let playIntentLock = NSLock()
    private var _playIntentProvider: (@Sendable () -> Bool)?

    /// Leaf lock over the sink and its gate: takes no other lock, and no other lock is held across it.
    private let networkPhaseLock = NSLock()
    private var _onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?
    private var networkPhaseGate = NetworkPhaseGate()

    /// Emit a phase transition through the gate. Called from the demux thread; the sink runs OUTSIDE the
    /// lock so a consumer hop can never serialize against the read loop.
    private func emitNetworkPhase(_ phase: ReaderNetworkPhase) {
        networkPhaseLock.lock()
        let sink = networkPhaseGate.shouldEmit(phase) ? _onNetworkPhaseChanged : nil
        networkPhaseLock.unlock()
        sink?(phase)
    }

    /// Cached CDN URL after redirect resolution; skips proxy hop on subsequent chunks.
    /// Auth-expiry statuses (401/403/404/410) against it invalidate and fall back to
    /// the source URL. See AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?
    /// The pin the ladder most recently dropped, kept only to describe what answers next (#377).
    /// A source that re-mints the SAME target the ladder just dropped has not handed out a fresh
    /// lease, and off the responding host alone that case is indistinguishable from a fresh target
    /// refusing, which is the reading that puts metering back on the table. Two different causes,
    /// two different fixes, one log line to tell them apart.
    private var _droppedResolvedURL: URL?

    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    /// #392: when bytes for this source last came off the NETWORK, across generations. Wall clock
    /// on purpose: a lease expires in wall time, and a device that slept through the gap has let it
    /// expire too, which `uptimeNanoseconds` would hide. `lastDeliveryAt` cannot answer this
    /// question at all, since `startPersistentConnection` rebases it to the connection start and it
    /// therefore always reads as fresh at the moment a refusal is being judged.
    ///
    /// Leaf lock: these two take no other lock, and nothing takes `winCond` while holding this one,
    /// so the delivery path can stamp it from inside its own winCond section.
    private let deliveryClockLock = NSLock()
    private var _lastNetworkDeliveryAt = Date()

    private func noteNetworkDelivery() {
        deliveryClockLock.lock()
        _lastNetworkDeliveryAt = Date()
        deliveryClockLock.unlock()
    }

    /// Negative gaps (a wall clock stepped backwards) read as zero, i.e. as "not idle", which
    /// falls back to the keep-pin grace rather than dropping a pin on a clock adjustment.
    private func secondsSinceNetworkDelivery() -> TimeInterval {
        deliveryClockLock.lock()
        let last = _lastNetworkDeliveryAt
        deliveryClockLock.unlock()
        return max(0, Date().timeIntervalSince(last))
    }

    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    private func recordResolvedURL(_ resolved: URL?) {
        guard let resolved else { return }
        // #388: the pinned target is where every later request is keyed, so it has to share the
        // source's request budget. Idempotent, and stated here as well as at the redirect itself
        // because a pin is also how a resolve that no delegate of ours followed becomes visible.
        OriginRequestBudget.shared.noteRedirect(from: url, to: resolved)
        // #377 round 5: this runs off an ACCEPTED response, so the target is answering. Clearing it
        // from the dropped ledger is what keeps "dropped and minted again" meaning a target that is
        // still refusing, instead of a label a host wears for the rest of the process.
        OriginRequestBudget.shared.noteTargetHealthy(resolved)
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if resolved != url && resolved != _resolvedURL {
            _resolvedURL = resolved
            // Release-visible, and rare by construction: only a pin that actually CHANGES logs, so
            // a healthy session emits this once. Which target is pinned is half of every field
            // trace about a redirecting origin (#307, #377, #380), and behind `#if DEBUG` it was
            // readable only by the reporters who happened to build the engine themselves.
            EngineLog.emit("[AVIOReader] Cached resolved URL host=\(resolved.host ?? "?")", category: .demux)
        }
    }

    private func invalidateResolvedURL(reason: String = "expiry status") {
        resolvedURLLock.lock()
        var droppedNow: URL?
        if _resolvedURL != nil {
            droppedNow = _resolvedURL
            _droppedResolvedURL = _resolvedURL
            _resolvedURL = nil
            // The other half, and the one #380 turned into a decision: dropping the pin is now a
            // policy the ladder makes (the bounded keep-pin grace), not just a reaction to an
            // expiry status. A rung the field cannot see is a rung the next trace cannot confirm.
            EngineLog.emit("[AVIOReader] Dropped resolved URL cache (\(reason))", category: .demux)
        }
        resolvedURLLock.unlock()
        // Outside the reader's lock, and outside the reader's lifetime: the ledger belongs to the
        // origin because the next request against it may well come from a demuxer that does not
        // exist yet (#377 round 5).
        if let droppedNow { OriginRequestBudget.shared.noteTargetDropped(droppedNow, from: url) }
    }

    /// #377/#380: this attempt is going through the source because the ladder dropped a pin, i.e.
    /// it is the re-resolve the drop was for. On the REQUEST side, because a target that never
    /// answers at all leaves no response line to read it off, and a drop whose next attempt cannot
    /// be seen going anywhere is a rung the field has to take on trust. Rare by construction: it
    /// stops as soon as a 2xx pins again.
    private func reResolveNote() -> String {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        guard _resolvedURL == nil, _droppedResolvedURL != nil else { return "" }
        return " re-resolving through the source"
    }

    /// #377/#380: which target answered, in the terms the ladder decides in.
    ///
    /// A pin is only ever recorded from a 2xx, deliberately (pinning a target that just refused
    /// would key the whole session on it), so a re-resolve that lands on a refusing target is
    /// recorded nowhere. Read from outside, the absence of a `Cached resolved URL host=` line after
    /// a drop is then indistinguishable between three shapes that need three different fixes: the
    /// source refused the re-resolve itself, the source handed back the target just dropped, or a
    /// genuinely fresh target refused. Only the last one means the origin is metering us. This is
    /// the line that says which.
    private func respondingTargetDescription(_ responded: URL?) -> String {
        resolvedURLLock.lock()
        let pinned = _resolvedURL
        let dropped = _droppedResolvedURL
        resolvedURLLock.unlock()
        let droppedEarlier = OriginRequestBudget.shared.droppedTargets(for: url)
        return Self.describeRespondingTarget(
            responded: responded, source: url, pinned: pinned, dropped: dropped,
            droppedEarlier: droppedEarlier)
    }

    /// Compared on the ORIGIN KEY, never on the whole URL: a source that re-mints a link for the
    /// same edge host with a fresh signature has handed back the same target, and reading that as a
    /// fresh one is exactly the mistake that puts metering back on the table.
    ///
    /// `droppedEarlier` comes from the origin's books rather than from this instance (#377 round 5).
    /// A metered revive builds a fresh demuxer, so the reader asking here is routinely NOT the one
    /// that dropped the target seconds ago, and an instance-scoped ledger answered `resolved
    /// freshly` for exactly those attempts: one host, one refusal window, two verdicts depending on
    /// which reader happened to ask, and the rebuilds are both the majority of the asks and the ones
    /// with no history.
    static func describeRespondingTarget(
        responded: URL?, source: URL, pinned: URL?, dropped: URL?,
        droppedEarlier: Set<String> = []
    ) -> String {
        guard let responded, let host = responded.host,
              let key = OriginRequestBudget.originKey(for: responded) else { return "" }
        if key == OriginRequestBudget.originKey(for: source) {
            return " from the source itself (\(host)), not a redirect target"
        }
        if let pinned, key == OriginRequestBudget.originKey(for: pinned) {
            return " from the pinned target \(host)"
        }
        if let dropped, key == OriginRequestBudget.originKey(for: dropped) {
            return " from \(host), the target this session dropped and the source minted again"
        }
        if droppedEarlier.contains(key) {
            return " from \(host), a target an earlier window dropped and the source minted again"
                + (dropped == nil ? " (a drop this reader did not make)" : "")
        }
        return " from \(host), a target the source resolved freshly"
    }

    /// Statuses that say the RESOLVED address is the problem, so the productive move is one
    /// re-resolve through the source URL for a fresh redirect rather than another attempt against
    /// the same pinned target.
    ///
    /// #405: 407 belongs here and used to fall through all three classifiers (no pin drop from the
    /// status, mid-stream cap of 12, the pin dropped only later by the unproductive-streak rule).
    /// On a redirect chain a 407 from the pinned media host cannot mean "authenticate to your
    /// proxy": the request went out direct, which is exactly why CFNetwork logs it as *Received
    /// unexpected proxy response*, and a genuinely configured proxy is answered by URLSession's own
    /// auth challenge long before a status reaches us. What it means is that the pinned lease is
    /// gone or an interception answered in its place, and re-resolving is the only move that can
    /// work (field trace: two wasted attempts, then the reader re-resolved and connected).
    ///
    /// 402 and 451 are the same shape from panels that answer an expired subscription or a
    /// geo-refusal per edge node: the source still mints working targets, this one stopped being
    /// one. Rate-limit statuses stay OUT (429/503/509 mean the origin is metering us and the pin is
    /// fine, #71/#307); so does every 5xx, which `isResolvedHardServerError` handles with its own
    /// reason string.
    static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 402 || status == 403 || status == 404
            || status == 407 || status == 410 || status == 451
    }

    /// Rate-limit-shaped statuses: the origin is metering us, not failing. 429/503 carry
    /// Retry-After (#71); 509 "Bandwidth Limit Exceeded" (nonstandard) is what a
    /// connection-capped IPTV panel answers while its slot is still occupied by the
    /// connection being replaced — the slot frees in seconds, the pinned redirect target
    /// is fine, and re-resolving through the portal spends the one request there is no
    /// room for (519ae26e, #307 follow-up). That grace is bounded, not absolute: a 509
    /// that outlives `rateLimitRepinStreak` paced attempts is a pinned edge target whose
    /// session expired (a resume after minutes of pause), and there the pin is dropped
    /// for one re-resolve through the source.
    static func isRateLimitStatus(_ status: Int) -> Bool {
        return status == 429 || status == 503 || status == 509
    }

    /// Hard server errors answered by a pinned post-redirect URL: the redirect target
    /// may be dead or expired while the source URL would mint a fresh one. Rate-limit
    /// statuses are excluded — the origin is metering us, and the pin is not the
    /// problem there.
    static func isResolvedHardServerError(_ status: Int) -> Bool {
        return status >= 500 && !isRateLimitStatus(status)
    }

    // Cumulative bytes fetched since open; memory probe compares against RSS growth.
    private let counterLock = NSLock()
    private var _cumulativeBytesFetched: Int64 = 0
    var cumulativeBytesFetched: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _cumulativeBytesFetched
    }
    /// #377: the origin just answered 429/503/509. Charge it against the shared budget, which
    /// lowers the concurrency this origin is offered from here on and stamps the refusal so the
    /// engine's revive arm can tell "metered" from "gone" (the FFmpeg-side code is -1 and carries
    /// neither). Called from wherever a status is first read, once per refusal.
    ///
    /// `respondedBy` is the host that ANSWERED, which is not always the one we asked: once the
    /// ladder has dropped the pin the request goes to the source, and a 302 can still put the
    /// refusal on an edge target. Keying off `requestURL()` there names the source in the books for
    /// an answer it never gave. The chain folding (#388) lands both keys in one bucket either way,
    /// so this is about which host the books name, not about which budget moves.
    private func noteOriginRefusal(status: Int, retryAfter: TimeInterval? = nil,
                                   respondedBy: URL? = nil) {
        let refusing = respondedBy ?? requestURL()
        OriginRequestBudget.shared.noteRefusal(for: refusing, status: status, retryAfter: retryAfter)
        // The refusal usually comes back from the post-redirect CDN, while the engine's revive arm
        // only knows the URL the host loaded. Where those differ (a proxy that 302s to a signed CDN
        // target, the shape in the #377 report) the verdict would never be found on the key the
        // engine asks about. Stamp the source URL as a witness, without moving its budget: the
        // proxy did not refuse us and should not be throttled for it.
        if OriginRequestBudget.originKey(for: refusing) != OriginRequestBudget.originKey(for: url) {
            OriginRequestBudget.shared.noteRefusalWitnessed(for: url)
        }
    }

    /// #377: true when this origin is down to one request at a time, so the reader's speculative
    /// parallel paths must not run. They exist to overlap with the pump, overlapping is the one
    /// thing a single-slot origin refuses, and each has a serial fallback that is merely slower.
    private var originRequiresSerialRequests: Bool {
        OriginRequestBudget.shared.requiresSerialRequests(requestURL())
    }

    private func addBytesFetched(_ n: Int) {
        counterLock.lock()
        _cumulativeBytesFetched &+= Int64(n)
        counterLock.unlock()
        // #392: every network delivery this reader makes passes through here (pump, chunk, tail
        // prefetch, detour fetch, streaming), which is why the idle clock is stamped here and not
        // in one of them. A serve out of memory does not reach this call, and must not: memory is
        // exactly what an idle reader lives on while its pin ages.
        noteNetworkDelivery()
    }

    private var isStreaming: Bool { fileSize <= 0 }

    /// #126: a VOD source that resolved no size runs the forward-only streaming reader
    /// (1 MB back-window, no reconnect); it must not be routed onto seek-dependent paths.
    /// Live keeps true: the persistent reader owns reconnection and live routing never
    /// seeks backward. Meaningful only after `open()` has resolved the mode.
    var isSeekable: Bool { isLive || !isStreaming }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Default 4 MB. Delegate-based incremental delivery (ChunkFetchDelegate on a
    /// shared long-lived chunkSession) avoids the per-request URLSession task-pool
    /// leak that made 8 MB chunks bleed ~6 MB/s (e327e5e). 4 MB gives ~0.7 s
    /// cold-start on 45 Mbps 4K HEVC. Smaller values add HTTP roundtrip overhead
    /// at 5+ ops/sec without meaningful latency benefit. Still-extraction passes a
    /// smaller value for random-access single-keyframe fetches.
    private let chunkSize: Int
    /// When false, no speculative next-chunk prefetch (random-access: next read
    /// almost always seeks elsewhere, so prefetch would be wasted bandwidth).
    private let prefetchEnabled: Bool
    /// When set, the open-time data connection requests a finite `bytes=0-N` range instead of the
    /// open-ended `bytes=0-` stream (#93 residual). Scopes to the open connection only; read-loop
    /// reconnects and seek reconnects stay open-ended. nil = open-ended everywhere (playback).
    private let boundedInitialFetch: Int64?
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks
    // Backpressure: suspend the streaming task above highWater, resume below lowWater.
    private static let streamHighWaterDefault = 64 * 1024 * 1024
    private let streamHighWater: Int
    private var streamLowWater: Int { streamHighWater / 2 }
    /// Audit DMX-7: the suspend above is advisory (#220 measured 911 MB arriving after one), and
    /// this path cannot re-request at an offset the way the persistent reader does, so a transport
    /// that keeps delivering past twice the high water is ended and the read fails with EIO once
    /// the buffered bytes are drained. Audit DMX-107: that failure is typed
    /// (`AVIOReaderError.originIgnoresFlowControl`, `lastReadFailure`), so it reads as what it is.
    private var streamHardCap: Int { 2 * streamHighWater }

    private let bufferLock = NSLock()
    private var currentBuffer = Data()
    private var currentOffset: Int64 = 0
    private var prefetchBuffer: Data?
    private var prefetchOffset: Int64 = 0
    private var isPrefetching = false
    private let prefetchReady = DispatchSemaphore(value: 0)
    private let prefetchQueue = DispatchQueue(label: "com.aetherengine.avio.prefetch", qos: .userInitiated)
    private static let maxRetries = 3

    // MARK: - Streaming Mode (sequential GET)

    /// Held as the delivered chunks, like the persistent window (AE#619): a read trims its consumed
    /// head by advancing an offset, where `Data.subdata` copied the whole 32-64 MB still ahead of the
    /// cut on every read (audit PERF-102). Guarded by `streamLock`.
    private var streamBuffer = ChunkedByteWindow()
    private var streamBytesRead: Int64 = 0
    /// Most bytes `streamBuffer` has held at once, for the bound tests. Guarded by `streamLock`.
    private var streamPeakBytes = 0
    private var streamEnded = false
    private let streamLock = NSLock()
    private let streamDataReady = DispatchSemaphore(value: 0)
    /// Advisory body length from the streaming response's Content-Length (-1 unknown). Only the
    /// sequential-origin path reads it: a connection that ends short of it (or stalls out) is a
    /// LOST source, not end-of-media, and must surface as a read error rather than EOF - the
    /// consumer treats EOF as "played to the end" and deliberately never retries it. Guarded by
    /// `streamLock`.
    private var streamExpectedBytes: Int64 = -1
    /// Audit DMX-6: the streaming GET ended in a transport error, or was ended at
    /// `streamHardCap`. Either way the bytes that did not arrive are lost, not absent, so the read
    /// that runs out reports EIO instead of end-of-media. Guarded by `streamLock`.
    private var streamFailed = false
    /// Audit DMX-107: why the streaming GET was ended by this reader when it was not the transport's
    /// doing. Guarded by `streamLock`.
    private var streamFailureCause: AVIOReaderError?
    /// The status the streaming GET was answered with when it was anything but 200/206, 0 while
    /// none. A status is not media: the delegate hangs up at the header, and `open()` fails typed
    /// on it rather than handing FFmpeg an empty stream to misreport as invalid data. Written on
    /// the delegate queue before `streamEnded`; guarded by `streamLock`.
    private var streamRefusedStatus = 0
    /// AE#495: the `NSURLErrorDomain` code of a TLS trust refusal seen on any of this reader's tasks,
    /// 0 when none. Recorded rather than thrown from where it happens, because the task that sees it
    /// is not the one the open is waiting on: without it the open fails as FFmpeg's invalid data and a
    /// self-signed origin is indistinguishable from a corrupt file. Guarded by `streamLock`.
    private var transportSecurityCode = 0

    // MARK: - Persistent Mode (single forward-streaming connection, playback path)

    // Backpressure: END the connection above highWater and re-request at the frontier once
    // the consumer drains below lowWater. Nothing is discarded and nothing is re-fetched:
    // every delivered byte stays in the window, and the next range starts exactly where
    // delivery stopped.
    //
    // This is the third design here, and the history is load-bearing. #174 replaced
    // delegate-blocking (no flow-control contract: TLS/H2 transports keep reading at line
    // rate into unbounded URLSession-internal allocations until jetsam) with task
    // suspend/resume. #220 then measured suspend() to be advisory — against an origin
    // serving 2.5x media rate, 911 MB arrived AFTER the task was suspended — so a hard cap
    // ended the connection when the suspend demonstrably had not taken.
    //
    // #310 is why the suspend is now gone entirely rather than capped: a data task left
    // suspended holding an undelivered window keeps a dormant established flow whose closed
    // receive window sits unread for as long as the consumer takes to drain — ~100 s per
    // cycle at 1 Mbps media rate, indefinitely while paused. On tvOS/iOS (user-space
    // networking: TCP for nw flows runs in the app process) that dormant state correlates,
    // dose-response by media bitrate, with 10-80 s episodes in which every
    // Network.framework flow in the process goes deaf at once — established WebSockets time
    // out unACKed, no new nw handshake completes — while raw BSD sockets from the same
    // process keep working. Ending the connection instead means the reader either has an
    // ACTIVELY delivering flow or NO flow: there is no parked state for the substrate to
    // rot in, and a paused player holds no connection at all. The price is one extra range
    // request per drain cycle (every ~100 s at 1 Mbps; connects measure ~2 ms on LAN). The
    // window peak is now bounded by construction at highWater plus one delivery's in-flight
    // overshoot, which subsumes the former winHardCap escape hatch and the realloc-doubling
    // peak it had to be sized against.
    //
    // Live raises the high water instead of changing the mechanism. Live connections are
    // open-ended by design (no ranges to bound them), so the high-water end is the ONLY
    // thing that ever terminates a healthy live connection — and "re-request at the
    // frontier" is a lie to a live origin: the bytes broadcast during the drain are gone,
    // so every cycle rejoined the stream on a corrupt TS packet. Worse, IPTV panels serve
    // their ring buffer as a join burst at line rate on EVERY (re)connect, so a 16 MB cap
    // made each reconnect the cause of the next one: burst to high water, end, drain ~8 MB
    // losing that much realtime, reconnect, absorb the next burst. The live threshold is
    // sized to absorb the burst ONCE; steady state then plateaus at burst size (arrival
    // rate == media rate once the burst is over) with the connection never voluntarily
    // ended. The end-and-refill stays, unchanged, as the memory backstop for a "live"
    // source that sustainedly outruns realtime (a misdeclared VOD). 64 MB matches
    // streamHighWater, the forward bound the engine already accepts for the other reader
    // that cannot bound by range request.
    private static let winHighWaterDefault = 16 * 1024 * 1024
    private static let liveWinHighWaterDefault = 64 * 1024 * 1024
    private static let winLowWater = 8 * 1024 * 1024
    // #220: how much the persistent reader asks for at a time. Bounds a single request's
    // exposure: `appendPersistentData` drops anything past the requested end and ends the
    // transfer (audit DMX-1), so an origin that ignores Range or answers wider than asked
    // cannot grow the window past it. It also keeps the request cadence modest on a healthy link:
    // one request per range boundary while the consumer keeps up, one per
    // highWater-to-lowWater drain cycle when the origin outruns it.
    static let persistentRangeBytes: Int64 = 32 * 1024 * 1024

    /// #377: the smallest window room worth a read on a held connection, and therefore the length
    /// of a dormant stretch in the steady state (this over media rate). #310's dose is that
    /// length: 16 MB of window at 1.2 Mbps is ~100 s dormant and produced 11 starvation episodes
    /// in 80 min, the same window at 88 Mbps is 1.4 s and produced none in 118 min. 64 KB is 0.4 s
    /// at that same 1.2 Mbps and 7 ms at 70 Mbps, so the steady state sits in the regime that
    /// never fired rather than relying on a measurement nobody can take on demand.
    private static let heldPullSlack = 64 * 1024
    /// How often a held connection on a full window re-reads the play intent. A pause is not
    /// broadcast on `winCond` -- nothing reads during one -- so this is what lets the paused
    /// budget below start at all.
    private static let heldPlayIntentPollSeconds: TimeInterval = 1
    /// How long a held connection may stay open while the consumer is PAUSED before it is ended.
    /// Playback never spends this: a parked producer is not a stopped one, and a reader that reads
    /// the first as the second re-requests every few seconds, which is what this flag exists to
    /// stop. A pause is the unbounded case #310's worst episode came from (11 minutes), so it is
    /// bounded here and nowhere else.
    ///
    /// The number is half the longest dormancy measured clean on the device, which is the whole of
    /// its derivation. Arm B on an Apple TV 4K 3rd gen (tvOS 26.6) held a stream task on a closed
    /// receive window for 600 s against the origin from #377: 1180 canary requests at 1 Hz, to that
    /// origin and to a host that is not it, all 206, and about 3 MB resident when the reads resumed
    /// against the ~12 GB the wire could have carried, so the window really was shut for the whole
    /// stretch. That is #310's wire condition itself rather than a proxy for it, and no cliff sits
    /// under twice this value. It stays at half of it because a clean run is not a threshold, and
    /// because being wrong here is cheap: one frontier request per pause that outlives the bound,
    /// against the 218 an hour this flag used to spend on parked producers alone.
    ///
    /// Media rate is not on this axis. A paused consumer takes no bytes, so the dormant stretch is
    /// the pause, whatever the file's rate; the rate only decides how quickly the socket buffer
    /// fills before the window shuts, which is the 3 MB above. #310's window-over-media-rate dose
    /// is the PLAYING case and it belongs to `heldPullSlack`, not here.
    static let heldPausedBudgetDefault: TimeInterval = 300

    /// Overridable so a test can express a pause without sleeping through the real budget.
    nonisolated(unsafe) var heldPausedBudgetSeconds: TimeInterval = AVIOReader.heldPausedBudgetDefault
    /// Ceiling on a single pull. The window's remaining room is normally the smaller number; this
    /// only keeps one read from asking the transport for an unbounded amount while the window is
    /// empty (an open, a seek).
    private static let heldMaxPullBytes = 1 * 1024 * 1024
    // #377: how long a pump range waits for an origin slot before going on the link anyway. The
    // pump is the main line and everything that can be holding a slot ahead of it is short (a 4 MB
    // detour block, a size probe), so this is "wait for the short thing", not "give up". Generous
    // on purpose: overrunning the budget costs one extra request against the origin, while
    // refusing the pump costs the session.
    private static let pumpSlotWaitSeconds: TimeInterval = 10
    // #377: a probe or detour block waits far less. Both have serial fallbacks and both run while
    // the consumer is waiting, so queueing them behind a 32 MB range would be felt as a stall.
    private static let shortFetchSlotWaitSeconds: TimeInterval = 4
    // Keep this many bytes behind the cursor for small matroska backward re-reads.
    private static let winLookback = 2 * 1024 * 1024
    // Trim in batches to avoid O(n^2) memmove storm on every 256 KB read.
    private static let winTrimBatch = 4 * 1024 * 1024
    // Forward seeks within this distance keep the live connection; beyond it, reconnect.
    private static let seekKeepForwardLimit = 8 * 1024 * 1024
    // CDN stall threshold: no bytes for this long triggers reconnect. Instance-captured (see
    // `connStallTimeout`) so tests can shorten it; the shipped value is this one.
    private static let connStallTimeoutDefault: TimeInterval = 20
    /// #450: fraction of the stall threshold at which a generation that has seen no first byte is
    /// REPORTED. Derived from the threshold rather than set beside it so the invariant holds at
    /// every value of the threshold, the shortened ones tests run with included: the witness speaks
    /// before the threshold acts.
    private static let firstByteWitnessFraction = 0.25
    /// Ceiling on that, so a long threshold cannot push the line past the arcs that give up on a
    /// source first. `awaitFirstPersistentData` allows an open 15 s, and the shipped threshold is
    /// 20 s: the one outcome the stall witness could never describe was the one where the first
    /// byte never comes, because the load was already over when it fired.
    private static let firstByteWitnessMaxSeconds: TimeInterval = 5
    // A reconnect that delivers at least this much counts as progress; resets streak.
    private static let minReconnectProgress: Int64 = 512 * 1024
    // Cap on CONSECUTIVE unproductive reconnects; resets on real progress.
    private static let reconnectMaxUnproductive = 12

    // MARK: - Cold-start round trips (#281)

    /// How much of the file's head to retain for the return trip after a parse excursion. Measured
    /// landings across six container layouts and a field trace: 48, 1161, 5752 and 265159, all well
    /// inside this. Sized to hold that return without becoming a second buffer worth worrying about
    /// next to the live window: this is charged against the same footprint the high-water end bounds.
    static let headSpanMaxBytes = 4 * 1024 * 1024

    /// Speculative suffix fetch issued with `open()`, sized to cover the small trailing objects a
    /// demuxer asks for before it can report a frame rate: `mfra` on fragmented MP4 (~1-2 KB), and
    /// the trailing `moov` of a non-faststart file whose sample tables are small enough to fit.
    ///
    /// Deliberately NOT sized to cover every trailing `moov`. Those grow with the sample count, so
    /// a feature-length file's runs into megabytes, and fetching that speculatively on every open
    /// would spend real bandwidth on a guess, competing with the first data connection on exactly
    /// the slow links this is meant to help. 64 KB is negligible on any link that plays video at
    /// all, and when it misses, the retained head still removes the return trip.
    static let tailPrefetchBytes = 64 * 1024

    /// [MovieClaw P49] Matroska 索引（Cues）离文件尾不超过这么多才提前取（从 Cues 起一直取到文件尾）。
    /// mkvmerge 产物的 Cues 连同其后的 Tags 离文件尾实测 7.7 万～93 万字节（语料 14 部 MKV）；更远的少见，照旧按需读
    static let cuesPrefetchMaxBytes: Int64 = 2 * 1024 * 1024
    /// 文件头攒到这么多还读不出 SeekHead 就不找了（SeekHead 通常在文件头 200 字节以内）
    static let cuesLocateMaxHeadBytes = 256 * 1024

    /// [MovieClaw P53] 在途的提前取已经开始往回送时，停下不动超过这么久（且超过按往返定的上限）才算它卡住
    static let prefetchProgressStallSeconds: TimeInterval = 1.0

    /// [MovieClaw P54] MP4 尾部 moov（mdat 之后到文件尾）不超过这么大才提前取。片库抽样 0.5～3 MB、最大 10.7 MB；
    /// 更大的多半是 mdat 后面还跟着别的大块，照旧按需读
    static let moovPrefetchMaxBytes: Int64 = 16 * 1024 * 1024

    /// [MovieClaw P56] 冷打开时文件头的第一个请求只要这么多：够读出容器头、找到索引（SeekHead / mdat 盒子头都在头几百
    /// 字节），不一口气要 32 MB 去和提前取的索引平分线路。解复用器真要更多时读取循环照常在那里续连
    static let openFirstRangeBytes: Int64 = 512 * 1024

    /// [MovieClaw P55] 按实测线路速度估一整块旁路补取要多久时，只算限时的这么多（留余量给同时在读的主连接）
    static let detourLinkMargin = 0.8
    /// [MovieClaw P55] 一代连接从首字节起收满这么多、且超过这么久，才拿它估线路速度（太短的读数被首块到货的突发带偏）
    static let linkRateMinBytes: Int64 = 256 * 1024
    static let linkRateMinSeconds: Double = 0.5

    // MARK: - Detour Block Cache (random-access parse reads; AetherEngine#69)

    // A non-faststart / coarsely-interleaved remote MP4 makes the demuxer ping-pong between
    // distant file regions (header, trailing moov, sample data) during find_stream_info /
    // index parse. Each non-sequential read used to tear down + reopen the persistent
    // connection (seekReconnect), so the parse storm hammered the origin into a 429.
    // Instead, serve those random-access reads through the pooled keep-alive chunkSession
    // (the one fetchChunk already uses), caching 4 MB aligned blocks. The streaming
    // connection stays ANCHORED; the ping-pong becomes cache hits; the storm collapses to
    // the two legitimate reconnects (open + the one seek to the moov). The sequential
    // playback fast path never enters this code, so it carries zero overhead.
    private static let detourBlockSize = 4 * 1024 * 1024
    private static let detourMaxBlocks = 8                       // ~32 MB LRU ceiling
    /// Audit PERF-108: a detour block nobody has read or filled for this long is a scrub's leftover,
    /// not a parse's working set (a parser revisits its region within seconds).
    private static let detourBlockIdleSecondsDefault: TimeInterval = 30
    // Once detour reads turn sequential past this much, re-anchor the streaming connection
    // there so sustained playback returns to the cheap window path (e.g. after a backward scrub).
    private static let detourReanchorBytes: Int64 = 8 * 1024 * 1024
    // Interactive per-fetch budget for a detour block (#93/#96). A backward-scrub read serves via the
    // detour cache; a miss fetches a 4 MB block over the pooled session. On a per-connection-starved
    // origin that fetch used to ride the full chunkRequestTimeout (idle 15s / total 35s) before falling
    // through to the rescue reconnect, which opens a fresh connection the origin serves in ~30-190ms
    // (rrgomes' #93/#96 traces: the whole 15-35s sat here, invisibly, in the detour fetch). A 4 MB block
    // over a healthy remote 4K source lands in ~1s, so a tight budget aborts a starved fetch fast and
    // lets the reconnect serve, without tripping healthy parse-time detour fetches (#69 stays intact:
    // its fetches complete well under this, and a genuinely slow parse fetch reconnecting is bounded by
    // the #71 rate-limit streak, far gentler than the pre-cache per-read storm).
    private static let detourFetchBudgetSeconds: TimeInterval = 4

    /// Effective per-fetch budget for a detour block: the tight interactive cap, never exceeding the
    /// caller's chunk budget (still-extraction passes a smaller one; it never reaches this path, but
    /// the clamp keeps the invariant). Internal so the bound is unit-tested without a live origin.
    static func effectiveDetourBudget(chunkRequestTimeout: TimeInterval) -> TimeInterval {
        min(detourFetchBudgetSeconds, chunkRequestTimeout)
    }

    // Cap on CONSECUTIVE rate-limited (429/503/509) network attempts before giving up cleanly.
    // Distinct axis from unproductiveReconnects: NOT reset by seekReconnect, so parse-driven
    // seeks cannot mask a throttled origin into an infinite reconnect loop (AetherEngine#71).
    private static let rateLimitMaxStreak = 6
    // Rate-limited attempts that keep the pinned redirect target before one attempt through the
    // source URL is spent on a fresh redirect. Three paced attempts (~7 s of ladder) ride out the
    // lingering-slot 509 of a connection-capped panel (#307 follow-up: the slot frees in seconds);
    // a streak that reaches this rung is the other shape — a pinned edge target whose session
    // expired during a long pause and refuses forever, where only a re-resolve heals. Internal so
    // the rung is unit-tested without a live origin.
    static let rateLimitRepinStreak = 3
    /// #392: how long the pin may carry no bytes at all before its FIRST rate-limited refusal is
    /// taken at face value instead of being ridden out by the grace above. The grace answers one
    /// specific shape, the lingering slot of a connection this reader just replaced, and that shape
    /// requires a recent byte of ours: the pump ends its connection at the window high water, so a
    /// reader that has been idle holds nothing at the origin for a slot to linger on (#310). A
    /// minute is far longer than a lingering slot lives (seconds) and far shorter than the pause
    /// that kills a lease (332 s in the #380 retest). Internal so the rung is unit-tested.
    static let pinIdleRepinSecondsDefault: TimeInterval = 60

    /// NSCondition guards all persistent-mode fields and serves as the
    /// edge-triggered condition variable for read waits and backpressure.
    private let winCond = NSCondition()
    /// Sliding window of bytes from the live connection, starting at `winStart`.
    /// `position - winStart` is the read offset within `window`. Held as the delivered chunks
    /// (AE#619), so trimming the consumed head copies nothing.
    private var window = ChunkedByteWindow()
    private var winStart: Int64 = 0
    // Connection state.
    private var connEnded = false
    private var connStatus = 0
    // Retry-After seconds from a rate-limit status, honoured before reconnect.
    private var connRetryAfter: TimeInterval = 0
    // Bumped on every (re)connect; stale delegate callbacks are ignored.
    private var connGeneration = 0
    /// #377: what is on the link for this reader. Either shape is ONE request against the
    /// origin holding one slot of its budget; they differ only in who decides when bytes
    /// move, and every other piece of this reader (window, frontier, reconnect ladder,
    /// diagnostics) is written against the transfer rather than against a URLSession task.
    private var activeTransfer: (any PersistentTransfer)?

    /// #174: winCond-guarded snapshots, internal so the task-level backpressure is
    /// unit-tested against a loopback origin without private state access.
    /// #220: planned range ends must leave the failure budget alone.
    var unproductiveReconnectsForTesting: Int {
        winCond.lock()
        defer { winCond.unlock() }
        return unproductiveReconnects
    }

    /// The rate-limit ladder's charge. A test asserting what does and does not count as progress
    /// against a metered origin (#380) reads this rather than inferring it from request counts,
    /// which only separate the cases once the ladder has already run to one of its ends.
    var rateLimitStreakForTesting: Int {
        winCond.lock()
        defer { winCond.unlock() }
        return rateLimitStreak
    }

    /// Bytes the window holds ahead of the cursor. Caller holds `winCond`. The held pull budget
    /// and the delivery-gap watchdog both decide on the room this leaves, and they have to agree:
    /// the watchdog stands aside exactly where the pump waits.
    private func windowAheadLocked() -> Int {
        window.count - max(0, Int(position - winStart))
    }

    /// The delivery gap the watchdog would judge right now. A test reads it to state the invariant
    /// the field case turns on: a stretch with no read outstanding does not accumulate against the
    /// read that follows it.
    var deliveryGapSecondsForTesting: Double {
        winCond.lock()
        defer { winCond.unlock() }
        return Double(DispatchTime.now().uptimeNanoseconds - lastDeliveryAt.uptimeNanoseconds) / 1_000_000_000
    }

    /// Whether a transfer is still installed. A test that needs a range to have COMPLETED, rather
    /// than merely to have delivered, waits on this instead of on a sleep: the completion callback
    /// is what clears `activeTransfer`, and that clearing is the state the behaviour turns on.
    var hasLiveConnectionForTesting: Bool {
        winCond.lock()
        defer { winCond.unlock() }
        return activeTransfer != nil
    }

    /// Audit DMX-107: the typed cause of the read error the streaming path reports, nil while the
    /// source is healthy and for a plain transport loss (which has no cause of ours to name).
    var lastReadFailure: AVIOReaderError? {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamFailureCause
    }

    /// Detour blocks currently resident.
    var detourResidentBlocksForTesting: Int { detourCache.residentCount }

    /// The most the forward-only streaming buffer has held at once.
    var streamPeakBufferBytesForTesting: Int {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamPeakBytes
    }

    #if DEBUG
    /// Storage address of every chunk the streaming buffer still holds, first to last. A trim that
    /// copied the buffer would move all of them.
    var streamChunkAddressesForTesting: [UnsafeRawPointer?] {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamBuffer.chunkStorageAddresses()
    }
    #endif

    /// Bytes the persistent window holds, behind and ahead of the cursor.
    var windowBytesForTesting: Int {
        winCond.lock()
        defer { winCond.unlock() }
        return window.count
    }

    /// #220/#310: set when WE ended the connection at `winHighWater` (ending is the only
    /// non-advisory flow control, and a task left suspended instead is a dormant flow — see
    /// the backpressure doc block above). The read loop re-requests at the frontier — at low
    /// water like a completed range, or immediately once the window is empty — without
    /// charging the reconnect to the unproductive-reconnect streak. Left unset, a deliberate
    /// end would spend the streak that exists to detect a dead source and
    /// `recordReconnectAndShouldGiveUp` would kill the reader on a perfectly healthy link.
    /// winCond-guarded, cleared by `startPersistentConnection`.
    private var connEndedByBackpressure = false

    /// #310: bytes that arrived after `connEndedByBackpressure` was set, i.e. after our own
    /// cancel, and whether the one-shot "the cancel did not take" line has been emitted for
    /// this generation. Both winCond-guarded, both cleared by `startPersistentConnection`.
    private var postEndDeliveryBytes: Int64 = 0
    private var postEndOvershootLogged = false

    /// #309: when the current generation last delivered a byte, or when it started if it has
    /// delivered none yet. The single input to the delivery-gap watchdog, and the reason that
    /// watchdog can exist at all: the read loop's forward wait used to be the only place
    /// `connStallTimeout` was ever evaluated, so a flow that died while the window could still
    /// serve reads was noticed only once a consumer happened to block on it (observed in the field:
    /// 4.5 minutes across a pause). The transport does not fill that gap either, since the
    /// persistent request runs with `timeoutInterval = 0` on purpose. winCond-guarded.
    private var lastDeliveryAt = DispatchTime.now()

    /// #309: earliest time the read loop may replace a FAULTED connection from the serve path.
    /// The failure ladder there cannot sleep (see `chargeFaultedRunwayRefill`), so its backoff is
    /// a timestamp instead. `.distantPast` = attempt now, `.distantFuture` = the bounded give-up
    /// has fired and only the empty-window path may still act. winCond-guarded, reset by
    /// `startPersistentConnection`.
    private var nextFaultedRefillAt = Date.distantPast

    /// #220: last byte the live connection was asked for, nil when the request was open-ended
    /// (live sources, and any source whose total size is not resolved yet). winCond-guarded.
    private var connRangeEnd: Int64?

    /// Audit DMX-101: true only while `open()` waits on the cold data connection, so that response
    /// alone is judged for range support. A 200 later in a session (a CDN cache miss on a refill)
    /// stays what it always was: rejected and retried, never a verdict on the origin. winCond-guarded.
    private var rangeVerdictPending = false
    /// Audit DMX-101: Content-Length of the cold connection's range-ignoring 200, -1 when it stated
    /// none, nil while the origin has not been caught ignoring. winCond-guarded.
    private var rangeIgnoredAtOpenLength: Int64?
    /// Audit DMX-101: the origin cannot address bytes, so this source plays forward-only on the
    /// streaming path. Written once by `open()` on the demux thread, read by `seek` on the same one.
    private(set) var originIgnoresRange = false

    /// Sodalite#117: contiguous range starts are summarised instead of logged one by one.
    /// winCond-guarded.
    private var connStartLogGate = ConnStartLogGate()

    /// #220: set when the connection ended because its range was delivered in full. That is a
    /// planned end, not a failure, and must not be charged to the reconnect budgets. Mirrors
    /// `connEndedByBackpressure`; cleared by `startPersistentConnection`.
    private var connEndedAtRangeEnd = false

    /// First byte the live connection was asked for. Distinct from `winStart` since #295: a
    /// continuation keeps the resident window, so the window no longer begins where the request
    /// did, and the checks that need the REQUESTED offset (a 200 that ignored Range, the size
    /// derived from a from-zero response) must not read the window's start instead. winCond-guarded.
    private var connRequestedOffset: Int64 = 0
    /// #331: latched once a live origin answers 416 to a nonzero offset, i.e. proves it has no
    /// byte addresses to resume at. From there every live request is the join shape (`bytes=0-`).
    /// Latched rather than unconditional because the two live origin shapes want opposite things:
    /// an IPTV panel serving a ring buffer cannot satisfy a frontier and rejects it outright,
    /// while a live source that IS a growing file (a Jellyfin live stream file, a misdeclared VOD)
    /// honours the frontier and resumes exactly where delivery stopped, and asking that one for
    /// byte zero re-delivers the whole buffer on top of the window. One rejected request per reader
    /// tells the two apart; guessing cannot. winCond-guarded.
    private var liveOffsetsUnsatisfiable = false

    /// #220: winCond-guarded snapshot of the sliding window for the periodic memprobe.
    /// `ahead` is the undrained forward extent, the quantity `appendPersistentData` gates the
    /// backpressure end on. `parked` is true while the connection has been deliberately ended
    /// at high water and the low-water refill has not fired yet (#310), so a long-lived
    /// `parked` with `ahead` holding above lowWater reads as a stalled consumer, not a
    /// transport fault.
    var windowDiagnostics: (windowBytes: Int, aheadBytes: Int, parked: Bool) {
        winCond.lock()
        defer { winCond.unlock() }
        return (window.count,
                window.count - max(0, Int(position - winStart)),
                connEndedByBackpressure)
    }
    // #93 restart latency diagnostics (winCond-guarded): bytes dropped by the stale-generation
    // guard, plus per-generation time-to-first-data tracking.
    private var staleGenDroppedBytes: Int64 = 0
    private var connStartedAt = DispatchTime.now()
    private var connFirstDataSeen = false
    // Consecutive unproductive reconnects (demux-thread-only).
    private var unproductiveReconnects = 0
    private var bytesAtLastReconnect: Int64 = 0
    // Consecutive rate-limited attempts; survives seekReconnect, resets on real read progress (#71).
    private var rateLimitStreak = 0

    /// Detour LRU block cache (its own leaf lock, never held across `fetchChunk`/network or
    /// `winCond`). Stores only full-size blocks; short bodies are served once but never cached
    /// (see serveFromDetour), so eviction never shadows a re-fetchable tail. Pure copy/eviction
    /// math lives on the cache and is unit-tested without any network.
    private let detourCache = DetourBlockCache(blockSize: AVIOReader.detourBlockSize,
                                               maxBlocks: AVIOReader.detourMaxBlocks)
    /// When the detour cache was last swept for idle blocks (audit PERF-108). Demux-thread-only.
    private var lastDetourIdleSweepNs: UInt64 = 0
    /// How long a detour block may sit unread before the sweep releases it. An init parameter for
    /// the same reason `connStallTimeout` is one: a process-wide hook would leak into whatever suite
    /// runs concurrently.
    private let detourBlockIdleSeconds: TimeInterval
    // Re-anchor run tracking (demux-thread-only): the file offset the next sequential detour read
    // would continue from, and how many contiguous bytes the current detour run has served.
    private var detourRunNextExpected: Int64 = -1
    private var detourRunBytes: Int64 = 0

    // MARK: - Cold-start spans (#281)

    /// The head of the FILE, retained for the open phase as the data connection delivers it, so the
    /// return trip after a parse excursion is a copy rather than a connection.
    ///
    /// #281 parked the window at seek time instead, cut from `winStart`, on the reasoning that the
    /// demuxer returns to the window's start. It returns to the FILE's start: measured landings of
    /// 48, 1161, 5752 across six container layouts and 265159 in a field trace. The two coincide
    /// only while the parse seeks away before reading anything, and the parked copy served nothing
    /// on any layout measured, so it is gone. Collected as the bytes arrive rather than copied at
    /// seek time, because `trimWindowLocked` has dropped the head long before a seek asks for it.
    /// winCond-guarded.
    private var headSpan: Data = Data()

    /// Speculative tail bytes fetched alongside `open()`. winCond-guarded: the fetch completes on a
    /// URLSession queue while the demux thread reads.
    private var tailSpan: ResidentSpan?

    /// In-flight speculative tail fetch, cancelled by `close()`.
    private var tailPrefetchTask: URLSessionDataTask?

    /// Whether that fetch is still outstanding, and when it went out. A read landing in its range
    /// waits for it rather than connecting past bytes that are already on the wire, so this is the
    /// difference between the fetch being an optimisation and being a wasted request. Cleared by
    /// the fetch's own completion, by `markClosed` and by `close`, each of which broadcasts.
    /// winCond-guarded.
    private var tailPrefetchInFlight = false
    private var tailPrefetchStartedAt = DispatchTime.now()

    /// [MovieClaw P49] Matroska 索引提前取：文件头一到就按 SeekHead 找出 Cues 的位置（`MatroskaCuesLocator`），
    /// 与开容器、探测流并行把「Cues 到文件尾」这段先取回来，装成和文件头 / 文件尾同样的常驻片段。解复用器随后
    /// 读索引时从这里给：省一次往返，也不再掐断正在读文件头的连接。开流与索引预热都结束后，第一次读不到它就放掉。
    /// 在途时读到这段范围会等它（上限同尾部预读）。都受 winCond 保护
    private var cuesSpan: ResidentSpan?
    private var cuesLocateDone = false
    private var cuesPrefetchTask: URLSessionDataTask?
    private var cuesPrefetchInFlight = false
    private var cuesPrefetchRange: Range<Int64>?
    private var cuesPrefetchStartedAt = DispatchTime.now()
    private var cuesSpanServeLogged = false
    /// [MovieClaw P58] `cuesSpan` 装的是服务端给的精简索引（不是原字节）。这时它在自己的范围里压过窗口与其他常驻片段：
    /// 同一个 Cues 元素不能前半截读原字节、后半截读精简版。随 `cuesSpan` 一起放掉
    private var cuesSpanFromHost = false
    /// [MovieClaw P58] 找索引时（持锁）要说的话，调用方解锁后说出去（`takePendingCuesLogLocked`）
    private var pendingCuesLog: String?

    /// [MovieClaw P53] 在途的提前取（尾部预读 / 索引提前取）最近一次收到字节的时刻，没收到过为 nil。读到它们的范围时，
    /// 只要还在往回送就接着等，停下不动才放弃（`prefetchWaitDeadlineLocked`）。都受 winCond 保护
    private var tailPrefetchLastProgressAt: DispatchTime?
    private var cuesPrefetchLastProgressAt: DispatchTime?

    /// [MovieClaw P55] 当前这代连接从首字节起收到的字节数与首字节时刻，以及据此（或整段提前取）实测出的线路速度
    /// （字节/秒，没测出来为 nil）。都受 winCond 保护
    private var genDeliveredBytes: Int64 = 0
    private var genFirstDataAt = DispatchTime.now()
    private var measuredLinkBytesPerSecond: Double?
    private var detourSkipLogged = false

    /// One log line per span per open, not per serve. winCond-guarded (set from the read loop).
    /// #551: the size this open took from a warm rather than from a response header. A size that
    /// came from a DIFFERENT response than the one now serving the session is the one adopted fact
    /// that could be wrong and could never be corrected, because the write-once rule below treats
    /// any positive `fileSize` as settled. Remembered so the frontier connection's own
    /// `Content-Range` can be checked against it, once.
    private var adoptedWarmSize: Int64?
    private var headSpanServeLogged = false
    private var headSpanPlaybackServeLogged = false
    private var tailSpanServeLogged = false

    /// Measured time to first data of the most recent connection: what one round trip against this
    /// origin actually costs, which is the only honest bound on how long waiting for in-flight bytes
    /// can be worth. winCond-guarded (written by the delegate thread).
    private var lastFirstDataMs: Double = 0

    /// Test seam: pins the wait budget, so a test that wants the fetch held in flight does not have
    /// to keep an origin's simulated latencies on the right side of a bound derived from one of
    /// them. That margin was 250 ms and a loaded CI runner spent it (#281 flake, 2026-08-11).
    /// `Self.tailPrefetchWaitBudget(firstDataMs:)` is what guards the real bound.
    var tailPrefetchWaitBudgetForTesting: TimeInterval?

    /// True from `open()` until the demuxer reports its header/stream-info pass done. The parse
    /// seeks this fix targets all happen inside that window; a far seek afterwards is a real scrub,
    /// where the old window is worthless and parking it would only cost memory.
    /// winCond-guarded.
    private var openPhaseActive = false

    /// AE#585: true while the host runs a bounded index pass after the open phase, which is index
    /// work rather than playback. winCond-guarded.
    private var indexPassActive = false

    /// Playback path (known size + prefetch) or live feeds. Live always uses the
    /// persistent reader; the streaming reader has no reconnect machinery.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// True for endless live feeds. Suppresses `position >= fileSize` EOF synthesis;
    /// reports EIO (-5) instead of EOF when the reconnect cap is hit.
    let isLive: Bool

    /// `LoadOptions.sequentialOrigin` (via `DemuxerOpenProfile.avioSequentialOnly`): the origin
    /// fabricates range answers, so only byte 0 is addressable. `open()` routes straight onto the
    /// forward-only streaming mode (one unranged GET) and never issues a ranged request - no tail
    /// prefetch, no optimistic persistent open, no size probe, no detours. `fileSize` stays -1 by
    /// construction, which keeps `isStreaming` true and the pb non-seekable (#126 block below).
    let sequentialOnly: Bool

    /// Detour cache is VOD-only: live feeds have no meaningful random access and a
    /// non-authoritative size, so they stay on the unchanged reconnect path.
    /// #377: a detour block is a SECOND request opened while the pump's is still on the link, which
    /// is exactly what a single-slot origin refuses. Falling back to repositioning the persistent
    /// connection (the path taken when the detour is ineligible anyway) costs the re-anchor and
    /// keeps the reader to one request, where queueing the detour behind a slot the pump holds
    /// would just spend its whole budget waiting.
    private var detourEligible: Bool { !isLive && fileSize > 0 && !originRequiresSerialRequests }

    /// Timestamp of the last unplanned reconnect (drop/stall, not a seek).
    /// Producer correlates with a backward source-PTS reset to detect Jellyfin
    /// transcode respawn (re-serves from byte 0 on re-GET, invisible at byte level).
    /// Demux-thread-only (AVIO callback executes synchronously inside av_read_frame).
    private(set) var lastUnplannedReconnectAt: Date?

    /// Seekable-path per-chunk Range-request budget (seconds) and retry passes.
    /// Defaults preserve the historical playback/probe behaviour; still extraction
    /// passes smaller values so a stalled scrub thumbnail aborts fast (issue #27).
    private let chunkRequestTimeout: TimeInterval
    private let chunkMaxRetries: Int

    /// TEST-ONLY slow-CDN throttle (kbit/s, 0 = unlimited), captured once from the static hook at init.
    private let throttleKbps: Int
    /// TEST-ONLY reconnect-backoff scale (1.0 = real timing), captured once from the static hook at init.
    private let backoffScale: Double
    /// #392: the idle gap this reader takes a first refusal at face value after. Shipped value
    /// unless a test shortens it, captured once at init like the two hooks above.
    private let pinIdleSeconds: TimeInterval
    /// Stall threshold this reader runs with, `connStallTimeoutDefault` unless a caller overrides it.
    /// One value for both detectors, because they are one policy: a connection that has delivered
    /// nothing for this long is replaced, whether or not a read is waiting on it (#309).
    ///
    /// An init parameter rather than a process-wide test hook on purpose. The hooks next to it are
    /// read at every reader's init, so a test that sets one changes the behaviour of every reader any
    /// CONCURRENTLY running suite happens to build, and swift-testing runs suites in parallel. A
    /// shortened stall threshold leaking that way would make other suites reconnect early under
    /// load. It is not a `LoadOptions` field either: #272 measured that a shorter threshold is worse
    /// under CPU starvation, and that conclusion is unchanged.
    private let connStallTimeout: TimeInterval
    /// #450: when this reader reports a generation that is on the link with nothing delivered.
    private var firstByteWitnessDelay: TimeInterval {
        min(Self.firstByteWitnessMaxSeconds, connStallTimeout * Self.firstByteWitnessFraction)
    }
    /// High-water mark this reader ends the connection at. Mode-dependent (live absorbs a
    /// join burst the VOD value was never sized for — see the backpressure doc block) and
    /// an init parameter for the same reason `connStallTimeout` is one: a process-wide
    /// hook would leak into whatever suite runs concurrently. The shipped values are the
    /// two statics above.
    private let winHighWater: Int
    /// `LoadOptions.heldSourceConnection` (#377): this reader asks the origin once and pulls,
    /// instead of ending at the high water and asking again at low water. Opt in, an init
    /// parameter rather than a process-wide hook for the same reason `winHighWater` is one, and
    /// off for every reader whose caller did not ask (the subtitle side reader included, whose
    /// deliberate multi-minute parks are the shape a held connection must not take).
    private let heldConnectionEnabled: Bool
    /// [MovieClaw P56] 这次播放从文件头起（`DemuxerOpenProfile.playbackStartsAtHead`）
    private let expectsHeadPlayback: Bool
    /// [MovieClaw P58] 服务端给的 Matroska 精简索引（`DemuxerOpenProfile.hostMatroskaCues`），只有主播放的读取器有
    private let hostMatroskaCues: MatroskaHostCues?
    private var throttleVClockNs: UInt64 = 0
    private let throttleLock = NSLock()

    /// #240: which reader this is, for the connection log. Several readers run against the same
    /// origin at once and the line used to name none of them.
    private let label: String
    /// Only static controlled probes use this; playback retains its existing transport policy.
    private let probeControl: ProbeControl?
    private let probeRequestSession: URLSession?
    private let probeDrainLock = NSLock()
    private var drainingProbeRequest = false

    init(url: URL, extraHeaders: [String: String] = [:], label: String = "source", chunkSize: Int = 4 * 1024 * 1024, prefetchEnabled: Bool = true, isLive: Bool = false, chunkRequestTimeout: TimeInterval = 35, chunkMaxRetries: Int = 3, boundedInitialFetch: Int64? = nil, sequentialOnly: Bool = false, connStallTimeout: TimeInterval = AVIOReader.connStallTimeoutDefault, windowHighWater: Int? = nil, streamHighWater: Int? = nil, detourIdleSeconds: TimeInterval? = nil, heldConnection: Bool = false, probeControl: ProbeControl? = nil, probeRequestSession: URLSession? = nil, expectsHeadPlayback: Bool = true, hostMatroskaCues: MatroskaHostCues? = nil) {
        self.expectsHeadPlayback = expectsHeadPlayback
        self.hostMatroskaCues = hostMatroskaCues
        self.probeControl = probeControl
        self.probeRequestSession = probeControl == nil ? nil : probeRequestSession
        self.url = url
        self.label = label
        self.extraHeaders = extraHeaders
        self.byteCacheKey = prefetchEnabled && !isLive ? SourceByteCache.shared.key(for: url) : nil
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
        self.sequentialOnly = sequentialOnly
        self.chunkRequestTimeout = chunkRequestTimeout
        self.chunkMaxRetries = max(1, chunkMaxRetries)
        self.boundedInitialFetch = boundedInitialFetch.map { max(1, $0) }
        self.throttleKbps = AetherEngine.sourceThrottleKbpsForTesting
        self.backoffScale = AetherEngine.reconnectBackoffScaleForTesting
        self.pinIdleSeconds = AetherEngine.pinIdleSecondsForTesting ?? Self.pinIdleRepinSecondsDefault
        self.connStallTimeout = max(0.05, connStallTimeout)
        self.winHighWater = max(1, windowHighWater
            ?? (isLive ? Self.liveWinHighWaterDefault : Self.winHighWaterDefault))
        self.streamHighWater = max(1, streamHighWater ?? Self.streamHighWaterDefault)
        self.detourBlockIdleSeconds = detourIdleSeconds ?? Self.detourBlockIdleSecondsDefault
        self.heldConnectionEnabled = heldConnection
    }

    /// Slow-CDN simulation: hold delivered bytes to `throttleKbps` by sleeping the demux thread before the
    /// bytes reach the demuxer. No-op unless the test hook is set. Lock-guarded: prefetch and demux paths
    /// can both deliver. Sleeping here is consistent with the existing reconnect backoff on this thread.
    private func applyThrottle(deliveredBytes: Int) {
        guard throttleKbps > 0, deliveredBytes > 0 else { return }
        throttleLock.lock()
        let sleepNs = SourceThrottle.advance(
            vclockNs: &throttleVClockNs,
            nowNs: DispatchTime.now().uptimeNanoseconds,
            deliveredBytes: deliveredBytes,
            kbps: throttleKbps
        )
        throttleLock.unlock()
        if sleepNs > 0 { Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000) }
    }

    /// The caller's headers this request may carry, given where it is actually going.
    ///
    /// Not the same set for every target, and that is the point. `RedirectHeaderPolicy` (#126)
    /// keeps a media-server credential off a cross-origin redirect target, but it only ever ran on
    /// the redirect HOP. Once a session pinned that target (#12), every later request was built
    /// straight against it with the full header set, so the credential the hop had just stripped
    /// went to the edge on the next range anyway. Measured against a logging origin: the 302 hop
    /// arrived `auth=none`, and the post-seek request to the same pinned host 13 s later carried
    /// both `Authorization` and `X-Emby-Token`. One policy, applied where the request is built, so
    /// a pin cannot outflank it.
    private func headers(for target: URL?) -> [String: String] {
        RedirectHeaderPolicy.headersToReplay(
            extraHeaders: extraHeaders, originalURL: url, redirectURL: target ?? url)
    }

    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in headers(for: request.url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func open() throws {
        try probeControl?.check()
        guard let buf = av_malloc(Int(Self.avioBufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.avioBufferSize,
            0,
            opaque,
            readCallback,
            nil,
            seekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }

        context = ctx

        if sequentialOnly {
            // Sequential origin: the only trustworthy request shape is one unranged GET from
            // byte 0. Everything the branches below would issue on top - the suffix tail
            // prefetch, the optimistic `Range: bytes=0-` persistent open, the dedicated size
            // probe - is a ranged request the origin would answer with fabricated positions,
            // so none of it runs. `fileSize` stays -1: `isStreaming` routes read()/seek()
            // onto the forward-only streaming path and the #126 block below marks the pb
            // non-seekable.
            startStreamingDownload()
            _ = streamDataReady.wait(timeout: .now() + .seconds(15))
            try failIfStreamingRefused(fallbackStatus: 0)
        } else if prefetchEnabled {
            // #281: the parse seeks that follow this open are what the retained head exists for.
            winCond.lock()
            openPhaseActive = true
            winCond.unlock()
            // #551: bytes a host warmed for this source before anything asked to play it. When
            // they are here, this open owes the origin nothing for the span they cover.
            let warm = adoptPrewarmedSource()
            // #281: issued BEFORE the data connection so it overlaps the round trip that follows,
            // rather than queueing behind it. It asks for a suffix range, which needs no size and
            // therefore needs nothing this open has learned yet. A warm that already carries the
            // trailing object has no use for it.
            if warm?.tail == nil {
                startTailPrefetch()
            }
            // Playback path. The persistent connection's `Range: bytes=0-` request is itself
            // the size probe: its 206 Content-Range is folded into fileSize by
            // persistentReceivedResponse (issue #70), so the common case skips the dedicated
            // probeFileSize() round-trip (and its HEAD fallback, the request some origins 429).
            //
            // #551: a warm open moves that connection to the warm frontier rather than skipping it.
            // Playback needs the bytes behind the head either way, and issuing it here is what
            // overlaps its round trip with the parse that the warm bytes are already serving.
            let warmFrontier = warm?.head.end ?? 0
            let gotData: Bool
            let openPrefix: [UInt8]
            if let warm {
                // [MovieClaw P22] 接管的是字节缓存：解析马上要跳到续播点 / 索引，那里多半也在缓存里，
                // 这时在文件头后面开连接只会白下；读到缓存没有的位置时读取循环会按那个位置连
                if warmFrontier < warm.contentLength, !warmFromByteCache {
                    startPersistentConnection(at: warmFrontier, boundedTo: boundedInitialFetch)
                }
                // The open has its first bytes in hand, so there is nothing to wait for. Waiting
                // anyway would spend the round trip this whole feature exists to remove.
                gotData = true
                openPrefix = Array(warm.head.data.prefix(16))
            } else {
                // [MovieClaw P56] 第一个请求只要文件头那一小段（见 `openFirstRangeBytes`）；调用方指定了范围时照它
                let firstBound = boundedInitialFetch
                    ?? (AetherEngine.prioritizesIndexPrefetch && !isLive ? Self.openFirstRangeBytes : nil)
                winCond.lock()
                rangeVerdictPending = !isLive
                winCond.unlock()
                startPersistentConnection(at: 0, boundedTo: firstBound)
                var opened = awaitFirstPersistentData()
                // AE#693: one refusal is the origin's answer to that request, not yet to the
                // resource. The #378 path below takes a 401/403/404/410 here as final and settles
                // the session forward-only, which costs it every seek and the resume position. An
                // IPTV panel answered a ranged open 403 and the unranged GET right after it 200, and
                // ranged requests worked again later. Asking the same range once more decides it:
                // served, the source stays seekable; refused again, the #378 path runs as before.
                if !opened, !isLive, let refusal = refusalOfOpenConnection() {
                    EngineLog.emit(
                        "[AVIOReader] \(label) ranged open refused status=\(refusal) at offset 0; "
                        + "asking once more before settling the source forward-only (AE#693)",
                        category: .demux)
                    try probeControl?.check()
                    winCond.lock()
                    rangeVerdictPending = true
                    winCond.unlock()
                    startPersistentConnection(at: 0, boundedTo: firstBound)
                    opened = awaitFirstPersistentData()
                }
                gotData = opened
                openPrefix = firstWindowPrefix()
            }
            // AE#140: an HLS playlist URL misrouted onto the raw-byte live path. A live origin serves the
            // finite #EXTM3U body at HTTP 200 and closes the connection; the endless-feed reader then
            // re-fetches that body forever. Those reconnects look PRODUCTIVE (a full body at 200, and every
            // find_stream_info probe seek resets the unproductive streak via seekReconnect), so the #71
            // give-up counters never trip, avformat_open_input never returns, and load() hangs with no
            // terminal state. Fail closed here, before the reconnect loop is ever entered: a raw media
            // container never begins with '#' (TS syncs on 0x47; MP4/MKV open with binary box/EBML markers),
            // so an #EXTM3U prefix is an unambiguous misroute. The host is pointed at the HLS entry points.
            if isLive, gotData, Self.bodyBeginsWithHLSPlaylistTag(openPrefix) {
                EngineLog.emit("[AVIOReader] HLS playlist body on the raw live path (AE#140); stopping here. A URL source is routed onto the live ingest by load() (AE#363); a custom reader keeps the typed rejection.", category: .demux)
                markClosed()
                close()
                throw AVIOReaderError.hlsPlaylistOnRawLivePath
            }
            // AE#154: same classification on the non-live path. FFmpeg (--disable-network) can
            // neither probe an m3u8 behind a custom pb (no extension / MIME hint reaches the hls
            // probe) nor fetch a variant, so avformat_open_input dies with AVERROR_INVALIDDATA.
            // Fail typed instead; load() reroutes the URL onto the native remote-HLS bypass.
            if !isLive, gotData, Self.bodyBeginsWithHLSPlaylistTag(openPrefix) {
                EngineLog.emit("[AVIOReader] HLS playlist body on the VOD loopback path (AE#154); rerouting to the native remote-HLS bypass.", category: .demux)
                markClosed()
                close()
                throw AVIOReaderError.hlsPlaylistOnVODPath
            }
            var tookFallback = false
            if !isLive {
                // Atomically decide, under winCond, whether the optimistic connection resolved
                // a size; if not, abandon it (generation bump ignores a size landing in the
                // race window). fileSize is read under the lock because the delegate thread now
                // writes it (issue #70 review #4/#5).
                let (haveSize, abandoned, pumpStatus, caughtIgnoringRange) = resolveOptimisticOpen()
                abandoned?.cancelTransfer()
                abandoned?.releaseOriginTicket()
                var ignoredRangeLength = caughtIgnoringRange
                if let length = caughtIgnoringRange {
                    tookFallback = true
                    try probeControl?.check()
                    if confirmRangeIsIgnored(contentLength: length) == .honoured { ignoredRangeLength = nil }
                    try probeControl?.check()
                }
                if let ignoredRangeLength {
                    openForwardOnlyBecauseRangeIsIgnored(contentLength: ignoredRangeLength)
                    try failIfStreamingRefused(fallbackStatus: 0)
                } else if !haveSize {
                    tookFallback = true
                    // A 401/403/404/410 at byte 0, given twice (AE#693: once can be the moment's),
                    // is the origin's answer to the RESOURCE, not to the range form: a HEAD or a
                    // `bytes=0-1` from the same client is answered
                    // alike, and a size learned from either would only re-issue the refused range
                    // on the persistent path (which then dies after one retry with the status
                    // lost). Skip the ladder. The one request still worth making is the unranged
                    // GET below: an origin that refuses `Range` but serves a plain GET plays
                    // forward-only (which is what the ladder's streaming fallback did for it
                    // anyway), and one that refuses both fails typed with its status.
                    let pumpRefusal = (!gotData && Self.isResolvedExpiryStatus(pumpStatus)) ? pumpStatus : 0
                    if pumpRefusal != 0 {
                        EngineLog.emit(
                            "[AVIOReader] \(label) data connection refused status=\(pumpRefusal) at offset 0; "
                            + "skipping the size probes, trying one unranged GET",
                            category: .demux)
                        fileSize = -1
                    } else {
                        // The data connection resolved no size (no-length origin, a transient 429,
                        // slow headers, or an origin whose length only comes via HEAD). Fall back to
                        // the exact pre-#70 probe path (Range bytes=0- then HEAD, on its own
                        // connection and budget): it keeps seekability whenever a size is reachable
                        // and only streams on a genuinely length-less source, restoring main's
                        // resilience to all of those cases (issue #70 review #1/#3/#4).
                        EngineLog.emit("[AVIOReader] Data connection resolved no size, falling back to probe", category: .demux, level: .verbose)
                        fileSize = resolveInitialFileSize()
                        try probeControl?.check()
                    }
                    if isStreaming {
                        startStreamingDownload()
                        _ = streamDataReady.wait(timeout: .now() + .seconds(15))
                        try failIfStreamingRefused(fallbackStatus: pumpRefusal)
                    } else {
                        // Audit DMX-101: a cold open that was refused or slow never judged the
                        // origin's range support, and the probe above takes a 200's Content-Length
                        // for a size. This connection is then the first to see the origin's answer,
                        // so it gets the same head classification and confirmation.
                        winCond.lock()
                        rangeVerdictPending = true
                        winCond.unlock()
                        startPersistentConnection(at: 0)
                        let gotData = awaitFirstPersistentData()
                        if let caught = takeRangeVerdictAfterProbe() {
                            caught.abandoned?.cancelTransfer()
                            caught.abandoned?.releaseOriginTicket()
                            try probeControl?.check()
                            let confirmation = confirmRangeIsIgnored(contentLength: caught.contentLength)
                            try probeControl?.check()
                            if confirmation == .ignored {
                                openForwardOnlyBecauseRangeIsIgnored(contentLength: caught.contentLength)
                                try failIfStreamingRefused(fallbackStatus: 0)
                            } else {
                                startPersistentConnection(at: 0)
                                if !awaitFirstPersistentData() {
                                    EngineLog.emit("[AVIOReader] Persistent open (post-probe): no data within 15s, proceeding to read-loop reconnect", category: .demux)
                                }
                            }
                        } else if !gotData {
                            EngineLog.emit("[AVIOReader] Persistent open (post-probe): no data within 15s, proceeding to read-loop reconnect", category: .demux)
                        }
                    }
                }
            }
            // #551: a warm open asserts `gotData` instead of observing it, which is the whole point
            // (nothing waits on a first byte), and the cost is that the open-time refusal ladder
            // above never runs for it. A source whose token expired between the warm and the play
            // would then parse happily out of warm bytes and die several seconds later as an
            // untyped read failure instead of as the 401 it is.
            //
            // Checked, not waited for: if the refusal has already landed by the time the open gets
            // here, it is thrown typed exactly as the cold path throws it, and if it has not, the
            // read loop's ladder still ends the session correctly, just later and less precisely.
            // The alternative, waiting for the answer, is the round trip this feature removes.
            if warm != nil {
                winCond.lock()
                let refusal = (connEnded && Self.isResolvedExpiryStatus(connStatus)) ? connStatus : 0
                winCond.unlock()
                if refusal != 0 {
                    EngineLog.emit(
                        "[AVIOReader] \(label) the warm open found the source already refused: "
                        + "HTTP \(refusal); failing the open typed (#551)", category: .demux)
                    markClosed()
                    close()
                    throw AVIOReaderError.httpStatus(refusal)
                }
            }
            if !tookFallback && !gotData {
                // No first byte within 15s; read loop's stall/reconnect machinery takes over.
                EngineLog.emit("[AVIOReader] Persistent open: no first byte within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else {
            // Non-prefetch (still extraction / one-shot seekable): the size is needed up
            // front for SEEK_END and container index seeks, so keep the dedicated probe.
            fileSize = resolveInitialFileSize()
            if isStreaming {
                startStreamingDownload()
                _ = streamDataReady.wait(timeout: .now() + .seconds(15))
                try failIfStreamingRefused(fallbackStatus: 0)
            } else {
                if let data = fetchChunk(from: 0, size: chunkSize) {
                    currentBuffer = data
                    currentOffset = 0
                }
            }
        }

        // #126: a VOD source that finishes open() without a resolved size runs the forward-only
        // streaming reader; FFmpeg must not believe pb is seekable. With a seekable-flagged pb the
        // mov demuxer far-forward-skips to a tail moov (buffering the entire skipped span in RAM),
        // parses an index it can never rewind to, and every sample read then dies with "partial
        // file" / zero produced packets. Non-seekable pb makes moov-at-end fail cleanly at open
        // and keeps faststart files on honest sequential reads.
        if !isLive, isStreaming, let ctx = context {
            ctx.pointee.seekable = 0
        }
    }

    /// Block up to 15s for the persistent connection's first window bytes. The response
    /// (and thus any Content-Range size) has already been processed by the time data
    /// arrives. Demux thread, open-time only. Returns true if data arrived.
    private func awaitFirstPersistentData() -> Bool {
        winCond.lock()
        let deadline = Date(timeIntervalSinceNow: 15)
        while window.isEmpty && !connEnded && !isClosed {
            if !winCond.wait(until: deadline) { break }
        }
        let gotData = !window.isEmpty
        winCond.unlock()
        return gotData
    }

    /// The refusal status the current persistent connection ended on, nil when it did not end on one
    /// of the `isResolvedExpiryStatus` refusals. Demux thread, open-time only.
    private func refusalOfOpenConnection() -> Int? {
        winCond.lock()
        defer { winCond.unlock() }
        return (connEnded && Self.isResolvedExpiryStatus(connStatus)) ? connStatus : nil
    }

    /// The streaming GET was answered with a status instead of a body, or the ranged open was
    /// already refused with one and the unranged GET then delivered nothing either. Either way the
    /// demuxer would be handed an empty stream (or an error page) and report it as invalid data;
    /// close and fail typed instead, the way the AE#140/AE#154 classifications do, so load()
    /// publishes the status. `fallbackStatus` is the ranged open's refusal (0 when there was
    /// none): a hung-up unranged GET whose header never arrived within the open budget still
    /// carries the verdict the origin already gave. Demux thread, open-time only.
    /// AE#495: record a TLS trust refusal off any task of this reader, and name it once in the log.
    /// Everything else is left to the caller's own error handling; this only classifies.
    func noteTransportSecurityFailure(_ error: Error?) {
        guard let code = TransportSecurityFailure.code(in: error) else { return }
        streamLock.lock()
        let first = transportSecurityCode == 0
        transportSecurityCode = code
        streamLock.unlock()
        guard first else { return }
        EngineLog.emit(
            "[AVIOReader] \(label) TLS refused (NSURLError \(code)): "
            + "\(TransportSecurityFailure.sentence(for: code))",
            category: .demux)
    }

    private func failIfStreamingRefused(fallbackStatus: Int) throws {
        streamLock.lock()
        let refused = streamRefusedStatus
        let ended = streamEnded
        let empty = streamBuffer.isEmpty && streamBytesRead == 0
        streamLock.unlock()
        let status = refused != 0 ? refused : ((ended && empty) ? fallbackStatus : 0)
        // AE#495: a handshake the system refused outranks a status, because there was never a
        // response to carry one. Same reason this function exists at all: the demuxer would be handed
        // nothing and report invalid data.
        streamLock.lock()
        let tlsCode = transportSecurityCode
        streamLock.unlock()
        if tlsCode != 0 {
            EngineLog.emit(
                "[AVIOReader] \(label) source unreachable: \(TransportSecurityFailure.sentence(for: tlsCode)); "
                + "failing the open typed",
                category: .demux)
            markClosed()
            close()
            throw AVIOReaderError.transportSecurityFailed(code: tlsCode)
        }
        guard status != 0 else { return }
        EngineLog.emit(
            "[AVIOReader] \(label) source refused: HTTP \(status); failing the open typed",
            category: .demux)
        markClosed()
        close()
        throw AVIOReaderError.httpStatus(status)
    }

    /// Snapshot up to `max` leading bytes of the first window (open-time, before any read has consumed
    /// it, so `winStart == 0`). winCond-guarded like every other window access. Used only by the AE#140
    /// misroute check; returns [] if no data has arrived.
    private func firstWindowPrefix(max: Int = 16) -> [UInt8] {
        winCond.lock()
        defer { winCond.unlock() }
        let n = Swift.min(max, window.count)
        return window.prefix(n)
    }

    /// True when a body's leading bytes are the HLS playlist tag `#EXTM3U`, tolerating a UTF-8 BOM and
    /// leading ASCII whitespace. A raw media container never opens with '#', so this is an unambiguous
    /// signal that an m3u8 playlist was handed to the raw-byte reader (AE#140). Static + internal so the
    /// classifier is unit-tested without a live origin.
    static func bodyBeginsWithHLSPlaylistTag(_ bytes: [UInt8]) -> Bool {
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
            i += 1
        }
        let tag = Array("#EXTM3U".utf8)
        guard bytes.count - i >= tag.count else { return false }
        return Array(bytes[i..<(i + tag.count)]) == tag
    }

    /// Under a single winCond critical section: snapshot whether the optimistic open-time
    /// connection resolved a size (fileSize > 0, written by the delegate thread in
    /// persistentReceivedResponse), and if not, atomically abandon that connection so the
    /// open can fall back to the probe path. Bumping the generation inside the same lock as
    /// the read means a size that lands in the race window is ignored rather than racing a
    /// half-done teardown (issue #70 review #4/#5). Returns the session to cancel outside
    /// the lock. Demux thread, open-time only; leaves the AVIO context intact (unlike close()).
    /// `pumpStatus` is the HTTP status the abandoned connection was answered with (0 when no
    /// response arrived), so the caller can tell a refused resource from a length-less one.
    private func resolveOptimisticOpen() -> (haveSize: Bool, abandoned: (any PersistentTransfer)?,
                                             pumpStatus: Int, caughtIgnoringRange: Int64?) {
        winCond.lock()
        defer { winCond.unlock() }
        rangeVerdictPending = false
        let ignoredLength = rangeIgnoredAtOpenLength
        rangeIgnoredAtOpenLength = nil
        if fileSize > 0 { return (true, nil, connStatus, nil) }
        let status = connStatus
        connGeneration &+= 1
        let transfer = activeTransfer
        activeTransfer = nil
        window.removeAll()
        connEnded = true
        winCond.broadcast()
        return (false, transfer, status, ignoredLength)
    }

    /// Audit DMX-101: the verdict of the post-probe connection, which `resolveOptimisticOpen` does
    /// for the cold one. The size is already resolved by the probe, so nothing here keys off it:
    /// a caught origin gets its connection abandoned under the lock, with the window emptied, and
    /// a connection that was not caught is left running. The flag is cleared either way, so a
    /// refill or reconnect later in the session is never read as a verdict. Demux thread,
    /// open-time only.
    private func takeRangeVerdictAfterProbe() -> (contentLength: Int64, abandoned: (any PersistentTransfer)?)? {
        winCond.lock()
        defer { winCond.unlock() }
        rangeVerdictPending = false
        guard let contentLength = rangeIgnoredAtOpenLength else { return nil }
        rangeIgnoredAtOpenLength = nil
        connGeneration &+= 1
        let transfer = activeTransfer
        activeTransfer = nil
        window.removeAll()
        connEnded = true
        winCond.broadcast()
        return (contentLength, transfer)
    }

    private enum RangeConfirmation { case honoured, ignored }

    /// Audit DMX-101: the cold connection's 200 is one answer. Some CDNs send a 200 on a cache miss
    /// and a 206 for every request after it, so the verdict waits for a second, one byte request.
    /// Anything but a 206 that starts where asked (a 200, a refusal, a timeout, a misplaced range)
    /// leaves the origin judged as it was caught: a source that cannot address bytes. The body a
    /// 200 answer carries is cut after the one byte the request asked for (`ChunkFetchDelegate`).
    /// Demux thread, open-time only.
    private func confirmRangeIsIgnored(contentLength: Int64) -> RangeConfirmation {
        var request = URLRequest(url: requestURL())
        request.setValue("bytes=1-1", forHTTPHeaderField: "Range")
        let budget = min(10, chunkRequestTimeout)
        request.timeoutInterval = budget
        applyExtraHeaders(&request)
        do {
            let (_, response) = try syncRequest(request, budget: budget)
            guard let http = response as? HTTPURLResponse else { return .ignored }
            switch Self.rangeAnswer(http, requestedStart: 1, requestedEnd: 1) {
            case .honoured:
                EngineLog.emit(
                    "[AVIOReader] \(label) the origin answered the ranged open with a 200 "
                    + "(Content-Length \(contentLength)) but honours a one byte range; "
                    + "keeping the seekable path (audit DMX-101)", category: .demux)
                return .honoured
            case .overWide:
                // A 206 is the origin addressing bytes, however wide it answered.
                return .honoured
            default:
                return .ignored
            }
        } catch {
            return .ignored
        }
    }

    /// Audit DMX-101: an origin that cannot address bytes is played forward-only, exactly what
    /// `sequentialOnly` does by declaration: one unranged GET, `fileSize` unresolved so the pb is
    /// non-seekable (#126 below), and the window bounded by the streaming path's high water. The
    /// Content-Length it stated stays advisory and is what `AVSEEK_SIZE` answers, because FFmpeg
    /// estimates an MPEG-TS duration from the size and a length-less source reports none.
    /// Demux thread, open-time only.
    private func openForwardOnlyBecauseRangeIsIgnored(contentLength: Int64) {
        EngineLog.emit(
            "[AVIOReader] \(label) origin does not honour Range (Content-Length \(contentLength)); "
            + "playing forward-only from one unranged GET (audit DMX-101)", category: .demux)
        originIgnoresRange = true
        winCond.lock()
        fileSize = -1
        winCond.unlock()
        streamLock.lock()
        streamExpectedBytes = contentLength > 0 ? contentLength : -1
        streamLock.unlock()
        winCond.lock()
        let tailTask = tailPrefetchTask
        tailPrefetchTask = nil
        tailPrefetchInFlight = false
        winCond.unlock()
        tailTask?.cancel()
        startStreamingDownload()
        _ = streamDataReady.wait(timeout: .now() + .seconds(15))
    }

    // Close flags written on the teardown thread (markClosed / fullyClose) and read on the demux
    // thread plus the URLSession delegate threads (persistent-connection callbacks). Backed by a
    // leaf unfair lock so every access is synchronized; the bare Bools were a TSan-confirmed data
    // race (markClosed write vs appendPersistentData read). The lock is only ever held for the
    // get/set itself (never across another lock), so it cannot invert with winCond/streamLock.
    private let isClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isClosed: Bool {
        get { isClosedLock.withLock { $0 } }
        set { isClosedLock.withLock { $0 = newValue } }
    }
    private let isFullyClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isFullyClosed: Bool {
        get { isFullyClosedLock.withLock { $0 } }
        set { isFullyClosedLock.withLock { $0 = newValue } }
    }

    /// #112 round 8: the resolved total byte size (Content-Length / Content-Range), nil until known.
    /// Read under winCond like every other fileSize access. Used by `Demuxer.seekByteEstimate` for the
    /// single-probe byte-position fallback when a timestamp seek on an index-less container times out.
    var resolvedByteSize: Int64? {
        winCond.lock()
        defer { winCond.unlock() }
        return fileSize > 0 ? fileSize : nil
    }

    /// Wall-clock deadline for reads. Armed by `beginReadDeadline` to abort
    /// a `avformat_seek_file` that degrades into a linear scan when MKV Cues
    /// index is missing or past EOF (tens of minutes on remote sources).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read returned early due to deadline. `seekBounded` uses this
    /// since matroska may still return success with a partial index after abort.
    private(set) var readDeadlineFired = false

    /// Contract: `readDeadline`/`readDeadlineFired` are demux-thread-only. The
    /// still-extraction (FrameExtractor) reader satisfies this because it runs on one
    /// serial decode queue and `avioPrefetch:false` means no background prefetch thread
    /// touches them. A future profile that re-enables prefetch on a deadline-armed
    /// reader would need these guarded.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
        // Wake a read already parked in the forward-wait so it re-evaluates
        // against the new deadline instead of sleeping the full stall window.
        winCond.lock()
        winCond.broadcast()
        winCond.unlock()
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    private var readByteBudget = ReadByteBudget()
    var readByteBudgetExhausted: Bool { readByteBudget.exhausted }
    func beginReadByteBudget(_ bytes: Int64) { readByteBudget.begin(bytes) }
    func endReadByteBudget() { readByteBudget.end() }

    /// Deadline expired; latches `readDeadlineFired` at the check sites.
    private var readDeadlinePassedOrAborted: Bool { isPastReadDeadline }

    // Streaming task/session held so teardown can cancel and unblock streamDownloadSync.
    private var streamingSession: URLSession?
    private var streamingTask: URLSessionDataTask?
    // Suspend/resume calls are balanced under streamLock.
    private var streamingTaskSuspended = false

    /// Unblock a suspended av_read_frame and release the live network connection.
    /// Must be called BEFORE acquiring the demuxer's access lock.
    func markClosed() {
        isClosed = true
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
        streamLock.lock()
        let sTask = streamingTask
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        sTask?.cancel()
        winCond.lock()
        connGeneration &+= 1
        // #93/#96 residual: cancel the persistent Range GET here, not only in close(). markClosed is
        // the abort used by the #79 reopen path (dem.markClosed() to unblock a wedged read); leaving
        // its long-lived open-ended connection alive lets it keep draining the origin for the whole
        // reopen + first-read window, and that connection fair-shares the origin's bandwidth with the
        // fresh reader's cold read, which is exactly the per-connection starvation behind the residual
        // 15-30s cold reads. The AVIO context is untouched (close() still frees it); only the socket
        // is released. Grab under winCond, invalidate outside it (mirrors close()).
        let transfer = activeTransfer
        activeTransfer = nil
        connEnded = true
        // #281: a speculative fetch outlives nothing. Same reasoning as the persistent GET above:
        // an abandoned reader's in-flight request fair-shares the origin with the fresh reader's
        // cold read, which is the starvation this whole area keeps paying for.
        let tailTask = tailPrefetchTask
        tailPrefetchTask = nil
        tailPrefetchInFlight = false
        let cuesTask = cuesPrefetchTask   // [MovieClaw P49] 同尾部预读：被弃用的读取器不留在途请求
        cuesPrefetchTask = nil
        cuesPrefetchInFlight = false
        openPhaseActive = false
        winCond.broadcast()
        winCond.unlock()
        transfer?.cancelTransfer()
        transfer?.releaseOriginTicket()   // #377: the fresh reader asks for this slot next
        tailTask?.cancel()
        cuesTask?.cancel()
    }

    /// Free all resources. Separate from `markClosed` (step 1: unblock reads)
    /// because `isClosed` alone can't gate this: prior misuse of that guard
    /// silently leaked 64 MB current + 64 MB prefetch buffers on teardown.
    /// `isFullyClosed` is the idempotency latch for this step.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer, not original av_malloc ptr: FFmpeg can
            // realloc internally via ffio_set_buf_size.
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil

        bufferLock.lock()
        currentBuffer = Data()
        prefetchBuffer = nil
        bufferLock.unlock()

        detourCache.clear()

        streamLock.lock()
        streamEnded = true
        streamBuffer.removeAll()
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        streamDataReady.signal()
        // Covers a close() without prior markClosed().
        sTask?.cancel()
        sSession?.invalidateAndCancel()

        winCond.lock()
        connGeneration &+= 1
        connEnded = true
        let transfer = activeTransfer
        activeTransfer = nil
        window.removeAll()
        // #281: both spans hold real bytes (up to headSpanMaxBytes + tailPrefetchBytes), so they
        // are released with the window rather than living until the reader is deallocated.
        headSpan = Data()
        tailSpan = nil
        cuesSpan = nil   // [MovieClaw P49]
        cuesSpanFromHost = false   // [MovieClaw P58]
        openPhaseActive = false
        let tailTask = tailPrefetchTask
        tailPrefetchTask = nil
        tailPrefetchInFlight = false
        let cuesTask = cuesPrefetchTask
        cuesPrefetchTask = nil
        cuesPrefetchInFlight = false
        winCond.broadcast()
        winCond.unlock()
        tailTask?.cancel()
        cuesTask?.cancel()
        // #220: the shared session is never invalidated, so the transfer has to be cancelled
        // explicitly. Invalidating used to be what released this connection.
        transfer?.cancelTransfer()
        transfer?.releaseOriginTicket()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    // Internal (not fileprivate) so the #174 backpressure tests can drive the consumer
    // side directly; production entry stays the C read callback below.
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        if readDeadlinePassedOrAborted { readDeadlineFired = true; return -1 }
        guard let allowed = readByteBudget.allowance(size) else { return -1 }
        // Check usePersistentReader before isStreaming: live feeds without
        // Content-Length must use the reconnect-capable persistent path.
        let n: Int32
        if usePersistentReader { n = readPersistent(into: buf, size: allowed) }
        else if isStreaming { n = readStreaming(into: buf, size: allowed) }
        else { n = readSeekable(into: buf, size: allowed) }
        if n > 0 { applyThrottle(deliveredBytes: Int(n)) }
        readByteBudget.consumed(n)
        return n
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            // Abort a superseded / torn-down / past-deadline still read between chunk
            // fetches so it cannot park the decode queue (issue #27). Mirrors the
            // checks readPersistent already does at its loop head.
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            bufferLock.lock()
            let bufEnd = currentOffset + Int64(currentBuffer.count)
            let inRange = position >= currentOffset && position < bufEnd
            bufferLock.unlock()

            if inRange {
                bufferLock.lock()
                let offsetInBuffer = Int(position - currentOffset)
                let available = currentBuffer.count - offsetInBuffer
                let toCopy = min(available, requestSize - totalRead)

                currentBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: offsetInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                position += Int64(toCopy)
                totalRead += toCopy

                let consumed = Double(position - currentOffset) / Double(currentBuffer.count)
                let nextPrefetchOffset = currentOffset + Int64(currentBuffer.count)
                let needsPrefetch = prefetchEnabled && consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
                bufferLock.unlock()

                if needsPrefetch {
                    triggerPrefetch(from: nextPrefetchOffset)
                }
            } else {
                bufferLock.lock()
                if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                    position < prefetchOffset + Int64(prefetch.count) {
                    currentBuffer = prefetch
                    currentOffset = prefetchOffset
                    prefetchBuffer = nil
                    bufferLock.unlock()
                    continue
                }
                let hasPrefetchInFlight = isPrefetching
                bufferLock.unlock()

                if hasPrefetchInFlight {
                    _ = prefetchReady.wait(timeout: .now() + .seconds(15))
                    bufferLock.lock()
                    if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                        position < prefetchOffset + Int64(prefetch.count) {
                        currentBuffer = prefetch
                        currentOffset = prefetchOffset
                        prefetchBuffer = nil
                        bufferLock.unlock()
                        continue
                    }
                    bufferLock.unlock()
                }

                let fetchSize: Int
                if fileSize > 0 {
                    fetchSize = min(chunkSize, Int(fileSize - position))
                } else {
                    fetchSize = chunkSize
                }

                if fetchSize <= 0 { break }

                let fetched = fetchChunk(from: position, size: fetchSize)
                guard let data = fetched, !data.isEmpty else {
                    // An aborted fetch (supersede/close/deadline) must report a read
                    // error, not EOF (which would truncate the stream cleanly). issue #27.
                    if isClosed || readDeadlinePassedOrAborted {
                        if readDeadlinePassedOrAborted { readDeadlineFired = true }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    // Audit DMX-10: nil is a transport failure short of a known size, which is the
                    // same loss #25 stopped reporting as EOF on the persistent path; a probe that
                    // read it as end-of-file reported a truncated duration instead of failing.
                    if fetched == nil, fileSize > 0 {
                        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eio
                    }
                    // Empty = 2xx with no body (would loop forever otherwise).
                    break
                }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Streaming Read (sequential GET)

    private func readStreaming(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            streamLock.lock()
            let posInBuffer = Int(position - streamBytesRead)
            let available = streamBuffer.count - posInBuffer
            let ended = streamEnded
            streamLock.unlock()

            if available > 0 && posInBuffer >= 0 {
                let toCopy = min(available, requestSize - totalRead)

                streamLock.lock()
                streamBuffer.copyBytes(to: buf.advanced(by: totalRead), from: posInBuffer, count: toCopy)
                streamLock.unlock()

                position += Int64(toCopy)
                totalRead += toCopy

                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer.dropFirst(trimAmount)
                    streamBytesRead += Int64(trimAmount)
                }
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended, streamBuffer.count < streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
            } else if ended {
                break
            } else {
                // Resume before waiting: a suspended task would never deliver.
                streamLock.lock()
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        if totalRead > 0 { return Int32(totalRead) }
        streamLock.lock()
        let refusedStatus = streamRefusedStatus
        streamLock.unlock()
        if refusedStatus != 0 {
            // The response header arrived after open()'s budget: still a refusal, not end-of-media.
            EngineLog.emit(
                "[AVIOReader] \(label) streaming GET refused status=\(refusedStatus) after open; reporting EIO",
                category: .demux)
            return FFmpegErr.eio
        }
        streamLock.lock()
        let ended = streamEnded
        let failed = streamFailed
        let cause = streamFailureCause
        let received = streamBytesRead + Int64(streamBuffer.count)
        let expected = streamExpectedBytes
        streamLock.unlock()
        // This path cannot be resumed at an offset, so a stalled-out wait, a transport error or a
        // body that ended short of its advisory length is a LOST source: report EIO so the pump
        // exits on a read error the session can surface. EOF here would read as end-of-media,
        // which the consumer deliberately never retries. Audit DMX-6: this held for the
        // sequential origin only, and a length-less source ended its film early on a Wi-Fi drop.
        if !ended || failed || (expected > 0 && received < expected) {
            EngineLog.emit(
                "[AVIOReader] \(label) stream \(!ended ? "stalled out" : failed ? "failed" : "ended short") at "
                + "\(received)\(expected > 0 ? "/\(expected)" : "") bytes"
                + (cause.map { " (\($0))" } ?? "") + "; reporting EIO",
                category: .demux
            )
            return FFmpegErr.eio
        }
        return FFmpegErr.eof
    }

    // MARK: - Persistent Read (single forward-streaming connection)

    /// Sliding-window read over a single long-lived Range: bytes=<offset>- connection.
    /// State machine: inside window -> copy; before window -> backward reconnect;
    /// position >= fileSize -> EOF (only EOF path); far forward -> reconnect;
    /// just ahead + live conn -> wait; conn ended -> reconnect + backoff.
    /// Fetch failures reconnect at the frontier, never collapse to AVERROR_EOF (AetherEngine#25).
    private func readPersistent(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0
        sweepIdleDetourBlocks()

        // #93 restart latency: accumulate where THIS read spends its time; one summary line fires
        // on completion when the whole call exceeded the threshold (see SlowReadDiagnostics).
        let readStart = DispatchTime.now()
        var diag = SlowReadDiagnostics()
        // #281 retest: fixed once per read, so a loop that wakes repeatedly cannot keep extending
        // its own patience for the speculative fetch.
        var tailWaitDeadline: Date?
        var cuesWaitDeadline: Date?   // [MovieClaw P49] 同上，给在途的索引提前取
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        // #93/#96 residual: count the reconnect AND time the synchronous connect path it drives
        // (the old session's invalidateAndCancel + new task setup, all on this demux thread), so a
        // slow read that sinks its time into reconnecting names it as `connect=` instead of `unaccounted=`.
        func timedReconnect(seek: Bool, at offset: Int64) {
            diag.recordReconnect()
            let connectStart = DispatchTime.now()
            if seek { seekReconnect(at: offset) } else { startPersistentConnection(at: offset) }
            diag.recordConnect(ms: msSince(connectStart))
        }
        winCond.lock()
        let diagEntryPosition = position
        let diagGenAtStart = connGeneration
        let diagDropsAtStart = staleGenDroppedBytes
        winCond.unlock()
        defer {
            let elapsedMs = msSince(readStart)
            if elapsedMs >= diag.thresholdMs {
                winCond.lock()
                let genAtEnd = connGeneration
                let dropped = staleGenDroppedBytes - diagDropsAtStart
                winCond.unlock()
                diag.recordStaleGenerationDrop(bytes: dropped)
                let budget = OriginRequestBudget.shared.snapshot(for: requestURL()).map {
                    SlowReadDiagnostics.OriginBudgetLine(
                        inflight: $0.inflight, peak: $0.peakInflight,
                        limit: $0.limit, refusals: $0.refusals)
                }
                if let line = diag.line(elapsedMs: elapsedMs, offset: diagEntryPosition,
                                        generationSpan: (diagGenAtStart, genAtEnd),
                                        origin: budget) {
                    EngineLog.emit(line, category: .demux)
                }
            }
        }

        while totalRead < requestSize {
            diag.recordIteration()
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            // #93/#96 residual: time the loop-head lock acquisition. A delegate thread holding winCond
            // across its window copy blocks the read HERE with nothing to show for it, so this turns
            // that invisible wait into `lockWait=`.
            let lockWaitStart = DispatchTime.now()
            winCond.lock()
            diag.recordLockWait(ms: msSince(lockWaitStart))

            // #281: bytes already in hand beat every network path below, so this is checked before
            // any of them, and before the reconnect decision that a dead connection would force.
            // Only when the live window cannot serve the position: a window hit is the cheap path
            // and stays first.
            let spanPos = position
            let windowCanServe = spanPos >= winStart && spanPos < winStart + Int64(window.count)

            // #281 retest: the head has now done the job it was kept past the parse for. This read
            // is not at the head, so playback has either moved beyond it or started nowhere near it,
            // and holding megabytes for a return that is not coming is just footprint.
            //
            // AE#585: unless the host is running its index pass, where neither half of that premise
            // holds. The cue prewarm seeks to the middle for the container's index and the cursor is
            // reset to zero straight after, so a drop here throws the head away one read before
            // playback asks for exactly those bytes.
            if !openPhaseActive, !indexPassActive, !headSpan.isEmpty,
               spanPos < 0 || spanPos >= Int64(headSpan.count) {
                headSpan = Data()
            }
            // [MovieClaw P49] 同文件头：索引只在开流与索引预热时读，之后第一次读不到它就放掉
            if !openPhaseActive, !indexPassActive, let span = cuesSpan, !span.covers(spanPos) {
                cuesSpan = nil
                cuesSpanFromHost = false   // [MovieClaw P58]
            }
            // [MovieClaw P58] 服务端给的精简索引覆盖这个位置时，窗口里就算有原字节也从它给
            let hostCuesHit = cuesSpanFromHost && cuesSpan?.covers(spanPos) == true
            if !windowCanServe || hostCuesHit, !headSpan.isEmpty || tailSpan != nil || cuesSpan != nil,
               let served = serveFromResidentSpansLocked(into: buf.advanced(by: totalRead),
                                                        maxLen: requestSize - totalRead,
                                                        at: spanPos) {
                let n = served.bytes
                // Once per span per open: the round trip that did not happen, named. Every serve
                // after the first says nothing new and would only make the log expensive.
                var spanLine: String? = nil
                switch served {
                // Two lines, not one, because they are two different findings: the parse's return to
                // the head was already true in 6.5.2, playback's first read being served is what the
                // head living past `markOpenPhaseFinished` added. One line could not tell a reporter
                // which of the two they were looking at.
                case .head where !openPhaseActive && !headSpanPlaybackServeLogged:
                    headSpanPlaybackServeLogged = true
                    spanLine = "[AVIOReader] \(label) retained file head served playback's first read"
                        + " at \(spanPos); no reconnect for it"
                case .head where !headSpanServeLogged:
                    headSpanServeLogged = true
                    spanLine = "[AVIOReader] \(label) retained file head served the return to \(spanPos)"
                        + "; no reconnect for it"
                case .tail where !tailSpanServeLogged:
                    tailSpanServeLogged = true
                    spanLine = "[AVIOReader] \(label) tail prefetch served the read at \(spanPos)"
                        + "; no reconnect for it"
                case .cues where !cuesSpanServeLogged:
                    cuesSpanServeLogged = true
                    spanLine = cuesSpanFromHost
                        ? "[AVIOReader] \(label) [MovieClaw P58] 服务端给的精简索引（\(cuesSpan?.data.count ?? 0) 字节）"
                            + "接住了 \(spanPos) 处的读取，原索引不用下载"
                        : "[AVIOReader] \(label) [MovieClaw P49] 提前取的那段接住了 \(spanPos) 处的读取，"
                            + "不用另发请求"
                default:
                    break
                }
                position = spanPos + Int64(n)
                let headContinuation = headContinuationAfterIndexLocked()   // [MovieClaw P56]
                // [MovieClaw P58] 读到服务端精简索引的末尾就先把这次读交出去（短读）：它是一整个 Cues 元素，解复用器读完
                // 不会再往后要。接着凑满这次读会在精简版后面另起连接，读的是原索引余下那些用不上的字节，还掐掉正在读文件头的
                // 连接（模拟器 6 Mbit/s 实测：白下约 0.3 MB，回到文件头时又重连一次）
                var hostCuesEnded = false
                if case .cues = served, cuesSpanFromHost, position == cuesSpan?.end { hostCuesEnded = true }
                winCond.broadcast()
                winCond.unlock()
                if let spanLine { EngineLog.emit(spanLine, category: .demux) }
                totalRead += n
                diag.recordDetourServe(ms: 0, fetched: false)
                if let headContinuation { timedReconnect(seek: false, at: headContinuation) }
                if hostCuesEnded { return Int32(totalRead) }
                // No ladder reset, and no phase either (#410): these spans are bytes fetched earlier
                // and kept, and the line above says so itself ("no reconnect for it"). Clearing the
                // streaks here is the #380 window-serve mistake in the branch that runs FIRST, before
                // every network path, and unlike the detour it is not taken out of service on a metered
                // origin, so the parse's return to the head could hold a refusing origin at streak=0.
                // Reporting `.flowing` off the same serve made the host read a delivering source out of
                // read-ahead the origin paid for before it died.
                continue
            }

            // #281 retest: this read wants bytes the speculative fetch is on the wire for RIGHT NOW.
            // Reconnecting here is what made that fetch pure cost in the field: the demuxer arrives
            // microseconds after the data connection's first byte, so the fetch, which pays the same
            // round trip plus a body, has never landed yet. Waiting is bounded by what a round trip
            // against this origin was measured to cost, so it can never be the more expensive choice.
            if !windowCanServe, tailPrefetchInFlight, isInTailPrefetchRangeLocked(spanPos) {
                let fixed = tailWaitDeadline ?? Date(
                    timeIntervalSinceNow: max(0, tailPrefetchWaitBudget()
                        - Double(DispatchTime.now().uptimeNanoseconds
                                 - tailPrefetchStartedAt.uptimeNanoseconds) / 1_000_000_000))
                tailWaitDeadline = fixed
                let deadline = prefetchWaitDeadlineLocked(fixed: fixed, lastProgress: tailPrefetchLastProgressAt)
                if Date() < deadline {
                    let waitStart = DispatchTime.now()
                    _ = winCond.wait(until: min(deadline, readDeadline))
                    winCond.unlock()
                    diag.recordTailWait(ms: msSince(waitStart))
                    continue
                }
            }

            // [MovieClaw P49] 同上：这次读的正是在途的索引提前取，等它落地，不另发请求、不掐断读文件头的连接。
            // 上限与尾部预读同一个道理：比从这里重连多等不了多少
            if !windowCanServe, cuesPrefetchInFlight, let range = cuesPrefetchRange, range.contains(spanPos) {
                let fixed = cuesWaitDeadline ?? Date(
                    timeIntervalSinceNow: max(0, tailPrefetchWaitBudget()
                        - Double(DispatchTime.now().uptimeNanoseconds
                                 - cuesPrefetchStartedAt.uptimeNanoseconds) / 1_000_000_000))
                cuesWaitDeadline = fixed
                let deadline = prefetchWaitDeadlineLocked(fixed: fixed, lastProgress: cuesPrefetchLastProgressAt)
                if Date() < deadline {
                    let waitStart = DispatchTime.now()
                    _ = winCond.wait(until: min(deadline, readDeadline))
                    winCond.unlock()
                    diag.recordTailWait(ms: msSince(waitStart))
                    continue
                }
            }

            // Genuine EOF: the only path that returns AVERROR_EOF, and it is decided BEFORE any
            // reconnect, because a position at or past the last byte has nothing to connect for.
            // It used to sit below the reconnect, so a read at exactly `fileSize` opened
            // `bytes=<fileSize>-` first: an empty 206 whose reconnect reset `winStart` past the
            // end and dropped a window the parse was still reading. Skipped for live, where the
            // length is not authoritative.
            if !isLive, fileSize > 0, position >= fileSize {
                winCond.unlock()
                return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
            }

            // #220: `connEndedByBackpressure` is excluded on purpose. This reconnects at the
            // READ position, which resets winStart and drops the window, so a backpressure
            // end would re-fetch up to winHighWater of already-resident bytes on every
            // cycle. That case refills at the frontier once the consumer draws down to low
            // water (or immediately once the window is empty), keeping every delivered byte.
            //
            // `windowCanServe` is excluded for exactly the same reason, and the omission was
            // measurable: a range delivered IN FULL also clears `activeTransfer`, so a consumer
            // slower than the transfer (the parse pass, which reads one 256 KB AVIO buffer at a
            // time) reached this branch with the rest of the range still resident and re-fetched
            // it. Measured against a Range-logging origin, a 764450 B trailing `moov` cost three
            // connections and 1506918 delivered bytes, 1.97x what was read. Serving what is in
            // hand first also lets the #220 frontier refill below run, which it could not while
            // this branch preempted it on every completed range.
            //
            // A connection that ended in ERROR without delivering a single byte of its
            // generation is excluded too: this branch reconnects via seekReconnect, which
            // clears the unproductive streak and applies no backoff, so an origin refusing
            // every request (e.g. a connection-capped panel answering 500) turned into an
            // unbounded reconnect spiral at ~15 connections/s. Falling through reaches the
            // ended-connection ladder below: status accounting, Retry-After, backoff,
            // `.reconnecting`, bounded give-up. Planned ends stay here — a completed range
            // (connEndedAtRangeEnd) and a hard-cap end delivered their bytes, and any
            // generation that delivered at least one byte keeps the fast path.
            let endedInError = connEnded && !connEndedAtRangeEnd && !connEndedByBackpressure
                && !connFirstDataSeen
            if activeTransfer == nil, !connEndedByBackpressure, !windowCanServe, !endedInError {
                let target = position
                // [MovieClaw P22] 本来要为这个位置发请求：字节缓存里有就从本机给
                let cached = serveFromByteCache(into: buf.advanced(by: totalRead),
                                                maxLen: requestSize - totalRead, at: target)
                if cached > 0 {
                    position = target + Int64(cached)
                    winCond.broadcast()
                    winCond.unlock()
                    totalRead += cached
                    continue
                }
                winCond.unlock()
                timedReconnect(seek: true, at: target)
                continue
            }

            let curPosition = position

            if curPosition < winStart {
                winCond.unlock()
                // [MovieClaw P22] 回跳先查字节缓存（MP4 解析在索引与数据间来回跳、往回拖动）：命中不必取 4 MB 零散块
                let cachedBack = serveFromByteCache(into: buf.advanced(by: totalRead),
                                                    maxLen: requestSize - totalRead, at: curPosition)
                if cachedBack > 0 {
                    winCond.lock(); position = curPosition + Int64(cachedBack); winCond.broadcast(); winCond.unlock()
                    totalRead += cachedBack
                    continue
                }
                // Backward random-access read (MP4 parse ping-pong, or a large backward scrub).
                // Serve via the pooled detour cache so the anchored streaming connection is NOT
                // torn down (the reconnect storm + origin 429, AetherEngine#69).
                // [MovieClaw P55] 线路慢到一整块在限时内到不齐时不走旁路（见 `detourFitsLink`）
                if detourEligible, detourFitsLink(at: curPosition) {
                    // Re-anchor the streaming connection once detour reads have turned sequential
                    // past the threshold (playback resumed here), so steady playback returns to
                    // the cheap window path instead of fetching 4 MB blocks forever.
                    if curPosition == detourRunNextExpected && detourRunBytes >= Self.detourReanchorBytes {
                        detourResetRun()
                        sweepIdleDetourBlocks(force: true)
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                    let detourStart = DispatchTime.now()
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: true) {
                    case .served(let n, let fetched):
                        diag.recordDetourServe(ms: msSince(detourStart), fetched: fetched)
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        // Only a serve that crossed the network is progress against the origin. The
                        // resident-block hit is the detour twin of the window serve #380 fixed: it
                        // hands back read-ahead already paid for, so resetting the ladders on it lets
                        // a parser ping-ponging through a cached region hold a refusing origin at
                        // streak=0 for as long as the blocks last.
                        if fetched {
                            unproductiveReconnects = 0
                            rateLimitStreak = 0
                            emitNetworkPhase(.flowing)   // the fetch crossed the network: the origin is serving (#85/#410)
                        }
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited(let retryAfter):
                        // #93/#96: account the (throttled) fetch attempt's time so it leaves `unaccounted`.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        // Origin is throttling the detour fetch too (#71). Back off in place and
                        // RETRY the detour fetch; do NOT open a fresh connection (that re-enters
                        // the 429 churn the cache exists to remove). Give up cleanly at the cap.
                        if recordRateLimitAndShouldGiveUp() {
                            EngineLog.emit("[AVIOReader] Detour rate-limit gave up at offset \(curPosition) (\(rateLimitStreak) consecutive rate-limited)", category: .demux)
                            emitNetworkPhase(.exhausted)   // ladder spent on the detour arm too (#410)
                            return totalRead > 0 ? Int32(totalRead) : -1
                        }
                        // #392: the detour fetches through the same pinned target, and this arm
                        // carried no pin rung at all, so a pin whose lease had died could only be
                        // given up on here (a failed read), never re-resolved. It is also the arm a
                        // backward read after a long pause lands on, i.e. exactly when a lease has
                        // died. Same decision as both reconnect ladders, in the same one place.
                        // #410: a metered detour fetch is a source-connection problem by the same
                        // definition as a metered reconnect, and it is the arm that carries a throttling
                        // origin (#69/#71), so leaving it silent hid exactly the case `.stalled` was added
                        // for. The ladder was already charged above; only the axis was missing.
                        emitNetworkPhase(.reconnecting)
                        let repinned = dropPinIfTheRefusalCallsForIt(isRateLimited: true)
                        let backoffStart = DispatchTime.now()
                        backoffBeforeReconnect(streak: repinned ? 0 : rateLimitStreak, retryAfter: retryAfter)
                        diag.recordBackoff(ms: msSince(backoffStart))
                        continue
                    case .miss:
                        // #93/#96: this is where the residual cold read actually lived. A starved fetch
                        // rode its budget then missed; account that time (else it hides in `unaccounted`)
                        // before falling through to the rescue reconnect that serves in ~30-190ms.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
                        if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }
                        // Hard transport failure: degrade to the OLD single-reconnect behavior.
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            let posInWindow = Int(curPosition - winStart)
            let available = window.count - posInWindow
            if available > 0 {
                let copyNow = min(available, requestSize - totalRead)
                window.copyBytes(to: buf.advanced(by: totalRead), from: posInWindow, count: copyNow)
                position = curPosition + Int64(copyNow)
                totalRead += copyNow
                trimWindowLocked()
                // "Real progress" is the CURRENT generation having delivered — draining read-ahead
                // is not. An unguarded reset here ran in the same iteration as the faulted-refill
                // decision below, so a connection-capped origin refusing every replacement was
                // charged streak=1 forever while the runway drained (field trace: a post-pause 509
                // storm held streak=1 across 4 MB of served reads, and the bounded give-up and the
                // re-resolve rung were both unreachable until the window hit empty).
                if connFirstDataSeen {
                    unproductiveReconnects = 0      // real progress
                    rateLimitStreak = 0             // real progress clears the 429 give-up streak (#71)
                    emitNetworkPhase(.flowing)      // recovered: source delivering again (#85/#410)
                }
                // No flow installed and the consumer has drawn down to low water: request at the
                // frontier. #220/#310 built this for PLANNED ends (a range delivered in full, a
                // high-water end); #309 made it the rule for every reason there is no flow, because
                // the exception was the second half of that report. A generation that ended in
                // FAULT was replaced only once the window hit EMPTY, so the reader spent its whole
                // read-ahead first and playback rejoined the clock with a burst (the field trace's
                // +17 MB interval and 389 dropped frames). Which reason it was still decides the
                // POLICY: a planned end costs nothing, a fault pays the ladder
                // (`chargeFaultedRunwayRefill`).
                //
                // Requesting at the frontier rather than at the read position keeps every delivered
                // byte. A frontier AT the end of the file is not a frontier: the range that ended
                // was the last one, and requesting `bytes=<fileSize>-` asks for nothing: origins
                // answer it with an empty 206, the reconnect resets `winStart` past the last byte,
                // and the window that was about to be read is dropped for it. On a trailing `moov`
                // that turned one connection into three. Live keeps the old behaviour: its length is
                // not authoritative and its end moves.
                var refillFrom: Int64? = nil
                var refillFaulted = false
                var refillStatus = 0
                var refillRetryAfter: TimeInterval = 0
                let undrained = window.count - max(0, Int(position - winStart))
                let frontier = winStart + Int64(window.count)
                if activeTransfer == nil, undrained <= Self.winLowWater,
                   isLive || fileSize <= 0 || frontier < fileSize,
                   !indexPrefetchHoldsHeadLocked() {   // [MovieClaw P56]
                    if connEndedAtRangeEnd || connEndedByBackpressure {
                        refillFrom = frontier
                    } else if connEnded, Date() >= nextFaultedRefillAt {
                        refillFrom = frontier
                        refillFaulted = true
                        refillStatus = connStatus
                        refillRetryAfter = connRetryAfter
                    }
                }
                winCond.broadcast()
                winCond.unlock()
                if let refillFrom {
                    if !refillFaulted || chargeFaultedRunwayRefill(at: refillFrom, ahead: undrained,
                                                                   status: refillStatus,
                                                                   retryAfter: refillRetryAfter) {
                        timedReconnect(seek: false, at: refillFrom)
                    }
                }
                continue
            }

            let frontier = winStart + Int64(window.count)
            let ended = connEnded
            let endedByBackpressure = connEndedByBackpressure
            let endedByRangeEnd = connEndedAtRangeEnd
            let status = connStatus
            let retryAfter = connRetryAfter

            if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {
                winCond.unlock()
                // [MovieClaw P22] 远跳先查字节缓存：命中就从本机给，读到缓存尽头时再走下面的重连
                let cachedAhead = serveFromByteCache(into: buf.advanced(by: totalRead),
                                                     maxLen: requestSize - totalRead, at: curPosition)
                if cachedAhead > 0 {
                    winCond.lock(); position = curPosition + Int64(cachedAhead); winCond.broadcast(); winCond.unlock()
                    totalRead += cachedAhead
                    continue
                }
                // Far-forward seek. Serve from the detour cache ONLY if the block is already
                // resident (e.g. the moov region the parser revisits); a genuine forward scrub
                // misses and re-anchors the streaming window there, never chunk-serving forever.
                if detourEligible {
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: false) {
                    case .served(let n, _):
                        diag.recordDetourServe(ms: 0, fetched: false)   // resident-only path
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        // No ladder reset and no phase: `allowFetch: false` cannot have crossed the
                        // network, so this serve says nothing about an origin that is refusing
                        // (#380/#410).
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited, .miss:
                        break   // allowFetch:false never rate-limits; a miss falls through to reconnect
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            if !ended {
                // Wait for the live connection to fill forward. A false return
                // means connStallTimeout elapsed with no data (socket stall).
                let waitStart = DispatchTime.now()
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: connStallTimeout), readDeadline))
                winCond.unlock()
                diag.recordStallWait(ms: msSince(waitStart), signaled: signaled)
                // Check deadline before stall handling to avoid misrouting a
                // deadline wake as a socket stall (which would reconnect).
                if isPastReadDeadline { continue }
                if !signaled {
                    if recordReconnectAndShouldGiveUp() {
                        EngineLog.emit("[AVIOReader] \(label) stall gave up at offset \(frontier) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                        emitNetworkPhase(.exhausted)   // ladder spent; the reopen owns recovery, the source is still down (#410)
                        if isLive {
                            return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eio
                        }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    EngineLog.emit("[AVIOReader] \(label) stall at offset \(frontier), reconnecting", category: .demux)
                    lastUnplannedReconnectAt = Date()
                    emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
                    let backoffStart = DispatchTime.now()
                    backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: 0)
                    diag.recordBackoff(ms: msSince(backoffStart))
                    timedReconnect(seek: false, at: frontier)
                }
                continue
            }

            // Connection ended before EOF; reconnect at frontier. Honour Retry-After when rate-limited.
            winCond.unlock()
            // #220/#310: we ended it ourselves at high water and the consumer has now emptied
            // the window (the low-water refill normally fires first; this is the backstop for
            // a position that jumped to the frontier). Re-request immediately: no backoff (the
            // origin never misbehaved), no streak charge (this is not an unproductive
            // reconnect), no `.reconnecting` phase and no `lastUnplannedReconnectAt` (nothing
            // here looks like a transcode respawn to the host). Without this the end would
            // spend the give-up budget on a healthy link.
            if endedByBackpressure {
                EngineLog.emit(
                    "[AVIOReader] \(label) window drained after backpressure end; re-requesting at \(frontier)",
                    category: .demux)
                timedReconnect(seek: false, at: frontier)
                continue
            }
            // #220: the range was delivered in full and the window has now drained, which is
            // the ordinary way a bounded read moves forward. No backoff and no streak charge:
            // nothing failed, and spending the give-up budget on range boundaries would kill
            // the reader on a healthy link.
            if endedByRangeEnd {
                timedReconnect(seek: false, at: frontier)
                continue
            }
            // A 429/503/509 is rate limiting, not a dead source: drive give-up + backoff off the
            // rate-limit streak, which (unlike unproductiveReconnects) survives the seekReconnect
            // that parse seeks fire, so a throttled origin fails cleanly instead of looping (#71).
            let isRateLimited = Self.isRateLimitStatus(status)
            let giveUp = isRateLimited ? recordRateLimitAndShouldGiveUp()
                                       : recordReconnectAndShouldGiveUp(status: status)
            if giveUp {
                let streakDesc = isRateLimited ? "\(rateLimitStreak) consecutive rate-limited" : "\(unproductiveReconnects) unproductive"
                EngineLog.emit("[AVIOReader] \(label) reconnect exhausted at offset \(frontier) status=\(status) (\(streakDesc))\(isLive ? " [live source lost]" : "")", category: .demux)
                emitNetworkPhase(.exhausted)   // ladder spent; the reopen owns recovery, the source is still down (#410)
                if isLive {
                    return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eio
                }
                return totalRead > 0 ? Int32(totalRead) : -1
            }
            let backoffStreak = isRateLimited ? rateLimitStreak : unproductiveReconnects
            EngineLog.emit("[AVIOReader] \(label) conn ended at offset \(frontier) status=\(status), reconnecting (streak=\(backoffStreak) retryAfter=\(retryAfter)s)", category: .demux)
            lastUnplannedReconnectAt = Date()
            emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
            let repinned = dropPinIfTheRefusalCallsForIt(isRateLimited: isRateLimited)
            let backoffStart = DispatchTime.now()
            // #392: a pin dropped for idleness sends this attempt to the SOURCE, which has refused
            // nothing, so the exponential pacing charged against the target that did refuse is not
            // its debt. A server-sent Retry-After still applies: that is the origin's own ask, and
            // the source belongs to the same origin.
            backoffBeforeReconnect(streak: repinned ? 0 : backoffStreak, retryAfter: retryAfter)
            diag.recordBackoff(ms: msSince(backoffStart))
            timedReconnect(seek: false, at: frontier)
        }

        return Int32(totalRead)
    }

    /// Drop consumed bytes in ~winTrimBatch steps to avoid O(n^2) memmove.
    /// MUST use `subdata` (not `removeFirst`): removeFirst only advances the slice's
    /// lower bound but backing storage grows with count.setter in appendPersistentData,
    /// leaking ~14 MB/s on 80 Mbps remux (AetherEngine#31). subdata re-bases to compact
    /// storage. Caller holds `winCond`.
    private func trimWindowLocked() {
        let behind = Int(position - winStart)
        let dropThreshold = Self.winLookback + Self.winTrimBatch
        if behind > dropThreshold {
            let drop = behind - Self.winLookback
            window.dropFirst(drop)
            winStart += Int64(drop)
        }
    }

    /// Intentional reconnect for a seek; clears the unproductive streak.
    private func seekReconnect(at offset: Int64) {
        unproductiveReconnects = 0
        bytesAtLastReconnect = cumulativeBytesFetched
        // A reposition starts a new lineage: the faulted-refill pacing belongs to the frontier
        // it was charged at, and holding a seek's refill to it would pace a healthy target.
        winCond.lock()
        nextFaultedRefillAt = .distantPast
        winCond.unlock()
        startPersistentConnection(at: offset)
    }

    /// Increments the unproductive-reconnect streak (resets if progress exceeded
    /// `minReconnectProgress`). Returns true when the cap is hit. Demux-thread-only.
    private func recordReconnectAndShouldGiveUp(status: Int = 0) -> Bool {
        let now = cumulativeBytesFetched
        if now - bytesAtLastReconnect >= Self.minReconnectProgress {
            unproductiveReconnects = 0
        } else {
            unproductiveReconnects += 1
        }
        bytesAtLastReconnect = now
        // Hard 4xx/5xx (not the rate-limit statuses, which are metering) on a source that
        // has never delivered a byte = server-side failure (e.g. Jellyfin 500 after
        // transcode-failure latency ~15-20s/attempt). One retry, then out.
        let isHardError = status >= 400 && !Self.isRateLimitStatus(status)
        if now == 0 && isHardError {
            return unproductiveReconnects > 1
        }
        // Dead-on-arrival sources (never produced data) get a reduced budget;
        // sources that ever produced data keep the full budget for mid-stream resilience.
        let cap = now == 0
            ? Self.reconnectMaxUnproductiveNeverProductive
            : Self.reconnectMaxUnproductive
        return unproductiveReconnects > cap
    }

    // 4 attempts ride out a transient transcode spin-up (~10-15s with backoff)
    // without grinding a dead tuner for minutes.
    private static let reconnectMaxUnproductiveNeverProductive = 4

    /// The pin rungs of every path that takes a refusal, in one place. Returns true when the pin was
    /// dropped because it had gone IDLE, which callers use to skip their own backoff: the attempt
    /// that follows goes to the source, an address that has refused nothing.
    ///
    /// Two consecutive zero-progress failures through the pinned URL point at the pin itself (an
    /// expired redirect target answers every offset alike), not at a transient: drop it so the retry
    /// re-resolves through the source URL for a fresh redirect. No-op when nothing is pinned.
    ///
    /// A rate-limit streak keeps the pin for `rateLimitRepinStreak` attempts: 429/503/509 says the
    /// origin is metering us, not that the target is dead (#71), and re-resolving spends a second
    /// request on the very origin that is refusing them. On the connection-capped panel behind #307
    /// that is the request that cannot be spared, and its lingering-slot 509 clears within an attempt
    /// or two. But a streak that OUTLIVES that grace is the other 509 shape: a pinned edge target
    /// whose session died during a long pause answers 509 forever, while a fresh redirect through the
    /// source connects on the first try (field trace: 20 generations of 509 against the pin across
    /// ~85 s, then a source-resolved reader delivered in 452 ms). Past the grace the pin IS the
    /// problem; drop it once and let the 200/206 re-pin.
    ///
    /// #392: the grace answers that ONE shape, and the shape is defined by a byte of ours having
    /// just been in flight. Past `pinIdleSeconds` with nothing delivered there is no slot of ours
    /// left to linger (the pump ends its connection at the window high water, so an idle reader
    /// holds nothing at the origin, #310), so what is refusing is the stale lease and the grace only
    /// delays finding out: three paced attempts against an address that will refuse all of them,
    /// 12.5 s in the 6.30.0 retest of #380. There the first refusal is taken at face value.
    ///
    /// Demux-thread-only: it reads the ladder streaks.
    @discardableResult
    private func dropPinIfTheRefusalCallsForIt(isRateLimited: Bool) -> Bool {
        guard isRateLimited else {
            if unproductiveReconnects >= 2 {
                invalidateResolvedURL(reason: "unproductive reconnect streak")
            }
            return false
        }
        let idle = secondsSinceNetworkDelivery()
        // The pin check is what makes the return value mean "the next attempt is going somewhere
        // else". An origin with nothing pinned refuses from the only address there is, and skipping
        // its backoff would just retry a refusing target faster.
        if idle >= pinIdleSeconds, cachedResolvedURL() != nil {
            invalidateResolvedURL(reason: "rate-limited after \(Int(idle))s idle through pinned URL")
            return true
        }
        if rateLimitStreak >= Self.rateLimitRepinStreak {
            invalidateResolvedURL(reason: "rate-limited x\(rateLimitStreak) through pinned URL")
        }
        return false
    }

    /// Exponential backoff (0.5s..8s) growing with streak; immediate on streak=0. How long the
    /// ladder waits before its next attempt. Shared by the blocking backoff below and the
    /// non-blocking one in `chargeFaultedRunwayRefill`, so both pace an origin identically.
    private func backoffDelay(streak: Int, retryAfter: TimeInterval) -> TimeInterval {
        let expo = streak <= 0 ? 0.0 : min(Double(1 << min(streak, 4)) * 0.5, 8.0)
        return min(max(expo, retryAfter), 15.0) * backoffScale
    }

    /// #309: account for replacing a FAULTED connection from the serve path, i.e. while the window
    /// still holds read-ahead. Returns true when the caller should open the replacement.
    ///
    /// This is the same ladder the empty-window path runs (status accounting, pin invalidation,
    /// bounded give-up), because a free reconnect off the books is exactly what #307 paid for. Two
    /// deliberate differences:
    ///
    /// - It does not SLEEP. It runs on the demux thread with megabytes still resident, and a backoff
    ///   sleep there would starve the demuxer of the very read-ahead that replacing early exists to
    ///   protect. The wait is a next-attempt timestamp instead, so reads keep being served at full
    ///   speed between attempts. The timestamp outlives the reconnect it authorises
    ///   (`startPersistentConnection` must not clear it) — it is released by first data or a seek.
    /// - It never returns the read as failed. A window that can still serve must not kill a session
    ///   that still holds seconds of playback. At the cap it stops attempting (`.distantFuture`) and
    ///   leaves termination to the empty-window ladder, where it has always lived.
    ///
    /// It also emits no `.reconnecting` phase: playback is uninterrupted here, and a phase that
    /// flapped between `.flowing` and `.reconnecting` on every read would describe the reader's
    /// bookkeeping rather than what the viewer sees. The empty-window path still emits it, which is
    /// when playback genuinely starves. Demux-thread-only.
    private func chargeFaultedRunwayRefill(at frontier: Int64, ahead: Int,
                                           status: Int, retryAfter: TimeInterval) -> Bool {
        let isRateLimited = Self.isRateLimitStatus(status)
        let giveUp = isRateLimited ? recordRateLimitAndShouldGiveUp()
                                   : recordReconnectAndShouldGiveUp(status: status)
        if giveUp {
            winCond.lock()
            nextFaultedRefillAt = .distantFuture
            winCond.unlock()
            EngineLog.emit(
                "[AVIOReader] \(label) faulted refill exhausted at offset \(frontier) status=\(status);"
                + " serving the remaining \(ahead / 1024)KB, then the read will fail",
                category: .demux)
            return false
        }
        let streak = isRateLimited ? rateLimitStreak : unproductiveReconnects
        let repinned = dropPinIfTheRefusalCallsForIt(isRateLimited: isRateLimited)
        lastUnplannedReconnectAt = Date()
        let delay = backoffDelay(streak: repinned ? 0 : streak, retryAfter: retryAfter)
        winCond.lock()
        nextFaultedRefillAt = Date().addingTimeInterval(delay)
        winCond.unlock()
        EngineLog.emit(
            "[AVIOReader] \(label) replacing a faulted connection at offset \(frontier) with"
            + " \(ahead / 1024)KB of read-ahead left (streak=\(streak) status=\(status),"
            + " next attempt in \(String(format: "%.1f", delay))s)",
            category: .demux)
        return true
    }

    /// Blocking form of the wait above: sleeps in 0.1s slices so a close is honoured promptly.
    private func backoffBeforeReconnect(streak: Int, retryAfter: TimeInterval) {
        let total = backoffDelay(streak: streak, retryAfter: retryAfter)
        if total <= 0 { return }
        var slept = 0.0
        while slept < total {
            if isClosed { return }
            let slice = min(0.1, total - slept)
            Thread.sleep(forTimeInterval: slice)
            slept += slice
        }
    }

    /// Increments the consecutive rate-limited streak; returns true once the bounded cap is hit.
    /// Demux-thread-only. Deliberately NOT reset by `seekReconnect` (parse seeks must not mask a
    /// throttled origin into an endless reconnect loop, #71); only real read progress clears it.
    /// Internal (not private) so the bounded give-up is unit-tested without a live origin.
    func recordRateLimitAndShouldGiveUp() -> Bool {
        rateLimitStreak += 1
        return rateLimitStreak > Self.rateLimitMaxStreak
    }

    // MARK: - Detour Block Cache (AetherEngine#69)

    /// `fetched` says whether the served bytes crossed the network. The callers charge the
    /// reconnect ladders on it: a resident-block hit is a memcpy out of read-ahead already paid
    /// for, so it is no more "progress" against a refusing origin than a window serve is (#380).
    private enum DetourServe { case served(Int, fetched: Bool); case rateLimited(TimeInterval); case miss }
    private enum DetourFetch { case ok(Data); case rateLimited(TimeInterval); case failed }

    /// [MovieClaw P55] 按实测线路速度，一整块（4 MB）旁路补取能不能在它的限时（4 秒）内到齐。
    ///
    /// 旁路补取是同步的：整块到齐才交出第一个字节，到限时还没齐就整块作废、再从这里重连。快线路上一块转眼就到，
    /// 省下的是一次重连；慢线路上（按限时与余量算，低于约 10 Mbit/s）它注定作废：6 Mbit/s 模拟器实测回到文件头时
    /// 这一块下到 2.6～2.9 MB 被丢掉、白等 4 秒，再重连从头下。到不齐就不取，直接走后面的重连——主连接挪到这里
    /// 流式读，第一个字节一到就能交出去。还没测出线路速度时照旧走旁路。不持锁调用
    private func detourFitsLink(at offset: Int64) -> Bool {
        guard AetherEngine.skipsDetourOnSlowLink else { return true }
        winCond.lock()
        let rate = measuredLinkBytesPerSecond
        let firstSkip = !detourSkipLogged
        winCond.unlock()
        let budget = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        guard let rate, !Self.detourFitsLink(bytesPerSecond: rate, budget: budget, blockSize: Self.detourBlockSize) else {
            return true
        }
        if firstSkip {
            winCond.lock()
            detourSkipLogged = true
            winCond.unlock()
            EngineLog.emit(
                "[AVIOReader] \(label) [MovieClaw P55] 线路实测约 \(String(format: "%.1f", rate * 8 / 1_000_000)) Mbit/s，"
                + "\(Self.detourBlockSize / 1024 / 1024) MB 整块补取 \(Int(budget)) 秒内到不齐：在 \(offset) 处重连流式读",
                category: .demux)
        }
        return false
    }

    /// [MovieClaw P55] 上面的纯计算：没测出速度时照旧走旁路；测出来了，按限时留余量能到齐一整块才走
    nonisolated static func detourFitsLink(bytesPerSecond: Double?, budget: TimeInterval, blockSize: Int) -> Bool {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return true }
        return bytesPerSecond * budget * detourLinkMargin >= Double(blockSize)
    }

    /// Serve `[offset, offset+maxLen)` (clamped to one 4 MB block) from the detour cache,
    /// fetching the block over the pooled keep-alive chunkSession on a miss when `allowFetch`.
    /// Demux-thread call; may block on the network via `detourFetchBlock` (no lock held across it).
    /// Returns `.miss` (never `.served(0)`) so callers fall back to a single reconnect.
    private func serveFromDetour(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                 at offset: Int64, allowFetch: Bool) -> DetourServe {
        guard fileSize > 0, offset < fileSize, maxLen > 0 else { return .miss }

        // Resident-block hit: pure copy, no network.
        if let n = detourCache.serveCached(into: dst, maxLen: maxLen, at: offset) {
            return .served(n, fetched: false)
        }
        guard allowFetch else { return .miss }

        let blockStart = (offset / Int64(Self.detourBlockSize)) * Int64(Self.detourBlockSize)
        let blockLen = Int(min(Int64(Self.detourBlockSize), fileSize - blockStart))
        let block: Data
        switch detourFetchBlock(from: blockStart, size: blockLen) {
        case .ok(let fetched):
            // Cache only FULL-length blocks. A truncated 206 cached verbatim would shadow the
            // re-fetch path for its uncovered tail, so the parser ping-ponging into that tail
            // would cost one reconnect per read, reintroducing a mild storm (#69 review). Serve
            // the short body once; the next read of this block re-fetches.
            if fetched.count == blockLen, !isFullyClosed {
                detourCache.insert(blockStart / Int64(Self.detourBlockSize), fetched)
                if let byteCacheKey {   // [MovieClaw P22]
                    SourceByteCache.shared.write(key: byteCacheKey, offset: blockStart, data: fetched)
                }
                #if DEBUG
                EngineLog.emit("[AVIOReader] detour fill block=\(blockStart / Int64(Self.detourBlockSize)) offset=\(blockStart) size=\(fetched.count) (resident=\(detourCache.residentCount))", category: .demux)
                #endif
            }
            block = fetched
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        case .failed:
            return .miss
        }

        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < block.count else { return .miss }
        let n = min(maxLen, block.count - inBlock)
        block.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return .served(n, fetched: true)
    }

    /// Single Range fetch for a detour block over the pooled chunkSession. Surfaces rate limiting with
    /// its Retry-After so the caller can back off in place rather than churn the connection (#71).
    ///
    /// The origin ticket is `syncRequest`'s, and only that one (audit DMX-105): a second acquire here
    /// took the last slot of a two-request origin and left the inner one waiting its whole budget for
    /// a slot this same fetch was holding, +4 s per block, with a third request on the books.
    private func detourFetchBlock(from offset: Int64, size: Int) -> DetourFetch {
        let budget = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: requestURL())
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        // #93/#96: a starved backward-scrub detour fetch must abort fast (the rescue reconnect serves
        // instantly), so this path uses the tight interactive budget, not the full chunk timeout.
        request.timeoutInterval = budget
        applyExtraHeaders(&request)
        do {
            let (data, response) = try syncRequest(
                request, budget: budget, slotLabel: "detour",
                slotWait: min(budget, Self.shortFetchSlotWaitSeconds))
            if let http = response as? HTTPURLResponse {
                let status = http.statusCode
                if Self.isRateLimitStatus(status) {
                    let retryAfter = Self.parseRetryAfter(http)
                    noteOriginRefusal(status: status, retryAfter: retryAfter > 0 ? retryAfter : nil,
                                      respondedBy: http.url)
                    return .rateLimited(retryAfter)
                }
                if status != 200 && status != 206 {
                    if Self.isResolvedExpiryStatus(status) { invalidateResolvedURL() }
                    return .failed
                }
                // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                if status == 200 && offset > 0 && !isLive {
                    EngineLog.emit("[AVIOReader] detour: server ignored Range (200 for offset \(offset)); rejecting", category: .demux, level: .verbose)
                    return .failed
                }
                if !isLive, let served = Self.misplacedRangeStart(http, requestedOffset: offset) {
                    EngineLog.emit("[AVIOReader] detour: 206 starts at \(served), not \(offset); rejecting (audit DMX-5)", category: .demux)
                    return .failed
                }
            }
            addBytesFetched(data.count)
            return .ok(data)
        } catch {
            return .failed
        }
    }

    /// Audit PERF-108: release detour blocks nothing has touched for `detourBlockIdleSeconds`, at most
    /// once a second from the read path and unconditionally when playback re-anchors, which is the
    /// moment a scrub's blocks stop being anyone's working set. Demux-thread-only.
    private func sweepIdleDetourBlocks(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now &- lastDetourIdleSweepNs >= 1_000_000_000 else { return }
        lastDetourIdleSweepNs = now
        let evicted = detourCache.evictIdle(olderThan: detourBlockIdleSeconds)
        if evicted > 0 {
            EngineLog.emit(
                "[AVIOReader] \(label) released \(evicted) idle detour block(s) "
                + "(\(detourCache.residentCount) resident)", category: .demux, level: .verbose)
        }
    }

    /// Tracks contiguity of detour reads for the re-anchor heuristic. Shared by BOTH the backward
    /// and far-forward branches; the re-anchor check itself lives only in the backward branch on
    /// purpose, so a forward-accumulated run later met by a contiguous backward read is an intended
    /// re-anchor, not an accident. A non-contiguous read restarts the run. Demux-thread-only.
    private func detourTrackSequential(at offset: Int64, length: Int) {
        if offset == detourRunNextExpected {
            detourRunBytes += Int64(length)
        } else {
            detourRunBytes = Int64(length)
        }
        detourRunNextExpected = offset + Int64(length)
    }

    private func detourResetRun() {
        detourRunNextExpected = -1
        detourRunBytes = 0
    }

    // MARK: - Cold-start spans (#281)

    /// #551: take whatever a host warmed for this source and install it as this open's resident
    /// bytes.
    ///
    /// Head, tail and size travel together because the open needs all three to stay off the
    /// network: the spans answer the parse reads, and the size is what keeps `resolveOptimisticOpen`
    /// from falling back to the probe ladder, which would spend the round trip the warm just saved.
    ///
    /// A take, not a copy. The bytes are this reader's from here on, and leaving a second copy in
    /// the store would hold megabytes for a source that is now playing.
    private func adoptPrewarmedSource() -> PrewarmedSource? {
        guard !isLive else { return nil }
        guard let warm = SourcePrewarmStore.shared.take(for: url) ?? byteCacheWarm() else { return nil }
        // The head is the one span an open cannot do without, and it is only usable where it says
        // it starts: at zero, which is where the parse begins.
        guard warm.head.start == 0, !warm.head.isEmpty, warm.contentLength > 0 else { return nil }
        // The URL is only half the request. An origin that varies on Referer, User-Agent or
        // Authorization answers a different body, and a different size, under the same URL, and
        // nothing about the bytes themselves would show it. A session whose headers differ from the
        // warm's opens cold instead.
        guard warm.requestHeaders == extraHeaders else {
            EngineLog.emit(
                "[AVIOReader] \(label) a warm exists for this URL but was fetched with different "
                + "headers; opening cold (#551)", category: .demux)
            return nil
        }
        winCond.lock()
        headSpan = warm.head.data
        if let tail = warm.tail { tailSpan = tail }
        fileSize = warm.contentLength
        adoptedWarmSize = warm.contentLength
        // [MovieClaw P49] 文件头是现成的：马上找索引。字节缓存里整段都有就直接装上，否则先取回来
        let cuesPrefetch = locateCuesLocked()
        let cuesLog = takePendingCuesLogLocked()   // [MovieClaw P58]
        winCond.unlock()
        if let cuesLog { EngineLog.emit(cuesLog, category: .demux) }
        if let cuesPrefetch { startCuesPrefetch(cuesPrefetch.range, what: cuesPrefetch.what) }
        SourceContentLengthCache.store(warm.contentLength, for: url)
        // The warm followed the redirect chain and knows where it ended. Pinning that target here
        // is what keeps this session from resolving it a second time: a resolver 302 measured
        // 800 ms on the AE#551 round 2 harness and 3.2 s on the reporter's panel, and it was paid
        // per fresh connection, not once. This is the same pin a redirect records (#12), so the
        // expiry ladder above handles a lease that has run out in the usual way: drop it and
        // re-resolve through the source URL. Credential headers do not follow it (`headers(for:)`).
        recordResolvedURL(warm.resolvedURL)
        EngineLog.emit(
            "[AVIOReader] \(label) adopted a prewarmed source: head=\(warm.head.data.count)B "
            + "tail=\(warm.tail?.data.count ?? 0)B of \(warm.contentLength)B; "
            + "the data connection starts at \(warm.head.end) (#551)",
            category: .demux)
        return warm
    }

    /// [MovieClaw P22] 字节缓存里有这个片源的大小和文件头：拼成预热数据交给 `adoptPrewarmedSource` 接管
    /// （文件尾也在缓存里就一起），换音轨 / 回前台的重建打开时一个请求都不发
    private func byteCacheWarm() -> PrewarmedSource? {
        let cache = SourceByteCache.shared
        guard let key = byteCacheKey, let length = cache.contentLength(key: key), length > 0 else { return nil }
        let headLength = Int(min(Int64(Self.headSpanMaxBytes), cache.contiguousEnd(key: key, from: 0), length))
        guard headLength >= Self.tailPrefetchBytes || Int64(headLength) == length,
              let head = cache.copy(key: key, offset: 0, length: headLength) else { return nil }
        let tailLength = Int(min(Int64(Self.tailPrefetchBytes), length))
        let tail = cache.copy(key: key, offset: length - Int64(tailLength), length: tailLength)
            .map { ResidentSpan(start: length - Int64(tailLength), data: $0) }
        warmFromByteCache = true
        EngineLog.emit(
            "[AVIOReader] \(label) [MovieClaw P22] reopening from the byte cache: head=\(headLength)B "
            + "tail=\(tail?.data.count ?? 0)B of \(length)B, no request until a read misses",
            category: .demux)
        return PrewarmedSource(head: ResidentSpan(start: 0, data: head), tail: tail, contentLength: length,
                               requestHeaders: extraHeaders, resolvedURL: nil)
    }

    /// [MovieClaw P22] 读取位置在字节缓存里：从本机给，不找源站要。只在「本来要为这个位置新发请求」的
    /// 分支上调（没有连接、远跳、回跳）；连接正在送的那段不碰，免得和在途的数据重复
    private func serveFromByteCache(into buf: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int {
        guard let key = byteCacheKey else { return 0 }
        return SourceByteCache.shared.read(key: key, offset: offset, into: buf, maxLen: maxLen)
    }

    /// Fire-and-forget suffix fetch for the last `tailPrefetchBytes` of the source, running
    /// alongside the open connection.
    ///
    /// `bytes=-n` is the one range form that needs no size, which is the whole point: at this
    /// moment the reader has not seen a single response header, so an explicit `bytes=a-b` is not
    /// yet expressible. VOD only: a live feed's tail is meaningless and its length non-authoritative.
    ///
    /// A read that lands in this range WAITS for the fetch (`awaitTailPrefetchLocked`) instead of
    /// connecting past it. The first cut of this let nothing wait, on the reasoning that a late
    /// fetch costs no more than the reconnect it failed to save. That reasoning was wrong about the
    /// timing, and the #281 retest measured it: the demuxer reaches the tail within microseconds of
    /// the data connection's first byte, and the speculative fetch pays the SAME round trip plus a
    /// body, so it is ALWAYS still in flight at that moment on any origin whose first byte costs
    /// anything. It never once served the read it exists for; it only added a request. Only a
    /// loopback origin, which answers before the race can be lost, made it look like it worked.
    private func startTailPrefetch() {
        guard !isLive, !isClosed else { return }
        let url = requestURL()
        // #377: a speculative second request is the first thing to drop on an origin that allows
        // one at a time. It races the data connection's first byte even on a healthy origin (see
        // above), so on a metered one it is a request spent to lose that race AND to occupy the
        // slot the pump needs.
        if originRequiresSerialRequests {
            EngineLog.emit(
                "[AVIOReader] \(label) tail prefetch skipped: this origin is down to one request "
                + "at a time (#377)", category: .demux)
            return
        }
        // An origin that already answered this form with something else will answer it that way
        // again. Said out loud rather than skipped silently: "no issued line" and "issued, declined"
        // are different findings, and a reporter reading this log can only report what it prints.
        if let reason = SuffixRangeSupport.shared.denialReason(for: url) {
            EngineLog.emit(
                "[AVIOReader] \(label) tail prefetch skipped: this origin declined suffix ranges "
                + "earlier this session (\(reason))", category: .demux)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=-\(Self.tailPrefetchBytes)", forHTTPHeaderField: "Range")
        request.timeoutInterval = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        applyExtraHeaders(&request)

        // A delegate rather than a completion handler, and the distinction is load-bearing: a
        // completion handler only fires once the body is in hand, so an origin that does not
        // implement suffix ranges and answers 200 with the WHOLE file would be downloaded in full
        // before this code could look at the status. On a 4 GB source that is the entire file
        // fetched speculatively. The delegate decides at the response header and hangs up there
        // (the same shape ProbeDelegate uses, and the same failure #255 paid for once already).
        // #377: measured against a metered origin, this was the request that got the pump refused.
        // It goes out microseconds before the first data connection, so the origin sees two at once
        // on the very first open, which is the "429 before any real number of requests" in the
        // report. It is speculative and nobody waits on it, so it takes a slot only if one is free.
        guard let tailTicket = OriginRequestBudget.shared.tryAcquire(
            for: url, label: "\(label) tail prefetch") else {
            EngineLog.emit(
                "[AVIOReader] \(label) tail prefetch skipped: no origin request slot free (#377)",
                category: .demux)
            return
        }

        let delegate = TailPrefetchDelegate(
            expectedLength: Self.tailPrefetchBytes,
            extraHeaders: headers(for: request.url)
        )
        delegate.onProgress = { [weak self] in   // [MovieClaw P53]
            guard let self else { return }
            self.winCond.lock()
            self.tailPrefetchLastProgressAt = DispatchTime.now()
            self.winCond.unlock()
        }
        // #281 retest: one line per open, and the line the field needs. The advertised way to check
        // this fix was "does a bytes=-65536 request show up", which the engine never printed, so a
        // reporter reading the log could only report its absence. Names the outcome, not the intent.
        delegate.onOutcome = { [weak self] outcome in
            // Fires exactly once, whatever happened, which makes it the one release point.
            OriginRequestBudget.shared.release(tailTicket)
            guard let self else { return }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds
                                   - self.tailPrefetchStartedAt.uptimeNanoseconds) / 1_000_000
            self.winCond.lock()
            self.tailPrefetchInFlight = false
            var installed = false
            if case .span(let start, let data) = outcome, !self.isFullyClosed, self.tailSpan == nil {
                self.tailSpan = ResidentSpan(start: start, data: data)
                installed = true
            }
            self.winCond.broadcast()
            self.winCond.unlock()
            if case .span(let start, let data) = outcome {
                SuffixRangeSupport.shared.noteServed(url)
                self.addBytesFetched(data.count)
                if let key = self.byteCacheKey {   // [MovieClaw P22]
                    SourceByteCache.shared.write(key: key, offset: start, data: data)
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) tail prefetch \(installed ? "installed" : "dropped") "
                    + "\(data.count)B at \(start) after \(Int(elapsedMs))ms",
                    category: .demux)
            } else if case .rejected(let reason, let verdict) = outcome {
                var learned = false
                switch verdict {
                case .declinedByOrigin:
                    SuffixRangeSupport.shared.noteDeclined(url, reason: reason)
                    learned = true
                case .transportFailure:
                    learned = SuffixRangeSupport.shared.noteTransportFailure(url, reason: reason)
                case .unrelated:
                    // A 403 during a connection-cap window, a 429, a 5xx: the origin has said
                    // nothing about suffix ranges, and the very next open may be served. Not a
                    // transport strike either — two opens inside one short outage would otherwise
                    // still latch for the rest of the process.
                    break
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) tail prefetch rejected after \(Int(elapsedMs))ms: \(reason)"
                    + (learned ? "; not asking this origin again this session" : ""),
                    category: .demux)
            }
        }
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate
        winCond.lock()
        tailPrefetchTask = task
        tailPrefetchInFlight = true
        tailPrefetchStartedAt = DispatchTime.now()
        tailPrefetchLastProgressAt = nil
        winCond.unlock()
        task.resume()
        // Issue AND outcome, because "no outcome line" and "never issued" are different findings and
        // one line cannot carry both. A fetch that hangs to teardown prints this one and no other.
        EngineLog.emit("[AVIOReader] \(label) tail prefetch issued bytes=-\(Self.tailPrefetchBytes)",
                       category: .demux)
    }

    /// Whether `offset` lies in the range the speculative fetch asked for. Caller holds `winCond`.
    private func isInTailPrefetchRangeLocked(_ offset: Int64) -> Bool {
        guard fileSize > 0 else { return false }
        return offset >= fileSize - Int64(Self.tailPrefetchBytes) && offset < fileSize
    }

    /// [MovieClaw P49] 在已到手的文件头里找 Matroska 的 Cues（每次打开只找到一次为止）。要提前取时返回
    /// 「Cues 到文件尾」这段：文件头 4 MB 以内（取文件头的连接顺带就到）、尾部预读已覆盖、离文件尾太远的都不取。
    /// 调用方持 winCond
    private func locateCuesLocked() -> (range: Range<Int64>, what: String)? {
        guard !cuesLocateDone, openPhaseActive, !isLive, fileSize > 0, !headSpan.isEmpty else { return nil }
        // [MovieClaw P54] MP4 / MOV 的「mdat 在前、moov 在后」：同一套提前取，范围是 mdat 之后到文件尾
        if AetherEngine.prefetchesMP4TailMoov {
            switch MP4MoovLocator.locate(head: headSpan, fileSize: fileSize) {
            case .needMore:
                if headSpan.count >= Self.cuesLocateMaxHeadBytes || Int64(headSpan.count) >= fileSize {
                    cuesLocateDone = true
                }
                return nil
            case .moovFirst:
                cuesLocateDone = true
                return nil
            case .moovAfterMdat(let offset):
                cuesLocateDone = true
                guard offset >= Int64(Self.headSpanMaxBytes),
                      offset < fileSize - Int64(Self.tailPrefetchBytes),
                      fileSize - offset <= Self.moovPrefetchMaxBytes else { return nil }
                return (offset ..< fileSize, "（P54）MP4 的 moov 在 \(offset)（mdat 之后，距文件尾 \(fileSize - offset) 字节）")
            case .notApplicable:
                break   // 不是 MP4：往下按 Matroska 找
            }
        }
        guard AetherEngine.prefetchesMatroskaCues || hostMatroskaCues != nil else {
            cuesLocateDone = true
            return nil
        }
        switch MatroskaCuesLocator.locate(head: headSpan) {
        case .needMore:
            if headSpan.count >= Self.cuesLocateMaxHeadBytes || Int64(headSpan.count) >= fileSize {
                cuesLocateDone = true
            }
            return nil
        case .absent:
            cuesLocateDone = true
            return nil
        case .found(let offset):
            cuesLocateDone = true
            // [MovieClaw P58] 服务端给了精简索引、位置也与文件头登记的对得上：直接装成常驻片段，原索引一个字节都不用下
            if let host = hostMatroskaCues {
                if host.offset == offset {
                    cuesSpan = ResidentSpan(start: offset, data: host.data)
                    cuesSpanFromHost = true
                    pendingCuesLog = "[AVIOReader] \(label) [MovieClaw P58] 索引在 \(offset)，装上服务端给的精简索引"
                        + "（\(host.data.count) 字节），不提前取原索引"
                    return nil
                }
                pendingCuesLog = "[AVIOReader] \(label) [MovieClaw P58] 服务端给的精简索引位置 \(host.offset) 与文件头登记的 "
                    + "\(offset) 对不上，不用它"
            }
            guard AetherEngine.prefetchesMatroskaCues, offset >= Int64(Self.headSpanMaxBytes),
                  offset < fileSize - Int64(Self.tailPrefetchBytes),
                  fileSize - offset <= Self.cuesPrefetchMaxBytes else { return nil }
            return (offset ..< fileSize, "Matroska 索引在 \(offset)（距文件尾 \(fileSize - offset) 字节，尾部预读够不着）")
        case .secondarySeekHead:
            // 开头的目录只指向文件尾附近的完整目录：Cues 在哪要读了那个目录才知道。试过盲取文件最后 1 MB，真机上这 1 MB
            // 要 90～180 毫秒，索引预热反而等得更久（按需读只要约 37 毫秒），所以不取，照旧由解复用器按需读
            cuesLocateDone = true
            if hostMatroskaCues != nil {   // [MovieClaw P58] 核对不了位置，宁可不用
                pendingCuesLog = "[AVIOReader] \(label) [MovieClaw P58] 文件头只指向次级目录，核对不了服务端给的索引位置，不用它"
            }
            return nil
        }
    }

    /// [MovieClaw P58] 取走找索引时记下的话，调用方解锁后再说出去。调用方持 winCond
    private func takePendingCuesLogLocked() -> String? {
        defer { pendingCuesLog = nil }
        return pendingCuesLog
    }

    /// [MovieClaw P49] 把「Cues 到文件尾」先取回来装成常驻片段。字节缓存（P22 / P42）里整段都有就直接装上、
    /// 不发请求；取回来的也写进字节缓存，下次打开同一个片源就不用再下。只是优化：源站拒绝、没有空闲的请求名额、
    /// 取回的字节对不上，都不装，解复用器照旧按需去读
    private func startCuesPrefetch(_ range: Range<Int64>, what: String) {
        let length = Int(range.count)
        if let key = byteCacheKey,
           let cached = SourceByteCache.shared.copy(key: key, offset: range.lowerBound, length: length) {
            winCond.lock()
            if !isFullyClosed, cuesSpan == nil { cuesSpan = ResidentSpan(start: range.lowerBound, data: cached) }
            winCond.broadcast()
            winCond.unlock()
            EngineLog.emit(
                "[AVIOReader] \(label) [MovieClaw P49] \(what)：字节缓存里整段都有，直接装上", category: .demux)
            return
        }
        let url = requestURL()
        guard !originRequiresSerialRequests,
              let ticket = OriginRequestBudget.shared.tryAcquire(for: url, label: "\(label) cues prefetch") else {
            EngineLog.emit(
                "[AVIOReader] \(label) [MovieClaw P49] Matroska 索引提前取跳过：源站此刻只许一个请求或没有空闲名额",
                category: .demux)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        applyExtraHeaders(&request)
        // 区间一直到文件尾，应答的 Content-Range 与尾部预读同一个形状：沿用它的校验（206、起点与长度对得上、
        // 不多不少）和跨域跳转不带凭据的规矩
        let delegate = TailPrefetchDelegate(expectedLength: length, extraHeaders: headers(for: request.url))
        delegate.onProgress = { [weak self] in   // [MovieClaw P53]
            guard let self else { return }
            self.winCond.lock()
            self.cuesPrefetchLastProgressAt = DispatchTime.now()
            self.winCond.unlock()
        }
        let startedAt = DispatchTime.now()
        delegate.onOutcome = { [weak self] outcome in
            OriginRequestBudget.shared.release(ticket)
            guard let self else { return }
            let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            self.winCond.lock()
            self.cuesPrefetchInFlight = false
            self.cuesPrefetchTask = nil
            var installed = false
            if case .span(let start, let data) = outcome, start == range.lowerBound, !self.isFullyClosed,
               self.cuesSpan == nil {
                self.cuesSpan = ResidentSpan(start: start, data: data)
                installed = true
            }
            self.winCond.broadcast()
            self.winCond.unlock()
            switch outcome {
            case .span(let start, let data):
                self.addBytesFetched(data.count)
                if Int64(data.count) >= Self.linkRateMinBytes, elapsedMs > 0 {   // [MovieClaw P55]
                    self.winCond.lock()
                    if self.measuredLinkBytesPerSecond == nil {
                        self.measuredLinkBytesPerSecond = Double(data.count) * 1000 / Double(elapsedMs)
                    }
                    self.winCond.unlock()
                }
                if installed, let key = self.byteCacheKey {
                    SourceByteCache.shared.write(key: key, offset: start, data: data)
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) [MovieClaw P49] 提前取的那段\(installed ? "已装上" : "用不上了")："
                    + "\(data.count) 字节，\(elapsedMs) 毫秒", category: .demux)
            case .rejected(let reason, _):
                EngineLog.emit(
                    "[AVIOReader] \(self.label) [MovieClaw P49] 提前取没成（\(elapsedMs) 毫秒）：\(reason)；"
                    + "照旧按需读", category: .demux)
            }
        }
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate
        winCond.lock()
        guard !isClosed else {
            winCond.unlock()
            OriginRequestBudget.shared.release(ticket)
            return
        }
        cuesPrefetchTask = task
        cuesPrefetchInFlight = true
        cuesPrefetchRange = range
        cuesPrefetchStartedAt = startedAt
        cuesPrefetchLastProgressAt = nil
        winCond.unlock()
        task.resume()
        EngineLog.emit("[AVIOReader] \(label) [MovieClaw P49] \(what)：和开容器并行先取回来", category: .demux)
    }

    /// How long a read may wait for the speculative fetch before giving up and reconnecting.
    ///
    /// Both requests left at the same instant against the same origin, so the fetch's first byte
    /// costs what the data connection's did: once it has been outstanding for materially longer
    /// than that, it is not about to land and a fresh connection is the better bet. Waiting up to
    /// that point can never cost more than the reconnect it replaces, which is what makes this
    /// bound the honest one rather than a tuned constant. The floor covers an origin that answered
    /// the first connection out of a warm cache; the cap keeps a hung fetch from owning the open.
    /// Caller holds `winCond`.
    private func tailPrefetchWaitBudget() -> TimeInterval {
        tailPrefetchWaitBudgetForTesting ?? Self.tailPrefetchWaitBudget(firstDataMs: lastFirstDataMs)
    }

    /// The bound itself, free of the reader's state so it can be checked without a socket.
    nonisolated static func tailPrefetchWaitBudget(firstDataMs: Double) -> TimeInterval {
        min(5.0, max(0.25, (firstDataMs / 1000) * 2))
    }

    /// [MovieClaw P53] 等在途提前取的截止时刻。上面按往返定的上限只回答「首字节该到了没有」：它假定字节一到整段
    /// 转眼就齐，快线路上成立，慢线路上不成立——6 Mbit/s 时 1.2 MB 的 Matroska 索引要传 2 秒以上，而上限只有
    /// 0.25 秒。等不及的那次读就在同一位置另发请求，把同一段再下一遍（两个请求平分同一条慢线路，谁都更慢），
    /// 还掐断正在读文件头的连接：模拟器冷起播实测索引下了两遍、文件头连接只下了 0.4 MB 就被换掉，首帧超过 12 秒。
    /// 所以一旦开始往回送，截止时刻就跟着最近一次到货往后推，停下不动超过 `prefetchProgressStallSeconds`
    /// （且超过按往返定的上限）才放弃：同一条线路上再下一遍同样的字节，永远不会比等它更快。调用方持 winCond
    /// [MovieClaw P56] 容器索引（Matroska Cues / MP4 moov）的提前取在途时，文件头连接到了请求范围的尽头先不往前续。
    ///
    /// 首帧之前必须下的只有两段：索引（开流、规划分片要用）和第一个分片。两段一起下时它们平分线路，索引晚到一倍，而文件头
    /// 那边多下的字节首帧根本用不上：模拟器 6 Mbit/s 冷起播《大江大河》MP4（1.3 Mbit/s，moov 3.2 MB，第一个分片只要约
    /// 0.6 MB），moov 与文件头并行时 moov 下了 5 秒、文件头白下 3 MB，首帧 9.3 秒；旧做法（掐断文件头、moov 独占线路）
    /// 反而 5.4 秒。所以索引在途时只让它跑：这里只拦「还有数据可读时顺手往前续」的超前预读，解复用器真读到窗口尽头时
    /// 读取循环照常在那里续连（那是它此刻就要的字节）。索引一到，下一次读就把文件头续上。调用方持 winCond
    private func indexPrefetchHoldsHeadLocked() -> Bool {
        AetherEngine.prioritizesIndexPrefetch && cuesPrefetchInFlight
    }

    /// [MovieClaw P56] 索引交出去以后该不该马上把文件头续上，该续时返回续的位置。
    ///
    /// 文件头的第一个请求只有 512 KB，平时靠「从窗口读的时候顺手往前续」接上；但 Matroska 开流读完索引之后，引擎要规划分片、
    /// 等 AVPlayer 来要第一个分片，零点几秒里一个字节都不从窗口读，文件头连接就闲在那里（模拟器快线路上续连晚了 0.68 秒，
    /// 慢线路上这段线路时间白白空着）。从头播时这段文件头正是接下来要播的，所以常驻片段（索引、文件尾）一交出字节就续上。
    /// 只在：从头播、窗口还锚在文件头、连接是按计划到了范围尽头（不是出错，出错走读取循环的重连梯子）、索引不在途、
    /// 窗口里还没攒到低水位。续播不续：马上要跳到续播点，续上文件头只会白占带宽。调用方持 winCond
    private func headContinuationAfterIndexLocked() -> Int64? {
        guard AetherEngine.prioritizesIndexPrefetch, expectsHeadPlayback, !isLive,
              winStart == 0, activeTransfer == nil, connEndedAtRangeEnd,
              !indexPrefetchHoldsHeadLocked(), window.count < Self.winLowWater else { return nil }
        let frontier = winStart + Int64(window.count)
        return fileSize > 0 && frontier < fileSize ? frontier : nil
    }

    private func prefetchWaitDeadlineLocked(fixed: Date, lastProgress: DispatchTime?) -> Date {
        guard AetherEngine.waitsOnProgressingPrefetch else { return fixed }
        let idle = lastProgress.map { Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 }
        return Self.prefetchWaitDeadline(fixed: fixed, now: Date(), idleSeconds: idle,
                                         allowance: max(tailPrefetchWaitBudget(), Self.prefetchProgressStallSeconds))
    }

    /// 上面的纯计算：没收到过字节（`idleSeconds` 为 nil）时只认按往返定的截止时刻；收到过就再给「停下不动的余量」
    /// 减去已经停了多久，两者取晚的
    nonisolated static func prefetchWaitDeadline(fixed: Date, now: Date, idleSeconds: Double?,
                                                 allowance: TimeInterval) -> Date {
        guard let idleSeconds else { return fixed }
        return max(fixed, now.addingTimeInterval(allowance - idleSeconds))
    }

    /// Which non-206 answers to `bytes=-n` are the origin's verdict on the suffix-range FORM, and so
    /// worth remembering for the session: a 200 that ignored it (and would have sent the whole
    /// file), a 416 that rejected it. A 401/403/404/410 is the origin's verdict on the resource, a
    /// 429/503/509 on the moment, a 5xx a fault: those repeat only while their condition does, and
    /// latching on one of them silently disabled the prefetch for the origin for the process
    /// lifetime after a single refusal.
    static func suffixRangeStatusDeclinesTheForm(_ status: Int) -> Bool {
        return status == 200 || status == 416
    }

    /// Start offset of the bytes a 206 actually carries, from `Content-Range: bytes a-b/total`.
    /// Returns nil unless the header agrees with what arrived, so a proxy that answered a suffix
    /// request with some other region cannot install bytes at the wrong offset.
    ///
    /// Audit DMX-8: a suffix is the END of the source, so the span has to end on the byte before a
    /// numeric total. Without that, `bytes <2^63-65536>-<Int64.max>/*` installed a span whose `end`
    /// overflows on the first read that reaches it.
    static func suffixRangeStart(_ http: HTTPURLResponse, expectedLength: Int) -> Int64? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let scanner = value.replacingOccurrences(of: "bytes ", with: "")
        let parts = scanner.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, end == total - 1,
              end - start + 1 == Int64(expectedLength) else { return nil }
        return start
    }

    /// The demuxer is done parsing; a far seek from here on is playback. Stops COLLECTING into the
    /// head, but deliberately does not release it here.
    ///
    /// #281 retest: releasing it here was one read too early. The read that follows this call is
    /// playback's FIRST, and after a trailing-index parse the anchored connection sits at the END of
    /// the file, so that read is a backward one that lands at the head on every layout measured (48
    /// here, 5752 in the field trace). Dropping the head on the last parse read handed straight back
    /// the round trip the head exists to remove, and no `probe`-based measurement could see it,
    /// because `probe` exits at exactly this line. The head is released instead by the first
    /// post-open read it cannot answer, which is either playback moving past it or a resume position
    /// nowhere near it. The tail span stays for the same reason it always did: it is 64 KB, and a
    /// container that re-reads its trailing index during playback should keep hitting it.
    func markOpenPhaseFinished() {
        winCond.lock()
        openPhaseActive = false
        winCond.unlock()
    }

    /// AE#585: the reads that follow are a bounded index pass, not playback.
    func beginIndexPass() {
        winCond.lock()
        indexPassActive = true
        winCond.unlock()
    }

    /// AE#585: the index pass is over; the next read that cannot be answered from a resident span
    /// is playback's, and #281's rule applies to it unchanged.
    func endIndexPass() {
        winCond.lock()
        indexPassActive = false
        winCond.unlock()
    }

    /// Which cold-start span answered, so the log can name the round trip that did not happen
    /// rather than leaving its absence to be inferred.
    enum SpanServe {
        case head(Int)
        case tail(Int)
        case cues(Int)   // [MovieClaw P49]

        var bytes: Int {
            switch self {
            case .head(let n), .tail(let n), .cues(let n): return n
            }
        }
    }

    /// Serve `offset` from either cold-start span. Caller holds `winCond` (the read loop already
    /// does, and `winCond` is an NSCondition, so re-acquiring here would deadlock). The copy runs
    /// under the lock on purpose: it is a memcpy out of a `Data` the delegate threads only ever
    /// install, never mutate.
    private func serveFromResidentSpansLocked(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                              at offset: Int64) -> SpanServe? {
        // [MovieClaw P58] 服务端给的精简索引在自己的范围里最先给（见 `cuesSpanFromHost`）
        if cuesSpanFromHost, let n = cuesSpan?.serve(into: dst, maxLen: maxLen, at: offset) { return .cues(n) }
        if !headSpan.isEmpty,
           let n = ResidentSpan(start: 0, data: headSpan).serve(into: dst, maxLen: maxLen, at: offset) {
            return .head(n)
        }
        if let n = tailSpan?.serve(into: dst, maxLen: maxLen, at: offset) { return .tail(n) }
        if let n = cuesSpan?.serve(into: dst, maxLen: maxLen, at: offset) { return .cues(n) }
        return nil
    }

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Open a fresh Range: bytes=<offset>- connection (live: always `bytes=0-`, see the
    /// request construction below). Bumps generation so late callbacks from the old
    /// connection are ignored.
    private func startPersistentConnection(at offset: Int64, boundedTo: Int64? = nil) {
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        // #220: VOD asks for a fixed amount at a time, and anything an origin delivers past it is
        // dropped at the append (audit DMX-1), so the window is bounded by the ask. Two
        // cases keep the open-ended form: live, where the material is produced in real time so
        // the origin cannot outrun media rate and the end is moving, and a source whose total
        // size is not resolved yet, where there is nothing to clamp the last range against. An
        // explicit caller bound (boundedInitialFetch) still wins. `fileSize` is read here
        // because winCond is already held, as every fileSize access requires.
        // #377: a held connection is open-ended by construction. Bounded ranges (#220) exist
        // because a pushed transport delivers everything it was asked for whether or not the
        // consumer is ready, so the ASK is what bounds the window. A pull bounds it at the read
        // instead, and asking for a finite range would put the request cadence straight back. An
        // explicit caller bound still wins, because that caller wants a specific amount read.
        let resolvedBound: Int64? = boundedTo ?? {
            guard !heldConnectionEnabled else { return nil }
            guard !isLive else { return nil }
            // fileSize is still 0 on the very first connection, since the response's
            // Content-Range is what resolves it. Asking for a fixed amount anyway is both safe
            // and necessary: safe because a server clamps a range that overruns the file (416
            // needs the START past the end, which cannot happen here), and necessary because
            // waiting for a resolved size would leave the first connection, the one that reads
            // from byte zero, open-ended.
            if fileSize > offset { return min(Self.persistentRangeBytes, fileSize - offset) }
            return fileSize <= 0 ? Self.persistentRangeBytes : nil
        }()
        // #295: a request that begins inside the resident window, or exactly at its end, is a
        // CONTINUATION rather than a reposition. Resetting `winStart` to it dropped every byte
        // below it, which for the #220 frontier refill is up to `winLowWater` of already delivered,
        // still undrained data: the very next read then sat below `winStart`, took the backward
        // branch, and pulled those same bytes back over the network 4 MB at a time on the demux
        // read thread. Keeping them costs nothing (the new range covers only what follows) and the
        // window stays bounded by `trimWindowLocked` and the high-water end exactly as before.
        // The truncating case is the narrow race where the old connection appended past the
        // frontier the read loop computed before it unlocked; those bytes are re-delivered by the
        // new range, which is correct if slightly wasteful, and never leaves a hole.
        if offset >= winStart, offset <= winStart + Int64(window.count) {
            let keep = Int(offset - winStart)
            if keep < window.count { window.truncate(to: keep) }
        } else {
            winStart = offset
            window.removeAll()
        }
        connRequestedOffset = offset
        let askAsJoin = isLive && liveOffsetsUnsatisfiable
        connEnded = false
        connEndedByBackpressure = false
        connEndedAtRangeEnd = false
        postEndDeliveryBytes = 0
        postEndOvershootLogged = false
        let skippedConnStarts = connStartLogGate.admit(
            continuesPrevious: connRangeEnd.map { offset == $0 + 1 } ?? false,
            now: TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
        connRangeEnd = resolvedBound.map { offset + $0 - 1 }
        connStatus = 0
        connRetryAfter = 0
        connStartedAt = DispatchTime.now()   // #93: time-to-first-data per generation
        connFirstDataSeen = false
        genDeliveredBytes = 0                // [MovieClaw P55]
        lastDeliveryAt = connStartedAt       // #309: the gap is measured from here until data lands
        // `nextFaultedRefillAt` is deliberately NOT reset here. The faulted-refill ladder sets it
        // just before authorising this very reconnect, so a reset on connection start erased the
        // pacing it had just announced — every "next attempt in Ns" fired as fast as the consumer
        // could read (field trace: a 509-refusing origin was retried on read cadence, streak=1).
        // The timestamp is cleared by proof of delivery (`appendPersistentData`, first data) and
        // by an intentional reposition (`seekReconnect`), the two events that genuinely end a
        // faulted lineage.
        let oldTransfer = activeTransfer
        activeTransfer = nil
        winCond.broadcast()
        winCond.unlock()

        oldTransfer?.cancelTransfer()
        // #377: hand the old range's origin slot back HERE rather than waiting for its
        // `didCompleteWithError`, which arrives asynchronously. On a single-slot origin the pump
        // would otherwise queue behind its own previous range at every 32 MB boundary and spend
        // its whole acquire budget waiting for itself.
        oldTransfer?.releaseOriginTicket()

        if isClosed { return }

        var request = URLRequest(url: requestURL())
        // #93 residual: a bounded open connection asks for a finite range so an origin that dribbles
        // the open-ended `bytes=0-` stream serves it as a fast finite GET. The 206 Content-Range still
        // carries the total size, so fileSize resolution (issue #70) is unaffected.
        if let resolvedBound {
            request.setValue("bytes=\(offset)-\(offset + resolvedBound - 1)", forHTTPHeaderField: "Range")
        } else {
            // Live: `offset` is reader bookkeeping (the window frontier the delivered bytes are
            // appended at), and whether it means anything server-side depends on the origin.
            // Panels serving a ring buffer have no byte addresses at all: some ignore the offset
            // and serve from now (which is why the frontier request ever worked), others answer
            // 416 to every offset they cannot satisfy, which turned each reconnect into an
            // unrecoverable rejection loop (#331). A live source that is a growing FILE resumes
            // at the frontier correctly, and asking it for byte zero would re-deliver its whole
            // buffer on top of the window. So keep the frontier until an origin rejects it, then
            // ask the way a join does for the rest of the session; the append anchors the bytes
            // at the frontier either way.
            request.setValue("bytes=\(askAsJoin ? 0 : offset)-", forHTTPHeaderField: "Range")
        }
        request.timeoutInterval = 0  // long-lived; stalls handled by the reader
        applyExtraHeaders(&request)

        // #377: take the origin slot before the connection goes on the link. The pump is the one
        // path that must never be refused a slot for long: it is the main line, and everything
        // else holding a slot is short (a 4 MB detour block, a probe). A generous budget here
        // means "wait for the short thing to finish", not "give up".
        let requestURLForBudget = request.url ?? url
        let ticket = OriginRequestBudget.shared.acquire(
            for: requestURLForBudget, label: "\(label) pump", timeout: Self.pumpSlotWaitSeconds,
            shouldAbort: { [weak self] in self?.isClosed ?? true })
        // Audit DMX-112: a pump torn down while parked for its slot leaves without a transfer.
        if ticket == nil, isClosed { return }

        let transfer: any PersistentTransfer
        if heldConnectionEnabled {
            transfer = HeldSourceConnection(
                url: request.url ?? requestURLForBudget,
                offset: offset,
                extraHeaders: headers(for: request.url ?? requestURLForBudget),
                userAgent: nil,
                label: label,
                generation: generation,
                ticket: ticket,
                delegate: self
            )
        } else {
            let delegate = PersistentReadDelegate(
                reader: self,
                generation: generation,
                extraHeaders: headers(for: request.url),
                ticket: ticket,
                originURL: requestURLForBudget
            )
            let task = Self.persistentSession.dataTask(with: request)
            task.delegate = delegate
            transfer = task
        }

        winCond.lock()
        // A close() that raced in bumped the generation; don't install a stale connection.
        guard generation == connGeneration, !isClosed else {
            winCond.unlock()
            transfer.cancelTransfer()
            transfer.releaseOriginTicket()   // never started, so no completion callback will free it
            return
        }
        activeTransfer = transfer
        winCond.unlock()

        transfer.startTransfer()
        // #309: from here the generation is watched on wall-clock time, not on consumer cadence.
        armDeliveryGapWatchdog(generation: generation, after: connStallTimeout)
        armFirstByteWitness(generation: generation, originURL: requestURLForBudget)
        // #240: not DEBUG-only any more, and it names its reader. This is the line a field report
        // needs to answer "who is on the link": with bounded ranges every 32 MiB refill starts a
        // generation, so an unlabelled sequence of them reads like several concurrent connections
        // when it is one reader walking forward. On a fast link that walk is a range every few
        // hundred milliseconds, so contiguous ranges are summarised (see ConnStartLogGate).
        guard let skippedConnStarts else { return }
        EngineLog.emit(
            "[AVIOReader] \(label) conn start gen=\(generation) offset=\(offset)"
            + (resolvedBound.map { " len=\($0 / 1024 / 1024)MB" } ?? " open-ended")
            + (heldConnectionEnabled ? " held" : "")
            + (skippedConnStarts > 0 ? " (+\(skippedConnStarts) contiguous ranges since the last line)" : "")
            + reResolveNote(),
            category: .demux)
    }

    /// #309: timer queue for the delivery-gap watchdog. Shared and serial: the work is one
    /// timestamp comparison per armed generation and never touches the network.
    private static let deliveryGapQueue = DispatchQueue(label: "aether.avio.delivery-gap")

    /// #450: report a generation that has been on the link for `firstByteWitnessDelay` with no
    /// first byte. It REPORTS, it never acts: ending a connection stays with `checkDeliveryGap` and
    /// the read loop, so an early line cannot change when anything reconnects.
    ///
    /// The line carries the two facts that separate the causes, because they pick different fixes.
    /// A request parked in the transport behind this process's own long-lived connections looks,
    /// from every vantage point downstream, exactly like an origin sitting on the request: the task
    /// is resumed, no callback comes, no error comes, and no metrics come until it ends. `inflight`
    /// is what this engine has open against the origin, the pool cap is what the transport will let
    /// on the link, and a reporter who can read both off one line does not have to run curl to find
    /// out which side is quiet.
    private func armFirstByteWitness(generation: Int, originURL: URL) {
        Self.deliveryGapQueue.asyncAfter(deadline: .now() + firstByteWitnessDelay) { [weak self] in
            self?.reportMissingFirstByte(generation: generation, originURL: originURL)
        }
    }

    private func reportMissingFirstByte(generation: Int, originURL: URL) {
        if isClosed { return }
        winCond.lock()
        // Nothing to report: a newer generation owns the link, this one already ended, no transfer
        // is installed, or the first byte landed while this closure was queued.
        guard generation == connGeneration, !connEnded, activeTransfer != nil, !connFirstDataSeen else {
            winCond.unlock()
            return
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds)
            / 1_000_000_000
        let offset = connRequestedOffset
        winCond.unlock()
        // Outside winCond: the budget takes its own lock, and no lock of this reader is held across
        // another object's.
        let inflight = OriginRequestBudget.shared.snapshot(for: originURL)?.inflight
        EngineLog.emit(
            "[AVIOReader] \(label) gen=\(generation) no first byte after "
            + "\(String(format: "%.1f", waited))s at offset \(offset); "
            + (inflight.map { "\($0) request(s) open to this origin" } ?? "origin not in the budget's books")
            + ", transport pool allows \(Self.longLivedConnectionsPerHost) connections per host",
            category: .demux)
    }

    /// #309: schedule the delivery-gap check for `generation`. One pending closure at a time per
    /// generation: it either ends the connection or re-arms itself for the remaining gap, so a
    /// healthy transfer costs one comparison per `connStallTimeout` instead of a repeating timer,
    /// and a generation that has already ended arms nothing at all.
    private func armDeliveryGapWatchdog(generation: Int, after delay: TimeInterval) {
        Self.deliveryGapQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkDeliveryGap(generation: generation)
        }
    }

    /// #309: end a generation that has an installed transfer and no delivery for
    /// `connStallTimeout`. Same threshold and same action as the read loop's forward wait, with the
    /// one precondition removed that made the field case invisible: that a consumer be blocked on
    /// it. A window holding read-ahead, or a paused player holding all of it, no longer defers the
    /// verdict.
    ///
    /// It ENDS, it never reconnects. Opening connections stays with the read thread, so a parked
    /// consumer cannot be turned into a timer-driven reconnect loop (the #307 failure mode), and a
    /// pause continues to hold no flow at all (the #310 invariant). The replacement is issued by
    /// the read loop: at low water while read-ahead remains, immediately once the window is empty.
    private func checkDeliveryGap(generation: Int) {
        if isClosed { return }
        winCond.lock()
        // Nothing to watch: a newer generation owns the link, the connection already ended
        // (delivered range, high-water end, transport error), or no transfer is installed.
        guard generation == connGeneration, !connEnded, let transfer = activeTransfer else {
            winCond.unlock()
            return
        }
        let gap = Double(DispatchTime.now().uptimeNanoseconds - lastDeliveryAt.uptimeNanoseconds)
            / 1_000_000_000
        // A held connection sitting on a full window has no read outstanding: the pump asked for a
        // budget, was told there was no room, and is waiting. Nothing is late, so there is no gap to
        // judge. The pushed path cannot reach this state -- it ends at the high water instead -- which
        // is why the verdict was safe to take on a full window before. Re-arm rather than end, and the
        // watchdog still owns the case this path can have: bytes asked for and none arriving.
        let heldAndFull = heldConnectionEnabled
            && (winHighWater - windowAheadLocked()) < Self.heldPullSlack
        if heldAndFull {
            // The clock restarts with the stretch it must not measure. Left running, it spends the
            // whole parked stretch, and the read the consumer's return issues is then born already
            // late: the next tick ends a connection that was healthy throughout, which is the
            // re-request this flag exists to remove, booked as a stall. A full period rather than
            // what is left of one, because once the gap has outgrown the timeout that remainder is
            // 20 ms and this would re-arm at 50 Hz for the length of the park.
            lastDeliveryAt = DispatchTime.now()
            winCond.unlock()
            armDeliveryGapWatchdog(generation: generation, after: connStallTimeout)
            return
        }
        if gap < connStallTimeout {
            winCond.unlock()
            // Data landed since this closure was scheduled; wait out what is left of the window.
            armDeliveryGapWatchdog(generation: generation, after: max(0.02, connStallTimeout - gap))
            return
        }
        connEnded = true
        activeTransfer = nil
        let frontier = winStart + Int64(window.count)
        let ahead = window.count - max(0, Int(position - winStart))
        let sawData = connFirstDataSeen
        winCond.broadcast()
        winCond.unlock()
        transfer.cancelTransfer()
        transfer.releaseOriginTicket()   // #377: a stalled connection must not hold the slot
        // The witness the field case had no line for: `bytesFetched` sat frozen for minutes and
        // nothing said so. Release-visible, and rare by construction (one per faulted generation).
        EngineLog.emit(
            "[AVIOReader] \(label) gen=\(generation) no delivery for \(String(format: "%.1f", gap))s"
            + " at offset \(frontier) (\(ahead / 1024)KB read-ahead held,"
            + " \(sawData ? "had delivered" : "never delivered") data); ending it",
            category: .demux)
    }

    /// Force-copies `data` into the sliding window and applies backpressure by ENDING the
    /// connection once the window exceeds winHighWater (#310); readPersistent re-requests at
    /// the frontier when the consumer drains below winLowWater. Never blocks: parking this
    /// delegate callback has no flow-control contract (TLS/H2 transports keep reading at
    /// line rate into unbounded internal buffers, the #174 EXC_RESOURCE). Force-copy
    /// releases source dispatch_data per delivery (same leak control as the chunk path).
    fileprivate func appendPersistentData(_ delivered: Data, generation: Int) {
        winCond.lock()
        guard generation == connGeneration, !isFullyClosed else {
            // #93: a slow read's summary line reports how much data the stale-generation
            // guard discarded while the read waited.
            staleGenDroppedBytes += Int64(delivered.count)
            winCond.unlock()
            return
        }
        // Audit DMX-1: the range is the bound only if bytes past its end are refused. A 200 that
        // ignored Range at offset 0, or a 206 wider than asked, otherwise kept appending under
        // `connEnded`, which also disarms the high-water end below, so the rest of the file
        // streamed into the window. The excess is dropped and the transfer ended; the frontier
        // refill asks for it properly.
        var data = delivered
        var overDelivered = false
        if let end = connRangeEnd {
            let room = end + 1 - (winStart + Int64(window.count))
            if Int64(data.count) > room {
                data = data.prefix(Int(max(0, room)))
                overDelivered = true
            }
        }
        lastDeliveryAt = DispatchTime.now()   // #309: the delivery-gap watchdog's only input
        var firstDataMs: Double? = nil
        if !connFirstDataSeen {
            connFirstDataSeen = true
            genFirstDataAt = DispatchTime.now()   // [MovieClaw P55]
            firstDataMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
            // #281 retest: the price of one round trip against this origin, which is what bounds
            // how long a read may wait for bytes that are already on the wire.
            lastFirstDataMs = firstDataMs ?? 0
            // Delivery is the proof that ends a faulted lineage: release the refill pacing (and
            // a give-up latch — an origin that recovered after the faulted ladder capped out may
            // fault again later and deserves a fresh ladder, not `.distantFuture` forever).
            nextFaultedRefillAt = .distantPast
        }
        let count = data.count
        // [MovieClaw P55] 这代连接从首字节起的平均速度就是线路此刻给它的速度（推送式连接不看消费快慢，到高水位才断）
        genDeliveredBytes += Int64(count)
        let genSeconds = Double(DispatchTime.now().uptimeNanoseconds - genFirstDataAt.uptimeNanoseconds) / 1_000_000_000
        if genDeliveredBytes >= Self.linkRateMinBytes, genSeconds >= Self.linkRateMinSeconds {
            measuredLinkBytesPerSecond = Double(genDeliveredBytes) / genSeconds
        }
        // #310: delivery that lands with the backpressure end ALREADY recorded, i.e. after our
        // own cancel. A bounded in-flight tail is expected. A figure that keeps climbing is the
        // witness that ending is as advisory as suspending was (#174 blocking, #220 suspend:
        // each mechanism here has failed exactly this way once), and without a line naming it
        // the next round would start from a memprobe and a guess. Counted before the append so
        // it is attributable to the transport rather than to our own bookkeeping.
        var overshootToLog: Int64? = nil
        if connEndedByBackpressure {
            postEndDeliveryBytes += Int64(count)
            if postEndDeliveryBytes > Int64(winHighWater), !postEndOvershootLogged {
                postEndOvershootLogged = true
                overshootToLog = postEndDeliveryBytes
            }
        }
        let base = window.count
        // [MovieClaw P22] 这一块在文件里的偏移：解锁后写进字节缓存
        let byteCacheOffset = winStart + Int64(base)
        window.append(data)
        // #281 retest: retain the head of the file for the open phase, as it arrives. It cannot be
        // copied later out of the window, because `trimWindowLocked` drops it as the parse reads
        // forward, which is why the seek-time park misses on every layout whose parse reads more
        // than `winLookback` before its first excursion. Contiguity is checked rather than assumed:
        // only the connection anchored at zero, and only while it is still the tail of what is held.
        if openPhaseActive, winStart == 0, base == headSpan.count,
           headSpan.count < Self.headSpanMaxBytes {
            headSpan.append(data.prefix(Self.headSpanMaxBytes - headSpan.count))
        }
        // [MovieClaw P49] 文件头一到就找 Matroska 索引的位置，解锁后与开容器并行先取回来
        let cuesPrefetch = locateCuesLocked()
        let cuesLog = takePendingCuesLogLocked()   // [MovieClaw P58]
        addBytesFetched(count)
        // #220: the requested range has been delivered in full. That ends the connection on
        // purpose; the read loop re-requests at the frontier once the consumer has drawn down.
        var overDeliveredTransfer: (any PersistentTransfer)?
        if let end = connRangeEnd, winStart + Int64(window.count) > end {
            connEndedAtRangeEnd = true
            connEnded = true
            if overDelivered {
                overDeliveredTransfer = activeTransfer
                activeTransfer = nil
            }
        }
        winCond.broadcast()
        // #310: past high water the connection is ENDED, not suspended. suspend() is
        // advisory (#220: CFNetwork keeps draining and delivering), and a task that does
        // park under it holds a dormant established flow whose closed receive window is the
        // process-wide nw-starvation trigger this design replaces (see the backpressure doc
        // block at the water marks). Deliveries already dispatched before the cancel takes
        // effect still land here (same generation until the refill starts a new one), so
        // the window can overshoot highWater by the transport's in-flight amount; the
        // frontier is computed from what actually arrived, so nothing is discarded,
        // re-fetched, or left as a hole. The window keeps every byte already delivered
        // (they are valid and the consumer reads them) and the read loop re-requests at
        // the frontier once the consumer drains below low water.
        var toCancel: (any PersistentTransfer)?
        let ahead = window.count - max(0, Int(position - winStart))
        // #377: a demand-driven transfer is not ended here. Its backpressure is the pull budget,
        // which never asks for more than the window has room for, so reaching this point at all
        // would be a bookkeeping surprise rather than an origin outrunning the consumer; ending it
        // would put back exactly the request-per-drain-cycle cadence the flag exists to remove.
        if ahead > winHighWater, !connEnded, !isClosed,
           let installed = activeTransfer, !installed.isDemandDriven {
            connEndedByBackpressure = true
            connEnded = true
            toCancel = activeTransfer
            activeTransfer = nil
            winCond.broadcast()
        }
        winCond.unlock()
        if let byteCacheKey {
            SourceByteCache.shared.write(key: byteCacheKey, offset: byteCacheOffset, data: data)
        }
        if let cuesLog { EngineLog.emit(cuesLog, category: .demux) }
        if let cuesPrefetch { startCuesPrefetch(cuesPrefetch.range, what: cuesPrefetch.what) }
        if let overDeliveredTransfer {
            EngineLog.emit(
                "[AVIOReader] \(label) gen=\(generation) origin delivered past the requested range "
                + "end; ending the connection (audit DMX-1)",
                category: .demux)
            overDeliveredTransfer.cancelTransfer()
            overDeliveredTransfer.releaseOriginTicket()
        }
        if let toCancel {
            EngineLog.emit(
                "[AVIOReader] \(label) window high water: \(ahead / 1024 / 1024)MB ahead; ending the "
                + "connection, will re-request at the frontier once the consumer drains",
                category: .demux)
            toCancel.cancelTransfer()
            // #377: the frontier re-request follows as soon as the consumer drains, so give the
            // slot back now instead of leaving it to the completion callback.
            toCancel.releaseOriginTicket()
        }
        if let overshootToLog {
            EngineLog.emit(
                "[AVIOReader] \(label) gen=\(generation) \(overshootToLog / 1024 / 1024)MB delivered "
                + "AFTER the backpressure end; the cancel is not stopping this transport",
                category: .demux)
        }
        if let firstDataMs {
            // #93/#96 residual: a slow first-data gap is release-visible so a device trace can pair it
            // with the response-header timing above. Small header gap + large first-data gap = the body
            // stalled after headers; large header gap = server-side connection queuing. Fast reads stay
            // on the DEBUG-only path to keep the release log quiet.
            if firstDataMs > 2000 {
                EngineLog.emit("[AVIOReader] \(label) gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
            } else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] \(label) gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
                #endif
            }
        }
    }

    /// `respondedBy` is where this response came from, redirects followed, and it is passed for
    /// EVERY status: the pin still moves on a 2xx only, but a refusal has to be able to name the
    /// host that refused (#377).
    fileprivate func persistentReceivedResponse(
        _ http: HTTPURLResponse,
        respondedBy: URL?,
        generation: Int
    ) -> Bool {
        let status = http.statusCode
        var isOK = status == 200 || status == 206
        var retryAfter: TimeInterval = 0
        if Self.isRateLimitStatus(status) {
            retryAfter = Self.parseRetryAfter(http)
            noteOriginRefusal(status: status, retryAfter: retryAfter > 0 ? retryAfter : nil,
                              respondedBy: respondedBy)
        }
        var headerMs: Double? = nil
        winCond.lock()
        if generation == connGeneration {
            connStatus = status
            connRetryAfter = retryAfter
            // #93/#96 residual: time-to-first-response-header for this generation. A large value here
            // with a small subsequent first-data gap points at server-side connection queuing (the
            // origin accepted the socket but withheld the response while it served another connection
            // of the same file at full rate), the prime suspect for the ~15s cold reads.
            headerMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        // VOD: 200 at offset > 0 means server ignored Range and sent the full body
        // from byte 0 (silent corruption). Reject it. Live is exempt: transcode
        // reconnect legitimately answers 200 with "from now".
        let requestedOffset = (generation == connGeneration) ? connRequestedOffset : 0
        // Audit DMX-101: the cold open asked for a bounded range at byte 0. A 200 whose body is not
        // that range is an origin that cannot address bytes, and this connection is abandoned at the
        // head: nothing below may adopt its Content-Length as a size the persistent reader could
        // seek by.
        var rangeIgnoredAtOpen = false
        if generation == connGeneration, !isLive, rangeVerdictPending,
           Self.rangeAnswer(http, requestedStart: requestedOffset, requestedEnd: connRangeEnd) == .ignored {
            rangeIgnoredAtOpen = true
            rangeIgnoredAtOpenLength = http.expectedContentLength
        }
        // #331: the origin just told us its live stream has no byte address to resume at. Latch
        // it, so every later request in this session is the join shape instead of repeating an
        // offset that can only ever be rejected again. Nonzero offsets only: a 416 at zero is a
        // different fault and must not silently change the request shape.
        var latchedJoinShape = false
        if generation == connGeneration, isLive, status == 416, requestedOffset > 0,
           !liveOffsetsUnsatisfiable {
            liveOffsetsUnsatisfiable = true
            latchedJoinShape = true
        }
        // Issue #70: the first from-0 data connection doubles as the size probe, so the
        // playback open skips probeFileSize() entirely. Derive the total from this
        // response (206 Content-Range, or Content-Length on a from-0 2xx). Write-once
        // (fileSize <= 0), current-gen only, and never for live (whose length is
        // non-authoritative). The response precedes any body and no read() reads fileSize
        // until open() returns, so this write is ordered behind winCond just like the data.
        // #551: the warm's size meets the connection that is actually serving this session. They
        // disagree only when the warm belongs to a different response, and then the warm is the
        // wrong one: these bytes are the ones being played. Drop the whole warm rather than keep
        // spans whose offsets belong to another body, and let the write-once rule below take the
        // real size.
        if generation == connGeneration, !isLive, let adopted = adoptedWarmSize,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset), total != adopted {
            EngineLog.emit(
                "[AVIOReader] \(label) the warm said \(adopted)B, this connection says \(total)B; "
                + "dropping the prewarmed bytes (#551)", category: .demux)
            headSpan = Data()
            tailSpan = nil
            cuesSpan = nil   // [MovieClaw P58] 位置同样属于另一份字节
            cuesSpanFromHost = false
            fileSize = 0
            adoptedWarmSize = nil
        }
        if generation == connGeneration, !isLive, let byteCacheKey,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset) {
            // [MovieClaw P22] 与字节缓存记的大小对不上：源站上的文件换过了，缓存整份作废
            SourceByteCache.shared.noteContentLength(key: byteCacheKey, length: total)
        }
        if generation == connGeneration, !isLive, fileSize <= 0, !rangeIgnoredAtOpen,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset) {
            fileSize = total
            // #112: share this resolved length so a later side demuxer on the same origin can skip a probe that
            // might be starved under this connection's load and would otherwise collapse it to forward-only.
            SourceContentLengthCache.store(total, for: url)
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(total) bytes (data connection)", category: .demux)
            #endif
        }
        winCond.unlock()
        if let headerMs, headerMs > 2000 {
            EngineLog.emit(
                "[AVIOReader] gen=\(generation) response headers after \(Int(headerMs))ms status=\(status)",
                category: .demux
            )
        }
        // #331: name the latch once. A field capture that shows the reconnect shape change is the
        // difference between "the origin has no byte addresses" and "the reconnect is broken".
        if latchedJoinShape {
            EngineLog.emit(
                "[AVIOReader] \(label) live origin rejected offset \(requestedOffset) (416); "
                + "requesting the stream as a join from here",
                category: .demux
            )
        }
        if status == 200 && requestedOffset > 0 && !isLive {
            EngineLog.emit(
                "[AVIOReader] server ignored Range (200 for offset \(requestedOffset)); rejecting body",
                category: .demux
            )
            isOK = false
        }
        if rangeIgnoredAtOpen {
            EngineLog.emit(
                "[AVIOReader] \(label) origin answered the ranged open with a 200 "
                + "(Content-Length \(http.expectedContentLength)); hanging up at the head (audit DMX-101)",
                category: .demux)
            isOK = false
        }
        // Live is exempt for the same reason as above: its offset is bookkeeping, and the append
        // anchors the bytes at the frontier whatever the origin calls them.
        if isOK, !isLive, generation == connGeneration,
           let served = Self.misplacedRangeStart(http, requestedOffset: requestedOffset) {
            EngineLog.emit(
                "[AVIOReader] \(label) gen=\(generation) 206 starts at \(served), not the requested "
                + "\(requestedOffset); rejecting body (audit DMX-5)",
                category: .demux
            )
            isOK = false
        }

        if isOK {
            recordResolvedURL(respondedBy)
            return true
        }
        // The 200-ignored-Range rejection logged above; every other rejected
        // status was previously silent, leaving the reconnect storm unexplained
        // in the log.
        if status != 200 {
            EngineLog.emit(
                "[AVIOReader] \(label) gen=\(generation) rejected response status=\(status) at offset \(requestedOffset)"
                    + respondingTargetDescription(respondedBy)
                    + (retryAfter > 0 ? " retryAfter=\(Int(retryAfter))s" : ""),
                category: .demux
            )
        }
        if Self.isResolvedExpiryStatus(status) {
            invalidateResolvedURL()
        } else if Self.isResolvedHardServerError(status) {
            invalidateResolvedURL(reason: "hard \(status) from pinned URL")
        }
        return false
    }

    fileprivate func persistentConnectionEnded(error: Error?, generation: Int) {
        winCond.lock()
        let isCurrentGen = (generation == connGeneration)
        if isCurrentGen {
            connEnded = true
            // #220: the refill below keys off there being no live connection, so the finished
            // task must not stay installed.
            activeTransfer = nil
        }
        // #310: our own high-water cancel completes here as NSURLErrorCancelled. That end was
        // already logged where it was decided; reporting it as an error too would make every
        // drain cycle against a fast origin read like a transport fault.
        let deliberateEnd = isCurrentGen && (connEndedByBackpressure || connEndedAtRangeEnd)
        let windowAhead = isCurrentGen ? (window.count - max(0, Int(position - winStart))) : 0
        winCond.broadcast()
        winCond.unlock()
        if let error, !(deliberateEnd && (error as? URLError)?.code == .cancelled) {
            EngineLog.emit("[AVIOReader] \(label) conn gen=\(generation) ended with error: \(error.localizedDescription)", category: .demux)
            noteTransportSecurityFailure(error)
        }
        if isCurrentGen && isLive {
            EngineLog.emit("[AVIOReader] Live source: connection ended gen=\(generation) buffered=\(windowAhead / 1024)KB; reconnect will fire when buffer drains", category: .demux)
        }
    }

    /// Parses delta-seconds Retry-After; HTTP-date form falls back to expo backoff. Cap 15s.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return min(max(seconds, 0), 15)
    }

    // MARK: - Streaming Download (background)

    private func startStreamingDownload() {
        prefetchQueue.async { [weak self] in
            self?.streamDownloadSync()
        }
    }

    private func streamDownloadSync() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0  // No timeout for live streams
        applyExtraHeaders(&request)

        // #377: this connection is open for the whole session, so it holds its slot for the whole
        // session, which is exactly what it costs the origin. Scoped to this function because the
        // function does not return until the transfer ends. A streaming-mode source has no detour
        // or ranged probe to starve (they are all switched off on this path), so a held slot here
        // blocks nothing but a second reader on the same origin, which is the point.
        let streamTicket: OriginRequestBudget.Ticket?
        do {
            streamTicket = try requestTicket(
                for: request.url ?? url, label: "\(label) stream", timeout: Self.pumpSlotWaitSeconds)
        } catch {
            streamLock.lock()
            streamEnded = true
            streamLock.unlock()
            streamDataReady.signal()
            return
        }
        defer { OriginRequestBudget.shared.release(streamTicket) }

        let semaphore = DispatchSemaphore(value: 0)

        let delegate = StreamingDelegate(
            extraHeaders: headers(for: request.url),
            onResponse: { [weak self] response in
                // Advisory length for the EOF/EIO distinction; -1 (chunked / unknown) leaves the
                // clean-end path as the only EOF source.
                guard let self else { return }
                let expected = response.expectedContentLength
                guard expected > 0 else { return }
                self.streamLock.lock()
                self.streamExpectedBytes = expected
                self.streamLock.unlock()
            },
            onRefused: { [weak self] status, respondedBy in
                guard let self else { return }
                self.streamLock.lock()
                self.streamRefusedStatus = status
                self.streamLock.unlock()
                // #377: a metering origin is charged wherever a status is first read, and this was
                // the one path that read one without charging it. On a sequential origin this GET
                // is the session's only request (no ranged open, no probe, by construction), so its
                // 429 was seen by nobody: the budget kept offering that origin its full concurrency
                // and the revive arm had no stamp saying the source was metered rather than gone.
                if Self.isRateLimitStatus(status) {
                    self.noteOriginRefusal(status: status, respondedBy: respondedBy)
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) streaming GET refused status=\(status); hanging up at the header",
                    category: .demux)
            }
        ) { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.streamLock.lock()
            if self.streamFailed {
                self.streamLock.unlock()
                return
            }
            // Owned bytes: the chunk is retained until it is consumed, and a delivery that still
            // references the transport's dispatch_data would pin its buffer for that long.
            self.streamBuffer.append(data.withUnsafeBytes { Data($0) })
            self.streamPeakBytes = max(self.streamPeakBytes, self.streamBuffer.count)
            var toCancel: URLSessionDataTask?
            if self.streamBuffer.count > self.streamHardCap {
                self.streamFailed = true
                self.streamFailureCause = .originIgnoresFlowControl
                toCancel = self.streamingTask
            }
            // Backpressure: park the transfer once the retained buffer
            // exceeds the high water mark; readStreaming resumes it when
            // the consumer drains below the low water mark (and before
            // any wait, so a far-forward seek can't deadlock against a
            // suspended producer).
            var toSuspend: URLSessionDataTask?
            if !self.streamingTaskSuspended, self.streamBuffer.count > self.streamHighWater {
                self.streamingTaskSuspended = true
                toSuspend = self.streamingTask
            }
            self.streamLock.unlock()
            if let toCancel {
                EngineLog.emit(
                    "[AVIOReader] \(self.label) streaming buffer passed \(self.streamHardCap / 1024)KB "
                    + "with the transfer suspended: the origin ignores flow control, so the source is "
                    + "ended here to keep memory bounded and the read will fail (audit DMX-7, DMX-107)",
                    category: .demux)
                toCancel.cancel()
            } else {
                toSuspend?.suspend()
            }
            self.addBytesFetched(data.count)
            self.streamDataReady.signal()
        } onComplete: { [weak self] error in
            guard let self else {
                semaphore.signal()
                return
            }
            self.streamLock.lock()
            if error != nil, !self.isClosed { self.streamFailed = true }
            self.streamEnded = true
            self.streamLock.unlock()
            self.streamDataReady.signal()
            semaphore.signal()
        }

        let streamSession = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: request)

        // Register before resume so markClosed()/close() can cancel; re-check after.
        streamLock.lock()
        streamingSession = streamSession
        streamingTask = task
        streamLock.unlock()

        task.resume()
        if isClosed { task.cancel() }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        semaphore.wait()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming ended", category: .demux)
        #endif
        streamLock.lock()
        streamingSession = nil
        streamingTask = nil
        streamLock.unlock()
        streamSession.invalidateAndCancel()
    }

    // MARK: - Prefetch (background, seekable mode only)

    private func triggerPrefetch(from offset: Int64) {
        guard prefetchEnabled else { return }
        if fileSize > 0 && offset >= fileSize { return }

        bufferLock.lock()
        guard !isPrefetching else { bufferLock.unlock(); return }
        isPrefetching = true
        bufferLock.unlock()

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            // Bail if close() ran to avoid writing stale data back into prefetchBuffer.
            if self.isFullyClosed {
                self.bufferLock.lock()
                self.isPrefetching = false
                self.bufferLock.unlock()
                self.prefetchReady.signal()
                return
            }

            let size: Int
            if self.fileSize > 0 {
                size = min(self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            // Re-check: close() may have fired while fetchChunk was on the network.
            if !self.isFullyClosed {
                self.prefetchBuffer = data
                self.prefetchOffset = offset
            }
            self.isPrefetching = false
            self.bufferLock.unlock()

            self.prefetchReady.signal()
        }
    }

    // MARK: - Seek

    /// Internal rather than fileprivate (#281) so the seek-driven paths, the parse seek and the
    /// return trip behind it, are exercised against a real origin without going through FFmpeg,
    /// the same reason `recordRateLimitAndShouldGiveUp` is not private. Callers outside the file
    /// are tests; production reaches this through `seekCallback`.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE {
            guard fileSize <= 0, originIgnoresRange else { return fileSize }
            streamLock.lock()
            defer { streamLock.unlock() }
            return streamExpectedBytes
        }
        // For persistent mode, position is shared with the delegate thread;
        // read SEEK_CUR base under the window lock.
        let newPosition: Int64
        switch whence {
        case SEEK_SET:
            newPosition = offset
        case SEEK_CUR:
            if usePersistentReader {
                winCond.lock(); let cur = position; winCond.unlock()
                newPosition = cur + offset
            } else {
                newPosition = position + offset
            }
        case SEEK_END:
            guard fileSize >= 0 else { return -1 }
            newPosition = fileSize + offset
        default:
            return -1
        }

        if usePersistentReader {
            // Just move the cursor; the read loop decides whether to reconnect.
            // Coalesces the matroska seek-storm on open into minimal reconnects.
            winCond.lock()
            position = newPosition
            winCond.broadcast()
            winCond.unlock()
        } else if !isStreaming {
            position = newPosition
            bufferLock.lock()
            let inCurrent = position >= currentOffset &&
                position < currentOffset + Int64(currentBuffer.count)
            if !inCurrent {
                currentBuffer = Data()
                currentOffset = position
                prefetchBuffer = nil
            }
            bufferLock.unlock()
        } else {
            // Streaming: forward-only; backward seeks below the retained
            // window return failure so the demuxer doesn't silently wait 15s.
            streamLock.lock()
            let oldestRetained = streamBytesRead
            streamLock.unlock()
            if newPosition < oldestRetained { return -1 }
            position = newPosition
        }

        return newPosition
    }

    // MARK: - Network (seekable mode)

    /// Long-lived session for file-size probes. Per-request sessions force fresh TLS
    /// handshakes, which Cloudflare-fronted origins can flag as suspicious. Distinct
    /// from syncRequest's per-request pattern (load-bearing for chunk-fetch leak control).
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }()

    /// Audit DMX-5: where a 206 says its body starts, when that is not where it was asked to.
    /// Every ranged path here places the body at the REQUESTED offset, so a 206 aligned to an
    /// edge's own chunk boundary would shift every later read by the difference. Nil for any other
    /// status and for a Content-Range this cannot read (those keep the lenient historical path).
    static func misplacedRangeStart(_ http: HTTPURLResponse, requestedOffset: Int64) -> Int64? {
        guard let served = contentRangeSpan(http) else { return nil }
        return served.start == requestedOffset ? nil : served.start
    }

    /// First and last byte a 206 says it carries, nil for any other status and for a Content-Range
    /// this cannot read.
    static func contentRangeSpan(_ http: HTTPURLResponse) -> (start: Int64, end: Int64?)? {
        guard http.statusCode == 206,
              let value = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let span = trimmed.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1).first ?? ""
        guard let dash = span.firstIndex(of: "-"),
              let start = Int64(span[..<dash].trimmingCharacters(in: .whitespaces)) else { return nil }
        let end = Int64(span[span.index(after: dash)...].trimmingCharacters(in: .whitespaces))
        return (start, end)
    }

    /// Audit DMX-101, NET-102: what an origin did with `Range: bytes=a-b`, judged from the response
    /// head alone, so a reader can hang up before a body it would have to throw away. One
    /// classification for every reader (`HTTPDiscIOReader` uses it too).
    enum RangeAnswer: Equatable {
        /// A 206 that starts where asked and stays inside the ask.
        case honoured
        /// A 206 that starts where asked but runs past the requested end. The origin CAN address
        /// bytes, so the caller keeps what it asked for and hangs up (audit DMX-1).
        case overWide
        /// A 206 that starts elsewhere, the way an edge that aligns ranges to its own chunks answers.
        case misplaced(start: Int64)
        /// A 200 that is not the asked range: the body is the source from byte 0, whatever was
        /// asked, and its length is not the ask's or is not stated at all.
        case ignored
        /// A 200 at offset 0 whose Content-Length fits inside the ask: the whole file, and a small
        /// one. Nothing was ignored that matters, so the source stays sized and seekable.
        case wholeFile
        /// Any other status. It says nothing about range support.
        case unjudged
    }

    static func rangeAnswer(_ http: HTTPURLResponse, requestedStart: Int64,
                            requestedEnd: Int64?) -> RangeAnswer {
        switch http.statusCode {
        case 206:
            if let served = misplacedRangeStart(http, requestedOffset: requestedStart) {
                return .misplaced(start: served)
            }
            if let end = requestedEnd {
                if let servedEnd = contentRangeSpan(http)?.end, servedEnd > end { return .overWide }
                if http.expectedContentLength > end - requestedStart + 1 { return .overWide }
            }
            return .honoured
        case 200:
            guard requestedStart == 0 else { return .ignored }
            let length = http.expectedContentLength
            guard length > 0 else { return .ignored }
            if let end = requestedEnd, length > end + 1 { return .ignored }
            return .wholeFile
        default:
            return .unjudged
        }
    }

    /// Total size from a data-connection response: `Content-Range` total on a 206, or
    /// `Content-Length` on a from-0 2xx (origins that answer 200 ignoring Range). Nil when
    /// the origin gave no usable length (chunked, or an unknown `*` total). Issue #70.
    static func sizeFromResponse(_ http: HTTPURLResponse, requestedOffset: Int64) -> Int64? {
        // On a 206 the total lives ONLY in Content-Range; Content-Length is the partial span,
        // so a 206 with an unknown (`*`) or unparseable range must report no size, never fall
        // through to the partial length (issue #70 review #6).
        if http.statusCode == 206 {
            guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = HTTPDiscIOReader.parseContentRangeTotal(cr), total > 0 else {
                return nil
            }
            return total
        }
        if (200...299).contains(http.statusCode), requestedOffset == 0,
           http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }

    /// #112: resolve the source length for the open, preferring a live probe and falling back to a length another
    /// demuxer already resolved for the same origin. A fresh probe here can be 429'd or answered without a length
    /// while the video producer is hammering the origin, which would drop this reader to forward-only streaming so
    /// every `avformat_seek_file` returns -1 and PGS reconstruction reads nothing. The producer's persistent open
    /// caches the real length (SourceContentLengthCache.store at the data-connection response), so a starved probe
    /// reuses it and stays byte-seekable. A successful probe also seeds the cache for whoever opens next.
    private func resolveInitialFileSize() -> Int64 {
        let probed = probeFileSize()
        if probed > 0 {
            SourceContentLengthCache.store(probed, for: url)
            return probed
        }
        if let cached = SourceContentLengthCache.lookup(url), cached > 0 {
            EngineLog.emit("[AVIOReader] size probe empty; reusing cached \(cached) bytes to keep seekability (#112)", category: .demux)
            return cached
        }
        return probed
    }

    /// Each staggered open-time size probe gets its own thread, because each one blocks on a
    /// semaphore-driven URLSession round-trip. On a concurrent queue that is a global-pool worker
    /// held for the whole round-trip, and a process whose pool workers are all in a blocking wait
    /// gives the fallbacks no thread at all: `open()` spends its budget, falls back to streaming
    /// mode, and the source silently loses seekability although the origin would have answered.
    /// Seen on CI as the #255 HEAD fallback never running.

    /// How long the primary open-ended range probe runs alone before the two fallback
    /// probes fire. Fast origins resolve well inside this window and never see a
    /// fallback request (identical wire behavior to the old sequential ladder).
    static let sizeProbeStaggerSeconds: TimeInterval = 0.75

    /// Shared, condition-guarded state for the staggered-concurrent size probes. Every field is
    /// touched only while `cond` is held, so the box is safe to capture in the @Sendable probe closures.
    private final class ProbeSizeState: @unchecked Sendable {
        let cond = NSCondition()
        var resolvedSize: Int64 = -1
        var outstanding = 0
    }

    private func probeFileSize() -> Int64 {
        if let probeControl {
            // No staggered worker outlives a one-shot probe, and no fallback starts after a stop.
            if let size = rangeProbeFileSize(range: "bytes=0-"), size > 0 { return size }
            guard !probeControl.isStopped else { return -1 }
            let head = headProbeFileSize()
            if head > 0 { return head }
            guard !probeControl.isStopped else { return -1 }
            return rangeProbeFileSize(range: "bytes=0-1") ?? -1
        }
        // Staggered-concurrent ladder (#107 follow-up). The probes themselves are unchanged:
        // Range bytes=0- primary (AetherEngine#8: HEAD breaks on Cloudflare-fronted origins
        // returning 405), HEAD for live-transcode endpoints that reject Range, and the #126
        // bounded bytes=0-1 for origins that answer bytes=0- with 200/chunked but honor real
        // ranges. Sequentially each failing probe cost a full origin round-trip; a live tuner
        // pays its ~4 s tune-in on EVERY connection, so the ladder tripled the open latency
        // of every genuinely length-less source. The fallbacks now start after a short
        // stagger and run in parallel; the first positive size wins.
        // All mutable probe state lives inside ProbeSizeState, guarded entirely by its own
        // NSCondition, so the box is a safe capture for the @Sendable asyncAfter closures below
        // (Swift 6 SendableClosureCaptures otherwise flags the raw local vars and the run thunk).
        let state = ProbeSizeState()

        func launch(after delay: TimeInterval, name: String, _ run: @escaping @Sendable () -> Int64) {
            state.cond.lock(); state.outstanding += 1; state.cond.unlock()
            let probe = Thread { [weak self] in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                state.cond.lock()
                let alreadyResolved = state.resolvedSize > 0
                state.cond.unlock()
                let closed = self?.isClosed ?? true
                let size = (alreadyResolved || closed) ? -1 : run()
                state.cond.lock()
                if size > 0, state.resolvedSize <= 0 {
                    state.resolvedSize = size
                    EngineLog.emit("[AVIOReader] File size: \(size) bytes (\(name))", category: .demux)
                }
                state.outstanding -= 1
                state.cond.broadcast()
                state.cond.unlock()
            }
            probe.name = "aether.avio.size-probe.\(name)"
            probe.qualityOfService = .userInitiated
            probe.start()
        }

        launch(after: 0, name: "Range probe") { [weak self] in
            self?.rangeProbeFileSize(range: "bytes=0-") ?? -1
        }
        launch(after: Self.sizeProbeStaggerSeconds, name: "HEAD fallback") { [weak self] in
            self?.headProbeFileSize() ?? -1
        }
        launch(after: Self.sizeProbeStaggerSeconds, name: "bounded-range fallback") { [weak self] in
            self?.rangeProbeFileSize(range: "bytes=0-1") ?? -1
        }

        // Budget mirrors a single sequential probe (its own 20-25 s ceiling) plus the stagger;
        // isClosed teardown breaks the individual probes, which then signal outstanding down.
        // Sodalite#173: the wait polls isClosed itself, since a fallback still asleep in its stagger
        // would otherwise hold a closed open for up to the full stagger.
        let deadline = Date(timeIntervalSinceNow: Self.sizeProbeStaggerSeconds + min(25, chunkRequestTimeout) + 2)
        state.cond.lock()
        while state.resolvedSize <= 0 && state.outstanding > 0 && !isClosed {
            let now = Date()
            if now >= deadline { break }
            _ = state.cond.wait(until: min(deadline, now.addingTimeInterval(0.05)))
        }
        let size = state.resolvedSize
        state.cond.unlock()
        if size <= 0, !isClosed {
            EngineLog.emit("[AVIOReader] no probe resolved a size, streaming mode (forward-only)", category: .demux)
        }
        return size > 0 ? size : -1
    }

    /// Range GET cancelled at didReceive response (no body transfers). Returns the total from
    /// Content-Range on 206, or expectedContentLength on 2xx (origins that ignore Range).
    /// The primary probe is the open-ended bytes=0- form; bytes=0- over bytes=0-0: some origins
    /// special-case the single-byte form and omit length, then 429 the HEAD fallback (issue #70);
    /// bytes=0- answers with a proper Content-Range in one shot. The bounded bytes=0-1 form is
    /// the #126 last-resort probe for origins that answer bytes=0- without a length but honor
    /// real ranges.
    private func rangeProbeFileSize(range: String) -> Int64? {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        applyExtraHeaders(&request)

        // #377: `probeSession` runs on `URLSessionConfiguration.default`, so its own cap is 6 and
        // it composes with nothing. The staggered fan fires two fallbacks at once by design, which
        // on a metered origin is three requests where one was refused. The budget serialises them
        // (each waits its short slot, then proceeds), so the fan keeps its latency win on a healthy
        // origin and stops being a burst on a capped one.
        let ticket: OriginRequestBudget.Ticket?
        do {
            ticket = try requestTicket(
                for: request.url ?? url, label: "\(label) size probe",
                timeout: Self.shortFetchSlotWaitSeconds)
        } catch {
            return nil
        }
        defer { OriginRequestBudget.shared.release(ticket) }

        let delegate = ProbeDelegate(extraHeaders: headers(for: request.url))
        let task = (probeRequestSession ?? Self.probeSession).dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Bound + make abortable: still extraction caps this at its small budget so a
        // reopen mid-scrub on a stalled source can't park ~25s, and a teardown during
        // open returns at once (issue #27). Playback keeps its 25s ceiling.
        let probeBudget = min(25, chunkRequestTimeout)
        if Self.awaitSignal(semaphore, budget: probeBudget, pollInterval: 0.1,
                            shouldAbort: { [weak self] in
                                self?.isClosed == true
                            }) != .signaled {
            task.cancel()
            finishCancelledProbeRequest(semaphore)
            EngineLog.emit("[AVIOReader] Range probe (\(range)) timed out", category: .demux, level: .verbose)
            return nil
        }

        if delegate.totalSize == nil {
            EngineLog.emit("[AVIOReader] Range probe (\(range)) didn't yield a size", category: .demux, level: .verbose)
        }
        return delegate.totalSize
    }

    /// HEAD probe fallback for live-transcode endpoints that reject Range.
    private func headProbeFileSize() -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)

        do {
            // Honour the still budget here too so the open-time HEAD fallback can't
            // ride the default 35s on a stalled origin during a cold/reopen scrub (#27).
            let (_, response) = try syncRequest(request, budget: chunkRequestTimeout)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if Self.isRateLimitStatus(status) {
                    noteOriginRefusal(status: status, respondedBy: (response as? HTTPURLResponse)?.url)
                }
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \(status))", category: .demux, level: .verbose)
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)", category: .demux)
            #endif
            return length
        } catch {
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription)", category: .demux, level: .verbose)
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        if let data = fetchChunkAttempt(from: offset, size: size, forceSource: false) {
            return data
        }
        // Retry against source URL only if a cached resolved URL was used
        // (so the proxy can re-issue a fresh signed redirect).
        if cachedResolvedURL() != nil {
            return fetchChunkAttempt(from: offset, size: size, forceSource: true)
        }
        return nil
    }

    private func fetchChunkAttempt(from offset: Int64, size: Int, forceSource: Bool) -> Data? {
        let usingCachedURL = !forceSource && cachedResolvedURL() != nil
        let target = forceSource ? url : requestURL()
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: target)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = min(15, chunkRequestTimeout)
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<chunkMaxRetries {
            do {
                let (data, response) = try syncRequest(request, budget: chunkRequestTimeout)
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        if usingCachedURL && Self.isResolvedExpiryStatus(status) {
                            invalidateResolvedURL()
                        }
                        EngineLog.emit("[AVIOReader] chunk fetch got HTTP \(status) at offset \(offset)\(usingCachedURL ? " (cached URL, will retry source)" : "")", category: .demux, level: .verbose)
                        return nil
                    }
                    // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                    if status == 200 && offset > 0 && !isLive {
                        EngineLog.emit(
                            "[AVIOReader] server ignored Range (200 for offset \(offset)); rejecting chunk",
                            category: .demux
                        )
                        return nil
                    }
                    if !isLive, let served = Self.misplacedRangeStart(http, requestedOffset: offset) {
                        EngineLog.emit(
                            "[AVIOReader] chunk fetch: 206 starts at \(served), not \(offset); rejecting (audit DMX-5)",
                            category: .demux
                        )
                        return nil
                    }
                }
                addBytesFetched(data.count)
                return data
            } catch {
                // Superseded / closed / past the read deadline: this read is disposable,
                // bail at once instead of retrying into the abort (issue #27).
                if isClosed || isPastReadDeadline { return nil }
                lastError = error
                if attempt < chunkMaxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        EngineLog.emit("[AVIOReader] Fetch failed after \(chunkMaxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")", category: .demux, level: .verbose)
        return nil
    }

    /// Long-lived session for seekable-path chunk fetches paired with per-task
    /// ChunkFetchDelegate. Delegate-based incremental delivery (not completion-handler)
    /// releases source dispatch_data per delivery on the delegate queue, so the body never
    /// reaches the demux thread's autorelease pool, which is what drove the original leak.
    /// No invalidation overhead.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }()

    /// #220: long-lived session for the persistent streaming path, paired with a per-task
    /// `PersistentReadDelegate`. Bounded ranges end a connection every `persistentRangeBytes`,
    /// and a session per connection would make each of those a fresh TLS handshake against the
    /// origin. The delegate carries the connection generation, so per-task assignment is all
    /// that was ever needed here. The old per-request-session rule does not apply, and #243
    /// showed why it never could: measured against a range origin, a session per request leaks
    /// exactly as much as a shared one (+973 MB vs +968 MB per 480 MB fetched). What retains a
    /// completion-handler body is the never-draining autorelease pool of the demux thread that
    /// bridges it out, not the session. This path is delegate-based, so the body is released on
    /// the delegate queue and never reaches that pool.
    ///
    /// Never invalidated. Releasing a connection is `task.cancel()` now, not session teardown.
    private static let persistentSession: URLSession = {
        URLSession(configuration: makeSessionConfig(longLived: true), delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }()

    /// [MovieClaw P43] 预连：在两个取源会话（文件头走 `persistentSession`，尾部预读走 `chunkSession`）上各发一个
    /// HEAD，把 TCP / TLS 握手提前做掉。装载时的第一个请求就落在已经连好的连接上（经反向代理的 HTTPS 源站
    /// 实测每次播放的首个请求中位 83 毫秒，其后同一连接上的冷区域请求 60 毫秒）。只建连接，不读片源、不管结果
    static func preconnect(url: URL, headers: [String: String]) {
        for session in [persistentSession, chunkSession] {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            session.dataTask(with: request).resume()
        }
    }

    /// Outcome of an abortable semaphore wait (issue #27).
    enum WaitOutcome: Equatable { case signaled, timedOut, aborted }

    /// Wait on `semaphore` up to `budget` seconds, polling `shouldAbort` every
    /// `pollInterval`. Returns `.signaled` the moment the semaphore fires,
    /// `.aborted` within one poll of `shouldAbort()` going true, or `.timedOut`
    /// when the budget elapses. Lets a seekable chunk read bail promptly on
    /// supersede / close / read-deadline instead of parking the decode queue in a
    /// flat 35s wait (the root cause of the frozen scrub preview, issue #27).
    static func awaitSignal(
        _ semaphore: DispatchSemaphore,
        budget: TimeInterval,
        pollInterval: TimeInterval,
        shouldAbort: () -> Bool
    ) -> WaitOutcome {
        let deadline = Date(timeIntervalSinceNow: budget)
        while true {
            if shouldAbort() { return .aborted }
            let now = Date()
            if now >= deadline { return .timedOut }
            let slice = min(pollInterval, deadline.timeIntervalSince(now))
            if semaphore.wait(timeout: .now() + max(0.001, slice)) == .success {
                return .signaled
            }
        }
    }

    // MARK: - Response Body Bounds (#255)

    /// Reservation ceiling for a response whose request set no bounded `Range`. `Data` grows on
    /// demand, so the cap costs at most one reallocation on a legitimately larger body, while a
    /// bogus or whole-source declared length stays harmless.
    static let maxBodyReserve = 8 * 1024 * 1024

    /// Bytes the request can legitimately deliver: the span of a bounded `Range: bytes=a-b`, 0 for a
    /// HEAD (bodyless by definition), nil when the request is open-ended and the body is whatever the
    /// origin chooses to stream.
    ///
    /// #255: the declared `Content-Length` is not that number and never was. A HEAD answers with the
    /// whole source's length and no body at all, and an origin that ignores `Range` answers a bounded
    /// chunk request with `200` plus the whole source's length, so sizing an allocation from it asked
    /// malloc for the entire 12.4 GB movie at open time. `Data`'s storage force-unwraps the NULL that
    /// a failing malloc returns, so it traps: a host app can neither catch it nor degrade.
    static func expectedBodyBytes(for request: URLRequest) -> Int? {
        if request.httpMethod?.uppercased() == "HEAD" { return 0 }
        guard let value = request.value(forHTTPHeaderField: "Range") else { return nil }
        return boundedRangeSpan(value)
    }

    /// Span of a single bounded byte range (`bytes=a-b`). Nil for the open-ended (`bytes=a-`), suffix
    /// (`bytes=-n`), multi-range and malformed forms: none of those bound the body, so they fall back
    /// to the flat ceiling rather than a wrong limit.
    static func boundedRangeSpan(_ headerValue: String) -> Int? {
        let spec = headerValue.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else { return nil }
        let set = spec.dropFirst("bytes=".count)
        guard !set.contains(",") else { return nil }
        let parts = set.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lower = Int64(parts[0]), let upper = Int64(parts[1]),
              lower >= 0, upper >= lower else { return nil }
        let span = upper - lower + 1
        return span <= Int64(Int.max) ? Int(span) : nil
    }

    /// Bytes to reserve up front for a response body: the origin's declared length clamped to what
    /// the request itself can deliver, or to `maxBodyReserve` when the request is open-ended.
    static func bodyReservation(declaredLength: Int64, limit: Int?) -> Int {
        guard declaredLength > 0 else { return 0 }
        let ceiling = Int64(limit ?? maxBodyReserve)
        guard ceiling > 0 else { return 0 }
        return Int(min(declaredLength, ceiling))
    }

    /// #255 test hook: the largest up-front body reservation any chunk fetch has asked for since the
    /// last reset. Written on the delegate queue, read once the fetch it belongs to has completed.
    nonisolated(unsafe) static var peakBodyReserveForTesting = 0

    private func requestTicket(for url: URL, label: String,
                               timeout: TimeInterval) throws -> OriginRequestBudget.Ticket? {
        guard let probeControl else {
            let ticket = OriginRequestBudget.shared.acquire(
                for: url, label: label, timeout: timeout,
                shouldAbort: { [weak self] in self?.isClosed ?? true })
            if ticket == nil, isClosed { throw CancellationError() }
            return ticket
        }
        guard !isClosed else { throw CancellationError() }
        try probeControl.check()
        // Wait for the slot, but never past the probe's own deadline. A slot wait is the one wait the
        // watchdog cannot interrupt (it fires at reads), so the deadline has to bound it here instead.
        // Not waiting at all would fail a probe that merely arrived while one other request held the
        // origin, which is the ordinary shape when a host probes several items off one server.
        let slotWait = probeControl.remainingTime.map { min(timeout, $0) } ?? timeout
        guard let ticket = OriginRequestBudget.shared.acquire(
            for: url, label: label, timeout: slotWait) else {
            probeControl.stop(ProbeError.sourceBusy)
            throw ProbeError.sourceBusy
        }
        do { try probeControl.check() }
        catch {
            OriginRequestBudget.shared.release(ticket)
            throw error
        }
        return ticket
    }

    /// Only the probe adapter calls this, after cancelling the transfer.
    func finishProbeTransfers() {
        precondition(probeControl != nil)
        prefetchQueue.sync {}
    }

    var isDrainingProbeRequestForTesting: Bool {
        probeDrainLock.withLock { drainingProbeRequest }
    }

    private func finishCancelledProbeRequest(_ completion: DispatchSemaphore) {
        guard probeControl != nil else { return }
        probeDrainLock.withLock { drainingProbeRequest = true }
        defer { probeDrainLock.withLock { drainingProbeRequest = false } }
        // Keep the origin ticket and callback state until this task acknowledges cancellation.
        completion.wait()
    }

    private func syncRequest(_ request: URLRequest, budget: TimeInterval = 35,
                             slotLabel: String = "fetch",
                             slotWait: TimeInterval = AVIOReader.shortFetchSlotWaitSeconds) throws -> (Data, URLResponse) {
        // #377: every short fetch the reader makes (detour blocks, size probes, HEAD) funnels
        // through here, so this is the one place that has to take an origin slot for all of them.
        // Scoped to the call: unlike the pump's, this request's life IS this function's.
        let slotURL = request.url ?? url
        let ticket = try requestTicket(
            for: slotURL, label: "\(label) \(slotLabel)", timeout: slotWait)
        defer { OriginRequestBudget.shared.release(ticket) }

        let delegate = ChunkFetchDelegate(extraHeaders: headers(for: request.url),
                                          bodyLimit: Self.expectedBodyBytes(for: request))
        let task = (probeRequestSession ?? Self.chunkSession).dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Poll for close / read-deadline so a superseded or torn-down still-extraction
        // read aborts within ~100ms instead of riding the full budget (issue #27).
        let outcome = Self.awaitSignal(
            semaphore, budget: budget, pollInterval: 0.1,
            shouldAbort: { [weak self] in self?.isClosed == true || self?.readDeadlinePassedOrAborted == true }
        )
        guard outcome == .signaled else {
            task.cancel()
            finishCancelledProbeRequest(semaphore)
            throw AVIOReaderError.requestTimeout
        }

        // A truncating cancel is this reader hanging up on purpose, so the cancellation error it
        // produces is not a failed fetch: the prefix the request asked for is in hand (#255).
        if let err = delegate.error, !delegate.truncated {
            noteTransportSecurityFailure(err)
            throw err
        }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        if delegate.truncated {
            EngineLog.emit(
                "[AVIOReader] response body ran past the requested range; kept \(delegate.body.count) bytes and hung up (origin ignored Range?)",
                category: .demux, level: .verbose
            )
        }
        return (delegate.body, response)
    }
}

// MARK: - Detour Block Cache

/// Fixed-block LRU cache backing the persistent reader's detour path (AetherEngine#69). Random-access
/// parse reads on a non-faststart remote MP4 are served from here over the pooled keep-alive session
/// instead of tearing down the anchored streaming connection. Thread-safe via a single leaf lock
/// (demux-thread reads + teardown-thread `clear`); never held across the network. Stores only
/// full-size blocks (the fetch/insert decision is the caller's), so eviction can't shadow a
/// re-fetchable short-body tail. The copy + eviction math is pure and unit-tested without a network.
final class DetourBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var lru: [Int64] = []
    /// When each resident block was last inserted or served, on `now`'s clock (audit PERF-108).
    private var lastHit: [Int64: TimeInterval] = [:]
    private let maxBlocks: Int
    private let now: @Sendable () -> TimeInterval
    let blockSize: Int

    /// `now` is injectable so the idle test moves a clock instead of waiting one out.
    init(blockSize: Int, maxBlocks: Int,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
        self.now = now
    }

    /// Returns the resident block for `idx` and bumps its recency, or nil on a miss.
    func block(_ idx: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = blocks[idx] else { return nil }
        if let i = lru.firstIndex(of: idx) {
            lru.remove(at: i)
            lru.append(idx)
        }
        lastHit[idx] = now()
        return data
    }

    /// Inserts a (full-size) block, evicting the least-recently-used tail beyond `maxBlocks`.
    func insert(_ idx: Int64, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if blocks[idx] == nil { lru.append(idx) }
        blocks[idx] = data
        lastHit[idx] = now()
        while lru.count > maxBlocks {
            let evicted = lru.removeFirst()
            blocks.removeValue(forKey: evicted)
            lastHit[evicted] = nil
        }
    }

    /// Drops every block nothing has read or filled for `seconds`, and returns how many went. The
    /// cache is otherwise only emptied at close, so the blocks of a backward scrub (up to 32 MB)
    /// outlived the scrub for the whole session (audit PERF-108). Age rather than a clear at the
    /// re-anchor, because a parser ping-ponging through a region keeps hitting its blocks.
    @discardableResult
    func evictIdle(olderThan seconds: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now() - seconds
        let idle = lru.filter { (lastHit[$0] ?? 0) < cutoff }
        guard !idle.isEmpty else { return 0 }
        let gone = Set(idle)
        lru.removeAll { gone.contains($0) }
        for idx in idle {
            blocks.removeValue(forKey: idx)
            lastHit[idx] = nil
        }
        return idle.count
    }

    func clear() {
        lock.lock()
        blocks.removeAll()
        lru.removeAll()
        lastHit.removeAll()
        lock.unlock()
    }

    var residentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blocks.count
    }

    /// Copy up to `maxLen` bytes covering `offset` from the resident block into `dst`, returning the
    /// byte count. Returns nil if the covering block is not resident, or if `offset` lands in the
    /// uncovered tail of a short block (so the caller re-fetches rather than serving stale bytes).
    /// One call serves at most to the block boundary; a read spanning blocks is driven by the caller
    /// re-entering at the advanced offset. Pure given the cache contents; bumps recency on a hit.
    func serveCached(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int? {
        guard maxLen > 0, offset >= 0 else { return nil }
        let idx = offset / Int64(blockSize)
        let blockStart = idx * Int64(blockSize)
        guard let blk = block(idx) else { return nil }
        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < blk.count else { return nil }
        let n = min(maxLen, blk.count - inBlock)
        blk.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return n
    }
}

/// Preserves Range + extra headers across cross-host redirects. URLSession strips
/// custom headers on host change; without this, CDN behind AIOStreams proxy gets a
/// plain GET and either streams the full body or 400s. Credential headers follow
/// RedirectHeaderPolicy (#126): same-host destinations only, never cross-origin.
private func redirectPreservingHeaders(
    task: URLSessionTask,
    newRequest request: URLRequest,
    extraHeaders: [String: String]
) -> URLRequest {
    // #388: this is the moment the request the reader budgeted for stops being answered by the
    // origin it was budgeted against. Every fetch the reader makes passes through here, so it is
    // the one place that sees the whole chain, including the hops no response ever pins (a target
    // that answers the very first request with a 509 is never recorded as resolved).
    if let from = task.originalRequest?.url, let to = request.url {
        OriginRequestBudget.shared.noteRedirect(from: from, to: to)
    }
    return RedirectHeaderPolicy.redirectRequest(
        request,
        originalURL: task.originalRequest?.url,
        originalRange: task.originalRequest?.value(forHTTPHeaderField: "Range"),
        extraHeaders: extraHeaders)
}

// MARK: - Persistent Read Delegate

/// Forwards deliveries into the reader's sliding window with generation tagging
/// so stale-connection late callbacks are no-ops. @unchecked Sendable: only
/// mutable coupling is weak reader, guarded by winCond.
// MARK: - #377 held connection

extension AVIOReader: HeldSourceConnectionDelegate {
    func heldConnection(_ connection: HeldSourceConnection,
                        didReceive response: HTTPURLResponse,
                        from url: URL) -> Bool {
        persistentReceivedResponse(response, respondedBy: url, generation: connection.generation)
    }

    func heldConnection(_ connection: HeldSourceConnection, didReceive data: Data) {
        appendPersistentData(data, generation: connection.generation)
    }

    /// How many bytes the held connection may pull next, and the one place this flag's #310
    /// exposure is decided.
    ///
    /// #310's dose is the LENGTH of a dormant stretch rather than its existence, and a pull that
    /// tops the window up as the consumer takes bytes is dormant for `heldPullSlack` over media
    /// rate, which is the regime the starvation never fired in. The stretch that is NOT bounded
    /// that way is a consumer which has STOPPED: a paused viewer holds one for the length of the
    /// pause, and that is where #310's worst episode came from. So a pause carries a budget, and
    /// running it out ends the connection exactly the way the high water ends a pushed one. The
    /// read loop then re-requests at the frontier when playback resumes, which is the same path a
    /// completed range takes.
    ///
    /// A FULL WINDOW IS NOT THAT CASE, and reading it as one is what this method got wrong until
    /// the field hour on the reporter's origin: 213 connections ended in 60 minutes with the viewer
    /// never pausing once, because the segment producer races ahead, parks with a full cache while
    /// the muxer works, and looks from here exactly like a consumer that stopped. That is 218
    /// requests where the design describes one, and against an origin that refuses requests it is
    /// 218 chances to be refused. So a playing consumer on a full window is waited out, not ended.
    /// Waiting costs nothing on the wire: no read is issued, the socket buffer fills, and the
    /// sender stops itself, which is what ffmpeg's reader does whenever its demuxer stops reading.
    /// The 16 MB window stays what it always was, a ceiling on a transport that could not be
    /// stopped (#174 crashed at 3.4 GB still delivering, #220 measured 911 MB after a suspend);
    /// a pull transport has no such problem, so here the window fills and drains rather than being
    /// held under. On the device, arm B of the transport probe held a stream task on a closed
    /// window for 600 s with 1 Hz canaries against the origin and a neutral host clean throughout,
    /// 1180 requests and not one refusal.
    ///
    /// Blocks on `winCond`, which is what the consumer broadcasts on after every read, so a
    /// generation that is abandoned (a seek, a close, a reconnect) wakes this immediately and
    /// answers 0 rather than waiting out its budget.
    func heldConnectionPullBudget(_ connection: HeldSourceConnection) -> Int {
        var budget = 0
        var pausedEndAhead: Int? = nil
        // Only a paused consumer carries a deadline, and only from the moment it paused.
        var pauseDeadline: Date? = nil
        winCond.lock()
        while true {
            guard connection.generation == connGeneration, !connEnded, !isClosed else { break }
            let ahead = windowAheadLocked()
            let room = winHighWater - ahead
            if room >= Self.heldPullSlack {
                budget = min(room, Self.heldMaxPullBytes)
                // A read begins here, and the gap watchdog judges an OUTSTANDING one. Without this
                // the wait that preceded the grant counts against the read it granted: coming back
                // from a park longer than connStallTimeout, the first tick after this would see a
                // gap older than the timeout and end a connection nothing is wrong with.
                lastDeliveryAt = DispatchTime.now()
                break
            }
            let playing = playIntentProvider?() ?? false
            if playing {
                // A full window under a playing consumer is the producer parked with a full
                // segment cache, not a stopped one. Issue no read and wait: no byte is on the
                // wire, the socket fills, and the sender stops itself.
                //
                // The wait carries a poll rather than blocking outright, because the thing it is
                // waiting to hear about does not broadcast: nobody reads during a pause, so a
                // consumer that pauses AFTER the window filled would never wake this loop and the
                // paused budget below would never start. Measured: a 420 s pause held the
                // connection to the end of the drill with no bound spent.
                pauseDeadline = nil
                _ = winCond.wait(until: Date().addingTimeInterval(Self.heldPlayIntentPollSeconds))
                continue
            }
            let deadline = pauseDeadline ?? Date().addingTimeInterval(heldPausedBudgetSeconds)
            pauseDeadline = deadline
            if Date() >= deadline {
                connEndedByBackpressure = true
                connEnded = true
                activeTransfer = nil
                pausedEndAhead = ahead
                winCond.broadcast()
                break
            }
            _ = winCond.wait(until: deadline)
        }
        winCond.unlock()
        if let pausedEndAhead {
            EngineLog.emit(
                "[AVIOReader] \(label) held connection paused for "
                + "\(Int(heldPausedBudgetSeconds))s with \(pausedEndAhead / 1024 / 1024)MB "
                + "ahead; ending it, will re-request at the frontier when playback resumes",
                category: .demux)
        }
        return budget
    }

    func heldConnection(_ connection: HeldSourceConnection, didEndWith error: Error?) {
        connection.releaseOriginTicket()
        persistentConnectionEnded(error: error, generation: connection.generation)
    }
}

// MARK: - Persistent transfer

/// #377: the one request this reader has on the link, whichever transport carries it.
///
/// Two shapes exist. A `URLSessionDataTask` is PUSHED: it delivers on the transport's schedule and
/// the only backpressure available is to end it, which is why the reader ends its connection at the
/// window high water and asks again at low water (#310, after #220 measured the suspend advisory).
/// A `HeldSourceConnection` is PULLED: nothing arrives that was not asked for, so one request can
/// serve a whole file, which is the entire point of `LoadOptions.heldSourceConnection`.
protocol PersistentTransfer: AnyObject {
    /// Put it on the link. Called once, after the reader has installed it.
    func startTransfer()
    /// End it. Idempotent, and never called while `winCond` is held.
    func cancelTransfer()
    /// Hand the origin slot back synchronously. The transfer's own completion would do it too, but
    /// that arrives asynchronously and every caller here is about to ask for a slot again.
    /// Idempotent, so the later callback is a no-op.
    func releaseOriginTicket()
    /// True when bytes only move because the reader asked. The high-water end exists to stop a
    /// transport delivering on its own schedule; against a pull it would end a healthy connection
    /// and put back the request cadence the held path exists to remove.
    var isDemandDriven: Bool { get }
}

extension URLSessionDataTask: PersistentTransfer {
    func startTransfer() { resume() }
    func cancelTransfer() { cancel() }
    /// The ticket lives on the delegate because the delegate's lifetime IS the task's; see the
    /// note on `PersistentReadDelegate.ticket`.
    func releaseOriginTicket() { (delegate as? PersistentReadDelegate)?.releaseTicket() }
    var isDemandDriven: Bool { false }
}

private final class PersistentReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var reader: AVIOReader?
    let generation: Int
    let extraHeaders: [String: String]
    /// #377: the origin slot this connection occupies, held here because the delegate's lifetime
    /// IS the task's. Seven paths in the reader clear `activeTransfer` and only one of them is the
    /// task ending, so a ticket released alongside `activeTransfer` would leak on the other six.
    /// `didCompleteWithError` is the one point every ending passes through, cancels included.
    private let ticketLock = NSLock()
    private var ticket: OriginRequestBudget.Ticket?
    /// The URL this connection was opened against, for the one-per-origin transport line.
    private let originURL: URL

    init(reader: AVIOReader, generation: Int, extraHeaders: [String: String],
         ticket: OriginRequestBudget.Ticket?, originURL: URL) {
        self.reader = reader
        self.generation = generation
        self.extraHeaders = extraHeaders
        self.ticket = ticket
        self.originURL = originURL
    }

    /// Backstop. A slot that is never returned would cap this origin one lower for the life of the
    /// process, and at a limit of 1 that means every later request waits out its full budget before
    /// proceeding. `didCompleteWithError` covers every ending a task actually reaches; this covers
    /// a delegate that is released without its task ever completing.
    deinit { releaseTicket() }

    /// Give the slot back. Idempotent: a reconnect releases synchronously so the pump does not
    /// queue behind its own previous range, and `didCompleteWithError` then finds nothing to do.
    func releaseTicket() {
        ticketLock.lock()
        let held = ticket
        ticket = nil
        ticketLock.unlock()
        OriginRequestBudget.shared.release(held)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let reader else {
            completionHandler(.cancel)
            return
        }
        // #377: unconditional, and the 2xx gate for pinning moved into the reader with the comment
        // that explains it. A refused response has a host too, and after a pin drop that host is
        // the whole question (source, the dropped target minted again, or a fresh one).
        let respondedBy = dataTask.currentRequest?.url ?? http.url
        let allow = reader.persistentReceivedResponse(
            http, respondedBy: respondedBy, generation: generation
        )
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        reader?.appendPersistentData(data, generation: generation)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        releaseTicket()
        reader?.persistentConnectionEnded(error: error, generation: generation)
    }

    /// #377: the reporter's open question was whether a per-session connection cap can do anything
    /// against their CDN, and it is unanswerable from outside the engine. This is the only place
    /// that names the transport.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        ReaderTransportLog.note(metrics, for: originURL)
        let hops = metrics.transactionMetrics.compactMap(AVIOReader.hopTiming)
        if let line = AVIOReader.slowFirstByteLine(
            taskSeconds: metrics.taskInterval.duration,
            hops: hops
        ) {
            EngineLog.emit(line, category: .engine)
        }
    }
}

// MARK: - Chunk Fetch Delegate

/// Single-use per fetch; force-copies each delivery into `body` so source
/// dispatch_data is released per delivery. @unchecked Sendable: ownership
/// via semaphore ensures no concurrent access to mutable fields.
private final class ChunkFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    /// Most this fetch will ever buffer, nil when the request is open-ended (#255). Derived from
    /// the request, never from the response: a declared length is the origin's claim about the
    /// whole source, not about this body.
    let bodyLimit: Int?
    var body = Data()
    var response: URLResponse?
    var error: Error?
    /// Set when the origin sent past `bodyLimit` and the task was cancelled mid-body, so the
    /// caller reads the kept prefix as a success instead of a cancellation failure.
    var truncated = false
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String], bodyLimit: Int?) {
        self.extraHeaders = extraHeaders
        self.bodyLimit = bodyLimit
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if let http = response as? HTTPURLResponse {
            let reserve = AVIOReader.bodyReservation(
                declaredLength: http.expectedContentLength, limit: bodyLimit)
            AVIOReader.peakBodyReserveForTesting = max(
                AVIOReader.peakBodyReserveForTesting, reserve)
            if reserve > 0 { body.reserveCapacity(reserve) }
            let status = http.statusCode
            if status == 200 || status == 206,
               let resolved = dataTask.currentRequest?.url {
                onResolved?(resolved)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var count = data.count
        var overshoot = false
        if let bodyLimit {
            // Past what the request asked for means the origin ignored the Range and is streaming
            // the whole source at us. Keep the prefix the caller wanted and hang up, rather than
            // buffer a 12 GB movie in order to reject it afterwards (#255).
            let room = bodyLimit - body.count
            if count > room {
                count = max(0, room)
                overshoot = true
            }
        }
        if count > 0 {
            // Force-copy: body.append(data) may retain source dispatch_data via CoW,
            // defeating the per-delivery release. Manual memcpy guarantees drop on return.
            let baseCount = body.count
            body.count = baseCount + count
            body.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                        (dstBase + baseCount).copyMemory(from: srcBase, byteCount: count)
                    }
                }
            }
        }
        if overshoot {
            truncated = true
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        self.error = error
        onCompletion?()
    }
}

// MARK: - Streaming Delegate

private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable (Error?) -> Void
    /// Response hook (advisory Content-Length capture on the sequential-origin path).
    let onResponse: (@Sendable (URLResponse) -> Void)?
    /// The origin answered with a status instead of media (anything but 200/206). Called at the
    /// response header, before the hang-up, so the reader can fail the open typed. Carries the URL
    /// that answered, redirects followed: on a source that 302s to an edge target, the refusing
    /// host is not the one the request named (#377).
    let onRefused: (@Sendable (Int, URL?) -> Void)?
    /// Re-applied across cross-host redirects like every other delegate in this file;
    /// IPTV origins routinely 302 twice (portal -> panel -> archive host) and the final
    /// host must still see the caller's User-Agent / auth headers.
    let extraHeaders: [String: String]

    init(
        extraHeaders: [String: String] = [:],
        onResponse: (@Sendable (URLResponse) -> Void)? = nil,
        onRefused: (@Sendable (Int, URL?) -> Void)? = nil,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.extraHeaders = extraHeaders
        self.onResponse = onResponse
        self.onRefused = onRefused
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Redirects never reach here (willPerformHTTPRedirection follows them), so anything but
        // a 200/206 is the origin's verdict, not media: a 401/403 refusal, a 404, a 429, a 5xx.
        // Hang up at the header so the error page never enters the stream buffer, where FFmpeg
        // would probe it as container bytes and report "Invalid data found when processing
        // input" for what was a refusal (#378).
        if let http = response as? HTTPURLResponse, http.statusCode != 200, http.statusCode != 206 {
            onRefused?(http.statusCode, dataTask.currentRequest?.url ?? http.url)
            completionHandler(.cancel)
            return
        }
        onResponse?(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if DEBUG
        if let error {
            EngineLog.emit("[AVIOReader] Stream error: \(error.localizedDescription)", category: .demux)
        }
        #endif
        onComplete(error)
    }
}

// MARK: - Probe Delegate

/// File-size Range probe delegate. Preserves Range across cross-host redirects,
/// captures total from Content-Range, cancels before the body streams.
/// @unchecked Sendable: single-use per probe, semaphore ownership prevents concurrency.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        let status = http.statusCode
        if (200...299).contains(status), let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        // The probe requests `bytes=0-`, so requestedOffset is 0. Shared with the
        // data-connection path so a 206 with an unknown (`*`) total never reports its
        // partial Content-Length as the size (issue #70 review #6).
        totalSize = AVIOReader.sizeFromResponse(http, requestedOffset: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}

/// Which origins have already shown they cannot answer a suffix range, so the next open does not
/// ask them again.
///
/// #281 retest: the reporter's origin answers `bytes=-65536` with a 200 and the WHOLE file, on every
/// single open. The delegate hangs up at the response header so the body is never taken, but the
/// request is not therefore free: it is a second connection opened at the same instant as the data
/// connection whose first byte IS the cold start, sharing that uplink, against a server that has
/// already demonstrated it cannot serve it. A request that structurally cannot be answered belongs
/// once per origin, not once per open.
///
/// Only the origin's own answer to the RANGE FORM latches (a 200 that ignored it, a 416 that rejected
/// it, a Content-Range that does not describe the span, a short body). A transport failure is the
/// network's rather than the server's, and a link bad enough to time out this request will time out
/// others, so it takes two before the origin is judged by it. A status about the resource or the
/// moment (401/403/404/410, 429/503/509, other 5xx) says nothing about suffix ranges and never
/// latches: it repeats only while its condition does. Process lifetime: a server does not gain
/// suffix-range support mid-session, and forgetting across launches costs exactly one request.
final class SuffixRangeSupport: @unchecked Sendable {
    static let shared = SuffixRangeSupport()

    private static let transportFailuresBeforeDenying = 2

    private let lock = NSLock()
    private var denied: [String: String] = [:]      // origin -> how it declined, for the log line
    private var transportFailures: [String: Int] = [:]

    /// Scheme + host + port. Suffix-range support is a property of the server, not of one file.
    static func originKey(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        return "\(url.scheme ?? "http")://\(host):\(url.port.map(String.init) ?? "-")"
    }

    /// How this origin declined, or nil if it has not (yet) declined.
    func denialReason(for url: URL) -> String? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return denied[key]
    }

    func noteDeclined(_ url: URL, reason: String) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        denied[key] = reason
    }

    /// Returns true when this failure was the one that tipped the origin into being denied.
    @discardableResult
    func noteTransportFailure(_ url: URL, reason: String) -> Bool {
        guard let key = Self.originKey(for: url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard denied[key] == nil else { return false }
        let count = (transportFailures[key] ?? 0) + 1
        transportFailures[key] = count
        guard count >= Self.transportFailuresBeforeDenying else { return false }
        denied[key] = reason
        return true
    }

    /// A served fetch clears the transport tally: whatever those failures were, they were not this
    /// origin refusing the form.
    func noteServed(_ url: URL) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        transportFailures[key] = nil
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        denied.removeAll()
        transportFailures.removeAll()
    }
}

/// #281: collects the speculative tail fetch, and refuses everything that is not the tail.
///
/// The guarantee that matters is that this never downloads a body it did not ask for. Suffix
/// ranges are not universally implemented: an origin may answer `bytes=-65536` with a 200 and the
/// whole file. That body is rejected at the header, before a byte of it is accepted, and the
/// collected length is capped besides, so a lying `Content-Range` cannot grow this either.
extension AetherEngine {
    /// [MovieClaw P53] 读到在途提前取（尾部预读 / Matroska 索引）的范围时，只要它还在往回送就一直等（默认开；
    /// 关掉即原来按往返时长定的等待上限，对照用）
    nonisolated(unsafe) public static var waitsOnProgressingPrefetch = true
    /// [MovieClaw P55] 实测线路慢到一整块旁路补取在限时内到不齐时，回跳直接重连流式读、不走旁路（默认开；对照用）
    nonisolated(unsafe) public static var skipsDetourOnSlowLink = true
    /// [MovieClaw P56] 冷打开时文件头第一个请求只要 512 KB，索引提前取在途时文件头不超前预读（默认开；关掉即
    /// 一开始就要 32 MB、与索引并行，对照用）
    nonisolated(unsafe) public static var prioritizesIndexPrefetch = true
}

private final class TailPrefetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case span(Int64, Data)
        /// Named so the log says WHICH way an origin declined, since "no suffix ranges", "a 200 with
        /// the whole file" and "a short body" are three different origins to talk to a reporter about.
        ///
        /// `verdict` separates what the answer was about. Only the origin's answer to the RANGE FORM
        /// is a property of the server that repeats on every open and is worth remembering after
        /// one occurrence (`SuffixRangeSupport`); a transport failure is the network's; and a status
        /// about the resource or the moment (a 403, a 404, a 429, a 5xx) says nothing about suffix
        /// ranges at all and must not disable the prefetch for the origin once the condition passes.
        case rejected(String, verdict: Verdict)
    }

    enum Verdict {
        case declinedByOrigin
        case transportFailure
        case unrelated
    }

    private let expectedLength: Int
    private let extraHeaders: [String: String]
    private var buffer = Data()
    private var spanStart: Int64?
    private var rejection: (String, Verdict)?

    /// Called exactly once, on completion, whatever happened. A caller waits on this fetch, so a
    /// silent failure would be a caller waiting out its whole budget for bytes that are never coming.
    var onOutcome: ((Outcome) -> Void)?

    /// [MovieClaw P53] 每收到一批本段的字节调一次：读取器据此判断在途的提前取是在往回送还是卡住了
    var onProgress: (() -> Void)?

    init(expectedLength: Int, extraHeaders: [String: String]) {
        self.expectedLength = expectedLength
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Same policy as every other delegate here: credential headers do not follow a redirect
        // to another host (the #126 cross-origin token replay).
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            rejection = ("no HTTP response", .declinedByOrigin)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 206 else {
            let status = http.statusCode
            rejection = AVIOReader.suffixRangeStatusDeclinesTheForm(status)
                ? ("status=\(status) (no suffix range support)", .declinedByOrigin)
                : ("status=\(status) (about the resource, not the range form)", .unrelated)
            completionHandler(.cancel)
            return
        }
        guard let start = AVIOReader.suffixRangeStart(http, expectedLength: expectedLength) else {
            let cr = http.value(forHTTPHeaderField: "Content-Range") ?? "absent"
            rejection = ("Content-Range: \(cr) does not describe the \(expectedLength)B asked for",
                         .declinedByOrigin)
            completionHandler(.cancel)
            return
        }
        spanStart = start
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count < expectedLength else { return }
        // Audit DMX-9: clamped, as `RangeFetchDelegate` does. Appended whole, an origin that sends a
        // few bytes past its own Content-Range read as a SHORT body and latched the origin as one
        // that declines suffix ranges for the rest of the process.
        buffer.append(data.prefix(expectedLength - buffer.count))
        onProgress?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = self.outcome(error: error)
        onOutcome?(outcome)
        onOutcome = nil
    }

    private func outcome(error: Error?) -> Outcome {
        if let (reason, verdict) = rejection { return .rejected(reason, verdict: verdict) }
        if let error { return .rejected("transport: \(error.localizedDescription)", verdict: .transportFailure) }
        guard let start = spanStart else {
            return .rejected("no usable response header", verdict: .declinedByOrigin)
        }
        // A short body would put later offsets in the span at the wrong place, so a partial
        // delivery is dropped rather than trimmed: this is an optimisation, and a wrong
        // optimisation is worse than none.
        guard buffer.count == expectedLength else {
            return .rejected("short body: \(buffer.count)B of \(expectedLength)B", verdict: .declinedByOrigin)
        }
        return .span(start, buffer)
    }
}

// MARK: - C Callbacks


private func readCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(into: buf, size: size)
}

private func seekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.seek(offset: offset, whence: whence)
}

// MARK: - Errors

enum AVIOReaderError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case allocationFailed
    case noResponse
    case requestTimeout
    /// AE#140: an HLS playlist body arrived on the raw-byte live reader (misroute). Surfaced to load()
    /// so it can fail closed with a typed rejection instead of looping the endless-feed reconnect.
    case hlsPlaylistOnRawLivePath
    /// AE#154: an HLS playlist body arrived on the non-live loopback reader. FFmpeg (built with
    /// --disable-network) can never demux it; surfaced to load() so it reroutes the source onto the
    /// native remote-HLS bypass instead of dying with a bare AVERROR_INVALIDDATA.
    case hlsPlaylistOnVODPath
    /// The origin answered the source request with an HTTP status instead of media: a 401/403
    /// refusal, a 404, a 5xx. Typed so load() publishes the status (`PlaybackErrorKind.sourceRefused`)
    /// instead of the AVERROR_INVALIDDATA FFmpeg reports for an empty or error-page stream, and so the
    /// error page never reaches the demuxer.
    case httpStatus(Int)
    /// AE#495: the transport was refused over certificate trust, so no body ever existed. Typed for
    /// the same reason `httpStatus` is: without it the open surfaces FFmpeg's invalid data and a
    /// self-signed origin reads as a corrupt file.
    case transportSecurityFailed(code: Int)
    /// Audit NET-102: a remote disc image on an origin that answers a range request with the whole
    /// source (a 200). A disc image is a filesystem, which no reader can walk forward-only, so this
    /// fails at the first response head. A plain media URL on such an origin plays forward-only
    /// instead (audit DMX-101).
    case originIgnoresRange
    /// Audit DMX-107: a forward-only source kept delivering after the reader paused it, past the
    /// streaming buffer's hard cap, so the source was ended to keep memory bounded. The read that
    /// follows fails with EIO, and `AVIOReader.lastReadFailure` says why.
    case originIgnoresFlowControl

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        case .hlsPlaylistOnRawLivePath: return "HLS playlist supplied to the raw live path"
        case .hlsPlaylistOnVODPath: return "HLS playlist supplied to the VOD loopback path"
        case .httpStatus(let status): return "Origin answered HTTP \(status) for the source"
        case .transportSecurityFailed(let code):
            return TransportSecurityFailure.sentence(for: code)
        case .originIgnoresRange:
            return "The origin ignores HTTP Range requests, which a remote disc image needs"
        case .originIgnoresFlowControl:
            return "The origin kept sending after the reader paused it, past the streaming buffer's bound"
        }
    }

    var errorDescription: String? { description }
}
