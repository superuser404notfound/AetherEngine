import Foundation

/// AE#859: turns an MPD URL into a `DASHVirtualMP4Reader`. Fetches the manifest, picks the
/// representations (`DASHManifest.selectRepresentations`), opens one ranged reader per
/// representation file and reads its initialization segment and segment index, which is all the
/// layout needs: no media byte is fetched before the demuxer asks for one.
///
/// Every request carries the session's headers, credentials only for the origin of the manifest URL. `cancel()` is safe from any thread and reaches the
/// manifest fetch and every reader opened so far, which is what lets a teardown that races the open
/// end it instead of waiting out the request timeouts (audit DMX-102's rule for the disc path).
final class DASHSourceOpener: @unchecked Sendable {

    /// A manifest is text; an on-demand one is a few kilobytes. The fetch stops at this size, so a
    /// misrouted media file is never read whole into memory.
    static let manifestByteLimit = 8 * 1024 * 1024
    /// Init and index further apart than this are read with two requests instead of one.
    static let contiguousHeadSlack: Int64 = 256 * 1024

    private let manifestURL: URL
    private let headers: [String: String]
    /// Credentials go only to the origin that received them; an MPD can name any host (audit NET-201).
    private let scope: CredentialScope
    private let requestTimeout: TimeInterval
    private let session: URLSession

    private let lock = NSLock()
    private var cancelled = false
    private var openedReaders: [IOReader] = []

    /// Manifest URLs this process has opened as DASH, most recent last. A DASH session's readers
    /// take their headers at open, like a disc image's, so `updateRequestHeaders` must not promise
    /// them to live requests; an extensionless manifest is only known to be one after its body was read.
    private static let knownManifestsLock = NSLock()
    nonisolated(unsafe) private static var knownManifests: [URL] = []

    static func isKnownManifest(_ url: URL) -> Bool {
        knownManifestsLock.withLock { knownManifests.contains(url) }
    }

    private static func noteManifest(_ url: URL) {
        knownManifestsLock.withLock {
            knownManifests.removeAll { $0 == url }
            knownManifests.append(url)
            if knownManifests.count > 32 { knownManifests.removeFirst() }
        }
    }

