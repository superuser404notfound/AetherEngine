import Foundation

/// A disc that a host serves as a FOLDER (the `BDMV` or `VIDEO_TS` tree, one address per file) rather
/// than as a single image. Hand one to `load(source: .custom(reader))`: the engine selects the title and
/// concatenates its clips or VOBs the same way it does for an ISO, so titles, chapters, track languages,
/// the multi-clip and multi-cell timelines and the seek tables all behave as they do there. As on an
/// image, Blu-ray is tried first and a listing with `VIDEO_TS/` in it falls back to DVD-Video.
///
/// A folder carries no bytes of its own: `read` is never called on it. The engine recognizes the
/// conformance before it reads anything and opens the files it needs through `openDiscFile(_:)`.
/// `discImageProbeEnabled` does not apply: it gates signature reads on a byte source, and a folder is
/// recognized by its conformance alone, so either value works.
public protocol DiscDirectoryReader: IOReader {
    /// Every file of the disc that can be read: its path relative to the disc root, with `/` as the
    /// separator (`BDMV/STREAM/00001.m2ts`, `VIDEO_TS/VTS_01_1.VOB`), and its size in bytes.
    var discFiles: [(path: String, size: Int64)] { get }

    /// A new, independent reader over one file of `discFiles` (matched case-insensitively), or nil when
    /// it cannot be opened. The caller closes it.
    func openDiscFile(_ path: String) -> IOReader?

    /// The `.mpls` file name of the title to play (`00800.mpls`), when the host already knows it. The
    /// engine then reads only that playlist and publishes it as the only title; nil reads every playlist
    /// and selects the main title by the engine's own rules, as on an ISO. Blu-ray only.
    var preferredPlaylist: String? { get }
}

/// A disc folder over HTTP: one URL per file, each read through its own range reader, so an origin
/// serves the disc as plain files and never remuxes it.
public final class HTTPDiscDirectoryReader: DiscDirectoryReader {
    public struct File: Sendable {
        /// Path relative to the disc root, `/`-separated (`BDMV/PLAYLIST/00800.mpls`).
        public let path: String
        /// The file's exact size in bytes.
        public let size: Int64
        /// Where the file's bytes are served. The origin must honour HTTP `Range`.
        public let url: URL

        public init(path: String, size: Int64, url: URL) {
            self.path = path
            self.size = size
            self.url = url
        }
    }

    private let files: [File]
    private let httpHeaders: [String: String]
    public let preferredPlaylist: String?

    /// `httpHeaders` ride on every range request to every file.
    public init(files: [File], preferredPlaylist: String? = nil, httpHeaders: [String: String] = [:]) {
        self.files = files
        self.preferredPlaylist = preferredPlaylist
        self.httpHeaders = httpHeaders
    }

    public var discFiles: [(path: String, size: Int64)] { files.map { ($0.path, $0.size) } }

    public func openDiscFile(_ path: String) -> IOReader? {
        guard let file = files.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return nil }
        // A small file (a playlist) is read whole, so whether its origin honours ranges does not matter and
        // the listed size can stand in for the range probe: a folder holds a few hundred playlists, and the
        // probe doubled the requests recognition made. A clip keeps the probe, which is what refuses an
        // origin that would answer a range with the whole file.
        let small = file.size > 0 && file.size <= DiscReader.maxSmallFileBytes
        return HTTPDiscIOReader(url: file.url, extraHeaders: httpHeaders, knownSize: small ? file.size : nil)
    }

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
    public func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    public func close() {}

    /// The side readers (subtitles, scrub previews) need a cursor of their own: the same listing again,
    /// whose files open on demand.
    public func makeIndependentReader() -> IOReader? {
        HTTPDiscDirectoryReader(files: files, preferredPlaylist: preferredPlaylist, httpHeaders: httpHeaders)
    }
}

