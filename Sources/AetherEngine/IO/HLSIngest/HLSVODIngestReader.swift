import CommonCrypto
import Foundation

/// The reader resolves one immutable ENDLIST playlist and exposes its segments
/// as a blocking MPEG-TS stream. Unlike `HLSLiveIngestReader`, seeks restart the
/// same source at the segment preceding the requested playlist time. Demuxer
/// packet gating then discards frames before the exact target.
///
/// Its seek axis is ELAPSED MEDIA TIME (the EXTINF sum), not the container's PTS: an MPEG-TS VOD
/// carries an arbitrary PTS origin, so `Demuxer` strips that origin before positioning the reader.
final class HLSVODIngestReader: TimeSeekableIOReader, @unchecked Sendable {
    private struct ResolvedMedia {
        let url: URL
        let segments: [HLSMediaSegment]
        let starts: [Double]
        let duration: Double
    }

    /// FIFO ceiling, matched to `HLSLiveIngestReader`: the producer parks here until the demuxer drains.
    private static let maximumBufferedBytes = 16 * 1024 * 1024
    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    private static let maxConcurrentSegmentFetches = 4
    /// Segment bytes the prefetch window may hold in memory. 4K VOD segments run 15-25 MB, so a fixed
    /// window of four would peak near 100 MB on a device that also holds decode buffers; the window
    /// narrows once the first segment's real size is known (AE#255: bound by bytes, not by count).
    private static let maximumInFlightBytes = 24 * 1024 * 1024

    private let diagnosticContext: SourceNetworkDiagnostics.Context?
    private let playlistURL: URL
    private let httpHeaders: [String: String]
    private let session: URLSession
    private let ownsSession: Bool
    /// AE#732: set under `LoadOptions.heldSourceConnection`. Every request of this reader then goes over
    /// one persistent HTTP/1.1 connection per origin, segments one at a time, instead of `session`.
    private let transport: PersistentHTTP1Transport?
    /// AE#732: the first segment as the carriage probe left it on the persistent path, its head read and
    /// the rest of the response still open, so the producer that starts there carries on with the same
    /// response instead of asking for the segment again.
    private var primedSegment: PrimedSegment?

    private struct PrimedSegment {
        let url: URL
        let head: Data
        let body: PersistentHTTP1Transport.Body
    }
    private let condition = NSCondition()
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    private var resolved: ResolvedMedia?
    private var queue: [Data] = []
    private var headOffset = 0
    private var bufferedBytes = 0
    private var bytePosition: Int64 = 0
    private var generation: UInt64 = 0
    private var started = false
    private var finished = false
    private var failed = false
    private var closed = false
    private var producer: Task<Void, Never>?
    /// Playlist index the running producer opened at; lets a reposition onto that same segment, before
    /// any byte was consumed, resolve without refetching it.
    private var producerStartIndex: Int?

