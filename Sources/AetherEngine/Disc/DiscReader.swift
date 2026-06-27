import Foundation

/// Detects a DVD-Video ISO and adapts it to the engine's normal demux path.
/// Given a raw ISO `IOReader`, returns a synthetic `IOReader` over the main
/// title's concatenated VOBs plus the demuxer format hint, or nil when the
/// source is not a playable DVD ISO (so the caller falls back to plain demux).
/// No decryption: encrypted retail ISOs parse but their streams will not
/// decode; that surfaces downstream as a normal demux/decode failure.
enum DiscReader {
    /// Drop every memoized disc recognition. Called when a new URL loads so a different disc at a
    /// reused cache key can never bleed (the cross-disc safety net `selectTitle` also relies on).
    static func clearCache() { DiscRecognitionCache.clear() }

    /// Cheap content sniff: the ISO9660 "CD001" signature at byte 0x8001.
    static func looksLikeISO9660(_ reader: IOReader) -> Bool {
        guard reader.seek(offset: 0x8001, whence: SEEK_SET) >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 5)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        return n == 5 && buf == Array("CD001".utf8)
    }

    /// Cheap UDF sniff: the Anchor Volume Descriptor Pointer (tag id 2) at
    /// logical sector 256 (offset 256 * 2048).
    static func looksLikeUDF(_ reader: IOReader) -> Bool {
        guard reader.seek(offset: 256 * 2048, whence: SEEK_SET) >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 2)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 2) }
        return n == 2 && (Int(buf[0]) | (Int(buf[1]) << 8)) == 2
    }

    /// Blu-ray: UDF filesystem with a BDMV directory. Enumerates every playlist as a selectable
    /// title and builds the concat reader for the chosen one (`selectTitleID`, default = main).
    /// Emits `.demux` diagnostics once the UDF anchor is confirmed so a disc image
    /// that fails recognition is debuggable (it would otherwise fall back to a raw
    /// FFmpeg open that reports a bare INVALIDDATA). Non-disc sources stay silent.
    static func wrapBluRay(_ reader: IOReader, selectTitleID: Int? = nil, cacheKey: String? = nil) throws -> DiscInfo? {
        guard looksLikeUDF(reader) else { return nil }
        EngineLog.emit("[disc] UDF anchor present; attempting Blu-ray BDMV", category: .demux)
        let udf: UDFReader
        do { udf = try UDFReader(reader: reader) }
        catch DiscError.notUDF {
            EngineLog.emit("[disc] UDF anchor present but volume structure not UDF", category: .demux)
            return nil
        }
        let root = (try? udf.list(path: [])) ?? []
        guard root.contains(where: { $0.isDir && $0.name == "BDMV" }) else {
            let names = root.isEmpty ? "<none>" : root.map(\.name).joined(separator: ", ")
            EngineLog.emit("[disc] no BDMV directory in UDF root (entries: \(names)); not a Blu-ray", category: .demux)
            return nil
        }
        let playlistDir = (try? udf.list(path: ["BDMV", "PLAYLIST"])) ?? []
        var parsed: [MPLSPlaylist] = []
        for e in playlistDir where e.name.hasSuffix(".mpls") {
            let exts = (try? udf.extents(of: e)) ?? []
            guard !exts.isEmpty else { continue }
            let bytes = readAll(reader, exts)
            if let pl = MPLSParser.parse(bytes) { parsed.append(pl) }
        }
        let titles = BDTitleSelector.enumerateTitles(parsed)
        guard !titles.isEmpty else {
            EngineLog.emit("[disc] BDMV present but no parseable .mpls (\(playlistDir.count) PLAYLIST entries, \(parsed.count) parsed); cannot select a title", category: .demux)
            return nil
        }
        let selectedIndex = selectTitleID.flatMap { titles.indices.contains($0) ? $0 : nil } ?? 0
        let selected = titles[selectedIndex]
        let streamDir = (try? udf.list(path: ["BDMV", "STREAM"])) ?? []
        var allExtents: [(offset: Int64, length: Int64)] = []
        for clip in selected.bdClipIDs ?? [] {
            guard let e = streamDir.first(where: { $0.name == "\(clip).m2ts" }),
                  let exts = try? udf.extents(of: e) else { continue }
            allExtents += exts
        }
        guard !allExtents.isEmpty else {
            EngineLog.emit("[disc] selected title \(selectedIndex) clips=\(selected.bdClipIDs ?? []) but resolved no m2ts extents in BDMV/STREAM (\(streamDir.count) entries); cannot build stream", category: .demux)
            return nil
        }
        let totalBytes = allExtents.reduce(Int64(0)) { $0 + max(0, $1.length) }
        EngineLog.emit("[disc] Blu-ray recognized: \(titles.count) title(s), selected \(selectedIndex) clips=\(selected.bdClipIDs ?? []) m2ts-extents=\(allExtents.count) bytes=\(totalBytes)", category: .demux)
        storeRecognition(cacheKey: cacheKey, selectTitleID: selectTitleID,
                         formatHint: "mpegts", titles: titles, selectedIndex: selectedIndex, extents: allExtents)
        return DiscInfo(reader: ConcatIOReader(base: reader, extents: allExtents),
                        formatHint: "mpegts", titles: titles, selectedTitleIndex: selectedIndex)
    }

    /// Memoize a successful recognition so a re-open of the same source (track switch on a remote ISO)
    /// reuses it. No-op when the caller passed no cache key (custom sources opt in explicitly).
    private static func storeRecognition(
        cacheKey: String?, selectTitleID: Int?,
        formatHint: String, titles: [DiscTitle], selectedIndex: Int,
        extents: [(offset: Int64, length: Int64)]
    ) {
        guard let cacheKey else { return }
        DiscRecognitionCache.store(
            key: cacheKey, selectTitleID: selectTitleID,
            DiscRecognition(formatHint: formatHint, titles: titles,
                            selectedTitleIndex: selectedIndex, extents: extents))
    }

    /// Read all bytes of an extent list into memory (small files only: mpls).
    static func readAll(_ base: IOReader, _ exts: [(offset: Int64, length: Int64)]) -> [UInt8] {
        // Extent lengths are untrusted on-disc bytes (up to ~1 GB each). Cap the total before
        // allocating so a crafted .mpls cannot drive an arbitrary allocation (jetsam/DoS); 8 MB
        // matches UDFReader.readDirectory's guard and dwarfs any real playlist (KB-scale).
        let maxBytes: Int64 = 8 * 1024 * 1024
        let declared = exts.reduce(Int64(0)) { $0 + max(0, $1.length) }
        guard declared > 0, declared <= maxBytes else { return [] }
        let total = Int(declared)
        let r = ConcatIOReader(base: base, extents: exts)
        var out = [UInt8](repeating: 0, count: total); var got = 0
        out.withUnsafeMutableBufferPointer { p in
            while got < total {
                let n = r.read(p.baseAddress!.advanced(by: got), size: Int32(min(Int64(total - got), Int64(Int32.max))))
                if n <= 0 { break }; got += Int(n)
            }
        }
        if got < total { out.removeLast(total - got) }
        return out
    }

    /// Returns a `DiscInfo` (selected-title reader + format hint + the full title list) for a DVD or
    /// Blu-ray ISO, else nil. `selectTitleID` chooses the title (default = main). DVD titles are the
    /// per-VTS VOB groups, filtered by the VMGI TT_SRPT title list (whole-VTS; per-cell splitting deferred).
    static func wrap(_ reader: IOReader, selectTitleID: Int? = nil, cacheKey: String? = nil) throws -> DiscInfo? {
        if let cacheKey, let cached = DiscRecognitionCache.lookup(key: cacheKey, selectTitleID: selectTitleID) {
            return DiscInfo(reader: ConcatIOReader(base: reader, extents: cached.extents),
                            formatHint: cached.formatHint, titles: cached.titles,
                            selectedTitleIndex: cached.selectedTitleIndex)
        }
        guard looksLikeISO9660(reader) else { return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey) }
        let iso: ISO9660Reader
        do {
            iso = try ISO9660Reader(reader: reader)
        } catch DiscError.notISO9660 {
            return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)
        }
        let files: [DiscFile]
        do {
            files = try iso.list(directory: "VIDEO_TS")
        } catch DiscError.directoryNotFound {
            return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)  // ISO9660 but not a DVD-Video disc (Blu-ray / data disc)
        }
        let groups = DVDTitleSelector.enumerateTitleVOBGroups(files)
        guard !groups.isEmpty else { return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey) }
        // VIDEO_TS.IFO's TT_SRPT names which title sets are real titles; filter the VOB groups to those so
        // incidental content VTS are excluded. Any parse failure (or a filter that would empty the list)
        // falls back to the full VOB-grouped set, so a disc with an unreadable VMGI still plays multi-title.
        var orderedGroups = groups
        if let ifoFile = files.first(where: { $0.name.uppercased() == "VIDEO_TS.IFO" }) {
            let ifoBytes = readAll(reader, [(offset: Int64(ifoFile.startSector * iso.sectorSize),
                                             length: Int64(ifoFile.length))])
            if let ifoTitles = DVDIFOParser.parseTitles(ifoBytes) {
                let titleVTSNs = Set(ifoTitles.map(\.vtsn))
                let filtered = groups.filter { titleVTSNs.contains($0.vtsn) }
                if !filtered.isEmpty { orderedGroups = filtered }
            }
        }
        let selectedIndex = selectTitleID.flatMap { orderedGroups.indices.contains($0) ? $0 : nil } ?? 0
        let extents = orderedGroups[selectedIndex].vobs.map {
            (offset: Int64($0.startSector * iso.sectorSize), length: Int64($0.length))
        }
        // Whole-VTS titles. Each VTS_NN_0.IFO's main PGC gives the title duration and chapter starts; a disc
        // with an unreadable VTS IFO keeps duration 0 / no chapters but still plays. dvdVTSN keeps the
        // title -> title-set mapping.
        let titles = orderedGroups.enumerated().map { idx, g -> DiscTitle in
            var durationTicks: UInt64 = 0
            var chapters: [DiscChapter] = []
            let nn = g.vtsn < 10 ? "0\(g.vtsn)" : "\(g.vtsn)"
            let ifoName = "VTS_\(nn)_0.IFO"
            if let vtsIFO = files.first(where: { $0.name.uppercased() == ifoName }) {
                let bytes = readAll(reader, [(offset: Int64(vtsIFO.startSector * iso.sectorSize),
                                             length: Int64(vtsIFO.length))])
                if let detail = DVDIFOParser.parseTitleDetail(bytes) {
                    durationTicks = detail.durationTicks
                    chapters = detail.chapterStartTicks.enumerated().map { i, start in
                        DiscChapter(id: i, startTicks: start)
                    }
                }
            }
            return DiscTitle(id: idx, durationTicks: durationTicks, chapters: chapters, dvdVTSN: g.vtsn)
        }
        storeRecognition(cacheKey: cacheKey, selectTitleID: selectTitleID,
                         formatHint: "mpeg", titles: titles, selectedIndex: selectedIndex, extents: extents)
        return DiscInfo(reader: ConcatIOReader(base: reader, extents: extents),
                        formatHint: "mpeg", titles: titles, selectedTitleIndex: selectedIndex)
    }
}
