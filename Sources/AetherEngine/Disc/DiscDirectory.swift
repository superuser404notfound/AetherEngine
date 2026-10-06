import Foundation

// [MovieClaw P5] 原盘目录（BDMV 文件夹）经 HTTP 直推（仓库 docs/design/disc-direct-play.md）。
//
// 引擎原本只认单个镜像文件（ISO 里的 UDF）：多剪辑原盘靠把各 m2ts 在镜像里的字节区间拼成一条虚拟 TS，
// 再按剪辑折叠时间戳（ClipSpan）。目录形态的原盘是同一件事换个字节来源：目录里每个文件各是一个独立的
// HTTP 读取器，拼接器按文件大小把它们首尾相接。选主片、拼接、时间轴折叠、章节、STN 语言全部复用 ISO
// 那套逻辑；服务端只按文件供字节，不起任何进程（NAS 以前要起 ffmpeg concat 换封装，还会丢掉杜比视界
// 增强层、把 TrueHD 退成 AC-3 核心、字幕整轨不进流）。

/// 原盘目录的字节源：宿主给出目录里的文件清单（相对原盘根目录的路径与字节数），引擎按相对路径开读取器。
/// 自身不承载字节（`read` 不会被调用）：`DiscReader.wrap` 认出它后改走目录分支。
public protocol DiscDirectoryReader: IOReader {
    /// 目录里可读的文件：相对原盘根目录的路径（如 `BDMV/STREAM/00001.m2ts`，大小写保留盘上原样）与字节数
    var discFiles: [(path: String, size: Int64)] { get }
    /// 按相对路径（大小写不敏感）开一个新的独立读取器；打不开返回 nil。调用方负责 `close()`
    func openDiscFile(_ path: String) -> IOReader?
    /// 宿主指定的主播放列表文件名（如 `00800.mpls`）：给了就只读这一个、直接当主片——服务端的诱饵判定与
    /// 台账时长同一口径，也省掉逐个读几十上百个播放列表的请求；nil = 读全部、按引擎自己的规则选
    var preferredPlaylist: String? { get }
}

/// 经 HTTP（支持 Range）读原盘目录：每个文件一个地址，读取时每个文件各开一个 `HTTPDiscIOReader`。
public final class HTTPDiscDirectoryReader: DiscDirectoryReader, @unchecked Sendable {
    public struct File: Sendable {
        public let path: String
        public let size: Int64
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

    public init(files: [File], preferredPlaylist: String?, httpHeaders: [String: String] = [:]) {
        self.files = files
        self.preferredPlaylist = preferredPlaylist
        self.httpHeaders = httpHeaders
    }

    public var discFiles: [(path: String, size: Int64)] { files.map { ($0.path, $0.size) } }

    public func openDiscFile(_ path: String) -> IOReader? {
        guard let file = files.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return nil }
        return HTTPDiscIOReader(url: file.url, extraHeaders: httpHeaders)
    }

    // 目录本身不是字节流：`DiscReader.wrap` 在读字节之前就认出它
    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
    public func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    public func close() {}
    public func cancel() {}

    /// 字幕侧读、拖动预览要独立游标：同一份清单再开一个（文件读取器各自按需打开）
    public func makeIndependentReader() -> IOReader? {
        HTTPDiscDirectoryReader(files: files, preferredPlaylist: preferredPlaylist, httpHeaders: httpHeaders)
    }

    public var discImageProbeEnabled: Bool { true }
}

/// 把若干个独立文件按顺序首尾相接成一条连续、可跳转的字节流（原盘目录里主片的各个 m2ts）。
/// 文件读取器按需打开、只留最近用过的几个：多剪辑主片动辄三四十段，不必一次开齐几十条连接。
final class MultiFileConcatIOReader: IOReader, @unchecked Sendable {
    struct Segment {
        let path: String
        let size: Int64
    }

    /// 同时保持打开的文件读取器上限：顺序播放只需要当前段，留两段余量给跨段读取与字幕侧读的回看
    private static let openLimit = 3

    private let segments: [Segment]
    /// 每段在拼接流里的起点（与 `segments` 平行）
    private let starts: [Int64]
    private let totalLength: Int64
    private let opener: @Sendable (String) -> IOReader?
    private let lock = NSLock()
    private var position: Int64 = 0
    /// 已打开的段：下标 → 读取器；`recent` 记使用先后，超上限关掉最久没用的
    private var open: [Int: IOReader] = [:]
    private var recent: [Int] = []

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

