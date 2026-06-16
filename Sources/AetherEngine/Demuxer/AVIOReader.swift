import Foundation
import Libavformat
import Libavutil

/// Custom AVIO context that feeds data to FFmpeg via URLSession.
///
/// Three modes:
/// - **Persistent** (file size known, prefetch enabled — the playback path):
///   a single long-lived `Range: bytes=<pos>-` GET that streams forward into
///   a sliding window. FFmpeg reads are served from the window; a new request
///   is issued ONLY on a real seek outside the window's reach. A connection
///   drop or an early EOF before `fileSize` triggers a reconnect at the last
///   delivered offset instead of being treated as terminal, and CDN
///   rate-limit statuses (429/503) back off and retry. This mirrors VLC's
///   "open once, read forward, reconnect on drop" model and is the fix for
///   AetherEngine#25 (direct-URL playback collapsing on the first CDN
///   stutter / rate-limit). See `readPersistent`.
/// - **Seekable chunked** (file size known, prefetch disabled — the still /
///   frame-extraction path): discrete HTTP Range chunks for random access,
///   where each read seeks elsewhere and a forward stream would be wasted.
///   See `readSeekable`.
/// - **Streaming** (file size unknown/-1): Single GET request, sequential reads.
///   Used for live transcoded streams from Jellyfin. See `readStreaming`.
///
/// Thread safety: AVIO callbacks run on the demux queue. Prefetch / streaming /
/// persistent-connection delivery runs on dedicated background queues. Shared
/// state protected by locks.
final class AVIOReader: AVIOProvider, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    /// Configuration template for per-request sessions. We do NOT
    /// share a long-lived URLSession across Range fetches: every
    /// completed dataTask sits inside the session's internal task
    /// list (Foundation's "completed-task pool") until the session
    /// is invalidated, retaining its 8 MB `dispatch_data_t` response
    /// body the whole time. With long-lived sessions playing a 4K
    /// HDR HEVC source at ~25 Mbps that pool grows at ~5 MB/s of
    /// heap, which is exactly the residual leak we chased after the
    /// urlCache=nil fix.
    ///
    /// Per-request sessions used to be unsafe because each
    /// configuration spun up its own URLCache (the "N URLCaches
    /// racing async invalidation" reverted in fef8ef4). Setting
    /// `config.urlCache = nil` removes the URLCache entirely, which
    /// makes per-request sessions safe again: each fetch creates a
    /// session with no URLCache, completes, and is dismantled via
    /// finishTasksAndInvalidate so the task pool releases its
    /// response data immediately.
    /// `longLived: true` is for the persistent / streaming connections
    /// that intentionally stay open for the whole playback session.
    /// `timeoutIntervalForResource` is a TOTAL-task-lifetime ceiling
    /// (it fires even while data is flowing), so the 60 s value that is
    /// right for probes and chunk fetches silently killed every stream
    /// connection at exactly t+60 s with NSURLError -1001. For VOD the
    /// frontier reconnect papered over it (Range resume, invisible);
    /// for live it made Jellyfin re-serve the transcode from byte 0
    /// every minute (the source-replay retune churn on device). Idle
    /// detection for long-lived connections is the reader's own
    /// `connStallTimeout` machinery, not URLSession's.
    private static func makeSessionConfig(longLived: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !longLived {
            config.timeoutIntervalForResource = 60
        }
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance — kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// Final URL after the first request's redirect chain resolved.
    /// Used for subsequent Range / probe fetches so we skip the proxy
    /// → CDN redirect hop on every chunk. Nil until a request
    /// completes with a 2xx/206 response whose `currentRequest.url`
    /// differs from the caller-supplied `url`.
    ///
    /// Auth-expiry statuses (401/403/404/410) against the resolved
    /// URL drop the cache and retry once against the original source
    /// URL so the proxy can re-issue a fresh signed redirect. See
    /// AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?

    /// URL to use for the next request: the cached resolved CDN URL
    /// when available, otherwise the caller-provided source URL.
    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    /// Snapshot of the current cached resolved URL, or nil if none.
    /// Used to distinguish "request hit the cached URL" from "request
    /// hit the source URL" so the auth-expiry fallback only triggers
    /// for the former.
    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    /// Cache the resolved URL after a successful response. Called from
    /// the per-task delegates' `didReceive response` with the task's
    /// `currentRequest.url` (the URL after the redirect chain). No-op
    /// when the resolved URL equals the source URL (no redirect
    /// happened) or matches an already-cached value.
    private func recordResolvedURL(_ resolved: URL?) {
        guard let resolved else { return }
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if resolved != url && resolved != _resolvedURL {
            _resolvedURL = resolved
            #if DEBUG
            EngineLog.emit("[AVIOReader] Cached resolved URL host=\(resolved.host ?? "?")", category: .demux)
            #endif
        }
    }

    /// Drop the cached resolved URL so the next request goes through
    /// the source URL and re-resolves. Called when a request against
    /// the cached URL returned an auth-expiry-like status.
    private func invalidateResolvedURL() {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if _resolvedURL != nil {
            _resolvedURL = nil
            #if DEBUG
            EngineLog.emit("[AVIOReader] Dropped resolved URL cache (expiry status)", category: .demux)
            #endif
        }
    }

    /// Status codes that mean "the cached signed URL has expired or
    /// is no longer authoritative; retry against the source URL".
    private static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 403 || status == 404 || status == 410
    }

    /// Cumulative bytes returned by every `fetchChunk` (seekable mode)
    /// and `StreamingDelegate.didReceive` (streaming mode) since the
    /// reader was opened. Read by the engine's memory probe to compare
    /// against RSS growth — if RSS climbs faster than this counter,
    /// the leak is downstream of the network read (AVPlayer, IOSurface,
    /// Foundation cache, etc.). Atomic via `counterLock`.
    private let counterLock = NSLock()
    private var _cumulativeBytesFetched: Int64 = 0
    var cumulativeBytesFetched: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _cumulativeBytesFetched
    }
    private func addBytesFetched(_ n: Int) {
        counterLock.lock()
        _cumulativeBytesFetched &+= Int64(n)
        counterLock.unlock()
    }

    /// True when the source is a live stream (no Content-Length).
    private var isStreaming: Bool { fileSize <= 0 }

    /// URL-backed sources are treated as seekable (HTTP Range / file seek).
    var isSeekable: Bool { true }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Per-instance seek chunk size. Default 4 MB (playback read-ahead);
    /// the still-extraction profile passes a smaller value for
    /// random-access single-keyframe fetches. (See the chunk-size leak
    /// history notes below -- they apply to the 4 MB playback default.)
    ///
    /// Settled chunk size: 4 MB.
    ///
    /// Field-validated 2026-05-22: paired with the delegate-based
    /// fetch path (`chunkSession` + `ChunkFetchDelegate`), 4 MB
    /// chunks stay bounded through 5+ min runs and deliver ~0.7 s
    /// cold-start chunk wait on 45 Mbps 4K HEVC (versus ~1.4 s at
    /// 8 MB, ~10 s at the historic 64 MB). Promoted from PROBE to
    /// shipped after field validation confirmed no leak at the
    /// 4 MB / ~1.4 ops/sec cadence.
    ///
    /// Why this works at any chunk size (where the historic 8 MB
    /// attempt leaked): delegate-based incremental delivery doesn't
    /// accumulate a monolithic response body in URLSession's task
    /// object. Each chunk is force-copied into the delegate's body
    /// buffer per `urlSession(_:dataTask:didReceive data:)` call,
    /// and URLSession releases the source dispatch_data after the
    /// delegate ack returns. No per-request `finishTasksAndInvalidate`
    /// either (shared session), so no invalidation backlog at high
    /// fetch frequency.
    ///
    /// Why not even smaller (2 MB / 1 MB): diminishing returns. From
    /// 8 MB → 4 MB the cold-start improved noticeably; from 4 MB →
    /// 2 MB the gain is sub-0.5 s while HTTP roundtrip overhead at
    /// 5+ ops/sec on remote CDN starts adding 50-275 ms/sec of
    /// server processing time per playback second. Not worth it.
    ///
    /// Why the previous 8 MB attempt (e327e5e) leaked at 6 MB/sec
    /// where this one doesn't: the old path used per-request
    /// URLSession + completion-handler, and URLSession's task object
    /// holds the monolithic response body in its internal state past
    /// the handler invocation until `finishTasksAndInvalidate`
    /// finishes (async). At 6 fetches/sec the pool of pending
    /// sessions piled up faster than invalidation could drain. The
    /// new path skips invalidation entirely: a shared long-lived
    /// session, incremental delivery to a delegate that force-copies
    /// each chunk, source dispatch_data released per delivery. No
    /// monolithic body, no accumulation.
    ///
    /// Trade-off captured: cold-start fetches 8 MB at source bitrate
    /// (~1 s on 50 Mbps 4K HEVC, vs ~10 s at 64 MB). Steady-state
    /// URLSession ops at ~0.8/sec for 50 Mbps source, handled by the
    /// shared session's TCP connection pool without per-fetch
    /// handshake cost.
    ///
    /// History of this knob:
    ///   - Long-form leak investigation A/B (with the periodic
    ///     demuxer recycle still active):
    ///       8 MB chunks  → 3.20 MB/s leak
    ///       64 MB chunks → 0.64 MB/s leak
    ///       256 MB chunks → 4.85 MB/s leak + memory warnings
    ///   - 1ee963d removed the recycle and the recycle race that
    ///     drove the bulk of the per-chunk retention. Bounded
    ///     mallocMB (211-291 MB oscillation through 11-min runs)
    ///     was field-measured at 64 MB chunks post-recycle-removal.
    ///   - e327e5e (2026-05-22) drop to 8 MB on the assumption that
    ///     "chunk size doesn't affect leak control after the
    ///     recycle is gone". That assumption was wrong: at 8 MB +
    ///     ~6 ops/sec at 4K HEVC bitrates, the per-request URLSession
    ///     `finishTasksAndInvalidate` (async by design) doesn't
    ///     complete between requests. URLSession instances and
    ///     their internal pools accumulate, and `mallocMB` grows
    ///     linearly at the source bitrate (~6 MB/s on a 50 Mbps
    ///     stream). Reverted to 64 MB after a 5-min Harry Potter
    ///     run hit 1.9 GB / 1.8 GB jetsam range.
    ///
    /// Why 64 MB works where 8 MB doesn't:
    ///   - URLSession ops drop from ~6/sec to ~0.8/sec
    ///   - finishTasksAndInvalidate has time to complete between
    ///     fetches, so the pool of pending sessions stays at ~1-2
    ///     instead of climbing to dozens
    ///   - Per-chunk dispatch_data still goes through force-copy
    ///     (heap-independent Data), so the per-fetch retention is
    ///     bounded; the multiplier was the pool accumulation, not
    ///     individual fetches leaking more
    ///
    /// Cost: cold-start fetches one 64 MB chunk before AVPlayer can
    /// open the asset. At 50 Mbps source bitrate ≈ ~10 s wait.
    /// Partially recovered by 6783036 (probe Demuxer reuse, saves
    /// 1-3 s by skipping the second avformat_find_stream_info), so
    /// effective cold-start is ~6-8 s versus the pre-fixes ~10 s+.
    ///
    /// Future optimisation paths (not implemented):
    ///   - Asymmetric: small first chunk (4 MB ≈ 0.6 s wait) for
    ///     fast startup, large subsequent chunks (64 MB) for low
    ///     ops/sec. Requires tracking "is this the first fetch" in
    ///     the reader.
    ///   - Single long-lived URLSession with per-task delegate
    ///     instead of per-request session. Eliminates the
    ///     invalidation backlog entirely. Risk: returns to the
    ///     historic dispatch_data task-pool retention pattern;
    ///     would need re-validating that force-copy makes the pool
    ///     drop bytes promptly enough.
    ///   - Bounded pool of N reusable URLSessions, round-robin.
    private let chunkSize: Int
    /// When false, no speculative next-chunk prefetch is issued (random
    /// access: the next read almost always seeks elsewhere, so a prefetch
    /// would be discarded and would compete with playback bandwidth).
    private let prefetchEnabled: Bool
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks
    /// Streaming-mode backpressure bounds: suspend the URLSession task
    /// once the retained buffer exceeds the high water mark, resume once
    /// the consumer drains it below the low water mark. Without this the
    /// delegate appended at line rate while a paused consumer read
    /// nothing, ballooning streamBuffer by the rest of the file.
    private static let streamHighWater = 64 * 1024 * 1024
    private static let streamLowWater = 32 * 1024 * 1024

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

    /// Growing buffer fed by the streaming task, read by FFmpeg.
    private var streamBuffer = Data()
    private var streamBytesRead: Int64 = 0
    private var streamEnded = false
    private let streamLock = NSLock()
    private let streamDataReady = DispatchSemaphore(value: 0)

    // MARK: - Persistent Mode (single forward-streaming connection, playback path)

    /// Pause delivery once the window holds this many bytes AHEAD of the
    /// read cursor. Blocking the delegate callback applies TCP backpressure
    /// so a fast CDN can't balloon the window for a slow consumer. Kept low
    /// (16 MB) because the whole point of the persistent connection is that
    /// it never re-requests during steady-state playback, so a deep read-
    /// ahead buys nothing and only costs heap. Peak resident window ≈
    /// highWater + one URLSession delivery + lookback + trim slack; with
    /// incremental deliveries that lands around 22 MB and can never run
    /// away (the next delivery blocks on backpressure).
    private static let winHighWater = 16 * 1024 * 1024
    /// Bytes kept BEHIND the read cursor for small backward seeks (the
    /// matroska demuxer routinely re-reads a few KB). Anything older is
    /// trimmed off the front of the window.
    private static let winLookback = 2 * 1024 * 1024
    /// Only trim once the behind-cursor slack exceeds lookback by this much,
    /// so the O(n) front-drop runs in ~4 MB batches instead of on every
    /// 256 KB read (avoids an O(n²) memmove storm).
    private static let winTrimBatch = 4 * 1024 * 1024
    /// A forward seek within this reach of the current frontier keeps the
    /// live connection (reads block until the stream fills to the target,
    /// trimming as it goes). Beyond it, reconnecting at the target is cheaper
    /// than streaming the gap.
    private static let seekKeepForwardLimit = 8 * 1024 * 1024
    /// No bytes delivered for this long on a live connection means the CDN
    /// stalled the socket; treat it as a drop and reconnect.
    private static let connStallTimeout: TimeInterval = 20
    /// A reconnect that delivers at least this much before failing again
    /// counts as progress and clears the unproductive streak. Sized so a
    /// healthy stream (which delivers MB between real drops) always clears
    /// it and only a flapping origin accumulates.
    private static let minReconnectProgress: Int64 = 512 * 1024
    /// Give up after this many CONSECUTIVE unproductive reconnects (a
    /// permanent 403/410, a dead origin, or an origin that flaps without
    /// making progress). VLC retries forever; we cap so a genuinely gone or
    /// pathological source neither hangs the demux thread nor hammers the
    /// CDN indefinitely. Counts unproductive reconnects, not total ones, so
    /// a long playback over a flaky link is not penalised.
    private static let reconnectMaxUnproductive = 12

    /// Guards every persistent-mode field below AND serves as the
    /// condition variable the demux thread and the delivery callback wait
    /// on. NSCondition (not a counting semaphore) because waiting here is
    /// edge-triggered on "window/connection state changed", re-checked
    /// against a predicate under the lock: that makes wakeups exact (no
    /// accumulated-signal busy-spin) and the stall timeout meaningful.
    private let winCond = NSCondition()
    /// Contiguous bytes buffered from the live connection, starting at
    /// `winStart`. `position` (the FFmpeg read cursor) indexes into the
    /// source; `position - winStart` is the offset within `window`.
    private var window = Data()
    private var winStart: Int64 = 0
    /// Current connection finished (graceful completion or error). When set
    /// and `position < fileSize`, the reader reconnects at the frontier.
    private var connEnded = false
    /// Last HTTP status seen on the active connection's response.
    private var connStatus = 0
    /// `Retry-After` (seconds) parsed from a 429/503 response, honoured
    /// before the next reconnect.
    private var connRetryAfter: TimeInterval = 0
    /// Bumped on every (re)connect. Delegate callbacks carry the generation
    /// they were created for and are ignored once stale, so an invalidated
    /// connection's late deliveries can't corrupt the window.
    private var connGeneration = 0
    private var activeSession: URLSession?
    private var activeTask: URLSessionDataTask?
    /// Consecutive UNPRODUCTIVE reconnects (each delivered less than
    /// `minReconnectProgress` before failing again). Reset to 0 on any real
    /// progress. A genuinely flaky link that still streams MB between drops
    /// never trips this; a flapping origin that hands out a few KB then RSTs
    /// every time does, so we stop hammering the CDN (the request storm
    /// AetherEngine#25 also reports) instead of reconnecting forever.
    /// Demux-thread-only; no lock needed.
    private var unproductiveReconnects = 0
    /// `cumulativeBytesFetched` snapshot at the last reconnect, to measure
    /// progress since. Demux-thread-only.
    private var bytesAtLastReconnect: Int64 = 0

    /// True for the playback path: known file size + sequential read-ahead.
    /// Selects the persistent forward-streaming reader over the chunked
    /// random-access one.
    ///
    /// For a live source (`isLive`), the persistent reader is always
    /// selected even without a known fileSize. The persistent reader has
    /// full reconnect/backoff machinery; the streaming reader has none. A
    /// live feed that drops its connection would otherwise collapse to a
    /// silent EOF in `readStreaming`. `isStreaming` no longer takes
    /// precedence for live sources.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// When true, the reader treats the source as a genuinely endless live
    /// feed: `fileSize` is non-authoritative (may be 0 or a stale chunk
    /// length) and the persistent-read EOF branch that fires on
    /// `position >= fileSize` is suppressed. When the unproductive-reconnect
    /// cap is hit on a live source the reader sets `liveExhausted` instead
    /// of collapsing to a silent EOF, so the demuxer surfaces a terminal
    /// error the host can map to "live source lost". For a non-live source
    /// all existing EOF / cap behaviour is unchanged.
    let isLive: Bool

    /// Set to true by `readPersistent` when the unproductive-reconnect cap
    /// is hit on a live source. `readPersistent` then returns a distinct
    /// FFmpeg error code (-5 / EIO) instead of AVERROR_EOF, so the demuxer
    /// raises a `readFailed` error the engine maps to `.error("live source
    /// lost")` rather than a silent EOF/stall. Demux-thread-only (written
    /// under no lock; read by the same thread before the read path exits).
    private(set) var liveExhausted = false

    /// Timestamp of the last UNPLANNED reconnect (connection drop or socket
    /// stall, not a seek). The producer correlates this with a backward
    /// source-PTS reset to detect a server that restarted its stream from
    /// the beginning on re-GET (Jellyfin transcode respawn re-serving from
    /// byte 0): the reader cannot see that at the byte level because the
    /// 200-at-offset answer is indistinguishable from a legitimate "from
    /// now" live rejoin. Demux-thread-only: written inside `readPersistent`
    /// and read by the pump thread, which is the same thread (the AVIO read
    /// callback executes synchronously inside `av_read_frame`).
    private(set) var lastUnplannedReconnectAt: Date?

    init(url: URL, extraHeaders: [String: String] = [:], chunkSize: Int = 4 * 1024 * 1024, prefetchEnabled: Bool = true, isLive: Bool = false) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
    }

    /// Apply the caller-supplied extra headers to a request. Used by
    /// every site that builds a URLRequest against the source URL
    /// (probe HEAD, Range fetch, streaming GET) so auth headers flow
    /// consistently. Range / method / timeout are set elsewhere and
    /// not overridden here.
    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func open() throws {
        fileSize = probeFileSize()

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

        if usePersistentReader {
            // Persistent mode (playback and live): open one forward-streaming
            // connection at offset 0 and wait for the first bytes before
            // returning so avformat_open_input has data to probe. For a live
            // source this path is reached even without a known fileSize.
            startPersistentConnection(at: 0)
            winCond.lock()
            let deadline = Date(timeIntervalSinceNow: 15)
            while window.isEmpty && !connEnded && !isClosed {
                if !winCond.wait(until: deadline) { break }
            }
            let gotData = !window.isEmpty
            winCond.unlock()
            if !gotData {
                // No first byte within 15s (slow or dead origin). Proceed
                // anyway; the read loop's stall/reconnect machinery takes
                // over once avformat_open_input starts pulling.
                EngineLog.emit("[AVIOReader] Persistent open: no data within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else if isStreaming {
            // Streaming mode (non-live, no Content-Length): start a continuous
            // GET in the background. Data accumulates in streamBuffer, read()
            // serves from it. No reconnect; a dropped connection surfaces as
            // EOF. For live sources the persistent path is used instead.
            startStreamingDownload()
            _ = streamDataReady.wait(timeout: .now() + .seconds(15))
        } else {
            // Seekable chunked mode (still extraction / random access):
            // pre-fill the first chunk with a Range request.
            if let data = fetchChunk(from: 0, size: chunkSize) {
                currentBuffer = data
                currentOffset = 0
            }
        }
    }

    private var isClosed = false
    private var isFullyClosed = false

    /// Optional wall-clock deadline for read operations. `.distantFuture`
    /// means "no deadline" (normal playback). When armed via
    /// `beginReadDeadline`, the read callback returns -1 once the deadline
    /// passes, which makes an in-flight `avformat_seek_file` abort instead
    /// of grinding through a multi-GB linear forward scan. This happens when
    /// a source's MKV Cues index is missing or points past EOF: libavformat's
    /// matroska seek then degrades from "one or two byte-range reads" into a
    /// sequential read of (typically) half the file — tens of minutes on a
    /// remote source, indistinguishable from a hang. Used only to bound the
    /// VOD cue prewarm (see `Demuxer.seekBounded`); read relaxed from the
    /// demux thread, exactly like `isClosed`.
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read actually returned early because the deadline passed.
    /// Lets `Demuxer.seekBounded` report whether the seek was capped even
    /// though `avformat_seek_file` may still return success (matroska keeps a
    /// partial keyframe index from the bytes it scanned before the abort).
    /// Written and read on the same thread that drives the synchronous seek.
    private(set) var readDeadlineFired = false

    /// Arm the read deadline `seconds` from now. Call immediately before a
    /// bounded seek; always pair with `endReadDeadline()`.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
        // Wake a read already parked in the forward-wait so it re-evaluates
        // against the new deadline instead of sleeping the full stall window.
        winCond.lock()
        winCond.broadcast()
        winCond.unlock()
    }

    /// Disarm the read deadline. Call right after the bounded seek returns.
    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    /// Streaming-mode session/task, held as fields so `markClosed()` /
    /// `close()` can cancel the in-flight download. Without this the GET
    /// kept streaming after teardown (endless for chunked responses with
    /// no Content-Length) and the semaphore wait in `streamDownloadSync`
    /// parked a prefetchQueue thread forever: one leaked connection,
    /// URLSession, and thread per closed streaming session. Guarded by
    /// `streamLock` (set on the prefetch queue, read from teardown threads).
    private var streamingSession: URLSession?
    private var streamingTask: URLSessionDataTask?
    /// True while the streaming task is suspended for backpressure.
    /// Guarded by `streamLock`; suspend/resume calls stay balanced
    /// because every transition flips this flag under the lock.
    private var streamingTaskSuspended = false

    /// Mark as closed without freeing resources. The AVIO read callback
    /// checks this flag and returns -1 immediately, which causes
    /// av_read_frame to return an error and unblock the demux thread.
    /// Call this BEFORE acquiring the demuxer's access lock to prevent
    /// deadlock when the demux thread is suspended inside av_read_frame.
    func markClosed() {
        isClosed = true
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
        // Streaming mode: cancel the in-flight download so the origin
        // stops sending and the completion delegate fires, which releases
        // the semaphore wait in streamDownloadSync.
        streamLock.lock()
        let sTask = streamingTask
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        sTask?.cancel()
        // Persistent mode: wake a read blocked waiting for forward data and
        // release a delivery callback blocked on backpressure. Bumping the
        // generation makes any in-flight delegate callback go stale, and the
        // broadcast wakes both the demux-thread wait and the delegate's
        // backpressure wait so they re-check and exit.
        winCond.lock()
        connGeneration &+= 1
        winCond.broadcast()
        winCond.unlock()
    }

    /// Fully release the AVIOContext, internal AVIO buffer, prefetch /
    /// current data buffers, and signal stream-mode termination.
    /// Idempotent against repeat invocation, but NOT idempotent against
    /// `markClosed` — they're two separate state transitions:
    ///
    /// 1. `markClosed` (unblock demux thread) — fast, no allocations.
    ///    `Demuxer.close()` calls it first so `av_read_frame` returns
    ///    immediately and the demuxer's access lock can be acquired
    ///    without waiting on a suspended read.
    /// 2. `close` (free resources) — invoked once the demuxer's
    ///    access lock is released. Must NOT short-circuit when
    ///    `isClosed` is already true (the previous `guard !isClosed`
    ///    did exactly that, which silently leaked the 64 MB current
    ///    + 64 MB prefetch chunk Data buffers any time a demuxer
    ///    teardown ran). `isFullyClosed` is a separate latch for
    ///    actual idempotency.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free releases the struct but NOT ctx->buffer
            // (verified against aviobuf.c); without this av_free every
            // demuxer open leaked the 256 KB AVIO buffer. Must free
            // ctx.pointee.buffer, not our original av_malloc pointer:
            // FFmpeg can realloc the buffer internally (ffio_set_buf_size).
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil

        bufferLock.lock()
        currentBuffer = Data()
        prefetchBuffer = nil
        bufferLock.unlock()

        streamLock.lock()
        streamEnded = true
        streamBuffer = Data()
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        streamDataReady.signal()
        // Cancel a still-running streaming download (markClosed normally
        // already did; this covers a close() without prior markClosed).
        sTask?.cancel()
        sSession?.invalidateAndCancel()

        // Persistent mode: invalidate the live connection (stale generation
        // drops any late delivery), drop the window, and release waiters.
        winCond.lock()
        connGeneration &+= 1
        connEnded = true
        let session = activeSession
        activeSession = nil
        activeTask = nil
        window = Data()
        winCond.broadcast()
        winCond.unlock()
        session?.invalidateAndCancel()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        if isPastReadDeadline { readDeadlineFired = true; return -1 }
        // For a live source, persistent reader is preferred even without a
        // known fileSize. Check usePersistentReader before isStreaming so a
        // live feed with no Content-Length is routed through the reconnect-
        // capable persistent path rather than the single-shot streaming path.
        if usePersistentReader { return readPersistent(into: buf, size: size) }
        if isStreaming { return readStreaming(into: buf, size: size) }
        return readSeekable(into: buf, size: size)
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
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

                guard let data = fetchChunk(from: position, size: fetchSize), !data.isEmpty else {
                    // nil = transport failure (budget exhausted); EMPTY =
                    // a 2xx response with no body, which used to refetch
                    // the same offset forever (the retry budget only
                    // covers transport errors).
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
                streamBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                streamLock.unlock()

                position += Int64(toCopy)
                totalRead += toCopy

                // Trim consumed data to prevent unbounded memory growth.
                // Keep last 1MB for potential small backward seeks.
                // subdata, not removeFirst: removeFirst leaves the slice's
                // backing storage growing with total streamed bytes (see
                // trimWindowLocked for the full mechanism).
                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer = streamBuffer.subdata(in: trimAmount..<streamBuffer.count)
                    streamBytesRead += Int64(trimAmount)
                }
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended, streamBuffer.count < Self.streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
            } else if ended {
                break
            } else {
                // About to wait for data: a backpressure-suspended task
                // would never deliver any, so resume it first (covers a
                // forward seek whose target lies beyond the suspended
                // frontier).
                streamLock.lock()
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                // Wait for more data from the streaming task
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Persistent Read (single forward-streaming connection)

    /// Serve FFmpeg reads from the sliding window fed by one long-lived
    /// `Range: bytes=<offset>-` connection. The state machine:
    ///
    ///   - cursor inside the window  → copy, advance, trim behind, done
    ///   - cursor before the window  → backward seek: reconnect at cursor
    ///   - cursor at/after fileSize   → genuine EOF (the ONLY EOF we report)
    ///   - cursor far ahead of frontier → forward seek out of reach: reconnect
    ///   - cursor just ahead, conn live → wait for the stream to fill forward
    ///   - cursor needs bytes, conn ended → drop/early-EOF: reconnect + backoff
    ///
    /// Crucially a fetch failure NEVER collapses into AVERROR_EOF the way the
    /// chunked path does — only `position >= fileSize` does. Drops, stalls,
    /// and 429/503 rate-limits reconnect at the frontier instead of killing
    /// the demuxer (AetherEngine#25).
    private func readPersistent(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if isPastReadDeadline { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            // Evaluate the whole decision under one lock acquisition so the
            // window can't shift between snapshot and use, and so the
            // forward-wait can release-and-reacquire atomically.
            winCond.lock()

            // No live connection (initial entry or post-give-up): open one.
            if activeTask == nil {
                let target = position
                winCond.unlock()
                seekReconnect(at: target)
                continue
            }

            let curPosition = position

            // Backward seek before the buffered window: reconnect at cursor.
            if curPosition < winStart {
                winCond.unlock()
                seekReconnect(at: curPosition)
                continue
            }

            let posInWindow = Int(curPosition - winStart)
            let available = window.count - posInWindow
            if available > 0 {
                let copyNow = min(available, requestSize - totalRead)
                window.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInWindow)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: copyNow)
                }
                position = curPosition + Int64(copyNow)
                totalRead += copyNow
                trimWindowLocked()
                unproductiveReconnects = 0      // real progress
                winCond.broadcast()              // window may have shrunk: wake backpressure
                winCond.unlock()
                continue
            }

            // Nothing buffered at the cursor. Decide why (still under lock).
            let frontier = winStart + Int64(window.count)
            let ended = connEnded
            let status = connStatus
            let retryAfter = connRetryAfter

            // Genuine end of file — the ONLY path that reports EOF.
            // For a live source fileSize is non-authoritative (may be 0 or
            // a stale chunk-length header); skip this check entirely so a
            // live feed never gets a synthesized EOF from a position
            // comparison.
            if !isLive && fileSize > 0 && curPosition >= fileSize {
                winCond.unlock()
                return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
            }

            // Forward seek beyond the live stream's reach: reconnect at target.
            if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {
                winCond.unlock()
                seekReconnect(at: curPosition)
                continue
            }

            if !ended {
                // Live connection streaming toward the cursor: wait for it to
                // fill forward. NSCondition.wait releases the lock while
                // blocked and re-acquires before returning; a false return
                // means the connStallTimeout elapsed with no state change,
                // i.e. a socket stall — treat it as a drop and reconnect.
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: Self.connStallTimeout), readDeadline))
                winCond.unlock()
                // Woken by the read deadline (bounded seek): bail at the loop
                // top, which returns -1 and aborts the seek. Do this before the
                // stall handling so a deadline wake isn't misread as a socket
                // stall (which would reconnect instead of aborting).
                if isPastReadDeadline { continue }
                if !signaled {
                    if recordReconnectAndShouldGiveUp() {
                        EngineLog.emit("[AVIOReader] Persistent stall gave up at offset \(frontier) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                        if isLive {
                            liveExhausted = true
                            return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                        }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    EngineLog.emit("[AVIOReader] Persistent stall at offset \(frontier), reconnecting", category: .demux)
                    lastUnplannedReconnectAt = Date()
                    backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: 0)
                    startPersistentConnection(at: frontier)
                }
                continue
            }

            // Connection ended before EOF (drop, early close, or a non-2xx
            // the response handler cancelled). Reconnect at the frontier with
            // backoff; honour Retry-After for 429/503.
            winCond.unlock()
            if recordReconnectAndShouldGiveUp(status: status) {
                EngineLog.emit("[AVIOReader] Persistent reconnect exhausted at offset \(frontier) status=\(status) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                if isLive {
                    liveExhausted = true
                    return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                }
                return totalRead > 0 ? Int32(totalRead) : -1
            }
            EngineLog.emit("[AVIOReader] Persistent conn ended at offset \(frontier) status=\(status), reconnecting (streak=\(unproductiveReconnects) retryAfter=\(retryAfter)s)", category: .demux)
            lastUnplannedReconnectAt = Date()
            backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: retryAfter)
            startPersistentConnection(at: frontier)
        }

        return Int32(totalRead)
    }

    /// Trim consumed bytes off the front of the window once the slack behind
    /// the cursor exceeds the lookback by a full batch, so the front-drop
    /// runs in ~`winTrimBatch` steps instead of on every read. Caller holds
    /// `winCond`.
    ///
    /// The trim MUST re-base into fresh storage (`subdata`), never
    /// `removeFirst`. `Data.removeFirst` only advances the slice's lower
    /// bound; the backing `__DataStorage` stays addressed from its origin,
    /// and the `count.setter` growth in `appendPersistentData` reallocates
    /// it to fit the slice's ever-increasing upper bound. Net effect: the
    /// allocation grows with every byte ever streamed through the
    /// connection even though `window.count` holds at ~20 MB. On an
    /// 80 Mbps remux this leaked ~14 MB/s into one realloc block until
    /// jetsam (AetherEngine#31, Instruments stack: appendPersistentData →
    /// Data count.setter → ensureUniqueBufferReference(growingTo:);
    /// verified standalone: 512 MB streamed through a 20 MB
    /// removeFirst-trimmed window = +513 MB footprint, subdata re-base =
    /// +9 MB flat). `subdata` copies the live ~18 MB into a compact buffer
    /// and releases the old storage; at the ~4 MB batch cadence that is a
    /// few cheap memcpys per second.
    private func trimWindowLocked() {
        let behind = Int(position - winStart)
        let dropThreshold = Self.winLookback + Self.winTrimBatch
        if behind > dropThreshold {
            let drop = behind - Self.winLookback
            window = window.subdata(in: drop..<window.count)
            winStart += Int64(drop)
        }
    }

    /// Intentional reconnect for a seek (backward, far-forward, or initial
    /// open). Not a failure, so it clears the unproductive streak and
    /// rebases the progress counter before opening the new connection.
    private func seekReconnect(at offset: Int64) {
        unproductiveReconnects = 0
        bytesAtLastReconnect = cumulativeBytesFetched
        startPersistentConnection(at: offset)
    }

    /// Account a failure-driven reconnect against the progress-aware cap.
    /// If at least `minReconnectProgress` bytes were delivered since the
    /// last reconnect the streak resets (the link is flaky but alive);
    /// otherwise it grows. Returns true once the streak exceeds the cap, so
    /// a dead or flapping origin neither hangs the demux thread nor hammers
    /// the CDN forever. Demux-thread-only.
    private func recordReconnectAndShouldGiveUp(status: Int = 0) -> Bool {
        let now = cumulativeBytesFetched
        if now - bytesAtLastReconnect >= Self.minReconnectProgress {
            unproductiveReconnects = 0
        } else {
            unproductiveReconnects += 1
        }
        bytesAtLastReconnect = now
        // A hard HTTP error (4xx/5xx without retry semantics; 429/503
        // carry Retry-After and stay on the normal budget) on a source
        // that has NEVER delivered a byte is a server-side open failure,
        // e.g. Jellyfin's ffmpeg cannot read the channel and answers 500
        // only after its full transcode-failure latency (~15-20s per
        // attempt). Grinding the regular budget against that costs a
        // minute+ before the user sees an error. One retry, then out.
        let isHardError = status >= 400 && status != 429 && status != 503
        if now == 0 && isHardError {
            return unproductiveReconnects > 1
        }
        // A source that has NEVER delivered a single byte is dead-on-arrival
        // (hard HTTP 5xx on a live tuner, wrong URL), not a flaky-but-alive
        // link; the full 13-attempt budget kept such opens grinding for
        // minutes (and, before the probe-abort hook, into the next
        // sessions). Give those up after a handful of attempts. Anything
        // that ever produced data keeps the full progress-aware budget so
        // mid-stream resilience is unchanged.
        let cap = now == 0
            ? Self.reconnectMaxUnproductiveNeverProductive
            : Self.reconnectMaxUnproductive
        return unproductiveReconnects > cap
    }

    /// Reconnect budget for a connection that has never delivered any data
    /// (see `recordReconnectAndShouldGiveUp`). 4 attempts ride out a
    /// transient transcode spin-up hiccup (~10-15 s with backoff) without
    /// grinding a dead tuner for minutes.
    private static let reconnectMaxUnproductiveNeverProductive = 4

    /// Sleep before a reconnect. A productive reconnect (streak 0) retries
    /// immediately so a single clean drop doesn't stall playback; the delay
    /// grows (0.5s → 8s) only as the unproductive streak rises. A
    /// server-supplied Retry-After always wins if larger. Sleeps in short
    /// slices so a close during the wait is honoured promptly.
    private func backoffBeforeReconnect(streak: Int, retryAfter: TimeInterval) {
        let expo = streak <= 0 ? 0.0 : min(Double(1 << min(streak, 4)) * 0.5, 8.0)
        let total = min(max(expo, retryAfter), 15.0)
        if total <= 0 { return }
        var slept = 0.0
        while slept < total {
            if isClosed { return }
            Thread.sleep(forTimeInterval: 0.1)
            slept += 0.1
        }
    }

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Tear down any live connection and open a fresh forward-streaming GET
    /// at `offset`. Bumps the generation so late callbacks from the old
    /// connection are ignored. Safe to call from the demux thread.
    private func startPersistentConnection(at offset: Int64) {
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        winStart = offset
        window = Data()
        connEnded = false
        connStatus = 0
        connRetryAfter = 0
        let oldSession = activeSession
        activeSession = nil
        activeTask = nil
        // Wake a backpressure-blocked delegate from the OLD generation so it
        // re-checks, sees it is stale, and returns instead of sitting on the
        // 0.2s safety timeout.
        winCond.broadcast()
        winCond.unlock()

        // Invalidate outside the lock; releases the old delegate + any bytes.
        oldSession?.invalidateAndCancel()

        if isClosed { return }

        var request = URLRequest(url: requestURL())
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.timeoutInterval = 0  // long-lived; stalls handled by the reader
        applyExtraHeaders(&request)

        let delegate = PersistentReadDelegate(
            reader: self,
            generation: generation,
            extraHeaders: extraHeaders
        )
        let session = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)

        winCond.lock()
        // A close() that raced in while we were building the session wins:
        // it bumped the generation, so don't install a stale connection.
        guard generation == connGeneration, !isClosed else {
            winCond.unlock()
            session.invalidateAndCancel()
            return
        }
        activeSession = session
        activeTask = task
        winCond.unlock()

        task.resume()
        #if DEBUG
        EngineLog.emit("[AVIOReader] Persistent conn start gen=\(generation) offset=\(offset)", category: .demux)
        #endif
    }

    /// Delegate callback: a chunk arrived. Force-copies into the window so
    /// the source dispatch_data is released per delivery (same leak control
    /// as the chunk path), wakes a reader waiting for forward data, then
    /// applies backpressure by blocking on the condition until the consumer
    /// has drained the window below the high-water mark.
    ///
    /// Window peak ≈ winHighWater + one URLSession delivery (deliveries are
    /// incremental, typically well under a MB) + lookback + trim slack. The
    /// high-water check is per-delivery, so a single very large delivery can
    /// briefly overshoot, but it can never run away: the next delivery
    /// blocks here until the reader drains.
    fileprivate func appendPersistentData(_ data: Data, generation: Int) {
        winCond.lock()
        guard generation == connGeneration, !isFullyClosed else {
            winCond.unlock()
            return
        }
        let count = data.count
        let base = window.count
        window.count = base + count
        window.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let d = dst.baseAddress, let s = src.baseAddress {
                    (d + base).copyMemory(from: s, byteCount: count)
                }
            }
        }
        addBytesFetched(count)
        winCond.broadcast()   // wake a reader waiting for forward data

        // Backpressure: wait on the condition (which releases the lock while
        // blocked, so the reader can copy + trim + broadcast) until the
        // window drains below the high-water mark, this connection goes
        // stale, or we close. The 0.2s timeout is a belt-and-suspenders
        // re-check; correctness comes from the broadcasts, not the poll.
        while generation == connGeneration && !isClosed {
            let ahead = window.count - max(0, Int(position - winStart))
            if ahead <= Self.winHighWater { break }
            _ = winCond.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
        winCond.unlock()
    }

    /// Delegate callback: response headers arrived. Captures the status,
    /// caches the resolved CDN URL on success, parses Retry-After on a
    /// rate-limit, and drops an expired signed URL so the reconnect falls
    /// back to the source. Returns false to cancel the body on a non-2xx.
    fileprivate func persistentReceivedResponse(
        _ http: HTTPURLResponse,
        resolvedURL: URL?,
        generation: Int
    ) -> Bool {
        let status = http.statusCode
        var isOK = status == 200 || status == 206
        var retryAfter: TimeInterval = 0
        if status == 429 || status == 503 {
            retryAfter = Self.parseRetryAfter(http)
        }
        winCond.lock()
        if generation == connGeneration {
            connStatus = status
            connRetryAfter = retryAfter
        }
        // VOD only: a 200 for a connection opened at offset > 0 means
        // the server ignored the Range header and is sending the full
        // body from byte 0; the window would label those bytes at
        // `winStart = offset` and feed FFmpeg data from the wrong file
        // position (silent corruption). Reject the body; the
        // reconnect/backoff machinery turns this into an honest failure
        // instead. LIVE is exempt: a live transcode reconnect at the
        // frontier legitimately answers 200 with the stream "from now",
        // the byte offset is synthetic there and continuation-by-time
        // is exactly what the live window models.
        let requestedOffset = (generation == connGeneration) ? winStart : 0
        winCond.unlock()
        if status == 200 && requestedOffset > 0 && !isLive {
            EngineLog.emit(
                "[AVIOReader] server ignored Range (200 for offset \(requestedOffset)); rejecting body",
                category: .demux
            )
            isOK = false
        }

        if isOK {
            if let resolvedURL { recordResolvedURL(resolvedURL) }
            return true
        }
        if Self.isResolvedExpiryStatus(status) {
            invalidateResolvedURL()
        }
        return false
    }

    /// Delegate callback: the connection finished (graceful or error). Marks
    /// it ended so the reader's wait loop reconnects if more bytes are owed.
    fileprivate func persistentConnectionEnded(error: Error?, generation: Int) {
        winCond.lock()
        let isCurrentGen = (generation == connGeneration)
        if isCurrentGen {
            connEnded = true
        }
        let windowAhead = isCurrentGen ? (window.count - max(0, Int(position - winStart))) : 0
        winCond.broadcast()
        winCond.unlock()
        if let error {
            EngineLog.emit("[AVIOReader] Persistent conn gen=\(generation) ended with error: \(error.localizedDescription)", category: .demux)
        }
        if isCurrentGen && isLive {
            // Log drop/close detection for live sources. If the window has
            // buffered data the read path continues without stalling and
            // reconnects silently once the buffer drains; otherwise it
            // reconnects immediately. This fires on both graceful server
            // close (shutdown/Connection:close) and transport errors.
            EngineLog.emit("[AVIOReader] Live source: connection ended gen=\(generation) buffered=\(windowAhead / 1024)KB; reconnect will fire when buffer drains", category: .demux)
        }
    }

    /// Parse a `Retry-After` header (delta-seconds form; HTTP-date form is
    /// ignored and falls back to exponential backoff). Capped at 15s so a
    /// hostile value can't park the demux thread.
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

        let semaphore = DispatchSemaphore(value: 0)

        let delegate = StreamingDelegate { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.streamLock.lock()
            self.streamBuffer.append(data)
            // Backpressure: park the transfer once the retained buffer
            // exceeds the high water mark; readStreaming resumes it when
            // the consumer drains below the low water mark (and before
            // any wait, so a far-forward seek can't deadlock against a
            // suspended producer).
            var toSuspend: URLSessionDataTask?
            if !self.streamingTaskSuspended, self.streamBuffer.count > Self.streamHighWater {
                self.streamingTaskSuspended = true
                toSuspend = self.streamingTask
            }
            self.streamLock.unlock()
            toSuspend?.suspend()
            self.addBytesFetched(data.count)
            self.streamDataReady.signal()
        } onComplete: { [weak self] in
            self?.streamLock.lock()
            self?.streamEnded = true
            self?.streamLock.unlock()
            self?.streamDataReady.signal()
            semaphore.signal()
        }

        let streamSession = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: request)

        // Register BEFORE resume so a racing markClosed()/close() can
        // cancel the task; re-check the close flag afterwards to cover a
        // teardown that ran between the registration and the resume.
        streamLock.lock()
        streamingSession = streamSession
        streamingTask = task
        streamLock.unlock()

        task.resume()
        if isClosed { task.cancel() }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        // Wait until stream ends, errors out, or a teardown cancels the
        // task (markClosed/close): all three fire the completion delegate.
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

            // Bail before issuing the fetch if close already ran.
            // Without this the closure would still spend up to one
            // chunk-size worth of network time downloading data
            // we're about to throw away, and a teardown that races
            // with an in-flight prefetch can complete the fetch
            // AFTER `close()` has cleared the buffers — the closure
            // would then write its fresh chunk-size Data back into
            // `prefetchBuffer`, undoing the cleanup.
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
            // Re-check under lock: close() may have fired while
            // fetchChunk was blocking on the network. If so, drop the
            // freshly-fetched data on the floor instead of pinning
            // chunk-size bytes in prefetchBuffer for an
            // already-discarded reader. The Data goes out of scope at
            // the end of this block and its backing buffer is freed
            // immediately.
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

    fileprivate func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE { return fileSize }

        // Compute the target. For persistent mode `position` is shared with
        // the delegate thread, so read the SEEK_CUR base under the window
        // lock; the other whences don't touch it.
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
            // Don't reconnect here: just move the cursor. The read loop
            // decides whether the live connection can still serve the new
            // position (forward within reach) or needs a reconnect (backward
            // before the window, or far forward). This coalesces the
            // seek-storm the matroska demuxer fires on open into the minimum
            // number of reconnects.
            winCond.lock()
            position = newPosition
            winCond.broadcast()
            winCond.unlock()
        } else if !isStreaming {
            // Seekable chunked mode: invalidate buffers if outside range
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
            // Streaming mode: the connection is forward-only and only
            // `streamTrimThreshold` bytes behind the cursor are retained.
            // A backward seek below the retained window can never be
            // served; pre-fix this path reported success and the
            // following readStreaming then waited 15 s for data that
            // would never arrive and collapsed into a silent EOF, with
            // FFmpeg believing the seek had landed. Report failure
            // instead so the demuxer treats the position as unseekable.
            streamLock.lock()
            let oldestRetained = streamBytesRead
            streamLock.unlock()
            if newPosition < oldestRetained { return -1 }
            position = newPosition
        }

        return newPosition
    }

    // MARK: - Network (seekable mode)

    /// Long-lived URLSession dedicated to file-size probes. AetherEngine.load()
    /// probes the same URL twice (once via probe Demuxer, once via session
    /// Demuxer), and per-request sessions force a fresh TLS handshake each
    /// time — Cloudflare-fronted origins can flag the changing TLS
    /// fingerprint as suspicious, intermittently slowing or 400-ing the
    /// repeat probe. A single long-lived session keeps the connection
    /// pool warm and the fingerprint stable. Distinct from `syncRequest`'s
    /// per-request session pattern, which is load-bearing for chunk-fetch
    /// leak control but adds no benefit to a one-byte probe.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private func probeFileSize() -> Int64 {
        // Per Delarkz's AetherEngine#8: HEAD probes break against origins
        // that reject HEAD (e.g. Cloudflare-fronted tb-cdn.st returning
        // 405). Without a known file size AVIOReader falls back to
        // streaming mode where SEEK_SET / SEEK_END both return -1, which
        // breaks any demuxer that seeks on open (MKV / WebM Cues, AVI
        // index, non-faststart MP4) and disables user scrubbing on
        // everything else.
        //
        // Replace with Range bytes=0-0 GET, cancel in didReceive
        // response so the body never streams. Fall back to HEAD if
        // the Range probe doesn't yield a size (live-transcode URLs
        // that don't accept Range early in the session).
        if let size = rangeProbeFileSize(), size > 0 {
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(size) bytes (Range probe)", category: .demux)
            #endif
            return size
        }
        return headProbeFileSize()
    }

    /// Range `bytes=0-0` GET that cancels in `didReceive response`.
    /// Returns the total size parsed from `Content-Range: bytes 0-0/<TOTAL>`
    /// on a 206 response, or `expectedContentLength` on a 2xx response
    /// (some origins ignore Range and respond with full content + length).
    /// Nil on cancellation, timeout, network error, or unparseable
    /// Content-Range.
    private func rangeProbeFileSize() -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        applyExtraHeaders(&request)

        let delegate = ProbeDelegate(extraHeaders: extraHeaders)
        let task = Self.probeSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + .seconds(25)) == .timedOut {
            task.cancel()
            #if DEBUG
            EngineLog.emit("[AVIOReader] Range probe timed out → trying HEAD", category: .demux)
            #endif
            return nil
        }

        if delegate.totalSize == nil {
            #if DEBUG
            EngineLog.emit("[AVIOReader] Range probe didn't yield a size → trying HEAD", category: .demux)
            #endif
        }
        return delegate.totalSize
    }

    /// Legacy HEAD probe, kept as fallback for live-transcode endpoints
    /// that don't accept Range early in the session.
    private func headProbeFileSize() -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)

        do {
            let (_, response) = try syncRequest(request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) → streaming mode", category: .demux)
                #endif
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)\(length <= 0 ? " streaming mode" : "")", category: .demux)
            #endif
            return length
        } catch {
            // HEAD timeout or network error, fall back to streaming mode.
            // This is expected for live transcode URLs where the server
            // needs to start transcoding before responding.
            #if DEBUG
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription) → streaming mode", category: .demux)
            #endif
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        // First attempt: use the cached resolved CDN URL if we have
        // one, otherwise the source URL. If the cached URL was used
        // and returned an auth-expiry-like status, fall back to the
        // source URL for one more attempt so the proxy can re-issue
        // a signed redirect.
        if let data = fetchChunkAttempt(from: offset, size: size, forceSource: false) {
            return data
        }
        // Only retry against the source if the first attempt actually
        // used a cached URL. Otherwise the second pass would just
        // repeat the same request.
        if cachedResolvedURL() != nil {
            return fetchChunkAttempt(from: offset, size: size, forceSource: true)
        }
        return nil
    }

    /// Single fetch pass against either the cached resolved URL or
    /// the source URL. Returns nil on any non-200/206 response,
    /// dropping the cached URL when the failure looks like an expiry.
    private func fetchChunkAttempt(from offset: Int64, size: Int, forceSource: Bool) -> Data? {
        let usingCachedURL = !forceSource && cachedResolvedURL() != nil
        let target = forceSource ? url : requestURL()
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: target)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                let (data, response) = try syncRequest(request)
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        if usingCachedURL && Self.isResolvedExpiryStatus(status) {
                            invalidateResolvedURL()
                        }
                        return nil
                    }
                    // VOD only: a 200 for a Range request at offset > 0
                    // means the server ignored Range and sent the FULL
                    // body from byte 0; storing it labeled at `offset`
                    // would feed FFmpeg bytes from the wrong file
                    // position (silent stream corruption). Reject; an
                    // honest failure beats corrupt media. (Live never
                    // uses the chunked path, but keep the guard
                    // consistent with the persistent one.)
                    if status == 200 && offset > 0 && !isLive {
                        EngineLog.emit(
                            "[AVIOReader] server ignored Range (200 for offset \(offset)); rejecting chunk",
                            category: .demux
                        )
                        return nil
                    }
                }
                addBytesFetched(data.count)
                return data
            } catch {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Fetch failed after \(Self.maxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")", category: .demux)
        #endif
        return nil
    }

    /// Long-lived URLSession dedicated to chunk fetches in the seekable
    /// path. Paired with per-task `ChunkFetchDelegate` instances that
    /// receive bytes incrementally and force-copy each delivery into
    /// our own buffer.
    ///
    /// Why long-lived this time (the historic leak chase rejected
    /// long-lived sessions): the original leak was driven by
    /// completion-handler-style dataTasks where URLSession's task
    /// pool accumulated monolithic response bodies past completion-
    /// handler return. The delegate-based path doesn't accumulate —
    /// URLSession delivers chunks as they arrive and releases its
    /// internal references once the delegate ack returns. With
    /// per-delivery force-copy, the source dispatch_data is released
    /// per delivery, never accumulating. No invalidation overhead per
    /// fetch either, so high-frequency small-chunk patterns don't
    /// stack up un-invalidated sessions.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        // Delegate-based incremental fetch on a shared long-lived
        // session. See `chunkSession` for the why; the rest of this
        // function is just lifecycle: build a fresh delegate, attach
        // it to a fresh task on the shared session, wait on a
        // semaphore for completion, hand back our heap-allocated
        // body Data.
        let delegate = ChunkFetchDelegate(extraHeaders: extraHeaders)
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + .seconds(35)) == .timedOut {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        if let err = delegate.error { throw err }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        return (delegate.body, response)
    }
}

