import Foundation
import CommonCrypto

/// Live HLS ingest as a forward-only `IOReader`. Resolves master -> highest-BANDWIDTH variant, polls the media playlist, fetches MPEG-TS segments through a bounded prefetch pipeline (#177: up to `maxConcurrentSegmentFetches` in flight, committed in playlist order), and exposes a single TS byte stream for `AetherEngine.load(source: .custom(reader, formatHint: "mpegts"), options: <isLive>)`.
///
/// Phase-1: unencrypted TS on the MAIN variant only. Encrypted (EXT-X-KEY), fMP4 (EXT-X-MAP), unreachable, and stalled streams all go terminal with `HLSIngestError`; host falls back to the Jellyfin-mediated route.
///
/// Demuxed-audio (ARD-style video-only variants + separate EXT-X-MEDIA:TYPE=AUDIO,URI=...): the resolver spins up a companion `HLSLiveIngestReader` on the rendition playlist and exposes it as `companionAudioReader`. The companion accepts TS and Apple packed audio (ADTS AAC with ID3v2 PRIV program-clock timestamp; ARD masteraudio1 style). `resolveSegmentFormatHint` blocks until the first segment is classified so the engine picks the right FFmpeg demuxer. `packedAudioTimestampOffset90k` anchors the synthesized side-audio clock.
///
/// FIFO caps at 16 MB plus at most one segment of overshoot.
public final class HLSLiveIngestReader: IOReader, LiveIngestSourceInfo, @unchecked Sendable {

    /// Governs first-segment acceptance: `.mainVideo` requires TS; `.companionAudio` also accepts Apple packed audio.
    enum Role {
        case mainVideo
        case companionAudio
    }

    private let playlistURL: URL
    private let httpHeaders: [String: String]
    /// The URL the host gave `httpHeaders` for. A companion inherits its parent's, since its own
    /// playlist URL is one the master named (audit NET-7).
    let credentialOrigin: URL
    private let role: Role
    private let fifo = ByteFIFO(capacity: 16 * 1024 * 1024)
    /// Wider than the VOD reader's 2 MB: a live window with hours of DVR at short segments is a
    /// legitimately long playlist, and this one is refetched every few seconds rather than once.
    static let maximumPlaylistBytes = 8 * 1024 * 1024
    private let session: URLSession
    private var ingestTask: Task<Void, Never>?
    private let startLock = NSLock()
    private var started = false
    private var closed = false
    // All _-prefixed vars are protected by startLock.
    private var _terminalFailure: Error?
    /// Written before any segment byte reaches the FIFO; first write wins.
    private var _upstreamTargetDuration: Double?
    /// Tracks observed segment-arrival cadence for LL-HLS shaping (AetherEngine#167). Updated whenever new
    /// upstream segments appear; read via `observedLiveCadenceSeconds`.
    private var _cadenceMeter = LiveArrivalCadenceMeter()
    /// AE#447: longest EXTINF the upstream has actually served, the measured counterpart to
    /// `_upstreamTargetDuration`. Monotonic; read via `upstreamSegmentDurationSeconds`.
    private var _upstreamSegmentDurationSeconds: Double?
    /// AE#684: summed EXTINF of the join batch. Written with the join line, before its bytes flow.
    private var _joinBacklogSeconds: Double?
    /// AE#684: the join batch has been committed to the FIFO in full / has been seen consumed.
    private var _joinBatchCommitted = false
    private var _joinSpent = false
    /// Installed by the resolver before the first FIFO byte; nil = muxed audio.
    private var _companionAudioReader: HLSLiveIngestReader?
    /// AE#359: SUBTITLES renditions of the picked variant, resolved to absolute URLs. Metadata only.
    private var _subtitleRenditions: [LiveSubtitleRenditionInfo] = []
    /// AE#359: EXT-X-PROGRAM-DATE-TIME of the first segment this reader joined at, i.e. the wall time
    /// the engine's own timeline starts at. The anchor a sibling rendition is placed against.
    private var _joinWallClock: Date?
    /// "mpegts" or "aac", classified from the first segment's leading bytes, written before that segment's first FIFO byte.
    private var _segmentFormatHint: String?
    private var _packedAudioTimestampOffset90k: Int64?
    /// `LoadOptions.liveEdgeCushionSeconds`, validated, set by the engine before the first read: the
    /// join takes enough of the upstream listing to cover it (`HLSPlaylistTracker.joining(cushion:)`).
    private var _joinCushionSeconds: Double?
    /// The Retry-After of the last refused playlist request, taken by the refresh loop as it waits.
    private var _playlistRetryAfter: TimeInterval?

    /// `formatResolved` flips after classification OR on any ingest exit, so `resolveSegmentFormatHint` never outwait a dead ingest.
    private let formatCondition = NSCondition()
    private var formatResolved = false

    /// AES-128 key cache keyed by URI. FAST providers reuse one key per clip; lock is never held across the fetch (concurrent miss just refetches 16 bytes).
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    /// #177: bounded prefetch window. Serial fetch paid a connection + TTFB round-trip per segment
    /// with no bytes flowing, capping ingest near real-time on high-bitrate streams. Four in-flight
    /// fetches saturate the link while bounding in-memory segment bytes to the window size.
    static let maxConcurrentSegmentFetches = 4

