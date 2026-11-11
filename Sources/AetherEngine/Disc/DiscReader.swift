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
    /// `udfAnchorChecked`: the caller has already found the UDF anchor, so it is not read again.
    static func wrapBluRay(_ reader: IOReader, selectTitleID: Int? = nil, cacheKey: String? = nil,
                           udfAnchorChecked: Bool = false) throws -> DiscInfo? {
        guard udfAnchorChecked || looksLikeUDF(reader) else { return nil }
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
        let parsed = scanPlaylists(playlistDir,
                                   extents: { (try? udf.extents(of: $0)) ?? [] },
                                   read: { readAll(reader, $0) })
        let titles = BDTitleSelector.enumerateTitles(parsed)
        guard !titles.isEmpty else {
            EngineLog.emit("[disc] BDMV present but no parseable .mpls (\(playlistDir.count) PLAYLIST entries, \(parsed.count) parsed); cannot select a title", category: .demux)
            return nil
        }
        let selectedIndex = selectTitleID.flatMap { titles.indices.contains($0) ? $0 : nil } ?? 0
        let selected = titles[selectedIndex]
        let streamDir = (try? udf.list(path: ["BDMV", "STREAM"])) ?? []
        let streamIndex = Dictionary(streamDir.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let assembled = assembleBluRayTitle(
            clipIDs: selected.bdClipIDs ?? [],
            subtractTicks: selected.bdClipSubtractTicks ?? [],
            cumulativeBeforeTicks: selected.bdClipCumulativeBeforeTicks ?? [],
            extentsOfClip: { clip in streamIndex["\(clip).m2ts"].flatMap { try? udf.extents(of: $0) } })
        let allExtents = assembled.extents
        var clipTimeline = assembled.clipTimeline
        guard !allExtents.isEmpty else {
            EngineLog.emit("[disc] selected title \(selectedIndex) clips=\(selected.bdClipIDs ?? []) but resolved no m2ts extents in BDMV/STREAM (\(streamDir.count) entries); cannot build stream", category: .demux)
            return nil
        }
        // A multi-clip title whose clips carry a real STC jump needs normalization; a single clip, or one
        // whose clips are already contiguous (predicted offset 0 everywhere), is a no-op. The magnitude of
        // the predicted offset may be wrong (wrap), but non-zero still flags "these clips jump" reliably.
        if clipTimeline.count < 2 || !clipTimeline.contains(where: { $0.predictedShiftSec != 0 }) {
            clipTimeline = []
        }
        let totalBytes = allExtents.reduce(Int64(0)) { $0 + max(0, $1.length) }
        EngineLog.emit("[disc] Blu-ray recognized: \(titles.count) title(s), selected \(selectedIndex) playlist=\(selected.bdPlaylist ?? "-") clips=\(selected.bdClipIDs ?? []) m2ts-extents=\(allExtents.count) bytes=\(totalBytes) clipSpans=\(clipTimeline.count) stnLanguages=\(selected.streamLanguages.count)", category: .demux)
        let clipInfoDir = (try? udf.list(path: ["BDMV", "CLIPINF"])) ?? []
        let seekTable = buildSeekTable(title: selected, resolved: assembled.resolved) { clip in
            guard let entry = clipInfoDir.first(where: { $0.name.caseInsensitiveCompare("\(clip).clpi") == .orderedSame }),
                  let extents = try? udf.extents(of: entry), !extents.isEmpty else { return nil }
            return readAll(reader, extents)
        }
        storeRecognition(cacheKey: cacheKey, selectTitleID: selectTitleID,
                         formatHint: "mpegts", titles: titles, selectedIndex: selectedIndex,
                         extents: allExtents, clipTimeline: clipTimeline, seekTable: seekTable)
        return DiscInfo(reader: ConcatIOReader(base: reader, extents: allExtents),
                        formatHint: "mpegts", titles: titles, selectedTitleIndex: selectedIndex,
                        clipTimeline: clipTimeline, seekTable: seekTable)
    }

    // MARK: - Bounds on what a disc image can make recognition do (audit NET-103)

    /// `.mpls` entries examined per PLAYLIST directory. Real discs carry dozens, anti-rip discs a few hundred.
    static let maxPlaylistFiles = 4_000
    /// Bytes of playlist data read in total. A real `.mpls` is KB-scale, so this is orders above any disc.
    static let maxPlaylistBytes: Int64 = 32 * 1024 * 1024
    /// PlayItems kept across every parsed playlist (about 32 bytes each), so a directory of maximal
    /// playlists cannot be retained whole.
    static let maxPlaylistItems = 500_000
    /// Extents in one assembled title. A real m2ts is a few dozen extents (1 GB each), a decoy loop
    /// repeats a short clip a few hundred times.
    static let maxTitleExtents = 65_536
    /// A run of this many unreadable playlists means the source is gone (cancelled or closed reader).
    private static let maxConsecutiveShortReads = 16
    /// `readAll`'s ceiling.
    static let maxSmallFileBytes: Int64 = 8 * 1024 * 1024

    /// Reads and parses the `.mpls` entries of a PLAYLIST directory under the bounds above. Stops at the
    /// first bound that trips and keeps what was parsed before it.
    static func scanPlaylists(
        _ entries: [UDFEntry],
        extents: (UDFEntry) -> [(offset: Int64, length: Int64)],
        read: ([(offset: Int64, length: Int64)]) -> [UInt8]
    ) -> [MPLSPlaylist] {
        scanPlaylists(entries, name: \.name, extents: extents, read: { _, exts in read(exts) })
    }

    /// The same scan over any directory listing: a UDF directory, or the files of a disc folder
    /// (`DiscDirectoryReader`), where each playlist is one whole file rather than a set of extents.
    static func scanPlaylists<Entry>(
        _ entries: [Entry],
        name: (Entry) -> String,
        extents: (Entry) -> [(offset: Int64, length: Int64)],
        read: (Entry, [(offset: Int64, length: Int64)]) -> [UInt8]
    ) -> [MPLSPlaylist] {
        var parsed: [MPLSPlaylist] = []
        var examined = 0
        var bytesRead: Int64 = 0
        var items = 0
        var shortReads = 0
        for e in entries where name(e).lowercased().hasSuffix(".mpls") {
            examined += 1
            guard examined <= maxPlaylistFiles else {
                EngineLog.emit("[disc] PLAYLIST scan stopped at \(maxPlaylistFiles) .mpls entries", category: .demux)
                break
            }
            let exts = extents(e)
            guard !exts.isEmpty else { continue }
            let declared = exts.reduce(Int64(0)) { $0 + max(0, $1.length) }
            guard declared > 0, declared <= maxSmallFileBytes else { continue }
            bytesRead += declared
            guard bytesRead <= maxPlaylistBytes else {
                EngineLog.emit("[disc] PLAYLIST scan stopped after \(maxPlaylistBytes) bytes of playlists", category: .demux)
                break
            }
            let bytes = read(e, exts)
            if Int64(bytes.count) < declared {
                shortReads += 1
                if shortReads >= maxConsecutiveShortReads {
                    EngineLog.emit("[disc] PLAYLIST scan stopped, \(shortReads) unreadable playlists in a row", category: .demux)
                    break
                }
            } else {
                shortReads = 0
            }
            guard var pl = MPLSParser.parse(bytes) else { continue }
            pl.fileName = name(e).split(separator: "/").last.map(String.init)
            items += pl.clipIDs.count
            guard items <= maxPlaylistItems else {
                EngineLog.emit("[disc] PLAYLIST scan stopped after \(maxPlaylistItems) PlayItems", category: .demux)
                break
            }
            parsed.append(pl)
        }
        return parsed
    }

    /// Resolves a title's clips into the concatenated extent list plus one `ClipSpan` per resolved clip
    /// (byte start in the concat stream, and how far to pull its timestamps back so it continues
    /// contiguously from clip 0, AE#105). Each distinct clip is looked up once, a repeated clip reuses its
    /// extents, and the title ends at the clip that would pass `maxTitleExtents`. `resolved` names each
    /// clip that made it in, by play item index, parallel to `clipTimeline`.
    static func assembleBluRayTitle(
        clipIDs: [String], subtractTicks: [Int64], cumulativeBeforeTicks: [UInt64],
        extentsOfClip: (String) -> [(offset: Int64, length: Int64)]?
    ) -> (extents: [(offset: Int64, length: Int64)], clipTimeline: [ClipSpan],
          resolved: [(item: Int, clip: String, byteStart: Int64)]) {
        let assembled = assembleBluRayTitle(clipIDs: clipIDs, subtractTicks: subtractTicks,
                                            cumulativeBeforeTicks: cumulativeBeforeTicks,
                                            piecesOfClip: extentsOfClip, length: \.length)
        return (assembled.pieces, assembled.clipTimeline, assembled.resolved)
    }

    /// The same assembly over any byte source of a clip: the extents of an image, or the one file a clip is
    /// in a disc folder. `length` is a piece's byte count in the concatenated stream.
    static func assembleBluRayTitle<Piece>(
        clipIDs: [String], subtractTicks: [Int64], cumulativeBeforeTicks: [UInt64],
        piecesOfClip: (String) -> [Piece]?, length: (Piece) -> Int64
    ) -> (pieces: [Piece], clipTimeline: [ClipSpan], resolved: [(item: Int, clip: String, byteStart: Int64)]) {
        var allExtents: [Piece] = []
        var clipTimeline: [ClipSpan] = []
        var resolvedClips: [(item: Int, clip: String, byteStart: Int64)] = []
        var resolved: [String: [Piece]?] = [:]
        var byteStart: Int64 = 0
        for (k, clip) in clipIDs.enumerated() {
            let lookup: [Piece]?
            if let known = resolved[clip] {
                lookup = known
            } else {
                lookup = piecesOfClip(clip)
                resolved[clip] = .some(lookup)
            }
            guard let exts = lookup else { continue }
            guard allExtents.count + exts.count <= maxTitleExtents else {
                EngineLog.emit("[disc] title truncated at clip[\(k)]: more than \(maxTitleExtents) extents", category: .demux)
                break
            }
            let predictedShift = k < subtractTicks.count ? Double(subtractTicks[k]) / discTickRate : 0
            let cumBeforeSec = k < cumulativeBeforeTicks.count ? Double(cumulativeBeforeTicks[k]) / discTickRate : 0
            resolvedClips.append((k, clip, byteStart))
            clipTimeline.append(ClipSpan(concatByteStart: byteStart,
                                         cumulativeBeforeSec: cumBeforeSec,
                                         predictedShiftSec: predictedShift))
            EngineLog.emit("[disc] AE#105 clip[\(k)] id=\(clip) subTicks=\(k < subtractTicks.count ? subtractTicks[k] : 0) predictedSec=\(String(format: "%.3f", predictedShift)) cumBeforeSec=\(String(format: "%.3f", cumBeforeSec)) byteStart=\(byteStart)", category: .demux, level: .verbose)
            allExtents += exts
            byteStart += exts.reduce(Int64(0)) { $0 + max(0, length($1)) }
        }
        return (allExtents, clipTimeline, resolvedClips)
    }

    /// Memoize a successful recognition so a re-open of the same source (track switch on a remote ISO)
    /// reuses it. No-op when the caller passed no cache key (custom sources opt in explicitly).
    private static func storeRecognition(
        cacheKey: String?, selectTitleID: Int?,
        formatHint: String, titles: [DiscTitle], selectedIndex: Int,
        extents: [(offset: Int64, length: Int64)], clipTimeline: [ClipSpan] = [],
        seekTable: DiscSeekTable? = nil, dvdTimeMap: DVDTimeMap? = nil
    ) {
        guard let cacheKey else { return }
        let recognition = DiscRecognition(formatHint: formatHint, titles: titles,
                                          selectedTitleIndex: selectedIndex, extents: extents,
                                          clipTimeline: clipTimeline, seekTable: seekTable, dvdTimeMap: dvdTimeMap)
        DiscRecognitionCache.store(key: cacheKey, selectTitleID: selectTitleID, recognition)
        // The probe opens with selectTitleID == nil (default title), but the rest of the engine
        // references that same title by its resolved id (== selectedIndex): reloads and the subtitle
        // side demuxer pass that concrete id, never nil. Alias the entry under the resolved index so
        // the first side-demuxer open is a cache hit instead of a second full disc parse, which is the
        // remaining startup "disc tray" re-open on a remote ISO (#76).
        if selectTitleID != selectedIndex {
            DiscRecognitionCache.store(key: cacheKey, selectTitleID: selectedIndex, recognition)
        }
    }

    /// Read all bytes of an extent list into memory (small files only: mpls).
    static func readAll(_ base: IOReader, _ exts: [(offset: Int64, length: Int64)]) -> [UInt8] {
        // Extent lengths are untrusted on-disc bytes (up to ~1 GB each). Cap the total before
        // allocating so a crafted .mpls cannot drive an arbitrary allocation (jetsam/DoS); 8 MB
        // matches UDFReader.readDirectory's guard and dwarfs any real playlist (KB-scale).
        let maxBytes = maxSmallFileBytes
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
        // A disc folder is a set of files, not one byte range, so it is recognized before the cache,
        // which rebuilds a reader from extents of a single image.
        if let folder = reader as? DiscDirectoryReader {
            // Blu-ray first and DVD-Video as the fallback, as on an image, so a hybrid listing with both
            // trees plays its Blu-ray title.
            func has(_ root: String) -> Bool { folder.discFiles.contains { $0.path.uppercased().hasPrefix(root) } }
            guard has("VIDEO_TS/") else { return wrapBluRayFolder(folder, selectTitleID: selectTitleID) }
            if has("BDMV/"), let bluRay = wrapBluRayFolder(folder, selectTitleID: selectTitleID) { return bluRay }
            return wrapDVDFolder(folder, selectTitleID: selectTitleID)
        }
        if let cacheKey, let cached = DiscRecognitionCache.lookup(key: cacheKey, selectTitleID: selectTitleID) {
            return DiscInfo(reader: ConcatIOReader(base: reader, extents: cached.extents),
                            formatHint: cached.formatHint, titles: cached.titles,
                            selectedTitleIndex: cached.selectedTitleIndex,
                            clipTimeline: cached.clipTimeline, seekTable: cached.seekTable,
                            dvdTimeMap: cached.dvdTimeMap)
        }
        guard looksLikeISO9660(reader) else {
            // The anchor is read once: a probe's input budget counts every read recognition makes.
            guard looksLikeUDF(reader) else { return nil }
            if let bluRay = try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey,
                                           udfAnchorChecked: true) {
                return bluRay
            }
            return wrapUDFDVD(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)
        }
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
        if let dvd = wrapDVD(reader, files: files, sectorSize: iso.sectorSize, selectTitleID: selectTitleID,
                             cacheKey: cacheKey) {
            return dvd
        }
        return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)
    }

    /// A DVD-Video image with no ISO9660 bridge volume: sector 16 starts UDF's BEA01 directly, so the image
    /// used to go down the Blu-ray branch, find no BDMV, and play as a raw file, which is the first VOB's
    /// menu (8 s of a 6364 s film). `VIDEO_TS` is listed through UDF instead, and the title is built the
    /// same way as from ISO9660. DVD files are one contiguous run on disc; a file recorded as runs that do
    /// not continue each other is left out. The caller has found the UDF anchor.
    static func wrapUDFDVD(_ reader: IOReader, selectTitleID: Int?, cacheKey: String?) -> DiscInfo? {
        guard let udf = try? UDFReader(reader: reader),
              let root = try? udf.list(path: []),
              let dir = root.first(where: { $0.isDir && $0.name.uppercased() == "VIDEO_TS" }),
              let entries = try? udf.list(path: [dir.name]) else { return nil }
        let sectorSize = 2048
        let files: [DiscFile] = entries.compactMap { entry in
            guard !entry.isDir, let extents = try? udf.extents(of: entry), let first = extents.first,
                  first.offset % Int64(sectorSize) == 0 else { return nil }
            var end = first.offset
            for extent in extents {
                guard extent.offset == end else { return nil }
                end += extent.length
            }
            return DiscFile(name: entry.name, startSector: Int(first.offset / Int64(sectorSize)),
                            length: Int(end - first.offset))
        }
        EngineLog.emit("[disc] UDF-only image with VIDEO_TS (\(files.count) files); attempting DVD-Video", category: .demux)
        return wrapDVD(reader, files: files, sectorSize: sectorSize, selectTitleID: selectTitleID, cacheKey: cacheKey)
    }

    /// A DVD-Video title set from a `VIDEO_TS` listing, whichever filesystem it came from; nil when the
    /// listing holds no title VOBs.
    private static func wrapDVD(_ reader: IOReader, files: [DiscFile], sectorSize: Int, selectTitleID: Int?,
                                cacheKey: String?) -> DiscInfo? {
        let readFile: (DiscFile) -> [UInt8] = { file in
            readAll(reader, [(offset: Int64(file.startSector * sectorSize), length: Int64(file.length))])
        }
        guard let set = dvdTitleSet(files: files, selectTitleID: selectTitleID, readFile: readFile) else { return nil }
        let extents = set.vobs.map {
            (offset: Int64($0.startSector * sectorSize), length: Int64($0.length))
        }
        let (cellTimeline, timeMap) = set.selectedIFO.map(dvdCellTimeline) ?? ([], nil)
        storeRecognition(cacheKey: cacheKey, selectTitleID: selectTitleID,
                         formatHint: "mpeg", titles: set.titles, selectedIndex: set.selectedIndex, extents: extents,
                         clipTimeline: cellTimeline, dvdTimeMap: timeMap)
        return DiscInfo(reader: ConcatIOReader(base: reader, extents: extents),
                        formatHint: "mpeg", titles: set.titles, selectedTitleIndex: set.selectedIndex,
                        clipTimeline: cellTimeline, dvdTimeMap: timeMap)
    }

    /// The titles of a `VIDEO_TS` listing and the selected one's VOBs (in part order) and VTS IFO, whatever
    /// holds the bytes: `readFile` reads one whole file. nil when the listing holds no title VOBs.
    static func dvdTitleSet(files: [DiscFile], selectTitleID: Int?, readFile: (DiscFile) -> [UInt8])
        -> (titles: [DiscTitle], selectedIndex: Int, vobs: [DiscFile], selectedIFO: [UInt8]?)? {
        let groups = DVDTitleSelector.enumerateTitleVOBGroups(files)
        guard !groups.isEmpty else { return nil }
        // VIDEO_TS.IFO's TT_SRPT names which title sets are real titles; filter the VOB groups to those so
        // incidental content VTS are excluded. Any parse failure (or a filter that would empty the list)
        // falls back to the full VOB-grouped set, so a disc with an unreadable VMGI still plays multi-title.
        var orderedGroups = groups
        let filesByName = Dictionary(files.map { ($0.name.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        if let ifoFile = filesByName["VIDEO_TS.IFO"], let ifoTitles = DVDIFOParser.parseTitles(readFile(ifoFile)) {
            let titleVTSNs = Set(ifoTitles.map(\.vtsn))
            let filtered = groups.filter { titleVTSNs.contains($0.vtsn) }
            if !filtered.isEmpty { orderedGroups = filtered }
        }
        let selectedIndex = selectTitleID.flatMap { orderedGroups.indices.contains($0) ? $0 : nil } ?? 0
        // Whole-VTS titles. Each VTS_NN_0.IFO's main PGC gives the title duration and chapter starts; a disc
        // with an unreadable VTS IFO keeps duration 0 / no chapters but still plays. dvdVTSN keeps the
        // title -> title-set mapping.
        var selectedIFO: [UInt8]?  // the cell table and time map come from the selected title's VTS IFO
        let titles = orderedGroups.enumerated().map { idx, g -> DiscTitle in
            var durationTicks: UInt64 = 0
            var chapters: [DiscChapter] = []
            // The VOBs carry no track language, so the IFO's attribute tables are the only source (#527).
            var streamLanguages: [Int: String] = [:]
            var subpictureStreamIDs: [Int]?
            let nn = g.vtsn < 10 ? "0\(g.vtsn)" : "\(g.vtsn)"
            let ifoName = "VTS_\(nn)_0.IFO"
            if let vtsIFO = filesByName[ifoName] {
                let bytes = readFile(vtsIFO)
                if idx == selectedIndex { selectedIFO = bytes }
                if let detail = DVDIFOParser.parseTitleDetail(bytes) {
                    durationTicks = detail.durationTicks
                    chapters = detail.chapterStartTicks.enumerated().map { i, start in
                        DiscChapter(id: i, startTicks: start)
                    }
                }
                streamLanguages = DVDIFOParser.parseStreamLanguages(bytes)
                subpictureStreamIDs = DVDIFOParser.parseSubpictureStreamIDs(bytes)
            }
            return DiscTitle(id: idx, durationTicks: durationTicks, chapters: chapters, dvdVTSN: g.vtsn,
                             streamLanguages: streamLanguages,
                             dvdSubpictureStreamIDs: subpictureStreamIDs)
        }
        return (titles, selectedIndex, orderedGroups[selectedIndex].vobs, selectedIFO)
    }

    /// The selected DVD title's cells as AE#105 clip spans, and its time map.
    ///
    /// A title's VOBs are read as one MPEG-PS, but many discs restart the presentation timestamps at each
    /// cell: one title's 14 cells put cell 7, at 3569 s of title time, at 147.9 s. Past such a cell the
    /// playhead and every timestamp search over the title go wrong. Each cell is handed to the Blu-ray
    /// clip fold as a clip (its first byte in the concatenation, its start on the title timeline); its
    /// actual timestamp base is measured from the navigation packs as they are read (`Demuxer.adoptDVDNav`).
    /// The time map turns title time into a VOBU's byte, so a seek is one byte reposition.
    /// Only the common shape is folded: the main PGC starts at the first title sector, its cells follow each
    /// other sector by sector, and none is in an angle block. Anything else gets neither, and reads as before.
    static func dvdCellTimeline(_ ifo: [UInt8]) -> ([ClipSpan], DVDTimeMap?) {
        guard let cells = DVDIFOParser.parseMainPGCCells(ifo), cells.count >= 2, cells[0].firstSector == 0,
              !cells.contains(where: \.inAngleBlock),
              zip(cells, cells.dropFirst()).allSatisfy({ $1.firstSector == $0.lastSector + 1 }) else { return ([], nil) }
        let sector: Int64 = 2048
        var spans: [ClipSpan] = []
        var cumulative = 0.0
        for cell in cells {
            // Predicted as if every cell restarts from cell 0's base; the navigation pack replaces it.
            spans.append(ClipSpan(concatByteStart: Int64(cell.firstSector) * sector,
                                  cumulativeBeforeSec: cumulative, predictedShiftSec: -cumulative))
            cumulative += cell.durationSec
        }
        let timeMap = DVDIFOParser.parseMainTimeMap(ifo).map {
            DVDTimeMap(unitSec: $0.unitSec, titleStartByte: 0, byteOffsets: $0.sectors.map { Int64($0) * sector })
        }
        EngineLog.emit("[disc] DVD title: \(cells.count) cells, time map \(timeMap.map { "\($0.byteOffsets.count) x \(Int($0.unitSec))s" } ?? "none")", category: .demux)
        return (spans, timeMap)
    }
}