    init(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil,
        persistentHTTP1: Bool = false,
        diagnosticContext: SourceNetworkDiagnostics.Context? = SourceNetworkDiagnostics.context
    ) {
        self.diagnosticContext = diagnosticContext
        self.playlistURL = playlistURL
        self.httpHeaders = httpHeaders
        transport = persistentHTTP1 ? PersistentHTTP1Transport(label: "vod") : nil
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // The request timeout is the idle one, the longest wait for the next byte. No resource
            // ceiling: a large segment from a slow origin that keeps arriving is never cut off (#732).
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            self.session = URLSession(
                configuration: configuration, delegate: EngineTLS.sessionDelegate,
                delegateQueue: nil)
            ownsSession = true
        }
    }

    /// Returns a pre-resolved reader only when the finite playlist has positive
    /// content evidence for HEVC in MPEG-TS. Unknown, live, fMP4, H.264 and
    /// demuxed-audio shapes stay on the existing native remote-HLS route.
    static func makeIfHEVCMPEGTS(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil,
        persistentHTTP1: Bool = false,
        diagnosticContext: SourceNetworkDiagnostics.Context? = SourceNetworkDiagnostics.context
    ) async throws -> HLSVODIngestReader? {
        let reader = HLSVODIngestReader(
            playlistURL: playlistURL,
            httpHeaders: httpHeaders,
            session: session,
            persistentHTTP1: persistentHTTP1,
            diagnosticContext: diagnosticContext
        )
        var accepted = false
        defer {
            if !accepted { reader.close() }
        }
        do {
            let media = try await reader.resolveMedia()
            guard let first = media.segments.first,
                  first.crypt == nil,
                  let segmentURL = HLSPlaylistParser.resolve(
                    uri: first.uri,
                    against: media.url
                  ) else {
                return nil
            }
            guard try await reader.probeCarriage(segmentURL, duration: first.duration,
                                                 byteRange: first.byteRange) == .hevcInMPEGTS else {
                return nil
            }
            reader.condition.withLock {
                reader.resolved = media
            }
            accepted = true
            return reader
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            EngineLog.emit(
                "[HLSVODIngest] carriage probe inconclusive: \(EngineLog.summary(of: error))",
                category: .engine
            )
            return nil
        }
    }

    var mediaDuration: Double {
        condition.withLock { resolved?.duration ?? 0 }
    }

    /// EXTINF sum in front of each segment. A conforming HLS segment opens on a random-access point,
    /// so these are the only boundaries the segment plan may advertise: a finer synthetic grid puts
    /// boundaries where no keyframe is, and a restart there overshoots to the next IRAP (AE#268).
    var segmentStartTimesSeconds: [Double] {
        condition.withLock { resolved?.starts ?? [] }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !finished, !failed, !closed {
            condition.wait()
        }
        guard !failed, !closed else { return -1 }
        guard !queue.isEmpty else { return 0 }

        let available = queue[0].count - headOffset
        let count = min(available, Int(size))
        queue[0].withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.update(
                from: base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: headOffset),
                count: count
            )
        }
        headOffset += count
        bufferedBytes -= count
        bytePosition += Int64(count)
        if headOffset == queue[0].count {
            queue.removeFirst()
            headOffset = 0
        }
        condition.broadcast()
        return Int32(count)
    }

    /// Byte seeks are deliberately unsupported: the concatenated segment stream has no address space
    /// the reader could honour, and claiming one would let libavformat binary-search over HTTP. Only a
    /// no-op reposition succeeds, which is what `CustomIOReaderBridge.open`'s SEEK_SET(0) capability
    /// handshake asks at position 0; answering 0 unconditionally would report a rewind that never
    /// happened. Real positioning crosses the `TimeSeekableIOReader` seam in `Demuxer`.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.withLock {
            if whence == SEEK_SET, offset == bytePosition { return bytePosition }
            if whence == SEEK_CUR, offset == 0 { return bytePosition }
            return -1
        }
    }

    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        startIfNeeded()

        condition.lock()
        while resolved == nil, !failed, !closed {
            condition.wait()
        }
        guard let resolved, !failed, !closed else {
            condition.unlock()
            return false
        }
        let startIndex = Self.restartSegmentIndex(forElapsed: seconds, starts: resolved.starts)
        // A reposition onto the segment the running producer opened at, with nothing consumed since,
        // is where the ingest already stands. Scrub churn lands here: consecutive targets inside one
        // segment would otherwise cancel and refetch that segment per reposition.
        if startIndex == producerStartIndex, bytePosition == 0, !finished {
            condition.unlock()
            return true
        }
        let previous = producer
        generation &+= 1
        let currentGeneration = generation
        queue.removeAll(keepingCapacity: true)
        headOffset = 0
        bufferedBytes = 0
        bytePosition = 0
        finished = false
        failed = false
        producerStartIndex = startIndex
        producer = BlockingWork.detached(priority: .userInitiated) { [self] in
            await produce(
                resolved: resolved,
                startIndex: startIndex,
                generation: currentGeneration
            )
        }
        condition.broadcast()
        condition.unlock()
        previous?.cancel()

        let targetText = String(format: "%.2f", seconds)
        let startText = String(format: "%.2f", resolved.starts[startIndex])
        EngineLog.emit(
            "[HLSVODIngest] seek elapsed=\(targetText)s "
                + "segment=\(startIndex) segmentStart=\(startText)s",
            category: .engine
        )
        return true
    }

    /// Segment the ingest restarts at for `elapsed` seconds of media time: the segment containing the
    /// target, minus one. A playlist need not declare EXT-X-INDEPENDENT-SEGMENTS, so the extra segment
    /// buys the decoder a random-access point ahead of the target; landing early is the reader's
    /// contract and the engine's packet gate drops what precedes the exact target. A target past the
    /// end clamps to the last segment rather than failing, which keeps a rounding overshoot at the
    /// final boundary playable.
    ///
    /// A target sitting just BELOW a segment start counts as that segment: the plan built on this
    /// playlist backs each boundary off by `HLSVideoEngine.segmentedPlanBoundaryBackoff` so an IRAP can
    /// never fall below its own boundary (AE#268), and without the same tolerance here every such seek
    /// would fetch one more segment than it needs. The tolerance uses that same formula, so it can
    /// never reach past the previous segment start.
    static func restartSegmentIndex(forElapsed elapsed: Double, starts: [Double]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var shortest = Double.greatestFiniteMagnitude
        for i in 1..<max(1, starts.count) where starts[i] > starts[i - 1] {
            shortest = min(shortest, starts[i] - starts[i - 1])
        }
        let tolerance = shortest.isFinite ? min(0.5, shortest / 2) : 0
        let containing = starts.lastIndex(where: { $0 <= elapsed + tolerance }) ?? 0
        return max(0, containing - 1)
    }

    func cancel() {
        condition.lock()
        failed = true
        let task = producer
        producer = nil
        condition.broadcast()
        condition.unlock()
        task?.cancel()
    }

    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let task = producer
        producer = nil
        let primed = primedSegment
        primedSegment = nil
        queue.removeAll()
        bufferedBytes = 0
        condition.broadcast()
        condition.unlock()
        task?.cancel()
        primed?.body.abandon()
        transport?.close()
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    /// No independent cursor: a second reader would mean a second full HTTP ingest of the same VOD
    /// (its own playlist resolve, its own segment fetches from wherever it is positioned), and the
    /// features that ask for one, side-demuxed subtitles and scrub previews, are not worth that
    /// bandwidth on a source the host is already streaming once. The engine skips them for nil.
    func makeIndependentReader() -> IOReader? { nil }

    private func startIfNeeded() {
        condition.lock()
        guard !started, !closed else {
            condition.unlock()
            return
        }
        started = true
        generation &+= 1
        let currentGeneration = generation
        let preResolved = resolved
        producerStartIndex = 0
        producer = BlockingWork.detached(priority: .userInitiated) { [self] in
            do {
                let media: ResolvedMedia
                if let preResolved {
                    media = preResolved
                } else {
                    media = try await resolveMedia()
                }
                let accepted = condition.withLock { () -> Bool in
                    guard generation == currentGeneration, !closed else {
                        return false
                    }
                    resolved = media
                    condition.broadcast()
                    return true
                }
                guard accepted else {
                    return
                }
                let durationText = String(format: "%.2f", media.duration)
                EngineLog.emit(
                    "[HLSVODIngest] resolved finite MPEG-TS VOD segments=\(media.segments.count) "
                        + "duration=\(durationText)s",
                    category: .engine
                )
                await produce(
                    resolved: media,
                    startIndex: 0,
                    generation: currentGeneration
                )
            } catch is CancellationError {
            } catch {
                fail(error, generation: currentGeneration)
            }
        }
        condition.unlock()
    }

    private func produce(
        resolved: ResolvedMedia,
        startIndex: Int,
        generation: UInt64
    ) async {
        do {
            let remaining = Array(resolved.segments[startIndex...])
            try await ingestSegmentBatch(
                remaining,
                mediaURL: resolved.url,
                generation: generation
            )
            condition.withLock {
                if self.generation == generation, !closed {
                    finished = true
                    producer = nil
                    condition.broadcast()
                }
            }
        } catch is CancellationError {
        } catch {
            fail(error, generation: generation)
        }
    }

    /// Prefetch depth for an observed segment size: the count cap, narrowed so the segments held in
    /// memory stay inside `maximumInFlightBytes`, never below one.
    static func prefetchWindow(forSegmentBytes bytes: Int) -> Int {
        guard bytes > 0 else { return maxConcurrentSegmentFetches }
        return max(1, min(maxConcurrentSegmentFetches, maximumInFlightBytes / bytes))
    }

    private func ingestSegmentBatch(
        _ segments: [HLSMediaSegment],
        mediaURL: URL,
        generation: UInt64
    ) async throws {
        let resolvedSegments: [(HLSMediaSegment, URL)] = try segments.map { segment in
            guard let url = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
            }
            return (segment, url)
        }

        if transport != nil {
            try await ingestSequentially(resolvedSegments, mediaURL: mediaURL, generation: generation)
            return
        }

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextToSpawn = 0
            var nextToCommit = 0
            var ready: [Int: Data] = [:]

            func spawn(_ index: Int) {
                let item = resolvedSegments[index]
                group.addTask {
                    let bytes = try await self.fetch(
                        item.1, limit: BoundedFetch.segmentLimit(forDuration: item.0.duration),
                        byteRange: item.0.byteRange)
                    guard let crypt = item.0.crypt else { return (index, bytes) }
                    return (
                        index,
                        try await self.decrypt(bytes, crypt: crypt, baseURL: mediaURL)
                    )
                }
            }

            var window = Self.maxConcurrentSegmentFetches
            while nextToSpawn < resolvedSegments.count, nextToSpawn < window {
                spawn(nextToSpawn)
                nextToSpawn += 1
            }
            while nextToCommit < resolvedSegments.count {
                try Task.checkCancellation()
                guard let (index, bytes) = try await group.next() else { break }
                ready[index] = bytes
                while let head = ready.removeValue(forKey: nextToCommit) {
                    if nextToCommit == 0 {
                        guard LiveSegmentFormat.classify(head) == .mpegts else {
                            throw HLSIngestError.unsupportedSegmentFormat
                        }
                        window = Self.prefetchWindow(forSegmentBytes: head.count)
                    }
                    nextToCommit += 1
                    guard append(head, generation: generation) else {
                        group.cancelAll()
                        return
                    }
                    while nextToSpawn < resolvedSegments.count,
                          nextToSpawn < nextToCommit + window {
                        spawn(nextToSpawn)
                        nextToSpawn += 1
                    }
                }
            }
        }
    }

    /// AE#732: one segment at a time, so the persistent connection carries them back to back. The FIFO
    /// is the read-ahead; a parallel window would need a connection per in-flight segment, and a second
    /// connection is what the origins this path exists for refuse. Each body goes into the FIFO as it
    /// arrives, so a slow segment feeds the demuxer while it downloads.
    private func ingestSequentially(
        _ segments: [(HLSMediaSegment, URL)],
        mediaURL: URL,
        generation: UInt64
    ) async throws {
        var primed = condition.withLock { () -> PrimedSegment? in
            defer { primedSegment = nil }
            return primedSegment
        }
        // A probe response this run does not open with holds the origin; let it go before any request,
        // or that request waits behind a body nobody will read.
        if let ready = primed, segments.first?.1 != ready.url || segments.first?.0.crypt != nil
            || segments.first?.0.byteRange != nil {
            ready.body.abandon()
            primed = nil
        }
        defer { primed?.body.abandon() }
        for (offset, (segment, url)) in segments.enumerated() {
            try Task.checkCancellation()
            // Runs on the producer's BlockingWork executor. The last offered chunk can fill the
            // FIFO with no pending remainder, so admission must not depend on append() parking.
            guard waitForSegmentAdmission(generation: generation) else { return }
            // A sub-range is fetched whole like a ciphertext: an origin that ignores `Range` answers with
            // the entire resource, and only a complete body can be cut down to the segment.
            if segment.crypt != nil || segment.byteRange != nil {
                var bytes = try await fetch(url, limit: BoundedFetch.segmentLimit(forDuration: segment.duration),
                                            byteRange: segment.byteRange)
                if let crypt = segment.crypt {
                    bytes = try await decrypt(bytes, crypt: crypt, baseURL: mediaURL)
                }
                if offset == 0, LiveSegmentFormat.classify(bytes) != .mpegts {
                    throw HLSIngestError.unsupportedSegmentFormat
                }
                guard append(bytes, generation: generation) else { return }
                continue
            }
            let head: Data
            let body: PersistentHTTP1Transport.Body
            if offset == 0, let ready = primed, ready.url == url {
                (head, body) = (ready.head, ready.body)
                primed = nil
            } else {
                primed?.body.abandon()
                primed = nil
                body = try await openSegment(url, limit: BoundedFetch.segmentLimit(forDuration: segment.duration))
                head = Data()
            }
            guard try await stream(head: head, body: body, checkCarriage: offset == 0, generation: generation)
            else { return }
        }
    }

    /// Copies one segment body into the FIFO as it arrives. False when the generation was superseded;
    /// the body is then abandoned, which drains or closes its connection.
    ///
    /// The FIFO's backpressure applies between segments, never inside one: with the FIFO full the rest
    /// of the segment is read on into `pending` (one segment over the ceiling, as a whole-segment fetch
    /// held), so a paused player leaves the connection idle between two requests, where keep-alive
    /// expiry costs one retry, rather than mid-body, where an origin's send timeout costs the session.
    private func stream(
        head: Data, body: PersistentHTTP1Transport.Body, checkCarriage: Bool, generation: UInt64
    ) async throws -> Bool {
        var pending = head
        var checked = !checkCarriage
        var total = head.count
        do {
            while true {
                let chunk = try await body.next()
                if let chunk {
                    if pending.isEmpty { pending = chunk } else { pending.append(chunk) }
                    total += chunk.count
                }
                if !checked, chunk == nil || !pending.isEmpty {
                    guard LiveSegmentFormat.classify(pending) == .mpegts else {
                        body.abandon()
                        throw HLSIngestError.unsupportedSegmentFormat
                    }
                    checked = true
                }
                if chunk == nil { break }
                guard !pending.isEmpty else { continue }
                switch offer(pending, generation: generation) {
                case .taken: pending = Data()
                case .full: continue
                case .superseded:
                    body.abandon()
                    return false
                }
            }
        } catch is BoundedFetch.Exceeded {
            throw HLSIngestError.playlistInvalid(reason: "segment body over its limit")
        }
        guard total > 0 else { throw HLSIngestError.playlistUnreachable(status: body.response.statusCode) }
        // The ceiling between segments is enforced before the next request (`waitForSegmentAdmission`).
        return pending.isEmpty || append(pending, generation: generation)
    }

    private enum Offer { case taken, full, superseded }

    /// `append` without the wait: a full FIFO answers `.full` and leaves the bytes with the caller.
    private func offer(_ data: Data, generation: UInt64) -> Offer {
        condition.withLock {
            guard self.generation == generation, !closed else { return .superseded }
            guard bufferedBytes < Self.maximumBufferedBytes else { return .full }
            queue.append(data)
            bufferedBytes += data.count
            condition.broadcast()
            return .taken
        }
    }

    /// A segment's response with its status checked; the body is still to be read.
    private func openSegment(
        _ url: URL, limit: Int, byteRange: HLSByteRange? = nil
    ) async throws -> PersistentHTTP1Transport.Body {
        guard let transport else { throw CancellationError() }
        let body: PersistentHTTP1Transport.Body
        do {
            body = try await transport.open(url, headers: scopedHeaders(url, byteRange: byteRange), limit: limit,
                                             diagnosticContext: diagnosticContext, role: .hlsSegment)
        } catch is BoundedFetch.Exceeded {
            throw HLSIngestError.playlistInvalid(reason: "body exceeds \(limit) bytes")
        }
        guard (200..<300).contains(body.response.statusCode) else {
            throw HLSIngestError.playlistUnreachable(status: body.response.statusCode)
        }
        return body
    }

    /// Wait between requests, after the previous body has completed. Seek/close wake the producer
    /// and invalidate its generation; a superseded producer must never open the next segment.
    private func waitForSegmentAdmission(generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while self.generation == generation, !closed, !failed,
              bufferedBytes >= Self.maximumBufferedBytes {
            condition.wait()
        }
        return self.generation == generation && !closed && !failed
    }

    private func append(_ data: Data, generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while self.generation == generation,
              !closed,
              bufferedBytes >= Self.maximumBufferedBytes {
            condition.wait()
        }
        guard self.generation == generation, !closed else { return false }
        queue.append(data)
        bufferedBytes += data.count
        condition.broadcast()
        return true
    }

    private func fail(_ error: Error, generation: UInt64) {
        condition.lock()
        guard self.generation == generation, !closed else {
            condition.unlock()
            return
        }
        failed = true
        producer = nil
        condition.broadcast()
        condition.unlock()
        EngineLog.emit("[HLSVODIngest] terminal: \(EngineLog.summary(of: error))", category: .engine)
    }

    private func resolveMedia() async throws -> ResolvedMedia {
        let (root, rootURL) = try await fetchPlaylist(playlistURL)
        let media: HLSMediaPlaylist
        let mediaURL: URL
        switch root {
        case .media(let value):
            media = value
            mediaURL = rootURL
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  best.audioGroupID == nil,
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: rootURL) else {
                throw HLSIngestError.demuxedAudioNotSupported
            }
            let (selected, selectedURL) = try await fetchPlaylist(url)
            guard case .media(let value) = selected else {
                throw HLSIngestError.playlistInvalid(reason: "selected variant is not a media playlist")
            }
            media = value
            mediaURL = selectedURL
        }

        guard media.hasEndList else {
            throw HLSIngestError.playlistInvalid(reason: "finite VOD requires EXT-X-ENDLIST")
        }
        guard !media.hasMap else { throw HLSIngestError.unsupportedSegmentFormat }
        guard !media.hasUnsupportedEncryption else {
            throw HLSIngestError.encryptedNotSupported
        }
        let timeline = try Self.segmentTimeline(media.segments)
        return ResolvedMedia(
            url: mediaURL,
            segments: media.segments,
            starts: timeline.starts,
            duration: timeline.duration
        )
    }

    static func segmentTimeline(_ segments: [HLSMediaSegment]) throws -> (starts: [Double], duration: Double) {
        var starts: [Double] = []
        starts.reserveCapacity(segments.count)
        var duration = 0.0
        for segment in segments {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSIngestError.playlistInvalid(reason: "segment duration must be positive")
            }
            starts.append(duration)
            duration += segment.duration
        }
        // Audit HLS-102: each entry is inside the parser's ceiling, the sum need not be. A tiny entry
        // after a large sum also leaves the total unmoved, the starts stop being monotonic, and the
        // uniform fallback plans the whole sum.
        guard duration <= MediaDurationCeiling.seconds else {
            throw HLSIngestError.playlistInvalid(reason: "program duration exceeds \(MediaDurationCeiling.seconds)s")
        }
        return (starts, duration)
    }

    /// Credentials only where the host's playlist is (audit NET-7), and a segment's sub-range when it
    /// has one.
    func makeRequest(_ url: URL, byteRange: HLSByteRange? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in scopedHeaders(url, byteRange: byteRange) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return SourceNetworkDiagnostics.request(request, context: diagnosticContext)
    }

    private func scopedHeaders(_ url: URL, byteRange: HLSByteRange? = nil) -> [String: String] {
        var headers = RedirectHeaderPolicy.scoped(httpHeaders, grantedFor: playlistURL, sentTo: url)
        if let byteRange {
            headers["Range"] = byteRange.requestHeaderValue
        }
        return headers
    }

    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let data: Data
        let response: URLResponse
        if let transport {
            do {
                let answer = try await transport.get(url, headers: scopedHeaders(url), limit: Self.maximumPlaylistBytes,
                                                     diagnosticContext: diagnosticContext, role: .hlsPlaylist)
                (data, response) = (answer.body, answer.response)
            } catch let error as BoundedFetch.Exceeded {
                throw HLSIngestError.playlistInvalid(reason: "playlist exceeds \(error.limit) bytes")
            }
        } else {
            (data, response) = try await BoundedPlaylistFetch.data(
                for: makeRequest(url), session: session, limit: Self.maximumPlaylistBytes)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "playlist is not bounded UTF-8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    /// A segment or a key body, cut off at `limit` while it arrives (audit NET-112). With a byte range,
    /// the segment's sub-range of that body.
    private func fetch(_ url: URL, limit: Int, role: SourceNetworkDiagnostics.Role = .hlsSegment,
                       byteRange: HLSByteRange? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let transport {
                let answer = try await transport.get(url, headers: scopedHeaders(url, byteRange: byteRange), limit: limit,
                                                     diagnosticContext: diagnosticContext, role: role)
                (data, response) = (answer.body, answer.response)
            } else {
                (data, response) = try await BoundedFetch.data(
                    for: makeRequest(url, byteRange: byteRange), session: session, limit: limit, role: role)
            }
        } catch is BoundedFetch.Exceeded {
            throw HLSIngestError.playlistInvalid(reason: "body exceeds \(limit) bytes")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let byteRange else { return data }
        return try byteRange.segmentBytes(
            from: data, status: status,
            contentRange: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
    }

    /// Reads the head of the first segment and classifies its carriage (AE#293 shares this read with the
    /// live probe, so both paths judge a source the same way). A sub-range segment is probed on its own
    /// range: its resource is the whole file, which overruns the segment limit on the persistent path.
    /// That response goes after the verdict, since the segment is fetched again on its own request.
    private func probeCarriage(
        _ url: URL, duration: Double, byteRange: HLSByteRange? = nil
    ) async throws -> MPEGTransportStreamCodecProbe.Verdict {
        if transport != nil {
            // The probe reads the head and leaves the response open: stopping the body here would
            // cost the connection, and reading it whole delays the start by the whole segment.
            let body = try await openSegment(url, limit: BoundedFetch.segmentLimit(forDuration: duration),
                                             byteRange: byteRange)
            var head = Data()
            var verdict = MPEGTransportStreamCodecProbe.Verdict.inconclusive
            do {
                while head.count < HLSCarriageProbe.maximumSegmentHeadBytes, let chunk = try await body.next() {
                    head.append(chunk)
                    verdict = MPEGTransportStreamCodecProbe.classify(head.prefix(HLSCarriageProbe.maximumSegmentHeadBytes))
                    if verdict != .inconclusive { break }
                }
            } catch {
                body.abandon()
                throw error
            }
            guard !head.isEmpty else { throw HLSIngestError.unsupportedSegmentFormat }
            if verdict == .hevcInMPEGTS, byteRange == nil {
                let displaced = condition.withLock { () -> PrimedSegment? in
                    defer { primedSegment = PrimedSegment(url: url, head: head, body: body) }
                    return primedSegment
                }
                displaced?.body.abandon()
            } else {
                body.abandon()
            }
            return verdict
        }
        return try await HLSCarriageProbe.classifySegmentHead(
            url: url,
            httpHeaders: RedirectHeaderPolicy.scoped(httpHeaders, grantedFor: playlistURL, sentTo: url),
            session: session,
            diagnosticContext: diagnosticContext
        )
    }

    private func decrypt(
        _ ciphertext: Data,
        crypt: HLSSegmentCrypt,
        baseURL: URL
    ) async throws -> Data {
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: baseURL) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "unresolvable key URI")
        }
        let key: Data
        if let cached = keyCacheLock.withLock({ keyCache[keyURL.absoluteString] }) {
            key = cached
        } else {
            let fetched = try await fetch(keyURL, limit: BoundedFetch.keyLimit, role: .hlsKey)
            guard fetched.count == kCCKeySizeAES128 else {
                throw HLSIngestError.segmentDecryptFailed(reason: "key length is not 16 bytes")
            }
            keyCacheLock.withLock { keyCache[keyURL.absoluteString] = fetched }
            key = fetched
        }
        guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(
            ciphertext,
            key: key,
            iv: crypt.iv
        ) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "AES-128-CBC failed")
        }
        return plaintext
    }
}

