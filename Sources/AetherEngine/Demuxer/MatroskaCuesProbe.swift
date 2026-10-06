import Foundation

/// [MovieClaw P18] 没有 Cues（关键帧索引）的 MKV：识别与定位辅助用到的 EBML 解析，全是纯函数。
///
/// 背景（2026-09-28 真机 + NAS 只读统计）：片库 6675 个 MKV 里 45 个没有可用的 Cues——39 个封装时就没写
/// （《无间道》三部曲、《大话西游》《风之谷》等同一批压制），1 个下载不完整、SeekHead 指向文件尾之外（《饥饿站台》，
/// 文件 11.8 GB、Cues 指针在 18.6 GB 处），5 个指针处不是 Cues。libavformat 只经 SeekHead（或第一个 Cluster 之前）
/// 找 Cues；找不到时按时间定位退回「从上一个已知位置往后逐个解析 Cluster」。引擎起播前为加载索引往片中间跳的那一下
/// （cue prewarm）于是线性读了 10 秒（上限）才放弃，扫到的关键帧只覆盖开头 212 秒，却被当成可信索引切分片：最后一段
/// 从 205 秒拉到片尾 5933 秒，AVPlayer 等不到这一段，永远不出画。
///
/// 这里只做两件事：
/// - `headInfo`：从文件开头的字节判断 Cues 在不在、在不在文件内，顺带取 TimestampScale；
/// - `firstCluster`：在任意一段字节里找第一个 Cluster 的起点与时间码（定位时按字节估位置后用它校正）。
enum MatroskaCuesProbe {
    enum CuesState: Equatable {
        /// SeekHead 指向的 Cues（或第一个 Cluster 之前直接出现的 Cues）在文件内：交给 libavformat 照常加载
        case present(offset: Int64)
        /// 走到第一个 Cluster 都没有任何 Cues 线索：文件没有索引
        case missing
        /// SeekHead 指向文件尾之外：文件不完整（下载没下完、被截断）
        case pastEndOfFile(offset: Int64)
        /// 解析不了、文件头不够长，或 SeekHead 还引用了第二个 SeekHead（libavformat 会跟过去）：不下结论
        case unknown
    }

    struct HeadInfo: Equatable {
        var cues: CuesState
        /// Info 里的 TimestampScale（纳秒 / 单位），缺省 1_000_000（毫秒）
        var timestampScale: UInt64
    }

    static let ebmlHeaderID: UInt32 = 0x1A45_DFA3
    static let segmentID: UInt32 = 0x1853_8067
    static let seekHeadID: UInt32 = 0x114D_9B74
    static let seekID: UInt32 = 0x4DBB
    static let seekIDID: UInt32 = 0x53AB
    static let seekPositionID: UInt32 = 0x53AC
    static let infoID: UInt32 = 0x1549_A966
    static let timestampScaleID: UInt32 = 0x2A_D7B1
    static let clusterID: UInt32 = 0x1F43_B675
    static let clusterTimestampID: UInt32 = 0xE7
    static let cuesID: UInt32 = 0x1C53_BB6B
    static let crc32ID: UInt32 = 0xBF
    static let voidID: UInt32 = 0xEC

    /// 读一个元素 ID（保留长度标记位）。返回 (值, 字节数)；首字节为 0 或越界时返回 nil
    static func readID(_ bytes: [UInt8], at index: Int) -> (value: UInt32, length: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, index + length <= bytes.count else { return nil }
        var value = UInt32(first)
        for k in 1 ..< length { value = (value << 8) | UInt32(bytes[index + k]) }
        return (value, length)
    }

    /// 读一个元素长度（去掉标记位）。全 1 表示「长度未知」，返回 value = nil
    static func readSize(_ bytes: [UInt8], at index: Int) -> (value: UInt64?, length: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard index + length <= bytes.count else { return nil }
        let mask: UInt8 = length == 8 ? 0 : (0xFF >> length)
        var value = UInt64(first & mask)
        var allOnes = (first & mask) == mask
        for k in 1 ..< length {
            let byte = bytes[index + k]
            value = (value << 8) | UInt64(byte)
            if byte != 0xFF { allOnes = false }
        }
        return (allOnes ? nil : value, length)
    }

    /// 大端无符号整数（元素体，最多 8 字节）
    static func readUInt(_ bytes: [UInt8], at index: Int, length: Int) -> UInt64? {
        guard length >= 1, length <= 8, index + length <= bytes.count else { return nil }
        var value: UInt64 = 0
        for k in 0 ..< length { value = (value << 8) | UInt64(bytes[index + k]) }
        return value
    }

