import Foundation
import Testing
@testable import AetherEngine

/// MP4 尾部 moov 定位（引擎补丁 P54，`MP4MoovLocator`）：从文件头的顶层盒子算出 mdat 之后（moov 所在）从哪开始。
/// 位置错了只会白取一段数据，但布局没认对时绝不能给出偏移：看不懂的一律「不适用」，截断的只能答「还不够」。
struct MP4MoovLocatorTests {
    /// 顶层盒子头：4 字节长度 + 4 字节类型（`large` 时长度写 1、后跟 8 字节长度）
    private func box(_ type: String, size: Int64, large: Bool = false) -> [UInt8] {
        func be(_ value: UInt64, _ width: Int) -> [UInt8] {
            (0 ..< width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(width - 1 - $0))) }
        }
        if large { return be(1, 4) + Array(type.utf8) + be(UInt64(size), 8) }
        return be(UInt64(size), 4) + Array(type.utf8)
    }

    @Test func tailMoovAfterMdat() {
        // ftyp 32 + free 8 + mdat 1 GB，文件再多 2 MB 放 moov：moov 从 mdat 结束处开始
        let mdat: Int64 = 1 << 30
        let fileSize = 40 + mdat + 2_000_000
        let head = Data(box("ftyp", size: 32) + [UInt8](repeating: 0, count: 24) + box("free", size: 8) + box("mdat", size: mdat))
        #expect(MP4MoovLocator.locate(head: head, fileSize: fileSize) == .moovAfterMdat(offset: 40 + mdat))
    }

    @Test func largeSizeMdat() {
        // 超过 4 GB 的 mdat 用 64 位长度（长度字段写 1）
        let mdat: Int64 = 6_000_000_000
        let fileSize = 32 + mdat + 3_000_000
        let head = Data(box("ftyp", size: 32) + [UInt8](repeating: 0, count: 24) + box("mdat", size: mdat, large: true))
        #expect(MP4MoovLocator.locate(head: head, fileSize: fileSize) == .moovAfterMdat(offset: 32 + mdat))
    }

    @Test func faststartAndFragmented() {
        // moov 在 mdat 前（faststart）、分片 MP4（moov 后跟 moof）：文件头的连接顺带就到，不提前取
        let faststart = Data(box("ftyp", size: 24) + [UInt8](repeating: 0, count: 16) + box("moov", size: 500_000))
        #expect(MP4MoovLocator.locate(head: faststart, fileSize: 900_000_000) == .moovFirst)
        let fragmented = Data(box("ftyp", size: 24) + [UInt8](repeating: 0, count: 16) + box("moof", size: 4000))
        #expect(MP4MoovLocator.locate(head: fragmented, fileSize: 900_000_000) == .moovFirst)
    }

    @Test func notMP4OrUnreadableLayout() {
        // Matroska（EBML 开头）、第一个盒子不是 ftyp：不适用，交给 Matroska 定位
        #expect(MP4MoovLocator.locate(head: Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81]), fileSize: 1000) == .notApplicable)
        #expect(MP4MoovLocator.locate(head: Data(box("wide", size: 8) + box("mdat", size: 100)), fileSize: 1000) == .notApplicable)
        // mdat 一直到文件尾（长度 0 或正好到尾）：没有地方放 moov
        let toEnd = Data(box("ftyp", size: 16) + [UInt8](repeating: 0, count: 8) + box("mdat", size: 0))
        #expect(MP4MoovLocator.locate(head: toEnd, fileSize: 5000) == .notApplicable)
        let exact = Data(box("ftyp", size: 16) + [UInt8](repeating: 0, count: 8) + box("mdat", size: 4984))
        #expect(MP4MoovLocator.locate(head: exact, fileSize: 5000) == .notApplicable)
        // 盒子长度越过文件尾、小于盒子头：结构不对，不给偏移
        let overrun = Data(box("ftyp", size: 16) + [UInt8](repeating: 0, count: 8) + box("mdat", size: 9000))
        #expect(MP4MoovLocator.locate(head: overrun, fileSize: 5000) == .notApplicable)
        let tiny = Data(box("ftyp", size: 16) + [UInt8](repeating: 0, count: 8) + box("free", size: 3))
        #expect(MP4MoovLocator.locate(head: tiny, fileSize: 5000) == .notApplicable)
    }

    @Test func truncatedHeadAsksForMore() {
        let full = box("ftyp", size: 32) + [UInt8](repeating: 0, count: 24) + box("mdat", size: 1 << 30, large: true)
        // 截在任何一个盒子头中间都只能答「还不够」，不能拿半个长度字段算出偏移
        for cut in [0, 4, 7, 31, 35, 39, 45] {
            #expect(MP4MoovLocator.locate(head: Data(full.prefix(cut)), fileSize: 2 << 30) == .needMore)
        }
        // 文件头里是一个很大的 free：要跳过它才看得到 mdat，字节还没到就答「还不够」
        let bigFree = Data(box("ftyp", size: 16) + [UInt8](repeating: 0, count: 8) + box("free", size: 300_000))
        #expect(MP4MoovLocator.locate(head: bigFree, fileSize: 1 << 30) == .needMore)
    }

    @Test func fuzzNeverCrashesOrPointsOutsideTheFile() {
        // 随机字节（开头伪装成 ftyp）：不崩溃，给出的偏移一定落在文件里
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            var bytes = [UInt8](repeating: 0, count: Int.random(in: 0 ... 96, using: &rng))
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255, using: &rng) }
            if bytes.count >= 8, Bool.random(using: &rng) { bytes.replaceSubrange(4 ..< 8, with: Array("ftyp".utf8)) }
            let fileSize = Int64.random(in: 1 ... 10_000_000, using: &rng)
            if case let .moovAfterMdat(offset) = MP4MoovLocator.locate(head: Data(bytes), fileSize: fileSize) {
                #expect(offset > 0 && offset < fileSize)
            }
        }
    }
}