/// Bounded MPEG-TS PMT inspection. HEVC is stream_type 0x24, or private PES (0x06) carrying a
/// well-formed `registration_descriptor("HEVC")` (AE#718); no URL suffix or response MIME type is
/// treated as codec evidence.
enum MPEGTransportStreamCodecProbe {
    private static let packetSize = 188
    private static let hevcStreamType: UInt8 = 0x24
    private static let privatePESStreamType: UInt8 = 0x06
    private static let registrationDescriptorTag: UInt8 = 0x05
    private static let hevcFormatIdentifier: [UInt8] = Array("HEVC".utf8)

    enum Verdict: Equatable {
        /// PMT declares HEVC: AVFoundation builds no video track for this carriage (HLS Authoring
        /// Spec sanctions HEVC only in fMP4), so the source belongs on the ingest.
        case hevcInMPEGTS
        /// Not MPEG-TS at all, or a PMT that declares something AVPlayer carries itself.
        case otherCarriage
        /// Not enough evidence yet; read further or, at the ceiling, leave the source on its route.
        case inconclusive
    }

    /// Definitive as soon as one complete PMT section has been read; `inconclusive` while the head
    /// still parses as TS but no PMT has appeared. Callers treat a final `inconclusive` like
    /// `otherCarriage`: the reroute needs positive evidence, never an absence of it.
    static func classify(_ data: Data) -> Verdict {
        guard !data.isEmpty else { return .inconclusive }
        guard LiveSegmentFormat.classify(data) == .mpegts else { return .otherCarriage }
        let bytes = [UInt8](data)
        guard bytes.count >= packetSize else { return .inconclusive }
        var packetStart = 0
        var sawPMT = false
        while packetStart + packetSize <= bytes.count {
            guard bytes[packetStart] == 0x47 else { return .otherCarriage } // lost packet alignment
            switch programMapVerdict(bytes, packetStart: packetStart) {
            case .hevcInMPEGTS: return .hevcInMPEGTS
            case .otherCarriage: sawPMT = true
            case .inconclusive: break
            }
            packetStart += packetSize
        }
        return sawPMT ? .otherCarriage : .inconclusive
    }

