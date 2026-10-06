import Foundation
import Testing
@testable import AetherEngine

/// Matroska 索引定位（引擎补丁 P49，`MatroskaCuesLocator`）：从文件头读出 SeekHead 登记的 Cues 位置。
/// 位置错了只会白取一段数据，但结构没认对时绝不能给出一个「看起来像」的偏移，截断的字节只能答「还不够」。
struct MatroskaCuesLocatorTests {
    // MARK: - 拼 EBML 字节

    private func idBytes(_ id: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var value = id
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return bytes
    }

    /// 大小字段：默认用最短写法，`width` 指定时按那么多字节写（mkvmerge 的 Segment 用 8 字节）
    private func sizeBytes(_ size: Int, width: Int? = nil) -> [UInt8] {
        let length = width ?? (1 ... 8).first { size < (1 << (7 * $0)) - 1 }!
        var bytes = [UInt8](repeating: 0, count: length)
        var value = size
        for i in stride(from: length - 1, through: 0, by: -1) {
            bytes[i] = UInt8(value & 0xFF)
            value >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    private func element(_ id: UInt64, _ payload: [UInt8], sizeWidth: Int? = nil) -> [UInt8] {
        idBytes(id) + sizeBytes(payload.count, width: sizeWidth) + payload
    }

    private func uint(_ value: UInt64) -> [UInt8] {
        let bytes = idBytes(value)
        return bytes.isEmpty ? [0] : bytes
    }

    private func seek(_ target: UInt64, _ position: UInt64) -> [UInt8] {
        element(0x4DBB, element(0x53AB, idBytes(target)) + element(0x53AC, uint(position)))
    }

    private let ebmlHeader: [UInt8] = [
        0x1A, 0x45, 0xDF, 0xA3, 0x9F,
        0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81, 0x04, 0x42, 0xF3, 0x81, 0x08,
        0x42, 0x82, 0x88, 0x6D, 0x61, 0x74, 0x72, 0x6F, 0x73, 0x6B, 0x61, 0x42, 0x87, 0x81, 0x04,
    ]

    /// 仿 mkvmerge：EBML 头、8 字节大小的 Segment、SeekHead（Info / Tracks / Tags / Cues）、Void、Info
    private func mkvmergeHead(cuesPosition: UInt64, leadingVoid: Bool = false, listsCues: Bool = true,
                              unknownSegmentSize: Bool = false) -> (bytes: [UInt8], segmentDataStart: Int) {
        var seeks = seek(0x1549_A966, 0x1000) + seek(0x1654_AE6B, 0x1100)
        seeks += seek(0x1254_C367, 708_000_000)
        if listsCues { seeks += seek(0x1C53_BB6B, cuesPosition) }
        var body: [UInt8] = []
        if leadingVoid { body += element(0xEC, [UInt8](repeating: 0, count: 20)) }
        body += element(0x114D_9B74, seeks)
        body += element(0xEC, [UInt8](repeating: 0, count: 200))
        body += element(0x1549_A966, [0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40])
        let segmentHeader = unknownSegmentSize
            ? idBytes(0x1853_8067) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            : idBytes(0x1853_8067) + sizeBytes(1_239_127_000, width: 8)
        let head = ebmlHeader + segmentHeader
        return (head + body, head.count)
    }

    // MARK: - 用例

    @Test func findsCuesListedInTheLeadingSeekHead() {
        let (bytes, start) = mkvmergeHead(cuesPosition: 1_239_050_000)
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .found(Int64(start) + 1_239_050_000))
    }

    @Test func skipsAVoidInFrontOfTheSeekHead() {
        let (bytes, start) = mkvmergeHead(cuesPosition: 42_000_000, leadingVoid: true)
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .found(Int64(start) + 42_000_000))
    }

