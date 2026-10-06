import Foundation

extension AetherEngine {
    /// [MovieClaw P54] 文件头一到就按顶层盒子找出尾部 moov，与开容器并行先取回来（默认开；关掉即原样按需读，对照用）
    nonisolated(unsafe) public static var prefetchesMP4TailMoov = true
}

/// [MovieClaw P54] 从 MP4 / MOV 文件头的字节里判断 moov 在不在文件尾、从哪里开始。
///
/// 为什么要自己找：片库里超过 100 MB 的 MP4 约六成（2026-09-30 抽样 60 部里 34 部）是「mdat 在前、moov 在后」，
/// moov 0.5～3 MB、最大见过 10.7 MB，而且都是最后一个盒子。libavformat 的 mov 解复用器读到 mdat 的盒子头就跳过
/// 整个 mdat 去文件尾读 moov：读取器只能把正在读文件头的连接挪过去（尾部预读只有 64 KB，够不着），读完 moov 再回到
/// mdat 开头时，文件头只留下了连接被挪走前到手的那一点，剩下的要按 4 MB 整块补取。快线路上多一次往返；慢线路上整块在
/// 限时内下不完、作废重来，首帧晚好几秒。
///
/// 文件头里 mdat 的盒子头就写着它有多大，所以 moov 从哪开始在第一块数据里就能算出来：mdat 之后一直到文件尾就是
/// 解复用器接下来要整段读的元数据。提前并行取回来装成常驻片段（和 Matroska 索引同一套，P49），文件头的连接不动。
///
/// 只看顶层盒子头，不解析 moov 本身；看不懂的一律当「不是这种布局」，照旧按需读——这只是优化，猜错不如不做。
enum MP4MoovLocator {
    enum Result: Equatable {
        /// mdat 之后还有东西（moov 与可能跟着的 free / udta）：从 `offset` 起到文件尾
        case moovAfterMdat(offset: Int64)
        /// moov 在 mdat 之前（faststart），或是分片 MP4（moof）：文件头的连接顺带就读到了
        case moovFirst
        /// 不是 MP4 / MOV，或布局看不懂（第一个盒子不是 ftyp、mdat 一直到文件尾、盒子长度不合理）
        case notApplicable
        /// 文件头的字节还不够看到 mdat 或 moov 的盒子头
        case needMore
    }

    /// 顶层盒子最多看这么多个就不看了（ftyp、free、wide、uuid 之类都在 mdat 之前，正常文件三五个就到 mdat）
    static let maxBoxes = 16

    static func locate(head: Data, fileSize: Int64) -> Result {
        guard fileSize > 0 else { return .notApplicable }
        // 每次到货都会再看一遍，所以只按下标读盒子头那几个字节，不拷贝整段文件头
        let base = head.startIndex
        func byte(_ i: Int) -> UInt8 { head[base + i] }
        let available = Int64(head.count)
        var offset: Int64 = 0
        var index = 0
        while index < maxBoxes {
            // 盒子头：4 字节长度 + 4 字节类型；长度为 1 时后跟 8 字节的 64 位长度
            guard offset + 8 <= available else { return .needMore }
            let at = Int(offset)
            let size32 = UInt32(byte(at)) << 24 | UInt32(byte(at + 1)) << 16
                | UInt32(byte(at + 2)) << 8 | UInt32(byte(at + 3))
            let type = String(decoding: [byte(at + 4), byte(at + 5), byte(at + 6), byte(at + 7)], as: UTF8.self)
            if index == 0, type != "ftyp" { return .notApplicable }
            var size = Int64(size32)
            if size32 == 1 {
                guard offset + 16 <= available else { return .needMore }
                var large: UInt64 = 0
                for i in 8 ..< 16 { large = large << 8 | UInt64(byte(at + i)) }
                guard large <= UInt64(Int64.max) else { return .notApplicable }
                size = Int64(large)
            } else if size32 == 0 {
                // 长度 0 = 一直到文件尾：mdat 这样写就没有地方放 moov 了
                return type == "moov" ? .moovFirst : .notApplicable
            }
            guard size >= 8, offset + size <= fileSize else { return .notApplicable }
            switch type {
            case "moov", "moof":
                return .moovFirst
            case "mdat":
                let end = offset + size
                return end < fileSize ? .moovAfterMdat(offset: end) : .notApplicable
            default:
                offset += size
                index += 1
            }
        }
        return .notApplicable
    }
}