    /// 从文件开头的字节（建议 ≥ 64 KB）判断 Cues 状况。
    static func headInfo(_ head: [UInt8], fileSize: Int64) -> HeadInfo {
        var info = HeadInfo(cues: .unknown, timestampScale: 1_000_000)
        // EBML 头
        guard let ebml = readID(head, at: 0), ebml.value == ebmlHeaderID,
              let ebmlSize = readSize(head, at: ebml.length), let ebmlBody = ebmlSize.value
        else { return info }
        var cursor = ebml.length + ebmlSize.length + Int(ebmlBody)
        // Segment（长度可以是未知）
        guard let segment = readID(head, at: cursor), segment.value == segmentID,
              let segmentSize = readSize(head, at: cursor + segment.length)
        else { return info }
        cursor += segment.length + segmentSize.length
        let segmentDataStart = Int64(cursor)
        var cuesOffset: Int64?
        var chainedSeekHead = false
        var reachedCluster = false
        while cursor < head.count {
            guard let id = readID(head, at: cursor), let size = readSize(head, at: cursor + id.length) else { break }
            let body = cursor + id.length + size.length
            if id.value == clusterID { reachedCluster = true; break }
            guard let length = size.value else { break }  // 顶层元素长度未知：没法往后跳
            let end = body + Int(length)
            switch id.value {
            case seekHeadID:
                guard end <= head.count else { return info }  // SeekHead 没读全
                var child = body
                while child < end {
                    guard let seek = readID(head, at: child), let seekSize = readSize(head, at: child + seek.length),
                          let seekLength = seekSize.value else { break }
                    let seekBody = child + seek.length + seekSize.length
                    let seekEnd = seekBody + Int(seekLength)
                    if seek.value == seekID {
                        var targetID: UInt64?
                        var position: UInt64?
                        var field = seekBody
                        while field < seekEnd {
                            guard let fid = readID(head, at: field), let fsize = readSize(head, at: field + fid.length),
                                  let flength = fsize.value else { break }
                            let fbody = field + fid.length + fsize.length
                            if fid.value == seekIDID { targetID = readUInt(head, at: fbody, length: Int(flength)) }
                            if fid.value == seekPositionID { position = readUInt(head, at: fbody, length: Int(flength)) }
                            field = fbody + Int(flength)
                        }
                        if targetID == UInt64(cuesID), let position { cuesOffset = segmentDataStart + Int64(position) }
                        if targetID == UInt64(seekHeadID) { chainedSeekHead = true }
                    }
                    child = seekEnd
                }
            case infoID:
                var field = body
                while field < min(end, head.count) {
                    guard let fid = readID(head, at: field), let fsize = readSize(head, at: field + fid.length),
                          let flength = fsize.value else { break }
                    let fbody = field + fid.length + fsize.length
                    if fid.value == timestampScaleID, let scale = readUInt(head, at: fbody, length: Int(flength)),
                       scale > 0 {
                        info.timestampScale = scale
                    }
                    field = fbody + Int(flength)
                }
            case cuesID:
                if cuesOffset == nil { cuesOffset = Int64(cursor) }
            default:
                break
            }
            cursor = end
        }
        if let cuesOffset {
            info.cues = cuesOffset < fileSize ? .present(offset: cuesOffset) : .pastEndOfFile(offset: cuesOffset)
        } else if reachedCluster, !chainedSeekHead {
            info.cues = .missing
        }
        return info
    }

    /// 在一段字节里找第一个 Cluster：ID + 合法长度（可以是未知长度），第一个子元素（跳过 CRC-32 / Void）是 Timestamp。
    /// 返回 Cluster 起点在这段字节里的下标与原始时间码（TimestampScale 单位）。
    static func firstCluster(in bytes: [UInt8], from start: Int = 0) -> (index: Int, timestamp: UInt64)? {
        guard bytes.count >= 8 else { return nil }
        var i = max(0, start)
        while i + 8 <= bytes.count {
            guard bytes[i] == 0x1F, bytes[i + 1] == 0x43, bytes[i + 2] == 0xB6, bytes[i + 3] == 0x75,
                  let size = readSize(bytes, at: i + 4)
            else { i += 1; continue }
            var child = i + 4 + size.length
            // CRC-32 或 Void 可以排在 Timestamp 前面
            for _ in 0 ..< 2 {
                guard let id = readID(bytes, at: child), id.value == crc32ID || id.value == voidID,
                      let skip = readSize(bytes, at: child + id.length), let skipLength = skip.value,
                      skipLength < 4096 else { break }
                child += id.length + skip.length + Int(skipLength)
            }
            if let id = readID(bytes, at: child), id.value == clusterTimestampID,
               let tsSize = readSize(bytes, at: child + id.length), let tsLength = tsSize.value, tsLength >= 1, tsLength <= 8,
               let timestamp = readUInt(bytes, at: child + id.length + tsSize.length, length: Int(tsLength)) {
                return (i, timestamp)
            }
            i += 1
        }
        return nil
    }
}
