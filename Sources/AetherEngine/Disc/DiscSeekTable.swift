import Foundation

// [MovieClaw P7] 原盘按 CLPI 的 EP map 定位（仓库 docs/design/disc-direct-play.md）。
//
// 引擎原本对原盘源按时间二分查找（avformat_seek_file）。多剪辑主片的各剪辑时间戳常常各自从头开始、
// 互相重叠（《完美陌生人》两段都从约 600 秒起），二分会落到别的剪辑里，跳转一直落不了地；经 HTTP 读
// NAS 机械盘时，二分的每一步都是一次请求加一次随机寻道，续播起播要十几秒（《不一样的天空》14.8 秒）。
// 蓝光每个剪辑自带 CLPI，里面的 EP map 就是「关键帧 PTS → 源包号」的对照表：按折叠后的时间找到剪辑、
// 换成剪辑内的原始 PTS、查表得到字节偏移，一次按字节定位就到。

/// CLPI 的 EP map 入口：关键帧的原始 PTS（45 kHz）与源包号（每个源包 192 字节）
struct CLPIEntryPoint: Sendable, Equatable {
    let pts45k: UInt64
    let spn: UInt32
}

enum CLPIParser {
    /// 主视频 PID；杜比视界双层原盘的增强层在另一个 PID，定位只看主视频
    static let primaryVideoPID = 0x1011

    /// 解析 CPI/EP_map，返回主视频流的入口（按 PTS 升序）。位域与 libbluray 的 `clpi_access_point`
    /// 一致（也与服务端 bluray.parse_clpi_keyframes 同一套）：
    /// 粗表 8 字节 = ref_to_EP_fine_id 18 位 · PTS_EP_coarse 14 位 · SPN_EP_coarse 32 位；
    /// 细表 4 字节 = 角度标志 1 位 · I 帧尾偏移 3 位 · PTS_EP_fine 11 位 · SPN_EP_fine 17 位。
    /// 完整 PTS（45 kHz）= ((粗 & ~1) << 18) + (细 << 8)；完整 SPN = (粗 & ~0x1FFFF) + 细。
    /// 畸形数据返回空表（调用方退回时间二分）。
    static func entryPoints(_ data: [UInt8]) -> [CLPIEntryPoint] {
        func be16(_ at: Int) -> Int { (Int(data[at]) << 8) | Int(data[at + 1]) }
        func be32(_ at: Int) -> UInt32 {
            (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16) | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
        }
        guard data.count >= 20, Array(data[0..<4]) == Array("HDMV".utf8) else { return [] }
        let cpiOffset = Int(be32(16))
        guard cpiOffset > 0, cpiOffset + 4 <= data.count else { return [] }
        let cpiLength = Int(be32(cpiOffset))
        let cpiEnd = cpiOffset + 4 + cpiLength
        guard cpiLength > 0, cpiEnd <= data.count else { return [] }
        // 2 字节：12 位保留 + 4 位 cpi_type；EP_map 内的相对地址以其后为基准
        let epMapPos = cpiOffset + 4 + 2
        guard epMapPos + 2 <= cpiEnd else { return [] }
        let streamCount = Int(data[epMapPos + 1])
        var pos = epMapPos + 2
        var chosen: (pid: Int, coarse: Int, fine: Int, start: Int)?
        for _ in 0..<streamCount {
            guard pos + 12 <= cpiEnd else { return [] }
            // 12 字节：PID 16 · 保留 10 · 流类型 4 · 粗表数 16 · 细表数 18 · 流表起址 32
            let pid = be16(pos)
            let packed = (UInt64(be32(pos + 2)) << 32) | UInt64(be32(pos + 6))  // 64 位里是：保留 10 · 类型 4 · 粗 16 · 细 18 · 起址高 16
            let coarseCount = Int((packed >> 34) & 0xFFFF)
            let fineCount = Int((packed >> 16) & 0x3FFFF)
            let start = Int((UInt32(truncatingIfNeeded: packed & 0xFFFF) << 16) | UInt32(be16(pos + 10)))
            if chosen == nil || pid == primaryVideoPID || (chosen!.pid != primaryVideoPID && pid < chosen!.pid) {
                chosen = (pid, coarseCount, fineCount, start)
            }
            pos += 12
        }
        guard let table = chosen, table.coarse > 0, table.fine > 0 else { return [] }
        let streamPos = epMapPos + table.start
        guard streamPos + 4 <= cpiEnd else { return [] }
        let fineStart = Int(be32(streamPos))
        let coarsePos = streamPos + 4
        let finePos = streamPos + fineStart
        guard coarsePos + table.coarse * 8 <= cpiEnd, finePos + table.fine * 4 <= cpiEnd else { return [] }
        var fineEntries: [(pts: UInt64, spn: UInt32)] = []
        fineEntries.reserveCapacity(table.fine)
        for i in 0..<table.fine {
            let raw = be32(finePos + i * 4)
            fineEntries.append((UInt64((raw >> 17) & 0x7FF), raw & 0x1FFFF))
        }
        var out: [CLPIEntryPoint] = []
        out.reserveCapacity(table.fine)
        for i in 0..<table.coarse {
            let hi = be32(coarsePos + i * 8)
            let spnCoarse = be32(coarsePos + i * 8 + 4)
            let fineFrom = Int(hi >> 14)
            let ptsCoarse = UInt64(hi & 0x3FFF)
            let fineTo = i + 1 < table.coarse ? Int(be32(coarsePos + (i + 1) * 8) >> 14) : table.fine
            guard fineFrom <= fineTo else { continue }
            for j in fineFrom..<min(fineTo, table.fine) {
                let pts = ((ptsCoarse & ~1) << 18) + (fineEntries[j].pts << 8)
                let spn = (spnCoarse & ~0x1FFFF) + fineEntries[j].spn
                out.append(CLPIEntryPoint(pts45k: pts, spn: spn))
            }
        }
        return out.sorted { $0.pts45k < $1.pts45k }
    }
}

