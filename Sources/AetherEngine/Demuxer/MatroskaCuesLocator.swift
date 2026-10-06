import Foundation

extension AetherEngine {
    /// [MovieClaw P49] 文件头一到就按 SeekHead 把 Matroska 索引先取回来（默认开；关掉即原样按需读，真机对照用）
    nonisolated(unsafe) public static var prefetchesMatroskaCues = true
    /// [MovieClaw P58] 宿主给了服务端生成的精简索引（`LoadOptions.matroskaCues`）就用它顶替原索引（默认开；关掉即照旧
    /// 下载原索引，真机对照用）
    nonisolated(unsafe) public static var usesHostMatroskaCues = true
}

/// [MovieClaw P58] 服务端生成的 Matroska 精简索引（docs/design/playback-qoe.md §9.12）：从原 Cues 里只挑出视频轨的
/// 索引点（时间、簇位置原样）重新编码成的一整个 Cues 元素，连同原 Cues 在文件里的位置。
///
/// 为什么要它：mkvmerge 给每条字幕轨的每个事件都写索引点，字幕轨多的片子原 Cues 有几百 KB 到几 MB（片库抽样九成在
/// 560 KB 以内、最大 4.2 MB）。P49 提前取也得把它整段下完，外网 6 Mbit/s 下 1.2 MB 就是 1.6 秒，直接压在首帧前面。
/// 主播放的解复用器只用得到视频轨的索引点（libavformat 建索引只读 CueTime、CueTrack、CueClusterPosition，跳转按视频流），
/// 所以读取器在解复用器读这个位置时直接给精简版，原索引一个字节都不用下。
///
/// 只给主播放的解复用器用（`DemuxerOpenProfile.hostMatroskaCues`）：读字幕的旁路解复用器可能按字幕轨的索引点跳转，
/// 照旧读原索引。位置必须与文件头里 SeekHead 登记的一致才装（`AVIOReader.locateCuesLocked`），对不上就当没给。
/// 服务端只为写在簇后面（文件尾）的 Cues 生成精简版：解复用器读文件头时不会顺序走进它，换成长度不同的元素不影响别处。
public struct MatroskaHostCues: Sendable, Equatable {
    /// 原 Cues 元素在文件里的绝对偏移（SeekHead 登记的位置）
    public let offset: Int64
    /// 精简后的整个 Cues 元素（含元素头）
    public let data: Data

    /// 数据不是一个完整的 Cues 元素（ID 不对、大小未知或与字节数对不上）时返回 nil
    public init?(offset: Int64, data: Data) {
        guard offset > 0, MatroskaCuesLocator.isWholeCuesElement(data) else { return nil }
        self.offset = offset
        self.data = data
    }
}

/// [MovieClaw P49] 从 Matroska（MKV / WebM）文件头的字节里找出索引（Cues）在文件里的位置。
///
/// 为什么要自己找：libavformat 的 matroska 解复用器把 Cues 的解析推迟到第一次跳转（引擎的「索引预热」），
/// 那时才按 SeekHead 登记的位置去读。常见的 mkvmerge 产物把 Cues 放在文件尾附近、却又离尾部几十 KB 到
/// 近 1 MB（后面还跟着 Tags 等），落在尾部预读（64 KB）之外，于是要单独再发一次请求：真机经外网域名
/// 每次多等 40～70 毫秒、最长 380 毫秒，还会把正在读文件头的连接掐掉重连。SeekHead 就在文件最前面
/// （EBML 头之后几十字节），文件头的第一块数据一到就能读出 Cues 的位置，和开容器、探测流并行把它先取回来。
///
/// 只读 Segment 开头的第一个 SeekHead（前面允许有 Void 等少数元素）；找不到就返回 `.absent`，照旧由
/// 解复用器按需去读，不会更慢。字节被截断时只答 `.needMore`，绝不给出半截结构猜出来的位置。
enum MatroskaCuesLocator {
    enum Result: Equatable {
        /// Cues 元素在文件里的绝对偏移
        case found(Int64)
        /// 开头的 SeekHead 没登记 Cues，只指向另一个 SeekHead（在这个绝对偏移）：mkvmerge 预留的位置放不下完整目录时
        /// 就这样写，完整目录连同 Cues、Tags 都在文件尾附近（语料《鹿鼎记2》：次级目录在文件最后 85 字节、Cues 离文件尾 17 万字节）。
        /// 读取器目前对这种布局不提前取（盲取文件尾 1 MB 实测得不偿失），留着结果供以后两步取（先读次级目录再取 Cues）
        case secondarySeekHead(Int64)
        /// 不是 Matroska，或 SeekHead 没登记 Cues、结构不认识：不用再找
        case absent
        /// 字节不够读完 SeekHead：等文件头多到一些再找
        case needMore
    }

    static let ebmlMagic: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
    static let segmentID: UInt64 = 0x1853_8067
    static let seekHeadID: UInt64 = 0x114D_9B74
    static let seekID: UInt64 = 0x4DBB
    static let seekIDElementID: UInt64 = 0x53AB
    static let seekPositionID: UInt64 = 0x53AC
    static let cuesID: UInt64 = 0x1C53_BB6B
    static let clusterID: UInt64 = 0x1F43_B675

    /// Segment 里在 SeekHead 之前最多跳过几个一级元素（Void、CRC-32 之类）
    static let maxLeadingElements = 8
    /// 正常的 SeekHead 只有几十到几百字节；大得离谱就是认错了结构
    static let maxSeekHeadBytes: UInt64 = 1 << 20