/// Shared redirect policy for every AVIOReader delegate: preserve the
/// `Range` header + caller-supplied extra headers across cross-host
/// redirects. URLSession's default behaviour strips custom request
/// headers when a redirect changes host; without this the redirected
/// origin (e.g. a Cloudflare CDN behind an AIOStreams proxy) sees a
/// plain GET and either streams the whole body (busted memory) or
/// 400s on proxies that require Range.
private func redirectPreservingHeaders(
    task: URLSessionTask,
    newRequest request: URLRequest,
    extraHeaders: [String: String]
) -> URLRequest {
    var updated = request
    if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range") {
        updated.setValue(originalRange, forHTTPHeaderField: "Range")
    }
    for (name, value) in extraHeaders {
        updated.setValue(value, forHTTPHeaderField: name)
    }
    return updated
}

// MARK: - Persistent Read Delegate

/// Per-connection delegate for the persistent forward-streaming reader.
/// Forwards incremental deliveries straight into the reader's window
/// (which force-copies + applies backpressure) and reports response /
/// completion back through generation-tagged callbacks so a reconnected
/// reader ignores a stale connection's late events.
///
/// `@unchecked Sendable`: the only mutable coupling is the `weak reader`,
/// and every callback hops into the reader under its `winCond`. The
/// generation guard there makes stale-connection callbacks no-ops.
private final class PersistentReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var reader: AVIOReader?
    let generation: Int
    let extraHeaders: [String: String]

    init(reader: AVIOReader, generation: Int, extraHeaders: [String: String]) {
        self.reader = reader
        self.generation = generation
        self.extraHeaders = extraHeaders
    }

    /// See `redirectPreservingHeaders`.
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
        let resolved = (http.statusCode == 200 || http.statusCode == 206)
            ? dataTask.currentRequest?.url
            : nil
        let allow = reader.persistentReceivedResponse(
            http, resolvedURL: resolved, generation: generation
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
        reader?.persistentConnectionEnded(error: error, generation: generation)
    }
}