    /// 取第 `index` 段的读取器（持锁调用）；打不开返回 nil
    private func reader(for index: Int) -> IOReader? {
        if let existing = open[index] {
            recent.removeAll { $0 == index }
            recent.append(index)
            return existing
        }
        guard let fresh = opener(segments[index].path) else { return nil }
        open[index] = fresh
        recent.append(index)
        while recent.count > Self.openLimit {
            let evicted = recent.removeFirst()
            open.removeValue(forKey: evicted)?.close()
        }
        return fresh
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard position < totalLength else { return 0 }  // EOF
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
            if chunk < want { break }  // 文件比清单短：按已读到的返回，下次读从断点接着来
            index += 1
        }
        position += got
        return Int32(got)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalLength }  // AVSEEK_SIZE
        lock.lock(); defer { lock.unlock() }
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

    func close() {
        lock.lock()
        let readers = Array(open.values)
        open.removeAll()
        recent.removeAll()
        lock.unlock()
        readers.forEach { $0.close() }
    }

    /// 转给已打开的文件读取器：停播时解开卡在网络读上的 read
    func cancel() {
        lock.lock()
        let readers = Array(open.values)
        lock.unlock()
        readers.forEach { $0.cancel() }
    }

    func makeIndependentReader() -> IOReader? {
        MultiFileConcatIOReader(segments: segments, opener: opener)
    }

    /// 已经是拆好的 TS 流，不再做光盘识别
    var discImageProbeEnabled: Bool { false }
}

extension DiscReader {
    /// [MovieClaw P26] DVD 目录（VIDEO_TS 文件夹）：与读 DVD 镜像同一套（`dvdTitleSet` 选标题、`dvdCellTimeline`
    /// 折叠 cell 时间轴），只换字节来源——镜像是一段段扇区区间，目录是一个个文件。标题集的 VOB 按分段顺序首尾
    /// 相接，与镜像里连续的扇区是同一段字节，所以 cell 表与时间表里的偏移原样可用。
    /// 原来目录分支只认蓝光：服务端把 DVD 目录当「原文件」给，取的是个文件夹，一律 404、App 只好降级
    static func wrapDVDFolder(_ folder: DiscDirectoryReader, selectTitleID: Int?) -> DiscInfo? {
        // 目录里只有 VIDEO_TS 这一层；镜像的文件记录带扇区号，目录没有扇区，借同一个记录类型分组、按长度拼接
        let entries = folder.discFiles.filter { $0.path.uppercased().hasPrefix("VIDEO_TS/") }
        var pathByName: [String: (path: String, size: Int64)] = [:]
        let files = entries.map { entry -> DiscFile in
            let name = String(entry.path.split(separator: "/").last ?? "")
            pathByName[name.uppercased()] = entry
            return DiscFile(name: name, startSector: 0, length: Int(entry.size))
        }
        // IFO 是 KB 级的小文件；与读播放列表同一个 8 MB 上限，防畸形清单撑爆内存
        let maxInfoBytes: Int64 = 8 * 1024 * 1024
        let readFile: (DiscFile) -> [UInt8] = { file in
            guard let entry = pathByName[file.name.uppercased()], entry.size > 0, entry.size <= maxInfoBytes,
                  let reader = folder.openDiscFile(entry.path) else { return [] }
            defer { reader.close() }
            return readAll(reader, [(offset: 0, length: entry.size)])
        }
        guard let set = dvdTitleSet(files: files, selectTitleID: selectTitleID, readFile: readFile) else {
            EngineLog.emit("[disc] DVD folder: no VTS_NN_P.VOB title set among \(entries.count) VIDEO_TS entries", category: .demux)
            return nil
        }
        let segments = set.vobs.compactMap { vob -> MultiFileConcatIOReader.Segment? in
            pathByName[vob.name.uppercased()].map { .init(path: $0.path, size: $0.size) }
        }
        guard !segments.isEmpty else { return nil }
        let (cellTimeline, timeMap) = set.selectedIFO.map(dvdCellTimeline) ?? ([], nil)
        EngineLog.emit("[disc] [MovieClaw P26] DVD folder recognized: \(set.titles.count) title(s), selected \(set.selectedIndex) "
                       + "VOBs=\(segments.map(\.path)) bytes=\(segments.reduce(0) { $0 + $1.size })", category: .demux)
        return DiscInfo(reader: MultiFileConcatIOReader(segments: segments, opener: { folder.openDiscFile($0) }),
                        formatHint: "mpeg", titles: set.titles, selectedTitleIndex: set.selectedIndex,
                        clipTimeline: cellTimeline, dvdTimeMap: timeMap)
    }