    /// AE#678: the prefetch window narrowed to the origin's request budget. A host that declares
    /// `maxConcurrentSourceRequests = 1` for a single-connection provider meant every request this
    /// reader makes, and four parallel segment fetches were four connections to it.
    static func segmentFetchConcurrency(budgetLimit: Int?) -> Int {
        guard let budgetLimit else { return maxConcurrentSegmentFetches }
        return max(1, min(maxConcurrentSegmentFetches, budgetLimit))
    }

    /// The URL the host loaded, which is what `OriginRequestBudget` keys the declared ceiling on.
    var budgetOriginURL: URL { playlistURL }

    /// First-segment classification latch; touched only from the ingest task's ordered commit path.
    private var sniffedFirstSegment = false

    public var terminalError: HLSIngestError? {
        // Keep the public terminal-state contract; the engine consumes the original cause below.
        terminalFailure.map { ($0 as? HLSIngestError) ?? .playlistUnreachable(status: -1) }
    }

    var terminalFailure: Error? {
        startLock.withLock { _terminalFailure }
    }

    public var upstreamTargetDuration: Double? {
        startLock.withLock { _upstreamTargetDuration }
    }

    public var observedLiveCadenceSeconds: Double? {
        let now = Self.monotonicNow()
        return startLock.withLock { _cadenceMeter.observedCadence(at: now) }
    }

    public var upstreamSegmentDurationSeconds: Double? {
        startLock.withLock { _upstreamSegmentDurationSeconds }
    }

    var joinBacklogSeconds: Double? {
        startLock.withLock { _joinBacklogSeconds }
    }

    var joinIsSpent: Bool {
        let (spent, committed, companion) = startLock.withLock {
            (_joinSpent, _joinBatchCommitted, _companionAudioReader)
        }
        if spent { return true }
        guard Self.pumpJoinIsSpent(
            main: (committed, fifo.isEmptyWithReaderParked),
            companion: companion?.pumpJoinState
        ) else { return false }
        startLock.withLock { _joinSpent = true }
        return true
    }

    /// One reader's half of `joinIsSpent`: whether its ingest ever started, whether its join batch
    /// is committed, and whether it is empty with its consumer parked on it.
    var pumpJoinState: (started: Bool, committed: Bool, parked: Bool) {
        let (isStarted, committed) = startLock.withLock { (started, _joinBatchCommitted) }
        return (isStarted, committed, fifo.isEmptyWithReaderParked)
    }

    /// AE#684: the fact is the PUMP's, not one reader's. With a demuxed audio rendition the cutter
    /// merges two readers on one thread and parks on whichever runs dry first, and a rendition whose
    /// segments end a little before the video's runs dry first every time: the video reader is then
    /// never parked, and a fact read off it alone never becomes true (measured: the full seal over a
    /// window that cannot hold it, 2.2 s to first picture under `.fastZap` and 10.4 s under
    /// `.standard`, where 7.25.1 took 0.18 s). So both join batches have to be committed, and the
    /// cutter has to be parked on EITHER empty reader: it holds a packet of the other one it cannot
    /// place until the dry one delivers, so nothing more is cut either way. A companion that was
    /// never started is not being read at all and does not count.
    static func pumpJoinIsSpent(main: (committed: Bool, parked: Bool),
                                companion: (started: Bool, committed: Bool, parked: Bool)?) -> Bool {
        guard main.committed else { return false }
        guard let companion, companion.started else { return main.parked }
        guard companion.committed else { return false }
        return main.parked || companion.parked
    }

    public var closedLiveCadenceSeconds: Double? {
        startLock.withLock { _cadenceMeter.closedCadence }
    }

    /// Monotonic seconds (uptime); immune to wall-clock jumps that would corrupt interval measurement.
    private static func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public var companionAudioReader: IOReader? {
        startLock.withLock { _companionAudioReader }
    }

    var subtitleRenditions: [LiveSubtitleRenditionInfo] {
        startLock.withLock { _subtitleRenditions }
    }

    var joinWallClock: Date? {
        startLock.withLock { _joinWallClock }
    }

    public var packedAudioTimestampOffset90k: Int64? {
        startLock.withLock { _packedAudioTimestampOffset90k }
    }

    /// Blocks (bounded by `formatResolveTimeout`) until the first segment is classified. Classification happens before any FIFO byte, so the demuxer that opens immediately after reads from byte 0. Returns nil when the ingest went terminal or timed out.
    public func resolveSegmentFormatHint() -> String? {
        startIfNeeded()
        let deadline = Date().addingTimeInterval(Self.formatResolveTimeout)
        formatCondition.lock()
        while !formatResolved, Date() < deadline {
            if !formatCondition.wait(until: deadline) { break }
        }
        formatCondition.unlock()
        return startLock.withLock { _segmentFormatHint }
    }

    /// 30s: ingest's per-fetch timeouts (10s request / 30s resource, 3 attempts) keep healthy streams inside this; anything slower is dead and should fail fast to the server-muxed route.
    private static let formatResolveTimeout: TimeInterval = 30