    static func locate(head: Data) -> Result {
        guard head.count >= ebmlMagic.count else {
            return head.elementsEqual(ebmlMagic.prefix(head.count)) ? .needMore : .absent
        }
        guard head.prefix(ebmlMagic.count).elementsEqual(ebmlMagic) else { return .absent }
        return head.withUnsafeBytes { raw -> Result in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            // 读失败时：字节不够 → 再等等；编码不合法 → 不认识，不找了
            func failed() -> Result { reader.truncated ? .needMore : .absent }

            // EBML 头
            guard reader.readID() != nil, let headerSize = reader.readSize() else { return failed() }
            guard let headerLength = headerSize.known else { return .absent }
            guard reader.skip(headerLength) else { return failed() }
            // Segment：SeekPosition 相对它数据区的起点
            guard let segment = reader.readID() else { return failed() }
            guard segment == segmentID else { return .absent }
            guard reader.readSize() != nil else { return failed() }
            let segmentDataStart = Int64(reader.position)
            for _ in 0 ..< maxLeadingElements {
                guard let id = reader.readID(), let size = reader.readSize() else { return failed() }
                if id == seekHeadID {
                    guard let length = size.known, length <= maxSeekHeadBytes else { return .absent }
                    return parseSeekHead(&reader, length: Int(length), segmentDataStart: segmentDataStart)
                }
                // 已经到了媒体数据：没有排在前面的 SeekHead
                if id == clusterID { return .absent }
                guard let length = size.known else { return .absent }
                guard reader.skip(length) else { return failed() }
            }
            return .absent
        }
    }

    /// [MovieClaw P58] `data` 正好是一个完整的 Cues 元素：以 Cues 的 ID 开头，大小已知且与余下的字节数相等
    static func isWholeCuesElement(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            guard reader.readID() == cuesID, let size = reader.readSize(), let length = size.known else { return false }
            return length == UInt64(reader.count - reader.position)
        }
    }

    private static func parseSeekHead(_ reader: inout Reader, length: Int, segmentDataStart: Int64) -> Result {
        let end = reader.position + length
        guard end <= reader.count else { return .needMore }
        var secondary: Int64?
        while reader.position < end {
            // ID 与大小字段本身也不能越过 SeekHead 的边界（乱码时会越过，先比再减，免得出负数）
            guard let id = reader.readID(), let size = reader.readSize(), let entryLength = size.known,
                  reader.position <= end, entryLength <= UInt64(end - reader.position) else { return .absent }
            let entryEnd = reader.position + Int(entryLength)
            if id == seekID {
                var target: UInt64?
                var position: UInt64?
                while reader.position < entryEnd {
                    guard let childID = reader.readID(), let childSize = reader.readSize(),
                          let childLength = childSize.known, childLength <= 8, reader.position <= entryEnd,
                          childLength <= UInt64(entryEnd - reader.position),
                          let value = reader.readUInt(length: Int(childLength)) else { return .absent }
                    if childID == seekIDElementID { target = value }
                    if childID == seekPositionID { position = value }
                }
                if let position, position <= UInt64(Int64.max - segmentDataStart) {
                    if target == cuesID { return .found(segmentDataStart + Int64(position)) }
                    if target == seekHeadID, secondary == nil { secondary = segmentDataStart + Int64(position) }
                }
            }
            reader.position = entryEnd
        }
        return secondary.map { .secondarySeekHead($0) } ?? .absent
    }

    /// EBML 的大小字段：数值位全 1 表示「未知大小」
    struct Size {
        let known: UInt64?
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0
        /// 最近一次读失败是不是因为字节不够（而不是编码不合法）
        var truncated = false
        var count: Int { bytes.count }

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        /// 变长整数的字节数：第一个字节前导零的个数 + 1。字节不够或编码不合法时返回 nil（`truncated` 区分两者）
        private mutating func vintLength(maxLength: Int) -> Int? {
            guard position < count else { truncated = true; return nil }
            let first = bytes[position]
            guard first != 0 else { truncated = false; return nil }
            let length = first.leadingZeroBitCount + 1
            guard length <= maxLength else { truncated = false; return nil }
            guard position + length <= count else { truncated = true; return nil }
            return length
        }

        /// 元素 ID：保留长度标记位（Matroska 规范里 ID 就是带标记位的原始字节），1～4 字节
        mutating func readID() -> UInt64? {
            guard let length = vintLength(maxLength: 4) else { return nil }
            var value: UInt64 = 0
            for i in 0 ..< length { value = value << 8 | UInt64(bytes[position + i]) }
            position += length
            return value
        }

        /// 元素大小：去掉长度标记位，1～8 字节；数值位全 1 = 未知大小
        mutating func readSize() -> Size? {
            guard let length = vintLength(maxLength: 8) else { return nil }
            let mask = UInt64(0xFF) >> UInt64(length)
            var value = UInt64(bytes[position]) & mask
            var allOnes = value == mask
            for i in 1 ..< length {
                let byte = bytes[position + i]
                value = value << 8 | UInt64(byte)
                allOnes = allOnes && byte == 0xFF
            }
            position += length
            return Size(known: allOnes ? nil : value)
        }

        /// 大端无符号整数（SeekID、SeekPosition）；调用方已确认字节足够
        mutating func readUInt(length: Int) -> UInt64? {
            guard length <= 8, position + length <= count else { truncated = true; return nil }
            var value: UInt64 = 0
            for i in 0 ..< length { value = value << 8 | UInt64(bytes[position + i]) }
            position += length
            return value
        }

        mutating func skip(_ length: UInt64) -> Bool {
            guard length <= UInt64(count - position) else { truncated = true; return false }
            position += Int(length)
            return true
        }
    }
}