    /// [MovieClaw P5] 原盘目录：读播放列表、选主片，把主片各剪辑文件首尾相接成一条虚拟 TS 流，
    /// 并按剪辑给出时间轴折叠（与 `wrapBluRay` 同一套 ClipSpan）。
    static func wrapBluRayFolder(_ folder: DiscDirectoryReader, selectTitleID: Int?) -> DiscInfo? {
        let files = folder.discFiles
        func entry(_ relative: String) -> (path: String, size: Int64)? {
            files.first { $0.path.caseInsensitiveCompare(relative) == .orderedSame }
        }
        var playlistPaths = files.map(\.path).filter {
            let upper = $0.uppercased()
            return upper.hasPrefix("BDMV/PLAYLIST/") && upper.hasSuffix(".MPLS")
        }
        if let preferred = folder.preferredPlaylist, let hit = entry("BDMV/PLAYLIST/\(preferred)") {
            playlistPaths = [hit.path]
        }
        // 播放列表是 KB 级的小文件；与 readAll 同一个 8 MB 上限，防畸形清单撑爆内存
        let maxPlaylistBytes: Int64 = 8 * 1024 * 1024
        var parsed: [MPLSPlaylist] = []
        for path in playlistPaths {
            guard let size = entry(path)?.size, size > 0, size <= maxPlaylistBytes,
                  let reader = folder.openDiscFile(path) else { continue }
            let bytes = readAll(reader, [(offset: 0, length: size)])
            reader.close()
            if let playlist = MPLSParser.parse(bytes) { parsed.append(playlist) }
        }
        let titles = BDTitleSelector.enumerateTitles(parsed)
        guard !titles.isEmpty else {
            EngineLog.emit("[disc] BDMV folder: no parseable .mpls (\(playlistPaths.count) candidates, preferred=\(folder.preferredPlaylist ?? "-"))", category: .demux)
            return nil
        }
        let selectedIndex = selectTitleID.flatMap { titles.indices.contains($0) ? $0 : nil } ?? 0
        let selected = titles[selectedIndex]
        let subTicks = selected.bdClipSubtractTicks ?? []
        let cumBeforeTicks = selected.bdClipCumulativeBeforeTicks ?? []
        var segments: [MultiFileConcatIOReader.Segment] = []
        var clipTimeline: [ClipSpan] = []
        var resolvedClips: [(index: Int, clip: String, byteStart: Int64)] = []  // [MovieClaw P7]
        var byteStart: Int64 = 0
        for (k, clip) in (selected.bdClipIDs ?? []).enumerated() {
            guard let file = entry("BDMV/STREAM/\(clip).m2ts"), file.size > 0 else {
                EngineLog.emit("[disc] BDMV folder: clip \(clip) listed by the playlist is missing from BDMV/STREAM", category: .demux)
                continue
            }
            resolvedClips.append((k, clip, byteStart))
            let predictedShift = k < subTicks.count ? Double(subTicks[k]) / discTickRate : 0
            let cumBeforeSec = k < cumBeforeTicks.count ? Double(cumBeforeTicks[k]) / discTickRate : 0
            clipTimeline.append(ClipSpan(concatByteStart: byteStart,
                                         cumulativeBeforeSec: cumBeforeSec,
                                         predictedShiftSec: predictedShift))
            segments.append(.init(path: file.path, size: file.size))
            byteStart += file.size
        }
        guard !segments.isEmpty else {
            EngineLog.emit("[disc] BDMV folder: selected title \(selectedIndex) resolved no m2ts in BDMV/STREAM", category: .demux)
            return nil
        }
        // 与 wrapBluRay 相同：单剪辑、或各剪辑本来就首尾连续（预测偏移全为 0）时不需要折叠
        if clipTimeline.count < 2 || !clipTimeline.contains(where: { $0.predictedShiftSec != 0 }) {
            clipTimeline = []
        }
        EngineLog.emit("[disc] Blu-ray folder recognized: \(titles.count) title(s), selected \(selectedIndex) clips=\(selected.bdClipIDs ?? []) files=\(segments.count) bytes=\(byteStart) clipSpans=\(clipTimeline.count) preferred=\(folder.preferredPlaylist ?? "-")", category: .demux)
        // [MovieClaw P7] 各剪辑的 CLPI → 按 EP map 定位
        let seekTable = buildSeekTable(title: selected, resolved: resolvedClips) { clip in
            guard let info = entry("BDMV/CLIPINF/\(clip).clpi"), info.size > 0, info.size <= maxPlaylistBytes,
                  let reader = folder.openDiscFile(info.path) else { return nil }
            defer { reader.close() }
            return readAll(reader, [(offset: 0, length: info.size)])
        }
        return DiscInfo(reader: MultiFileConcatIOReader(segments: segments, opener: { folder.openDiscFile($0) }),
                        formatHint: "mpegts", titles: titles, selectedTitleIndex: selectedIndex,
                        clipTimeline: clipTimeline, seekTable: seekTable)
    }
}
