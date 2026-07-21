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
    private let role: Role
    private let fifo = ByteFIFO(capacity: 16 * 1024 * 1024)
    private let session: URLSession
    private var ingestTask: Task<Void, Never>?
    private let startLock = NSLock()
    private var started = false
    private var closed = false
    // All _-prefixed vars are protected by startLock.
    private var _terminalError: HLSIngestError?
    /// Written before any segment byte reaches the FIFO; first write wins.
    private var _upstreamTargetDuration: Double?
    /// Tracks observed segment-arrival cadence for LL-HLS shaping (AetherEngine#167). Updated whenever new
    /// upstream segments appear; read via `observedLiveCadenceSeconds`.
    private var _cadenceMeter = LiveArrivalCadenceMeter()
    /// Installed by the resolver before the first FIFO byte; nil = muxed audio.
    private var _companionAudioReader: HLSLiveIngestReader?
    /// "mpegts" or "aac", classified from the first segment's leading bytes, written before that segment's first FIFO byte.
    private var _segmentFormatHint: String?
    private var _packedAudioTimestampOffset90k: Int64?

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

    /// First-segment classification latch; touched only from the ingest task's ordered commit path.
    private var sniffedFirstSegment = false

    public var terminalError: HLSIngestError? {
        startLock.withLock { _terminalError }
    }

    public var upstreamTargetDuration: Double? {
        startLock.withLock { _upstreamTargetDuration }
    }

    public var observedLiveCadenceSeconds: Double? {
        let now = Self.monotonicNow()
        return startLock.withLock { _cadenceMeter.observedCadence(at: now) }
    }

    /// Monotonic seconds (uptime); immune to wall-clock jumps that would corrupt interval measurement.
    private static func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public var companionAudioReader: IOReader? {
        startLock.withLock { _companionAudioReader }
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
    private func installCompanion(_ companion: HLSLiveIngestReader) {
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
    /// ingest the same way they accept the AVPlayer bypass (AetherEngine#168).
    public convenience init(playlistURL: URL, httpHeaders: [String: String]) {
        self.init(playlistURL: playlistURL, httpHeaders: httpHeaders, role: .mainVideo)
    }

    init(playlistURL: URL, httpHeaders: [String: String] = [:], role: Role) {
        self.playlistURL = playlistURL
        self.httpHeaders = httpHeaders
        self.role = role
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // 30s resource ceiling: one-shot fetches must fail fast so the host can fall back. The c7592ed no-ceiling lesson applies to long-lived stream connections, not bounded one-shot fetches.
        self.session = URLSession(configuration: config)
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
        ingestTask = Task.detached(priority: .userInitiated) { [self] in
            await runIngest()
        }
    }

    private func runIngest() async {
        defer {
            session.invalidateAndCancel()
            wakeFormatResolveWaiters() // wake any pending format resolve regardless of exit path
        }
        do {
            let (mediaURL, seedPlaylist) = try await resolveMediaPlaylistURL()
            var tracker = HLSPlaylistTracker()
            var loggedEncryptedDirectPlay = false
            var refreshInterval: Double = 2
            var pendingPlaylist: HLSMediaPlaylist? = seedPlaylist

            while !Task.isCancelled {
                let media: HLSMediaPlaylist
                if let seeded = pendingPlaylist {
                    media = seeded // reuse playlist parsed during resolve to avoid a redundant fetch
                    pendingPlaylist = nil
                } else {
                    let (playlist, _) = try await fetchPlaylistWithRetry(mediaURL)
                    guard case .media(let fetched) = playlist else {
                        throw HLSIngestError.playlistInvalid(reason: "expected media playlist on refresh")
                    }
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
                refreshInterval = min(6, max(1, media.targetDuration / 2))

                let isJoin = !sniffedFirstSegment
                let fresh = tracker.newSegments(in: media)
                if tracker.stallCount > 6 { throw HLSIngestError.ingestStalled }
                if !fresh.isEmpty {
                    // Real arrival of new content: the interval since the previous arrival is the observed
                    // cadence the engine shapes the local playlist around (AetherEngine#167).
                    let now = Self.monotonicNow()
                    startLock.withLock { _cadenceMeter.recordArrival(at: now) }
                }
                if isJoin, !fresh.isEmpty {
                    let backlog = fresh.reduce(0.0) { $0 + $1.duration }
                    EngineLog.emit(
                        "[HLSIngest] joined \(fresh.count) segment(s), ~\(Int(backlog))s behind the live edge",
                        category: .engine
                    )
                }

                if !fresh.isEmpty {
                    guard try await ingestSegmentBatch(fresh, mediaURL: mediaURL) else {
                        return // FIFO closed underneath us
                    }
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
            startLock.withLock { _terminalError = error }
            EngineLog.emit("[HLSIngest] terminal: \(error)", category: .engine)
            fifo.cancel()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return // teardown rides through as cancellation, not a terminal error
            }
            startLock.withLock { _terminalError = .playlistUnreachable(status: -1) }
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
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group -> Bool in
            var nextToSpawn = 0
            var nextToCommit = 0
            var ready: [Int: Data] = [:]

            while nextToSpawn < resolved.count,
                  nextToSpawn < nextToCommit + Self.maxConcurrentSegmentFetches {
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
                      nextToSpawn < nextToCommit + Self.maxConcurrentSegmentFetches {
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
            let fetched = try await self.fetchSegment(item.url)
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
                installCompanion(HLSLiveIngestReader(playlistURL: audioURL, httpHeaders: httpHeaders, role: .companionAudio))
            }
            EngineLog.emit("[HLSIngest] master playlist: picked variant bandwidth=\(best.bandwidth)", category: .engine)
            return (url, nil)
        }
    }

    /// 12s: FIFO + producer buffer give ~10-20s slack; past that, going terminal beats stretching a stall the buffer can no longer hide.
    private static let refreshRetryBudget: TimeInterval = 12

    /// Playlist refresh with bounded exponential backoff (1s, 2s, 4s). Device repro: a single -1001 CDN timeout used to force a visible ~10s retune; now bridged invisibly inside `refreshRetryBudget`. Parse errors and 4xx throw immediately. Initial join stays single-shot (fast spinner fallback beats slow retry).
    private func fetchPlaylistWithRetry(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let deadline = Date().addingTimeInterval(Self.refreshRetryBudget)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchPlaylist(url)
            } catch let error as HLSIngestError {
                guard case .playlistUnreachable(let status) = error,
                      status >= 500 || status == 429 else {
                    throw error
                }
                try await backoffOrRethrow(error, attempt: &attempt, deadline: deadline)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                try await backoffOrRethrow(error, attempt: &attempt, deadline: deadline)
            }
        }
    }

    private func backoffOrRethrow(_ error: Error, attempt: inout Int, deadline: Date) async throws {
        attempt += 1
        let delay = min(4.0, pow(2.0, Double(attempt - 1)))
        guard Date().addingTimeInterval(delay) < deadline else { throw error }
        EngineLog.emit(
            "[HLSIngest] playlist refresh failed (attempt \(attempt): \(error.localizedDescription)); retrying in \(Int(delay))s",
            category: .engine
        )
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Applies the configured origin headers to every ingest fetch. Internal for the header-contract tests.
    func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Fetch + parse a playlist. Returns parsed playlist and final URL after redirects (relative segment URIs resolve against it).
    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "non-UTF8 playlist")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetchSegment(_ url: URL) async throws -> Data {
        var lastStatus = -1
        for attempt in 0..<3 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(for: makeRequest(url))
                lastStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(lastStatus) { return data }
                if lastStatus == 404 { return Data() } // slid out of provider window; tracker advances regardless
                if (400..<500).contains(lastStatus) && lastStatus != 429 {
                    throw HLSIngestError.playlistUnreachable(status: lastStatus)
                }
            } catch let error as HLSIngestError { throw error }
            catch { /* transport blip: retry */ }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        throw HLSIngestError.playlistUnreachable(status: lastStatus)
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

        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "key fetch HTTP \(status)")
        }
        guard data.count == kCCKeySizeAES128 else {
            throw HLSIngestError.segmentDecryptFailed(reason: "key length \(data.count) != 16")
        }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