    @Test func worksWithAnUnknownSizeSegment() {
        let (bytes, start) = mkvmergeHead(cuesPosition: 9_000_000, unknownSegmentSize: true)
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .found(Int64(start) + 9_000_000))
    }

    /// 真实文件头（片库《鹿鼎记2》，1080p x265 FRDS）：开头的 SeekHead 只有一项，指向文件尾附近的完整目录
    @Test func realLeadingSeekHeadPointingToASecondOne() {
        let hex = "1a45dfa3a34286810142f7810142f2810442f381084282886d6174726f736b61428781044285810218538067"
            + "010000016c114dc9114d9b74924dbb8f53ab84114d9b7453ac85016c114d741043a77043ff45b943fb"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        // Segment 数据区从第 52 字节起（EBML 头 40 + Segment 的 ID 4、大小 8）；目录登记的相对位置 0x016c114d74
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .secondarySeekHead(52 + 0x016C_114D74))
    }

    /// 次级目录与 Cues 都登记了：Cues 优先（位置确切，不用靠「文件尾 2 MB」去兜）
    @Test func cuesWinOverASecondarySeekHead() {
        var seeks = seek(0x114D_9B74, 6_000_000_000) + seek(0x1C53_BB6B, 5_999_000_000)
        seeks += seek(0x1549_A966, 0x100)
        let body = element(0x114D_9B74, seeks)
        let head = ebmlHeader + idBytes(0x1853_8067) + sizeBytes(1_239_127_000, width: 8)
        #expect(MatroskaCuesLocator.locate(head: Data(head + body)) == .found(Int64(head.count) + 5_999_000_000))
    }

    @Test func seekHeadWithoutCuesIsAbsent() {
        let (bytes, _) = mkvmergeHead(cuesPosition: 0, listsCues: false)
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .absent)
    }

    @Test func nonMatroskaIsAbsent() {
        // MP4 的 ftyp
        let mp4: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
        #expect(MatroskaCuesLocator.locate(head: Data(mp4)) == .absent)
        #expect(MatroskaCuesLocator.locate(head: Data([0x47, 0x40, 0x11, 0x10])) == .absent)   // MPEG-TS
    }

    @Test func clusterBeforeAnySeekHeadIsAbsent() {
        let body = element(0x1549_A966, [0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40])
            + element(0x1F43_B675, [0xE7, 0x81, 0x00])
        let bytes = ebmlHeader + idBytes(0x1853_8067) + sizeBytes(body.count, width: 8) + body
        #expect(MatroskaCuesLocator.locate(head: Data(bytes)) == .absent)
    }

    /// 文件头一块一块到：任何截断只能答「还不够」或给出正确位置，绝不能给错的
    @Test func everyTruncationIsNeedMoreOrTheRightAnswer() {
        let (bytes, start) = mkvmergeHead(cuesPosition: 1_239_050_000, leadingVoid: true)
        let expected = MatroskaCuesLocator.Result.found(Int64(start) + 1_239_050_000)
        var firstFound: Int?
        for n in 0 ... bytes.count {
            let result = MatroskaCuesLocator.locate(head: Data(bytes.prefix(n)))
            #expect(result == .needMore || result == expected, "截断到 \(n) 字节时答了 \(result)")
            if result == expected, firstFound == nil { firstFound = n }
        }
        // SeekHead 收全就能答，不必等后面的 Void / Info
        #expect(firstFound != nil && firstFound! < bytes.count - 200)
    }

    /// 乱码不崩、不越界（第一版在 SeekHead 里的元素头越过边界时算出负数长度，这条就是抓它的）
    @Test func garbageAfterTheMagicNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            let count = Int.random(in: 0 ... 300, using: &generator)
            let noise = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            _ = MatroskaCuesLocator.locate(head: Data([0x1A, 0x45, 0xDF, 0xA3] + noise))
            _ = MatroskaCuesLocator.locate(head: Data(ebmlHeader + [0x18, 0x53, 0x80, 0x67] + noise))
        }
        // 在合法文件头上随机改几个字节、随机截断
        let (valid, _) = mkvmergeHead(cuesPosition: 1_239_050_000, leadingVoid: true)
        for _ in 0 ..< 5000 {
            var mutated = valid
            for _ in 0 ..< Int.random(in: 1 ... 4, using: &generator) {
                mutated[Int.random(in: 0 ..< mutated.count, using: &generator)] = UInt8.random(in: 0 ... 255, using: &generator)
            }
            _ = MatroskaCuesLocator.locate(head: Data(mutated.prefix(Int.random(in: 0 ... mutated.count, using: &generator))))
        }
    }

    // MARK: - 服务端精简索引（P58）

    /// 服务端给的精简索引必须正好是一个完整的 Cues 元素：读取器拿它整段顶替原索引，
    /// 多一个字节、少一个字节，解复用器接下来读到的就全错位了
    @Test func hostCuesAcceptOnlyOneWholeCuesElement() {
        let point = element(0xBB, element(0xB3, [0x00]) + element(0xB7, element(0xF7, [0x01]) + element(0xF1, [0x10])))
        let whole = element(0x1C53_BB6B, point + point)
        #expect(MatroskaHostCues(offset: 4096, data: Data(whole)) != nil)
        #expect(MatroskaHostCues(offset: 4096, data: Data(whole.dropLast())) == nil)
        #expect(MatroskaHostCues(offset: 4096, data: Data(whole + [0x00])) == nil)
        #expect(MatroskaHostCues(offset: 4096, data: Data(element(0x1654_AE6B, point))) == nil)
        #expect(MatroskaHostCues(offset: 0, data: Data(whole)) == nil)
        // 大小未知（数值位全 1）说明不了到哪结束，也不收
        #expect(MatroskaHostCues(offset: 4096, data: Data([0x1C, 0x53, 0xBB, 0x6B, 0xFF] + point)) == nil)
        // 从更大的数据里切出来的片段（下标不从 0 起）照样认
        let padded = Data([0xAA, 0xBB] + whole)
        #expect(MatroskaHostCues(offset: 4096, data: padded.dropFirst(2)) != nil)
    }
}