    /// One packet's contribution: `inconclusive` unless it opens a PMT section, which is then read for
    /// an HEVC elementary stream. A PMT split across packets is only judged on its first packet; a
    /// declaration hiding past that boundary reads as `otherCarriage` and keeps the native route.
    private static func programMapVerdict(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Verdict {
        guard bytes[packetStart + 1] & 0x40 != 0 else { return .inconclusive } // payload_unit_start
        let adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else { return .inconclusive }
        var payload = packetStart + 4
        let packetEnd = packetStart + packetSize
        if adaptationControl == 3 {
            payload += 1 + Int(bytes[payload])
            guard payload < packetEnd else { return .inconclusive }
        }
        payload += 1 + Int(bytes[payload]) // pointer_field
        guard payload + 12 <= packetEnd, bytes[payload] == 0x02 else { return .inconclusive }

        let sectionLength =
            (Int(bytes[payload + 1] & 0x0F) << 8)
                | Int(bytes[payload + 2])
        let sectionEnd = min(packetEnd, payload + 3 + sectionLength - 4)
        let programInfoLength =
            (Int(bytes[payload + 10] & 0x0F) << 8)
                | Int(bytes[payload + 11])
        var stream = payload + 12 + programInfoLength
        while stream + 5 <= sectionEnd {
            if bytes[stream] == hevcStreamType { return .hevcInMPEGTS }
            let infoLength =
                (Int(bytes[stream + 3] & 0x0F) << 8)
                    | Int(bytes[stream + 4])
            let descriptorsEnd = stream + 5 + infoLength
            if bytes[stream] == privatePESStreamType,
               descriptorsEnd <= sectionEnd,
               registersHEVC(bytes, descriptors: (stream + 5)..<descriptorsEnd) {
                return .hevcInMPEGTS
            }
            stream = descriptorsEnd
        }
        return .otherCarriage
    }

    /// AE#718: a descriptor loop that runs past its own bounds is not evidence, so a truncated
    /// registration descriptor never counts.
    private static func registersHEVC(_ bytes: [UInt8], descriptors: Range<Int>) -> Bool {
        var descriptor = descriptors.lowerBound
        while descriptor + 2 <= descriptors.upperBound {
            let length = Int(bytes[descriptor + 1])
            let body = descriptor + 2
            guard body + length <= descriptors.upperBound else { return false }
            if bytes[descriptor] == registrationDescriptorTag, length >= 4,
               Array(bytes[body..<(body + 4)]) == hevcFormatIdentifier {
                return true
            }
            descriptor = body + length
        }
        return false
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
