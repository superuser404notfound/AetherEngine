import Foundation

/// AE#859: turns an MPD URL into a `DASHVirtualMP4Reader`. Fetches the manifest, picks the
/// representations (`DASHManifest.selectRepresentations`), opens one ranged reader per
/// representation file and reads its initialization segment and segment index, which is all the
/// layout needs: no media byte is fetched before the demuxer asks for one.
///
/// Every request carries the session's headers. `cancel()` is safe from any thread and reaches the
/// manifest fetch and every reader opened so far, which is what lets a teardown that races the open
/// end it instead of waiting out the request timeouts (audit DMX-102's rule for the disc path).
final class DASHSourceOpener: @unchecked Sendable {

    /// A manifest is text; an on-demand one is a few kilobytes. The bound only stops a misrouted
    /// media file from being read whole into memory.
    static let manifestByteLimit = 8 * 1024 * 1024
    /// Init and index further apart than this are read with two requests instead of one.
    static let contiguousHeadSlack: Int64 = 256 * 1024

    private let manifestURL: URL
    private let headers: [String: String]
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
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
            + "header \(layout.header.count) bytes; " + tracks.joined(separator: "; "),
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

    /// One GET on the opener's own session, so `cancel()` reaches it.
    private func fetch(_ url: URL, range: ClosedRange<Int64>? = nil) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(engineURL: url, timeoutInterval: requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = session.dataTask(with: request) { data, response, error in
            outcome = (data, response, error)
            done.signal()
        }
        if isCancelled { throw DASHSourceError.cancelled }
        task.resume()
        done.wait()
        if isCancelled { throw DASHSourceError.cancelled }
        let (data, response, error) = outcome
        if let error {
            let ns = error as NSError
            throw DASHSourceError.representationUnreachable("\(ns.domain) \(ns.code)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DASHSourceError.representationUnreachable("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else { throw AVIOReaderError.httpStatus(http.statusCode) }
        return (data ?? Data(), http)
    }

    private func fetchManifest() throws -> (Data, URL) {
        let (data, response) = try fetch(manifestURL)
        guard data.count <= Self.manifestByteLimit else {
            throw DASHSourceError.manifestTooLarge(Self.manifestByteLimit)
        }
        guard DASHManifest.bodyBeginsWithManifest([UInt8](data.prefix(4096))) else {
            throw DASHSourceError.notAManifest
        }
        // Relative BaseURLs resolve against where the manifest was finally served from.
        return (data, response.url ?? manifestURL)
    }

    /// The bytes of `range` and the file's total size, from a 206 that starts where it was asked to.
    /// The head requests double as the range probe: a file whose origin answers them with a 200
    /// cannot be addressed by SegmentBase at all.
    private func fetchRange(_ rep: DASHManifest.Representation, _ range: ClosedRange<Int64>) throws -> ([UInt8], Int64) {
        let count = range.upperBound - range.lowerBound + 1
        guard count > 0, count <= 64 * 1024 * 1024 else {
            throw DASHSourceError.malformedIndex("representation \(rep.id) declares a \(count) byte head")
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try fetch(rep.url, range: range)
                guard response.statusCode == 206 else {
                    throw DASHSourceError.representationUnreachable(
                        "representation \(rep.id): the origin ignores Range requests, which SegmentBase addressing needs")
                }
                let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard contentRange.hasPrefix("bytes \(range.lowerBound)-"),
                      let total = HTTPDiscIOReader.parseContentRangeTotal(contentRange), total > range.upperBound,
                      Int64(data.count) >= count else {
                    throw DASHSourceError.representationUnreachable(
                        "representation \(rep.id) answered \(data.count) bytes (\(contentRange)) for bytes \(range.lowerBound)-\(range.upperBound)")
                }
                return ([UInt8](data.prefix(Int(count))), total)
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
        guard let reader = HTTPDiscIOReader(url: rep.url, extraHeaders: headers,
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
                              indexOffset: indexRange.lowerBound, language: rep.language))
    }
}