    /// Install companion under startLock. If close() raced the resolver, the new companion is closed immediately so no loop or URLSession outlives the parent.
    /// Set before the first read; a reader already ingesting keeps the depth it joined at.
    func setJoinCushion(_ seconds: Double?) {
        startLock.lock()
        _joinCushionSeconds = seconds
        startLock.unlock()
    }

    private var joinCushionSeconds: Double? {
        startLock.lock()
        defer { startLock.unlock() }
        return _joinCushionSeconds
    }

    private func installCompanion(_ companion: HLSLiveIngestReader) {
        companion.setJoinCushion(joinCushionSeconds)
        startLock.lock()
        let raceClosed = closed
        if !raceClosed { _companionAudioReader = companion }
        startLock.unlock()
        if raceClosed { companion.close() }
    }

    public convenience init(playlistURL: URL) {
        self.init(playlistURL: playlistURL, httpHeaders: [:], role: .mainVideo)
    }

    /// `httpHeaders` ride on every fetch (playlist, segment, AES key) and inherit to the companion audio
    /// reader, so header-enforcing IPTV origins (Referer / User-Agent / Authorization, #119) accept the
    /// ingest the same way they accept the AVPlayer bypass (AetherEngine#168). Credential headers go
    /// only to `playlistURL`'s origin with no TLS downgrade (audit NET-7).
    public convenience init(playlistURL: URL, httpHeaders: [String: String],
                            diagnosticContext: SourceNetworkDiagnostics.Context? = SourceNetworkDiagnostics.context) {
        self.init(playlistURL: playlistURL, httpHeaders: httpHeaders, role: .mainVideo,
                  diagnosticContext: diagnosticContext)
    }

    /// #199: fresh reader over the same playlist URL and headers, for the in-engine live reopen of an
    /// engine-created ingest session (the dead reader's construction inputs are immutable, so the fresh
    /// one rejoins the same channel at its current live edge). Main-video role only: the companion
    /// audio reader's lifetime is owned by its parent and never reopens independently.
    func makeFreshMainReader() -> HLSLiveIngestReader? {
        guard role == .mainVideo else { return nil }
        let fresh = HLSLiveIngestReader(playlistURL: playlistURL, httpHeaders: httpHeaders, role: .mainVideo,
                                        diagnosticContext: diagnosticContext)
        fresh.setJoinCushion(joinCushionSeconds)
        return fresh
    }

    private let diagnosticContext: SourceNetworkDiagnostics.Context?

    init(playlistURL: URL, httpHeaders: [String: String] = [:], role: Role,
         credentialOrigin: URL? = nil,
         diagnosticContext: SourceNetworkDiagnostics.Context? = SourceNetworkDiagnostics.context) {
        self.diagnosticContext = diagnosticContext
        self.playlistURL = playlistURL
        self.httpHeaders = httpHeaders
        self.credentialOrigin = credentialOrigin ?? playlistURL
        self.role = role
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // 30s resource ceiling: one-shot fetches must fail fast so the host can fall back. The c7592ed no-ceiling lesson applies to long-lived stream connections, not bounded one-shot fetches.
        self.session = URLSession(
            configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    // MARK: - IOReader

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        let n = fifo.read(into: buffer, maxLength: Int(size))
        return Int32(n)
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        -1 // forward-only, unknown length; reject including AVSEEK_SIZE
    }

    public func close() {
        startLock.lock()
        closed = true
        let wasStarted = started
        let task = ingestTask
        ingestTask = nil
        task?.cancel()
        let companion = _companionAudioReader
        _companionAudioReader = nil
        startLock.unlock()

        companion?.close() // companion lifetime bound to main reader; engine closes only the reader it holds
        fifo.cancel()
        wakeFormatResolveWaiters() // prevent resolveSegmentFormatHint from sleeping its full bound when never started
        if !wasStarted {
            session.invalidateAndCancel() // sole owner when ingest never launched; runIngest's defer owns it otherwise
        }
    }

    public func cancel() {
        // CAVEAT: FIFO cancel is permanent (all subsequent reads return -1), which violates the IOReader "unblock only" contract. Safe because forward-only sources never re-enter read after cancel; if that ever changes, this fires immediately.
        fifo.cancel()
    }

    // MARK: - Ingest loop

    private func startIfNeeded() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started, !closed else { return }
        started = true
        // Strong capture: the ingest loop must keep the reader and FIFO alive until close() cancels it.
        ingestTask = BlockingWork.detached(priority: .userInitiated) { [self] in
            await runIngest()
        }
    }