// MARK: - Chunk Fetch Delegate

/// Per-task delegate for the seekable-mode range fetch. Receives
/// response bytes incrementally and force-copies each delivery into
/// its own `body` Data buffer, so the source dispatch_data references
/// can be released per delivery instead of accumulating in URLSession's
/// task pool past completion.
///
/// `@unchecked Sendable` because the delegate is single-use per fetch
/// and ownership is enforced by the calling thread blocking on a
/// semaphore: URLSession's delegate callbacks run on its own queue
/// while the calling thread waits, so there's no concurrent access to
/// the mutable fields. Body access from the caller happens only after
/// `onCompletion` fires + the semaphore signals.
private final class ChunkFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var body = Data()
    var response: URLResponse?
    var error: Error?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    /// See `redirectPreservingHeaders`.
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
        // Pre-reserve buffer space when Content-Length is known so
        // body.append doesn't repeatedly realloc as chunks stream in.
        if let http = response as? HTTPURLResponse {
            let len = Int(http.expectedContentLength)
            if len > 0 { body.reserveCapacity(len) }
            // Surface the post-redirect URL so the reader can cache
            // it for subsequent range fetches. Only on success: a 4xx
            // redirect target shouldn't poison the cache.
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
        // Explicit force-copy: append a fresh contiguous range to our
        // heap-backed `body` and memcpy the source bytes in. Foundation's
        // own `body.append(data)` may keep a reference to the source
        // dispatch_data via copy-on-write semantics, defeating the
        // whole point. Manual memcpy through withUnsafeMutableBytes
        // guarantees the source can be dropped once this method returns.
        let count = data.count
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

/// URLSession delegate that delivers data chunks incrementally
/// instead of buffering the entire response.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable () -> Void

    init(onData: @escaping @Sendable (Data) -> Void, onComplete: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onComplete = onComplete
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
        onComplete()
    }
}

