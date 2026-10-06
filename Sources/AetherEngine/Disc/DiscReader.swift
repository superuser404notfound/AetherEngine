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
        let resolvedClips = assembled.resolvedClips   // [MovieClaw P7]
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
        EngineLog.emit("[disc] Blu-ray recognized: \(titles.count) title(s), selected \(selectedIndex) clips=\(selected.bdClipIDs ?? []) m2ts-extents=\(allExtents.count) bytes=\(totalBytes) clipSpans=\(clipTimeline.count) stnLanguages=\(selected.streamLanguages.count)", category: .demux)
        // [MovieClaw P7] 各剪辑的 CLPI → 按 EP map 定位（跨剪辑跳转、续播起播不再二分）
        let clipinfDir = (try? udf.list(path: ["BDMV", "CLIPINF"])) ?? []
        let seekTable = buildSeekTable(title: selected, resolved: resolvedClips) { clip in
            guard let e = clipinfDir.first(where: { $0.name.caseInsensitiveCompare("\(clip).clpi") == .orderedSame }),
                  let exts = try? udf.extents(of: e), !exts.isEmpty else { return nil }
            return readAll(reader, exts)
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
    private static let maxSmallFileBytes: Int64 = 8 * 1024 * 1024

    /// Reads and parses the `.mpls` entries of a PLAYLIST directory under the bounds above. Stops at the
    /// first bound that trips and keeps what was parsed before it.
    static func scanPlaylists(
        _ entries: [UDFEntry],
        extents: (UDFEntry) -> [(offset: Int64, length: Int64)],
        read: ([(offset: Int64, length: Int64)]) -> [UInt8]
    ) -> [MPLSPlaylist] {
        var parsed: [MPLSPlaylist] = []
        var examined = 0
        var bytesRead: Int64 = 0
        var items = 0
        var shortReads = 0
        for e in entries where e.name.hasSuffix(".mpls") {
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
            let bytes = read(exts)
            if Int64(bytes.count) < declared {
                shortReads += 1
                if shortReads >= maxConsecutiveShortReads {
                    EngineLog.emit("[disc] PLAYLIST scan stopped, \(shortReads) unreadable playlists in a row", category: .demux)
                    break
                }
            } else {
                shortReads = 0
            }
            guard let pl = MPLSParser.parse(bytes) else { continue }
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
    /// extents, and the title ends at the clip that would pass `maxTitleExtents`.
    static func assembleBluRayTitle(
        clipIDs: [String], subtractTicks: [Int64], cumulativeBeforeTicks: [UInt64],
        extentsOfClip: (String) -> [(offset: Int64, length: Int64)]?
    ) -> (extents: [(offset: Int64, length: Int64)], clipTimeline: [ClipSpan], resolvedClips: [(index: Int, clip: String, byteStart: Int64)]) {
        var allExtents: [(offset: Int64, length: Int64)] = []
        var clipTimeline: [ClipSpan] = []
        var resolvedClips: [(index: Int, clip: String, byteStart: Int64)] = []
        var resolved: [String: [(offset: Int64, length: Int64)]?] = [:]
        var byteStart: Int64 = 0
        for (k, clip) in clipIDs.enumerated() {
            let lookup: [(offset: Int64, length: Int64)]?
            if let known = resolved[clip] {
                lookup = known
            } else {
                lookup = extentsOfClip(clip)
                resolved[clip] = .some(lookup)
            }
            guard let exts = lookup else { continue }
            guard allExtents.count + exts.count <= maxTitleExtents else {
                EngineLog.emit("[disc] title truncated at clip[\(k)]: more than \(maxTitleExtents) extents", category: .demux)
                break
            }
            resolvedClips.append((k, clip, byteStart))
            let predictedShift = k < subtractTicks.count ? Double(subtractTicks[k]) / discTickRate : 0
            let cumBeforeSec = k < cumulativeBeforeTicks.count ? Double(cumulativeBeforeTicks[k]) / discTickRate : 0
            clipTimeline.append(ClipSpan(concatByteStart: byteStart,
                                         cumulativeBeforeSec: cumBeforeSec,
                                         predictedShiftSec: predictedShift))
            EngineLog.emit("[disc] AE#105 clip[\(k)] id=\(clip) subTicks=\(k < subtractTicks.count ? subtractTicks[k] : 0) predictedSec=\(String(format: "%.3f", predictedShift)) cumBeforeSec=\(String(format: "%.3f", cumBeforeSec)) byteStart=\(byteStart)", category: .demux, level: .verbose)
            allExtents += exts
            byteStart += exts.reduce(Int64(0)) { $0 + max(0, $1.length) }
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
        // [MovieClaw P5] 原盘目录走目录分支，放在识别缓存之前：缓存按「单个镜像 + 字节区间」重建读取器，
        // 套不到「多个独立文件」上
        if let folder = reader as? DiscDirectoryReader {
            // [MovieClaw P26] DVD 目录（VIDEO_TS）与蓝光目录（BDMV）各走各的
            if folder.discFiles.contains(where: { $0.path.uppercased().hasPrefix("VIDEO_TS/") }) {
                return wrapDVDFolder(folder, selectTitleID: selectTitleID)
            }
            return wrapBluRayFolder(folder, selectTitleID: selectTitleID)
        }
        if let cacheKey, let cached = DiscRecognitionCache.lookup(key: cacheKey, selectTitleID: selectTitleID) {
            return DiscInfo(reader: ConcatIOReader(base: reader, extents: cached.extents),
                            formatHint: cached.formatHint, titles: cached.titles,
                            selectedTitleIndex: cached.selectedTitleIndex,
                            clipTimeline: cached.clipTimeline, seekTable: cached.seekTable,
                            dvdTimeMap: cached.dvdTimeMap)
        }
        guard looksLikeISO9660(reader) else {
            // [MovieClaw P61] 只有 UDF、没有 ISO9660 桥接卷的 DVD 镜像：按 UDF 读 VIDEO_TS
            if let dvd = wrapUDFDVD(reader, selectTitleID: selectTitleID, cacheKey: cacheKey) { return dvd }
            return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)
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
        if let dvd = wrapDVD(reader, files: files, sectorSize: iso.sectorSize, selectTitleID: selectTitleID, cacheKey: cacheKey) {
            return dvd
        }
        return try wrapBluRay(reader, selectTitleID: selectTitleID, cacheKey: cacheKey)
    }

    /// [MovieClaw P61] UDF-only DVD-Video 镜像（没有 ISO9660 桥接卷，第 16 扇区直接是 UDF 的 BEA01）：原来只认
    /// ISO9660 的 DVD，这种盘落到蓝光分支、找不到 BDMV，退回把整个镜像当裸文件解复用，放出来是菜单那几秒。
    /// VIDEO_TS 改经 UDF 列出（DVD 的 VOB / IFO 在盘上都是连续的一段；分成多段的文件跳过），其余与 ISO9660 同一套
    static func wrapUDFDVD(_ reader: IOReader, selectTitleID: Int?, cacheKey: String?) -> DiscInfo? {
        guard looksLikeUDF(reader), let udf = try? UDFReader(reader: reader),
              let root = try? udf.list(path: []),
              let dir = root.first(where: { $0.isDir && $0.name.uppercased() == "VIDEO_TS" }),
              let entries = try? udf.list(path: [dir.name]) else { return nil }
        let sector = 2048
        let files: [DiscFile] = entries.compactMap { entry in
            guard !entry.isDir, let exts = try? udf.extents(of: entry), let first = exts.first,
                  first.offset % Int64(sector) == 0 else { return nil }
            // 各段首尾相接才当成一段（录制工具偶尔把一个文件记成几段相邻的区间）
            var end = first.offset
            for ext in exts {
                guard ext.offset == end else { return nil }
                end += ext.length
            }
            return DiscFile(name: entry.name, startSector: Int(first.offset / Int64(sector)), length: Int(end - first.offset))
        }
        guard !files.isEmpty else { return nil }
        EngineLog.emit("[disc] UDF-only DVD-Video image (\(files.count) VIDEO_TS entries)", category: .demux)
        return wrapDVD(reader, files: files, sectorSize: sector, selectTitleID: selectTitleID, cacheKey: cacheKey)
    }

    /// DVD 镜像（ISO9660 或 UDF 列出的 VIDEO_TS）：选标题、拼 VOB、cell 折叠表与时间表，存识别缓存
    private static func wrapDVD(_ reader: IOReader, files: [DiscFile], sectorSize: Int, selectTitleID: Int?,
                                cacheKey: String?) -> DiscInfo? {
        let readFile: (DiscFile) -> [UInt8] = { file in
            readAll(reader, [(offset: Int64(file.startSector * sectorSize), length: Int64(file.length))])
        }
        guard let set = dvdTitleSet(files: files, selectTitleID: selectTitleID, readFile: readFile) else {
            return nil
        }
        let (titles, selectedIndex) = (set.titles, set.selectedIndex)
        let extents = set.vobs.map {
            (offset: Int64($0.startSector * sectorSize), length: Int64($0.length))
        }
        let (cellTimeline, timeMap) = set.selectedIFO.map(dvdCellTimeline) ?? ([], nil)
        storeRecognition(cacheKey: cacheKey, selectTitleID: selectTitleID,
                         formatHint: "mpeg", titles: titles, selectedIndex: selectedIndex, extents: extents,
                         clipTimeline: cellTimeline, dvdTimeMap: timeMap)
        return DiscInfo(reader: ConcatIOReader(base: reader, extents: extents),
                        formatHint: "mpeg", titles: titles, selectedTitleIndex: selectedIndex,
                        clipTimeline: cellTimeline, dvdTimeMap: timeMap)
    }

    /// DVD 的标题集（镜像与目录共用，[MovieClaw P26] 从镜像分支抽出）。标题就是整个标题集（VTS）的 VOB 组：
    /// VIDEO_TS.IFO 的 TT_SRPT 说哪些标题集是真标题，据此滤掉花絮之类的附属标题集（解析失败、或滤完为空就用
    /// 全部 VOB 组，读不了 VMGI 的盘照样能放多标题）。各 VTS_NN_0.IFO 的主 PGC 给片长与章节起点，属性表给
    /// 音轨 / 字幕语言（VOB 里没有语言，只能靠它，#527）；读不了的 VTS IFO 片长记 0、没有章节，照样能放。
    /// `readFile` 读整个文件的字节；返回选中标题的 VOB（按分段顺序）与它的 VTS IFO（cell 折叠与时间表用）
    static func dvdTitleSet(files: [DiscFile], selectTitleID: Int?, readFile: (DiscFile) -> [UInt8])
        -> (titles: [DiscTitle], selectedIndex: Int, vobs: [DiscFile], selectedIFO: [UInt8]?)? {
        let groups = DVDTitleSelector.enumerateTitleVOBGroups(files)
        guard !groups.isEmpty else { return nil }
        var orderedGroups = groups
        let filesByName = Dictionary(files.map { ($0.name.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        if let ifoFile = filesByName["VIDEO_TS.IFO"],
           let ifoTitles = DVDIFOParser.parseTitles(readFile(ifoFile)) {
            let titleVTSNs = Set(ifoTitles.map(\.vtsn))
            let filtered = groups.filter { titleVTSNs.contains($0.vtsn) }
            if !filtered.isEmpty { orderedGroups = filtered }
        }
        let selectedIndex = selectTitleID.flatMap { orderedGroups.indices.contains($0) ? $0 : nil } ?? 0
        var selectedIFO: [UInt8]?  // [MovieClaw P13] 选中标题的 VTS IFO：cell 表与时间表
        let titles = orderedGroups.enumerated().map { idx, g -> DiscTitle in
            var durationTicks: UInt64 = 0
            var chapters: [DiscChapter] = []
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

    /// [MovieClaw P13] DVD 主 PGC 的 cell 折叠表与时间表（仓库 docs/design/disc-direct-play.md）。
    ///
    /// 整个 VTS 的 VOB 首尾相接当一条 MPEG-PS 读，可很多盘每个 cell 的 PTS 都从头开始：实测《公司的力量》
    /// 三个 cell 各自从 0.37 秒起，第二个 cell 在标题时间 2670 秒处 PTS 归零，播放头与按时间二分的定位
    /// 从那里起全乱（跳到 1200 秒后读到结尾）。这里把每个 cell 当成蓝光的一个剪辑交给现成的折叠
    /// （`ClipSpan`：cell 在拼接流里的字节起点 + 标题时间轴上的起点），cell 的实际时间戳基准由解复用器
    /// 读到的导航包（PCI 的 VOBU 起始 PTS 减去 cell 内已播时间）当场算出；时间表（VTS_TMAPT）给出
    /// 「标题时间 → VOBU 扇区」，定位一次按字节到位。
    /// 只处理最常见的形态：主 PGC 从标题 VOB 开头起、cell 按扇区首尾相接、没有多角度块（流的起始时间才是
    /// cell 0 的基准）；别的形态两样都不给，维持原来的读法
    static func dvdCellTimeline(_ ifo: [UInt8]) -> ([ClipSpan], DVDTimeMap?) {
        guard let cells = DVDIFOParser.parseMainPGCCells(ifo), cells.count >= 2, cells[0].firstSector == 0,
              !cells.contains(where: \.inAngleBlock),
              zip(cells, cells.dropFirst()).allSatisfy({ $1.firstSector == $0.lastSector + 1 }) else { return ([], nil) }
        let sector: Int64 = 2048
        var spans: [ClipSpan] = []
        var cumulative = 0.0
        for cell in cells {
            // 预测偏移按「PTS 每个 cell 从同一基准重来」估；导航包一到就换成实测值
            spans.append(ClipSpan(concatByteStart: Int64(cell.firstSector) * sector,
                                  cumulativeBeforeSec: cumulative, predictedShiftSec: -cumulative))
            cumulative += cell.durationSec
        }
        let timeMap = DVDIFOParser.parseMainTimeMap(ifo).map {
            DVDTimeMap(unitSec: $0.unitSec, titleStartByte: Int64(cells[0].firstSector) * sector,
                       byteOffsets: $0.sectors.map { Int64($0) * sector })
        }
        EngineLog.emit("[disc] [MovieClaw P13] DVD title: \(cells.count) cells, time map \(timeMap.map { "\($0.byteOffsets.count) × \(Int($0.unitSec))s" } ?? "none")", category: .demux)
        return (spans, timeMap)
    }
}