    init(manifestURL: URL, headers: [String: String], requestTimeout: TimeInterval = 30) {
        self.manifestURL = manifestURL
        self.headers = headers
        self.requestTimeout = requestTimeout
        scope = CredentialScope(headers: headers, anchor: manifestURL)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The request timeout is an idle timeout; this one ends a body that trickles forever (audit NET-204).
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func cancel() {
        lock.lock()
        cancelled = true
        let readers = openedReaders
        lock.unlock()
        session.getAllTasks { $0.forEach { $0.cancel() } }
        readers.forEach { $0.cancel() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func open() throws -> DASHVirtualMP4Reader {
        let (data, baseURL) = try fetchManifest()
        let manifest = try DASHManifest.parse(data, manifestURL: baseURL)
        let selected = try manifest.selectRepresentations()
        let audioSets = manifest.adaptationSets.filter { $0.kind == .audio }.count
        if audioSets > DASHManifest.maxAudioRepresentations {
            EngineLog.emit("[DASH] the MPD declares \(audioSets) audio adaptation sets; carrying the first "
                           + "\(DASHManifest.maxAudioRepresentations) (audit NET-204)", category: .demux)
        }
        if isCancelled { throw DASHSourceError.cancelled }

        let slots = Slots(count: selected.count)
        DispatchQueue.concurrentPerform(iterations: selected.count) { i in
            slots.set(i, Result { try openRepresentation(selected[i]) })
        }
        let results = slots.values
        var readers: [IOReader] = []
        var sources: [DASHVirtualLayout.Source] = []
        var failure: Error?
        for result in results {
            switch result {
            case .success(let pair)?:
                readers.append(pair.0)
                sources.append(pair.1)
            case .failure(let error)?:
                failure = failure ?? error
            case nil:
                failure = failure ?? DASHSourceError.cancelled
            }
        }
        if let failure {
            readers.forEach { $0.close() }
            throw failure
        }
        let layout: DASHVirtualLayout
        do {
            layout = try DASHVirtualLayout.build(sources: sources, durationSeconds: manifest.durationSeconds)
        } catch {
            readers.forEach { $0.close() }
            throw error
        }
        lock.withLock { openedReaders = [] }

        let tracks = selected.map { rep in
            "\(rep.kind == .video ? "video" : "audio") id=\(rep.id) codecs=\(rep.codecs ?? "?") "
                + "bandwidth=\(rep.bandwidth)" + (rep.language.map { " lang=\($0)" } ?? "")
        }
        EngineLog.emit(
            "[DASH] AE#859: \(selected.count) representation(s) of "
            + "\(manifest.adaptationSets.reduce(0) { $0 + $1.representations.count }) laid out as one "
            + "fragmented MP4: \(layout.pieces.count) subsegments, \(layout.totalSize) bytes, "
            + "header \(layout.header.count) bytes, "
            + "\(layout.randomAccessStartsSeconds.count) declared video SAPs; " + tracks.joined(separator: "; "),
            category: .demux)
        Self.noteManifest(manifestURL)
        return DASHVirtualMP4Reader(layout: layout, sources: readers)
    }

    // MARK: - Private

    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<(IOReader, DASHVirtualLayout.Source), Error>?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ value: Result<(IOReader, DASHVirtualLayout.Source), Error>) {
            lock.withLock { storage[i] = value }
        }
        var values: [Result<(IOReader, DASHVirtualLayout.Source), Error>?] { lock.withLock { storage } }
    }

    /// The manifest, read through the bounded fetch the HLS paths use: a declared length over the limit
    /// is refused at the head and an undeclared one is cut at it, so a misrouted media file or an
    /// endless body never sits whole in memory (audit NET-204).
    private func fetchManifestBody() throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(engineURL: manifestURL, timeoutInterval: requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = session
        let limit = Self.manifestByteLimit
        if isCancelled { throw DASHSourceError.cancelled }
        let result: Result<(Data, URLResponse), Error>
        do {
            result = .success(try BoundedFetch.blockingData(for: request, session: session, limit: limit))
        } catch {
            result = .failure(error)
        }
        if isCancelled { throw DASHSourceError.cancelled }
        switch result {
        case .success(let (data, response)):
            guard let http = response as? HTTPURLResponse else {
                throw DASHSourceError.representationUnreachable("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else { throw AVIOReaderError.httpStatus(http.statusCode) }
            return (data, http)
        case .failure(let error as BoundedFetch.Exceeded):
            throw DASHSourceError.manifestTooLarge(error.limit)
        case .failure(let error):
            let ns = error as NSError
            throw DASHSourceError.representationUnreachable("\(ns.domain) \(ns.code)")
        }
    }

    private func fetchManifest() throws -> (Data, URL) {
        let (data, response) = try fetchManifestBody()
        guard DASHManifest.bodyBeginsWithManifest([UInt8](data.prefix(4096))) else {
            throw DASHSourceError.notAManifest
        }
        // Relative BaseURLs resolve against where the manifest was finally served from.
        return (data, response.url ?? manifestURL)
    }

    /// Init and index are never further than this from the file's start in a real file, and a
    /// declared head beyond it is a hostile or broken MPD, not a bigger index (a sidx indexes at most
    /// 65535 subsegments, under 1 MB).
    static let maxHeadBytes: Int64 = 64 * 1024 * 1024

    /// The bytes of `range` and the file's total size, from a 206 that starts where it was asked to.
    /// The head requests double as the range probe: a file whose origin answers them with a 200
    /// cannot be addressed by SegmentBase at all. One bounded range GET, the one the disc reader
    /// uses, on the opener's own session so `cancel()` reaches it (audit NET-R203).
    private func fetchRange(_ rep: DASHManifest.Representation, _ range: ClosedRange<Int64>) throws -> ([UInt8], Int64) {
        let (span, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        guard !overflow, span >= 0, span < Self.maxHeadBytes else {
            throw DASHSourceError.malformedIndex("representation \(rep.id) declares a head of more than \(Self.maxHeadBytes) bytes")
        }
        let count = span + 1
        let requestHeaders = scope.headers(for: rep.url)
        var attempt = 0
        while true {
            if isCancelled { throw DASHSourceError.cancelled }
            let response = HTTPDiscIOReader.rangeGet(
                url: rep.url, extraHeaders: requestHeaders, session: session, timeout: requestTimeout,
                offset: range.lowerBound, length: Int(count))
            if isCancelled { throw DASHSourceError.cancelled }
            do {
                guard let response else {
                    throw DASHSourceError.representationUnreachable("representation \(rep.id) did not answer")
                }
                guard response.status == 206 || response.status == 200 else {
                    throw AVIOReaderError.httpStatus(response.status)
                }
                guard response.status == 206 else {
                    throw DASHSourceError.representationUnreachable(
                        "representation \(rep.id): the origin ignores Range requests, which SegmentBase addressing needs")
                }
                let contentRange = response.contentRange ?? ""
                guard HTTPDiscIOReader.parseContentRangeStart(contentRange) == range.lowerBound,
                      let total = HTTPDiscIOReader.parseContentRangeTotal(contentRange), total > range.upperBound,
                      Int64(response.body.count) >= count else {
                    throw DASHSourceError.representationUnreachable(
                        "representation \(rep.id) answered \(response.body.count) bytes (\(contentRange)) for bytes \(range.lowerBound)-\(range.upperBound)")
                }
                return ([UInt8](response.body.prefix(Int(count))), total)
            } catch let error as DASHSourceError where attempt == 0 && error != .cancelled
                        && !error.description.contains("ignores Range") {
                attempt += 1
            }
        }
    }

    private func openRepresentation(_ rep: DASHManifest.Representation) throws -> (IOReader, DASHVirtualLayout.Source) {
        guard let segmentBase = rep.segmentBase else {
            throw DASHSourceError.noPlayableRepresentation("representation \(rep.id) has no SegmentBase")
        }
        let initRange = segmentBase.initialization
        let indexRange = segmentBase.index
        let initialization: [UInt8]
        let index: [UInt8]
        let total: Int64
        if indexRange.lowerBound >= initRange.lowerBound,
           indexRange.lowerBound - initRange.upperBound <= Self.contiguousHeadSlack {
            let (head, size) = try fetchRange(rep, initRange.lowerBound...max(initRange.upperBound, indexRange.upperBound))
            initialization = Array(head[0..<Int(initRange.count)])
            let indexStart = Int(indexRange.lowerBound - initRange.lowerBound)
            index = Array(head[indexStart..<(indexStart + Int(indexRange.count))])
            total = size
        } else {
            (initialization, total) = try fetchRange(rep, initRange)
            (index, _) = try fetchRange(rep, indexRange)
        }
        // The size is known from the head's Content-Range, so the reader starts without a probe.
        guard let reader = HTTPDiscIOReader(url: rep.url, extraHeaders: scope.headers(for: rep.url),
                                            requestTimeout: requestTimeout, knownSize: total) else {
            throw DASHSourceError.representationUnreachable("representation \(rep.id) did not answer")
        }
        lock.lock()
        let cancelledNow = cancelled
        if !cancelledNow { openedReaders.append(reader) }
        lock.unlock()
        if cancelledNow {
            reader.close()
            throw DASHSourceError.cancelled
        }
        return (reader, .init(initialization: initialization, index: index,
                              indexOffset: indexRange.lowerBound, language: rep.language,
                              isVideo: rep.kind == .video))
    }
}