/// Independent files presented as one contiguous, seekable byte stream: the clips of a title in a disc
/// folder. Files open on demand and only the most recently used few stay open, because a multi-clip
/// title can run to dozens of clips and needs no more than one connection at a time to play.
final class MultiFileConcatIOReader: IOReader, SourceTransferCounting, @unchecked Sendable {
    struct Segment {
        let path: String
        let size: Int64
    }

    /// The current clip, plus room for a read across a clip boundary and a seek back into the last one.
    static let openLimit = 3

    private let segments: [Segment]
    /// Each segment's first byte in the concatenated stream, parallel to `segments`.
    private let starts: [Int64]
    private let totalLength: Int64
    private let opener: @Sendable (String) -> IOReader?
    /// Serializes `read`, `seek` and `close`, and is held across the network. `cancel` never takes it:
    /// it exists to unblock a read parked under it.
    private let ioLock = NSLock()
    private var position: Int64 = 0
    /// Guards the fields below, and is only ever held briefly.
    private let stateLock = NSLock()
    /// Open readers by segment index, and their use order: the least recently used one closes first.
    private var open: [Int: IOReader] = [:]
    private var recent: [Int] = []
    /// Bytes fetched by readers already closed, so the transfer count survives their eviction.
    private var retiredSourceBytes: Int64 = 0
    /// Bumped by `cancel`, so a file that was still opening when it arrived is cancelled once it exists.
    private var cancelGeneration = 0

    init(segments: [Segment], opener: @escaping @Sendable (String) -> IOReader?) {
        self.segments = segments
        self.opener = opener
        var cursor: Int64 = 0
        var starts: [Int64] = []
        for segment in segments {
            starts.append(cursor)
            cursor += max(0, segment.size)
        }
        self.starts = starts
        self.totalLength = cursor
    }

    var sourceBytesFetched: Int64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return retiredSourceBytes + open.values.reduce(0) { $0 + Self.fetched($1) }
    }

    private static func fetched(_ reader: IOReader) -> Int64 {
        (reader as? SourceTransferCounting)?.sourceBytesFetched ?? 0
    }

    /// The reader of segment `index`, opening it if needed. Called with `ioLock` held; the open itself
    /// (a range probe on HTTP) runs outside `stateLock`, so `cancel` never waits for it.
    private func reader(for index: Int) -> IOReader? {
        stateLock.lock()
        if let existing = open[index] {
            recent.removeAll { $0 == index }
            recent.append(index)
            stateLock.unlock()
            return existing
        }
        let generation = cancelGeneration
        stateLock.unlock()

        guard let fresh = opener(segments[index].path) else { return nil }

        stateLock.lock()
        let cancelledWhileOpening = cancelGeneration != generation
        open[index] = fresh
        recent.append(index)
        var evicted: [IOReader] = []
        while recent.count > Self.openLimit {
            if let gone = open.removeValue(forKey: recent.removeFirst()) {
                retiredSourceBytes += Self.fetched(gone)
                evicted.append(gone)
            }
        }
        stateLock.unlock()
        evicted.forEach { $0.close() }
        if cancelledWhileOpening { fresh.cancel() }
        return fresh
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        ioLock.lock(); defer { ioLock.unlock() }
        guard position < totalLength else { return 0 }
        var index = starts.lastIndex { $0 <= position } ?? 0
        let toRead = min(Int64(size), totalLength - position)
        var got: Int64 = 0
        while got < toRead, index < segments.count {
            let intra = position + got - starts[index]
            let want = min(toRead - got, segments[index].size - intra)
            if want <= 0 {
                index += 1
                continue
            }
            guard let segmentReader = reader(for: index),
                  segmentReader.seek(offset: intra, whence: SEEK_SET) >= 0 else {
                return got > 0 ? Int32(got) : -1
            }
            var chunk: Int64 = 0
            while chunk < want {
                let n = segmentReader.read(buffer.advanced(by: Int(got + chunk)), size: Int32(want - chunk))
                if n == 0 { break }
                if n < 0 { return got + chunk > 0 ? Int32(got + chunk) : -1 }
                chunk += Int64(n)
            }
            got += chunk
            // A file shorter than its listed size: return what arrived, the next read resumes from there.
            if chunk < want { break }
            index += 1
        }
        position += got
        return Int32(got)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalLength }               // AVSEEK_SIZE
        ioLock.lock(); defer { ioLock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = totalLength + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, totalLength)
        return position
    }

    /// Waits for a read in flight, as before the split, so no read is left holding a closed file.
    func close() {
        ioLock.lock(); defer { ioLock.unlock() }
        stateLock.lock()
        let readers = Array(open.values)
        retiredSourceBytes += readers.reduce(0) { $0 + Self.fetched($1) }
        open.removeAll()
        recent.removeAll()
        stateLock.unlock()
        readers.forEach { $0.close() }
    }

    /// Passed on to the open file readers, so a stop unblocks a read parked on the network. It takes
    /// only `stateLock`: the read it is meant to unblock holds `ioLock` for as long as it is parked.
    func cancel() {
        stateLock.lock()
        cancelGeneration &+= 1
        let readers = Array(open.values)
        stateLock.unlock()
        readers.forEach { $0.cancel() }
    }

    func makeIndependentReader() -> IOReader? {
        MultiFileConcatIOReader(segments: segments, opener: opener)
    }

    /// Already the title's transport stream; there is no disc left to recognize in it.
    var discImageProbeEnabled: Bool { false }
}