// MARK: - Probe Delegate

/// Per-task delegate for the file-size Range probe. Preserves the Range
/// header across cross-host redirects (URLSession default drops it),
/// captures the total size from the 206 response's `Content-Range`
/// header, and cancels the task before the body streams.
///
/// `@unchecked Sendable` because the delegate is single-use per probe
/// and is owned by the calling thread via the semaphore; URLSession's
/// delegate callbacks run on its own queue but the calling thread
/// blocks until `onCompletion` fires, so there's no concurrent access
/// to the mutable fields.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    /// See `redirectPreservingHeaders`.
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

    /// Capture Content-Range total size, then cancel so the body
    /// never streams. The fast path is a 206 response with
    /// `Content-Range: bytes 0-0/<TOTAL>`; we also accept a plain
    /// 2xx with a positive `Content-Length`, which is what some
    /// origins return when they ignore Range entirely on the first
    /// byte.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        // Surface the post-redirect URL so the reader can cache it for
        // subsequent range fetches. Only on success: a 4xx redirect
        // target shouldn't poison the cache.
        let status = http.statusCode
        if (status == 206 || (200...299).contains(status)),
           let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        if status == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.firstIndex(of: "/") {
            let totalString = contentRange[contentRange.index(after: slash)...]
            if totalString != "*", let size = Int64(totalString) {
                totalSize = size
                return
            }
        }
        if (200...299).contains(status), http.expectedContentLength > 0 {
            totalSize = http.expectedContentLength
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}

// MARK: - C Callbacks


/// FFmpeg AVERROR(EIO): input/output error. Used as the terminal error
/// code when a live source's reconnect cap is hit, so the demuxer raises
/// a `readFailed` error distinct from a normal EOF. The host maps this to
/// `.error("live source lost")`. Value = AVERROR(EIO) = -5.
private let AVERROR_EIO_VALUE: Int32 = -5

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

enum AVIOReaderError: Error, CustomStringConvertible {
    case allocationFailed
    case noResponse
    case requestTimeout

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        }
    }
}