    private func runIngest() async {
        defer {
            session.invalidateAndCancel()
            wakeFormatResolveWaiters() // wake any pending format resolve regardless of exit path
        }
        do {
            let (resolvedURL, seedPlaylist) = try await resolveMediaPlaylistURL()
            var mediaURL = resolvedURL
            // A media playlist the host's URL led to directly (through redirects, as an IPTV panel's
            // tokenized session URL), which that URL can lead to afresh when the session expires.
            let mediaURLIsReresolvable = seedPlaylist != nil && mediaURL != playlistURL
            var tracker = HLSPlaylistTracker.joining(cushion: joinCushionSeconds)
            var loggedEncryptedDirectPlay = false
            var refreshInterval: Double = 2
            var pendingPlaylist: HLSMediaPlaylist? = seedPlaylist

            while !Task.isCancelled {
                let media: HLSMediaPlaylist
                if let seeded = pendingPlaylist {
                    media = seeded // reuse playlist parsed during resolve to avoid a redundant fetch
                    pendingPlaylist = nil
                } else {
                    let (fetched, refreshedURL) = try await refreshMediaPlaylist(
                        mediaURL, canReresolve: mediaURLIsReresolvable)
                    mediaURL = refreshedURL
                    media = fetched
                }
                startLock.withLock { // publish before any segment byte reaches the FIFO; first write wins
                    if _upstreamTargetDuration == nil {
                        _upstreamTargetDuration = media.targetDuration
                    }
                }
                if media.hasUnsupportedEncryption { throw HLSIngestError.encryptedNotSupported }
                if media.isEncrypted, !loggedEncryptedDirectPlay {
                    loggedEncryptedDirectPlay = true
                    EngineLog.emit(
                        "[HLSIngest] AES-128 clear-key stream: decrypting segments inline (direct play)",
                        category: .engine
                    )
                }
                if media.hasMap { throw HLSIngestError.unsupportedSegmentFormat }
                // AE#447: sample at half the SERVED segment duration, not half the advertised target.
                // A padded advert (`segment + 1`, which the RFC allows and packagers habitually serve)
                // makes the poll coarser than the source's real cadence, and arrivals then quantize
                // upward: a 2.000 s source polled every 1.5 s shows 3 s inter-arrival gaps, and that is
                // what the served TARGETDURATION gets sealed from. Never above the advert, which stays
                // the upper bound a conforming origin promises.
                let servedSegment = media.segments.last?.duration ?? media.targetDuration
                refreshInterval = min(6, max(1, min(servedSegment, media.targetDuration) / 2))

                let isJoin = !sniffedFirstSegment
                let fresh = tracker.newSegments(in: media)
                if tracker.stallCount > 6 { throw HLSIngestError.ingestStalled }
                if !fresh.isEmpty {
                    // Real arrival of new content: the interval since the previous arrival is the observed
                    // cadence the engine shapes the local playlist around (AetherEngine#167). The longest
                    // segment served rides along, because it bounds that cadence from below before any
                    // interval has closed, which is when the served TARGETDURATION is sealed (AE#447).
                    let now = Self.monotonicNow()
                    let longest = fresh.reduce(0.0) { max($0, $1.duration) }
                    startLock.withLock {
                        _cadenceMeter.recordArrival(at: now)
                        if longest > 0 {
                            _upstreamSegmentDurationSeconds = max(_upstreamSegmentDurationSeconds ?? 0, longest)
                        }
                    }
                }
                if isJoin, !fresh.isEmpty {
                    // AE#359: the wall time the engine's timeline begins at. Sibling renditions carry the
                    // same PDT for the same content, which is what makes their cues placeable.
                    if let joinDate = fresh.first?.programDateTime {
                        startLock.withLock { _joinWallClock = joinDate }
                    }
                    let backlog = fresh.reduce(0.0) { $0 + $1.duration }
                    startLock.withLock { _joinBacklogSeconds = backlog }
                    EngineLog.emit(
                        "[HLSIngest] joined \(fresh.count) segment(s), ~\(String(format: "%.0f", backlog))s behind the live edge"
                        + " pdt=\(fresh.first?.programDateTime.map { "\($0)" } ?? "nil")",
                        category: .engine
                    )
                }

                if !fresh.isEmpty {
                    guard try await ingestSegmentBatch(fresh, mediaURL: mediaURL) else {
                        return // FIFO closed underneath us
                    }
                    if isJoin { startLock.withLock { _joinBatchCommitted = true } }
                }

                if media.hasEndList {
                    fifo.finish()
                    return
                }
                if fresh.isEmpty {
                    try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                }
            }
        } catch is CancellationError {
            // teardown
        } catch let error as HLSIngestError {
            startLock.withLock { _terminalFailure = error }
            EngineLog.emit("[HLSIngest] terminal: \(error)", category: .engine)
            fifo.cancel()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return // teardown rides through as cancellation, not a terminal error
            }
            startLock.withLock { _terminalFailure = error }
            EngineLog.emit("[HLSIngest] terminal (transport): \(error.localizedDescription)", category: .engine)
            fifo.cancel()
        }
    }

    /// #177: bounded prefetch pipeline over one batch of fresh segments. Up to
    /// `maxConcurrentSegmentFetches` fetches (and decrypts) run concurrently; results are committed
    /// to the FIFO strictly in playlist order, so every downstream ordering contract (first-segment
    /// classification before any FIFO byte, discontinuity logging, demuxer pacing via the blocking
    /// FIFO write) is unchanged. In-flight bytes are held in memory, decoupled from FIFO
    /// backpressure; the window is anchored at the commit point, bounding buffered segments to the
    /// window size even when the head segment is slow. Returns false when the FIFO was closed.
    private func ingestSegmentBatch(_ segments: [HLSMediaSegment], mediaURL: URL) async throws -> Bool {
        // Resolve every URI upfront so an unresolvable one throws before any fetch is spawned.
        let resolved: [(segment: HLSMediaSegment, url: URL)] = try segments.map { segment in
            guard let url = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
            }
            return (segment, url)
        }
        let window = Self.segmentFetchConcurrency(
            budgetLimit: OriginRequestBudget.shared.limit(for: mediaURL))
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group -> Bool in
            var nextToSpawn = 0
            var nextToCommit = 0
            var ready: [Int: Data] = [:]

            while nextToSpawn < resolved.count,
                  nextToSpawn < nextToCommit + window {
                spawnFetch(into: &group, index: nextToSpawn, item: resolved[nextToSpawn], mediaURL: mediaURL)
                nextToSpawn += 1
            }
            while nextToCommit < resolved.count {
                guard let (index, bytes) = try await group.next() else { break }
                ready[index] = bytes
                while let head = ready.removeValue(forKey: nextToCommit) {
                    let segment = resolved[nextToCommit].segment
                    nextToCommit += 1
                    if segment.discontinuityBefore {
                        // Phase 1 decision (design spec): the seam is logged, the actual
                        // timestamp handling rides on the producer's PTS-leap rebase
                        // heuristic downstream; a deterministic force-cut hint is a P2 item.
                        EngineLog.emit("[HLSIngest] discontinuity seam before segment \(segment.uri)", category: .engine)
                    }
                    if head.isEmpty { continue } // 404: slid out of the provider window
                    if !sniffedFirstSegment {
                        sniffedFirstSegment = true
                        try classifyFirstSegment(head)
                    }
                    guard fifo.write(head) else { // closed underneath us
                        group.cancelAll()
                        return false
                    }
                }
                while nextToSpawn < resolved.count,
                      nextToSpawn < nextToCommit + window {
                    spawnFetch(into: &group, index: nextToSpawn, item: resolved[nextToSpawn], mediaURL: mediaURL)
                    nextToSpawn += 1
                }
            }
            return true
        }
    }

    /// One in-flight prefetch: fetch plus (for AES-128 sources) inline decrypt. Decrypting in
    /// flight is safe because the key cache tolerates concurrent misses; classification stays on
    /// the ordered commit path (TS sync byte is only visible in plaintext).
    private func spawnFetch(
        into group: inout ThrowingTaskGroup<(Int, Data), Error>,
        index: Int,
        item: (segment: HLSMediaSegment, url: URL),
        mediaURL: URL
    ) {
        group.addTask {
            let fetched = try await self.fetchSegment(item.url, duration: item.segment.duration)
            guard !fetched.isEmpty, let crypt = item.segment.crypt else { return (index, fetched) }
            return (index, try await self.decryptSegment(fetched, crypt: crypt, against: mediaURL))
        }
    }

    /// Classify the first segment and publish format + PRIV timestamp before any byte is written to the FIFO (ordering contract). Companion packed audio without a parsable PRIV timestamp goes terminal: no way to align side audio without risking silent A/V desync.
    private func classifyFirstSegment(_ bytes: Data) throws {
        let format = LiveSegmentFormat.classify(bytes)
        switch role {
        case .mainVideo:
            guard format == .mpegts else {
                throw HLSIngestError.unsupportedSegmentFormat
            }
            publishSegmentFormat(hint: "mpegts", packedOffset90k: nil)
        case .companionAudio:
            switch format {
            case .mpegts:
                publishSegmentFormat(hint: "mpegts", packedOffset90k: nil)
            case .id3PackedAudio:
                guard let offset = PackedAudioID3.transportStreamTimestamp90k(in: bytes) else {
                    EngineLog.emit(
                        "[HLSIngest] packed-audio companion: first segment has no parsable "
                        + "\"\(PackedAudioID3.appleTimestampOwner)\" PRIV timestamp; cannot "
                        + "align to the program clock, failing fast for host fallback",
                        category: .engine
                    )
                    throw HLSIngestError.demuxedAudioNotSupported
                }
                EngineLog.emit(
                    "[HLSIngest] packed-audio companion: ADTS AAC with ID3 PRIV timestamp "
                    + "\(offset) (90 kHz, \(String(format: "%.3f", Double(offset) / 90000.0))s)",
                    category: .engine
                )
                publishSegmentFormat(hint: "aac", packedOffset90k: offset)
            case .adtsAAC:
                EngineLog.emit(
                    "[HLSIngest] packed-audio companion: raw ADTS first segment without the "
                    + "spec-required leading ID3 tag, no program-clock timestamp to align on; "
                    + "failing fast for host fallback",
                    category: .engine
                )
                throw HLSIngestError.demuxedAudioNotSupported
            case nil:
                throw HLSIngestError.unsupportedSegmentFormat
            }
        }
    }

    private func publishSegmentFormat(hint: String, packedOffset90k: Int64?) {
        startLock.withLock {
            _segmentFormatHint = hint
            _packedAudioTimestampOffset90k = packedOffset90k
        }
        wakeFormatResolveWaiters()
    }

    private func wakeFormatResolveWaiters() {
        formatCondition.lock()
        formatResolved = true
        formatCondition.broadcast()
        formatCondition.unlock()
    }

    /// Resolves the variant URL. Returns the parsed media playlist when the input is already a direct media playlist (avoids a redundant fetch); nil for the master-playlist case.
    private func resolveMediaPlaylistURL() async throws -> (URL, HLSMediaPlaylist?) {
        let (playlist, finalURL) = try await fetchPlaylist(playlistURL)
        switch playlist {
        case .media(let media):
            return (finalURL, media) // direct media playlist: reuse parsed result
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: finalURL) else {
                throw HLSIngestError.playlistInvalid(reason: "no usable variant")
            }
            // Demuxed-audio variant: companion reader ingests the rendition playlist for the side demuxer (ARD-style channels). Installed before this function returns so the ordering guarantee holds.
            if let group = best.audioGroupID, master.demuxedAudioGroupIDs.contains(group) {
                let groupRenditions = master.audioRenditions.filter { $0.groupID == group }
                // DEFAULT=YES is the provider's pick; first entry is the fallback (groups with URI entries are non-empty by construction).
                guard let rendition = groupRenditions.first(where: { $0.isDefault })
                        ?? groupRenditions.first,
                      let audioURL = HLSPlaylistParser.resolve(uri: rendition.uri, against: finalURL) else {
                    EngineLog.emit(
                        "[HLSIngest] variant audio is a separate rendition (group \"\(group)\") "
                        + "but its URI is unresolvable; failing fast for host fallback",
                        category: .engine
                    )
                    throw HLSIngestError.demuxedAudioNotSupported
                }
                EngineLog.emit(
                    "[HLSIngest] demuxed audio rendition (group \"\(group)\", default=\(rendition.isDefault)): "
                    + "starting companion reader on \(audioURL.lastPathComponent)",
                    category: .engine
                )
                installCompanion(HLSLiveIngestReader(
                    playlistURL: audioURL, httpHeaders: httpHeaders, role: .companionAudio,
                    credentialOrigin: credentialOrigin, diagnosticContext: diagnosticContext))
            }
            // AE#359: the variant's SUBTITLES group, resolved to absolute playlist URLs and published as
            // metadata. Nothing is fetched here; the host decides whether a subtitle track is ever wanted.
            if let group = best.subtitleGroupID {
                let resolved = master.subtitleRenditions
                    .filter { $0.groupID == group }
                    .compactMap { rendition -> LiveSubtitleRenditionInfo? in
                        guard let url = HLSPlaylistParser.resolve(uri: rendition.uri, against: finalURL) else {
                            return nil
                        }
                        return LiveSubtitleRenditionInfo(name: rendition.name, language: rendition.language,
                                                         isDefault: rendition.isDefault,
                                                         isForced: rendition.isForced, playlistURL: url)
                    }
                startLock.withLock { _subtitleRenditions = resolved }
                // Logged including the empty case: a group that resolves to nothing is a routing answer,
                // and a silent diagnostic there is indistinguishable from a resolver that never ran.
                EngineLog.emit(
                    "[HLSIngest] subtitle renditions in group \"\(group)\": \(resolved.count)"
                    + (resolved.isEmpty ? "" : " (" + resolved.map { $0.language ?? "und" }.joined(separator: ", ") + ")"),
                    category: .engine
                )
            }
            EngineLog.emit("[HLSIngest] master playlist: picked variant bandwidth=\(best.bandwidth)", category: .engine)
            return (url, nil)
        }
    }

    /// How long a live refresh is retried while the origin refuses it (`refusalStatuses`: 429, 503,
    /// 509). It outlasts what a session holds ahead of the playhead, so a refusal that
    /// ends while the picture is still playing from it is never seen: the host's own stall handling
    /// steps in once that runs dry. A connection-limited IPTV panel answers 509 for as long as another
    /// device on the account holds its last slot, which is seconds to tens of seconds when that device
    /// changes channels, and then serves again at once. The 7.36.0 ladder (1, 2, 4 s within 12 s) went
    /// terminal well inside such a window, and on the software path that ended the session.
    static let refreshRetryBudget: TimeInterval = 60

    /// How long a refresh or segment is retried when the origin cannot be reached or answers with any
    /// other 5xx. That is not a refusal that lifts by itself: a dead channel or a lost network would
    /// otherwise sit behind a spinner for a minute before the host's reopen or fallback gets a turn.
    /// FIFO and producer buffer give 10 to 20 s of slack, so 12 s still bridges a single CDN timeout.
    static let unreachableRetryBudget: TimeInterval = 12

    /// The retry budget for a failure with this HTTP status, nil for a transport error. A retry loop
    /// keeps the longest budget it has seen, so one transport blip inside a refusal does not end it.
    static func retryBudget(forStatus status: Int?) -> TimeInterval {
        guard let status, refusalStatuses.contains(status) else { return unreachableRetryBudget }
        return refreshRetryBudget
    }

    /// The steady wait between those retries. One small request a second, never growing: a refusal of
    /// this kind lifts the moment the other device lets its slot go, and a growing backoff only adds
    /// to the wait after that. An origin's own Retry-After stretches it, up to `maximumRetryWait`.
    static let refusedRefreshRetryInterval: TimeInterval = 1
    static let maximumRetryWait: TimeInterval = 5

    /// Failed refreshes that are each logged; past these, one line every `retryLogStride`.
    private static let loggedRetries = 3
    private static let retryLogStride = 10

    /// Refusals of a session URL after which it is asked for again through the URL the host loaded.
    /// An IPTV panel that let another device's connection take the account's last slot keeps refusing
    /// the session it evicted, for as long as that lasts, while a fresh session from the loaded URL is
    /// admitted at once. Two lets a refusal that lifts by itself within a second or two keep the
    /// session it has.
    static let sessionURLRefusalsBeforeReresolve = 2

    /// The live refresh, retried steadily while the origin refuses it or cannot be reached. When the
    /// URL the host loaded led to this media playlist through redirects (`canReresolve`: an IPTV
    /// panel's tokenized session URL), a playlist that answers as gone (a 4xx other than 429 and 408:
    /// the session expired or was revoked) is asked for again through the loaded URL at once, and one
    /// refused `sessionURLRefusalsBeforeReresolve` times in a row after that, for a fresh session URL;
    /// the loaded URL is then asked at the same steady pace. The playlist tracker follows
    /// MEDIA-SEQUENCE, so the segments it hands out continue where they left off. Parse errors throw at
    /// once. Returns the playlist and the URL it was read from, which later refreshes use.
    private func refreshMediaPlaylist(_ mediaURL: URL, canReresolve: Bool) async throws -> (HLSMediaPlaylist, URL) {
        let startedAt = Date()
        var budget = Self.unreachableRetryBudget
        var url = mediaURL
        var failures = 0
        while true {
            try Task.checkCancellation()
            startLock.withLock { _playlistRetryAfter = nil }
            do {
                let (playlist, finalURL) = try await fetchPlaylist(url)
                guard case .media(let media) = playlist else {
                    throw HLSIngestError.playlistInvalid(reason: "expected media playlist on refresh")
                }
                if failures > 0 || url != mediaURL {
                    EngineLog.emit(
                        "[HLSIngest] playlist refresh recovered after \(failures) failed attempt(s) in "
                        + "\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s"
                        + (url != mediaURL ? " through the loaded URL" : ""),
                        category: .engine
                    )
                }
                return (media, finalURL)
            } catch let error as HLSIngestError {
                guard case .playlistUnreachable(let status) = error else { throw error }
                if Self.isGoneStatus(status) {
                    guard canReresolve, url == mediaURL else { throw error }
                    EngineLog.emit(
                        "[HLSIngest] media playlist answered \(status); asking the loaded URL for a fresh one",
                        category: .engine
                    )
                    url = playlistURL
                    continue
                }
                failures += 1
                budget = max(budget, Self.retryBudget(forStatus: status))
                try await waitBeforeRetrying(error, failures: failures, deadline: startedAt.addingTimeInterval(budget))
                url = Self.nextRefreshURL(after: failures, current: url, sessionURL: mediaURL,
                                          loadedURL: playlistURL, canReresolve: canReresolve)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                failures += 1
                try await waitBeforeRetrying(error, failures: failures, deadline: startedAt.addingTimeInterval(budget))
                url = Self.nextRefreshURL(after: failures, current: url, sessionURL: mediaURL,
                                          loadedURL: playlistURL, canReresolve: canReresolve)
            }
        }
    }

    /// Where the next refresh goes after `failures` in a row: the loaded URL, for a fresh session,
    /// once the session URL has been refused `sessionURLRefusalsBeforeReresolve` times; otherwise
    /// where the last one went.
    static func nextRefreshURL(after failures: Int, current: URL, sessionURL: URL, loadedURL: URL,
                               canReresolve: Bool) -> URL {
        guard canReresolve, current == sessionURL, failures >= sessionURLRefusalsBeforeReresolve else {
            return current
        }
        EngineLog.emit(
            "[HLSIngest] session URL refused \(failures) times; asking the loaded URL for a fresh one",
            category: .engine
        )
        return loadedURL
    }

    /// A status that says the playlist will not be served at this URL again, rather than not now:
    /// any 4xx but 429 (Too Many Requests) and 408 (Request Timeout).
    static func isGoneStatus(_ status: Int) -> Bool {
        (400..<500).contains(status) && status != 429 && status != 408
    }

    /// The wait before the next retry, or the error once the budget would be overrun.
    static func retryWait(retryAfter: TimeInterval?) -> TimeInterval {
        min(max(retryAfter ?? refusedRefreshRetryInterval, refusedRefreshRetryInterval), maximumRetryWait)
    }

    private func waitBeforeRetrying(_ error: Error, failures: Int, deadline: Date) async throws {
        let retryAfter = startLock.withLock { _playlistRetryAfter }
        let delay = Self.retryWait(retryAfter: retryAfter)
        guard Date().addingTimeInterval(delay) < deadline else { throw error }
        if failures <= Self.loggedRetries || failures % Self.retryLogStride == 0 {
            EngineLog.emit(
                "[HLSIngest] playlist refresh failed (attempt \(failures): \(EngineLog.summary(of: error))); "
                + "retrying in \(String(format: "%.1f", delay))s",
                category: .engine
            )
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// AE#678: every ingest request is charged to `OriginRequestBudget` like the reader's and the relay's,
    /// so the host's declared ceiling, and a ceiling or pacer learned from another path's refusal, bind
    /// this path too. Its own refusals are not charged (see below). The slot wait blocks, so it runs off
    /// the cooperative pool; no ticket is ever held across another acquire.
    private func budgeted(
        _ url: URL, label: String, _ fetch: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        let ticket: OriginRequestBudget.Ticket? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                continuation.resume(returning: OriginRequestBudget.shared.acquire(
                    for: url, label: label, timeout: Self.budgetSlotWaitSeconds,
                    shouldAbort: { self?.isClosed ?? true }))
            }
        }
        defer { OriginRequestBudget.shared.release(ticket) }
        try Task.checkCancellation()
        let (data, response) = try await fetch()
        if let http = response as? HTTPURLResponse {
            if let finalURL = http.url, finalURL != url {
                OriginRequestBudget.shared.noteRedirect(from: url, to: finalURL)
            }
            // A refusal here is not charged to the origin's books. A live ingest asks at most once a
            // second while refused (`refusedRefreshRetryInterval`), and a connection-limited IPTV panel
            // refuses on behalf of another device holding the account's last slot, not of our request
            // rate. Charged, its 509 armed a quiet period of up to 15 s and halved the request budget
            // for the rest of the process, so the refresh that would have been served the moment the
            // slot freed, and every reopen or reload after it, waited up to 10 s for the pacer instead.
            if Self.refusalStatuses.contains(http.statusCode), label == "ingest-playlist" {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                startLock.withLock { _playlistRetryAfter = retryAfter }
            }
        }
        return (data, response)
    }

    static let budgetSlotWaitSeconds: TimeInterval = 10
    static let refusalStatuses: Set<Int> = [429, 503, 509]

    private var isClosed: Bool { startLock.withLock { closed } }

    /// Applies the configured origin headers to every ingest fetch, credentials only where the host's
    /// origin is (audit NET-7). Internal for the header-contract tests.
    func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in RedirectHeaderPolicy.scoped(
            httpHeaders, grantedFor: credentialOrigin, sentTo: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return SourceNetworkDiagnostics.request(request, context: diagnosticContext)
    }

    /// Fetch + parse a playlist. Returns parsed playlist and final URL after redirects (relative segment URIs resolve against it).
    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await budgeted(url, label: "ingest-playlist") {
            try await BoundedPlaylistFetch.data(
                for: self.makeRequest(url), session: self.session, limit: Self.maximumPlaylistBytes)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "non-UTF8 playlist")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetchSegment(_ url: URL, duration: Double) async throws -> Data {
        var lastFailure: Error = HLSIngestError.playlistUnreachable(status: -1)
        let limit = BoundedFetch.segmentLimit(forDuration: duration)
        let startedAt = Date()
        var budget = Self.unreachableRetryBudget
        var attempt = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            var retryAfter: TimeInterval?
            var status: Int?
            do {
                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await budgeted(url, label: "ingest-segment") {
                        try await BoundedFetch.data(for: self.makeRequest(url), session: self.session, limit: limit, role: .hlsSegment)
                    }
                } catch is BoundedFetch.Exceeded {
                    // Audit NET-112: an endless body is the origin's answer, not a blip to retry.
                    throw HLSIngestError.playlistInvalid(reason: "segment exceeds \(limit) bytes")
                }
                let lastStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastFailure = HLSIngestError.playlistUnreachable(status: lastStatus)
                status = lastStatus
                if (200..<300).contains(lastStatus) { return data }
                if lastStatus == 404 { return Data() } // slid out of provider window; tracker advances regardless
                if (400..<500).contains(lastStatus) && lastStatus != 429 {
                    throw HLSIngestError.playlistUnreachable(status: lastStatus)
                }
                retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            } catch let error as HLSIngestError { throw error }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                lastFailure = error
            }
            attempt += 1
            // Two quick retries for a blip, as before; then the steady pace of a refused refresh,
            // within the same budget the refresh would get for this failure.
            let delay = attempt <= 2 ? 0.5 * Double(attempt) : Self.retryWait(retryAfter: retryAfter)
            budget = max(budget, Self.retryBudget(forStatus: status))
            guard Date().addingTimeInterval(delay) < startedAt.addingTimeInterval(budget) else {
                throw lastFailure
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func decryptSegment(_ ciphertext: Data, crypt: HLSSegmentCrypt, against base: URL) async throws -> Data {
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: base) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "unresolvable key URI")
        }
        let key = try await fetchKey(keyURL)
        guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(ciphertext, key: key, iv: crypt.iv) else {
            throw HLSIngestError.segmentDecryptFailed(
                reason: "AES-128-CBC failed (key=\(key.count)B iv=\(crypt.iv.count)B ct=\(ciphertext.count)B)"
            )
        }
        return plaintext
    }

    private func fetchKey(_ url: URL) async throws -> Data {
        let cacheKey = url.absoluteString
        if let cached = keyCacheLock.withLock({ keyCache[cacheKey] }) { return cached }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await budgeted(url, label: "ingest-key") {
                try await BoundedFetch.data(
                    for: self.makeRequest(url), session: self.session, limit: BoundedFetch.keyLimit, role: .hlsKey)
            }
        } catch is BoundedFetch.Exceeded {
            throw HLSIngestError.segmentDecryptFailed(reason: "key exceeds \(BoundedFetch.keyLimit) bytes")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard data.count == kCCKeySizeAES128 else {
            throw HLSIngestError.segmentDecryptFailed(reason: "key length \(data.count) != 16")
        }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