extension DiscReader {
    /// A DVD-Video folder: the image path (`wrapDVD`) with files in place of sector ranges. A title set's
    /// VOBs follow each other in part order, which is the same run of bytes as their sectors on a disc, so
    /// the cell spans and the time map from its VTS IFO apply unchanged.
    static func wrapDVDFolder(_ folder: DiscDirectoryReader, selectTitleID: Int?) -> DiscInfo? {
        // Only VIDEO_TS's own files; a folder has no sectors, so each file is listed by name and size.
        let entries = folder.discFiles.filter { $0.path.uppercased().hasPrefix("VIDEO_TS/") }
        var byName: [String: (path: String, size: Int64)] = [:]
        let files = entries.compactMap { entry -> DiscFile? in
            let name = String(entry.path.split(separator: "/").last ?? "")
            guard !name.isEmpty, entry.size > 0, entry.size <= Int64(Int.max) else { return nil }
            byName[name.uppercased()] = entry
            return DiscFile(name: name, startSector: 0, length: Int(entry.size))
        }
        let readFile: (DiscFile) -> [UInt8] = { file in
            guard let entry = byName[file.name.uppercased()], let reader = folder.openDiscFile(entry.path) else { return [] }
            defer { reader.close() }
            return readAll(reader, [(offset: 0, length: entry.size)])
        }
        guard let set = dvdTitleSet(files: files, selectTitleID: selectTitleID, readFile: readFile) else {
            EngineLog.emit("[disc] VIDEO_TS folder: no title VOBs among \(entries.count) files", category: .demux)
            return nil
        }
        let segments = set.vobs.compactMap { vob in
            byName[vob.name.uppercased()].map { MultiFileConcatIOReader.Segment(path: $0.path, size: $0.size) }
        }
        guard !segments.isEmpty else { return nil }
        let (cellTimeline, timeMap) = set.selectedIFO.map(dvdCellTimeline) ?? ([], nil)
        EngineLog.emit("[disc] DVD-Video folder recognized: \(set.titles.count) title(s), selected \(set.selectedIndex) "
                       + "VOBs=\(segments.map(\.path)) bytes=\(segments.reduce(0) { $0 + $1.size })", category: .demux)
        return DiscInfo(reader: MultiFileConcatIOReader(segments: segments, opener: { folder.openDiscFile($0) }),
                        formatHint: "mpeg", titles: set.titles, selectedTitleIndex: set.selectedIndex,
                        clipTimeline: cellTimeline, dvdTimeMap: timeMap)
    }

