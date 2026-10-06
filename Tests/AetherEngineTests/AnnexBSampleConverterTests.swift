import Foundation
import Testing
@testable import AetherEngine

/// Annex B 样本转长度前缀（引擎补丁 P38）：保留全部 NAL（含参数集），去掉四字节起始码的前导 0 与尾随 0。
struct AnnexBSampleConverterTests {
    private func convert(_ bytes: [UInt8]) -> [UInt8]? {
        bytes.withUnsafeBytes { AnnexBSampleConverter.lengthPrefixed($0) }
    }

    @Test func keepsParameterSetsAndStripsZeroPadding() {
        let aud: [UInt8] = [0x46, 0x01, 0x50]
        let vps: [UInt8] = [0x40, 0x01, 0x0c]
        let pps: [UInt8] = [0x44, 0x01, 0xc0, 0x72]
        let idr: [UInt8] = [0x28, 0x01, 0xaf, 0x00, 0x00, 0x03, 0x01, 0x80]   // 带防竞争字节
        let annexB: [UInt8] = [0, 0, 0, 1] + aud + [0, 0, 1] + vps + [0, 0, 0, 1] + pps + [0, 0, 1] + idr + [0, 0]
        let expected: [UInt8] = [0, 0, 0, 3] + aud + [0, 0, 0, 3] + vps + [0, 0, 0, 4] + pps + [0, 0, 0, 8] + idr
        #expect(convert(annexB) == expected)
    }

    @Test func nonAnnexBIsLeftAlone() {
        #expect(convert([0, 0, 0, 5, 0x28, 0x01, 0xaf, 0x10, 0x20]) == nil)
    }
}