/// 选中标题的原盘定位表：每个剪辑在拼接流里的起点、在标题时间轴上的起点、MPLS in_time 与 EP map
struct DiscSeekTable: Sendable {
    struct Clip: Sendable {
        /// 这个剪辑在拼接流里的字节起点
        let concatByteStart: Int64
        /// 标题时间轴上这个剪辑之前的总时长（秒，MPLS 的 PlayItem 累计，不受 32 位回绕影响）
        let cumulativeBeforeSec: Double
        /// MPLS 的 in_time（秒）：剪辑内原始 PTS 从这里开始算入标题
        let inTimeSec: Double
        let entries: [CLPIEntryPoint]
    }

    let clips: [Clip]

    /// 源时间（剪辑 0 的时间戳基准 + 折叠后的标题时间，秒；生产端对光盘源就是按它定位的）
    /// → 拼接流里不晚于它的关键帧的字节偏移。某个剪辑没有 EP map 时返回 nil，调用方退回时间二分
    func keyframe(forSourceSeconds seconds: Double, base0Sec: Double) -> (offset: Int64, clip: Int, keyframeSec: Double)? {
        guard let first = clips.first else { return nil }
        let base = base0Sec.isFinite ? base0Sec : first.inTimeSec
        let titleTime = max(0, seconds - base)
        guard let k = clips.lastIndex(where: { $0.cumulativeBeforeSec <= titleTime + 0.001 }) else { return nil }
        let clip = clips[k]
        guard !clip.entries.isEmpty else { return nil }
        let raw45k = UInt64(max(0, (clip.inTimeSec + (titleTime - clip.cumulativeBeforeSec)) * 45000))
        var lo = 0
        var hi = clip.entries.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if clip.entries[mid].pts45k <= raw45k {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let entry = clip.entries[best]
        return (clip.concatByteStart + Int64(entry.spn) * 192, k, Double(entry.pts45k) / 45000)
    }
}

extension DiscReader {
    /// [MovieClaw P7] 组装选中标题的定位表：每个已解析的剪辑读自己的 CLPI（KB 级小文件）。
    /// `resolved` 是拼进流里的剪辑：在播放列表里的下标、剪辑 id、在拼接流里的字节起点
    static func buildSeekTable(title: DiscTitle,
                               resolved: [(index: Int, clip: String, byteStart: Int64)],
                               readCLPI: (String) -> [UInt8]?) -> DiscSeekTable? {
        guard let inTimes = title.bdClipInTimes, !resolved.isEmpty else { return nil }
        let cumBefore = title.bdClipCumulativeBeforeTicks ?? []
        var clips: [DiscSeekTable.Clip] = []
        for item in resolved {
            guard item.index < inTimes.count else { return nil }
            let entries = readCLPI(item.clip).map(CLPIParser.entryPoints) ?? []
            clips.append(.init(concatByteStart: item.byteStart,
                               cumulativeBeforeSec: item.index < cumBefore.count ? Double(cumBefore[item.index]) / discTickRate : 0,
                               inTimeSec: Double(inTimes[item.index]) / discTickRate,
                               entries: entries))
        }
        let usable = clips.filter { !$0.entries.isEmpty }.count
        EngineLog.emit("[disc] [MovieClaw P7] seek table: \(clips.count) clip(s), \(usable) with EP map, entries=\(clips.map(\.entries.count))", category: .demux)
        return usable == clips.count ? DiscSeekTable(clips: clips) : nil
    }
}