    /// A Blu-ray folder: the image path (`wrapBluRay`) with files in place of UDF extents. The playlist scan
    /// and the clip assembly are the same bounded code, so a folder cannot make recognition do more than
    /// an image can (audit NET-103).
    static func wrapBluRayFolder(_ folder: DiscDirectoryReader, selectTitleID: Int?) -> DiscInfo? {
        let files = folder.discFiles
        let byPath = Dictionary(files.map { ($0.path.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func file(_ path: String) -> (path: String, size: Int64)? { byPath[path.uppercased()] }

        var playlists = files.filter { $0.path.uppercased().hasPrefix("BDMV/PLAYLIST/") }
        if let preferred = folder.preferredPlaylist {
            if let hit = file("BDMV/PLAYLIST/\(preferred)") {
                playlists = [hit]
            } else {
                EngineLog.emit("[disc] BDMV folder: preferred playlist \(preferred) is not in the listing; scanning all", category: .demux)
            }
        }
        let parsed = scanPlaylists(playlists,
                                   name: { $0.path },
                                   extents: { [(offset: 0, length: $0.size)] },
                                   read: { entry, extents in
                                       guard let reader = folder.openDiscFile(entry.path) else { return [] }
                                       defer { reader.close() }
                                       return readAll(reader, extents)
                                   })
        let titles = BDTitleSelector.enumerateTitles(parsed)
        guard !titles.isEmpty else {
            EngineLog.emit("[disc] BDMV folder: no parseable .mpls (\(playlists.count) PLAYLIST entries, \(parsed.count) parsed)", category: .demux)
            return nil
        }
        let selectedIndex = selectTitleID.flatMap { titles.indices.contains($0) ? $0 : nil } ?? 0
        let selected = titles[selectedIndex]
        let assembled = assembleBluRayTitle(
            clipIDs: selected.bdClipIDs ?? [],
            subtractTicks: selected.bdClipSubtractTicks ?? [],
            cumulativeBeforeTicks: selected.bdClipCumulativeBeforeTicks ?? [],
            piecesOfClip: { clip in
                guard let stream = file("BDMV/STREAM/\(clip).m2ts"), stream.size > 0 else { return nil }
                return [MultiFileConcatIOReader.Segment(path: stream.path, size: stream.size)]
            },
            length: { (segment: MultiFileConcatIOReader.Segment) in segment.size })
        let segments = assembled.pieces
        var clipTimeline = assembled.clipTimeline
        guard !segments.isEmpty else {
            EngineLog.emit("[disc] BDMV folder: title \(selectedIndex) clips=\(selected.bdClipIDs ?? []) resolved no file in BDMV/STREAM", category: .demux)
            return nil
        }
        // As on an image: a single clip, or clips that already continue each other, need no folding.
        if clipTimeline.count < 2 || !clipTimeline.contains(where: { $0.predictedShiftSec != 0 }) {
            clipTimeline = []
        }
        let totalBytes = segments.reduce(Int64(0)) { $0 + $1.size }
        EngineLog.emit("[disc] Blu-ray folder recognized: \(titles.count) title(s), selected \(selectedIndex) playlist=\(selected.bdPlaylist ?? "-") clips=\(selected.bdClipIDs ?? []) files=\(segments.count) bytes=\(totalBytes) clipSpans=\(clipTimeline.count) preferred=\(folder.preferredPlaylist ?? "-")", category: .demux)
        let seekTable = buildSeekTable(title: selected, resolved: assembled.resolved) { clip in
            guard let info = file("BDMV/CLIPINF/\(clip).clpi"), info.size > 0,
                  let reader = folder.openDiscFile(info.path) else { return nil }
            defer { reader.close() }
            return readAll(reader, [(offset: 0, length: info.size)])
        }
        return DiscInfo(reader: MultiFileConcatIOReader(segments: segments, opener: { folder.openDiscFile($0) }),
                        formatHint: "mpegts", titles: titles, selectedTitleIndex: selectedIndex,
                        clipTimeline: clipTimeline, seekTable: seekTable)
    }
}
