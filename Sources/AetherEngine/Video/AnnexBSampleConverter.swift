import Foundation

/// [MovieClaw P38] Annex B 视频样本转成 4 字节长度前缀，**保留全部 NAL**。
///
/// movenc 自己转换 hvc1 样本时会剥掉带内 VPS/SPS/PPS（`ff_hevc_annexb2mp4` 的 filter_ps），解码器只能用 init 里
/// 片头那一套参数集。原盘片中换过 PPS 时（《黑豹2》118 秒、345.7 秒），之后的切片全按旧 PPS 解：Mac 系统硬解报
/// Cannot Decode、真机只有声音没有画面。样本里留着参数集（样本入口仍是 hvc1），系统解码器按样本里的更新，离线实测全部解出。
enum AnnexBSampleConverter {
    /// 找不到起始码（不是 Annex B）时返回 nil，调用方原样写出
    static func lengthPrefixed(_ sample: UnsafeRawBufferPointer) -> [UInt8]? {
        guard let base = sample.baseAddress?.assumingMemoryBound(to: UInt8.self), sample.count >= 4 else { return nil }
        let n = sample.count
        // 每个起始码（00 00 01）后第一个字节的位置
        var starts: [Int] = []
        var i = 0
        while i + 2 < n {
            if base[i + 2] > 1 { i += 3; continue }        // 快速跳过：第三字节不是 0/1 就不可能是起始码的末尾
            if base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
                starts.append(i + 3); i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(n + starts.count * 2)
        for (k, s) in starts.enumerated() {
            // NAL 到下一个起始码为止；去掉尾随的 0（四字节起始码的前导 0 与 trailing_zero_8bits）
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
            while e > s, base[e - 1] == 0 { e -= 1 }
            let len = e - s
            guard len > 0 else { continue }
            out.append(UInt8(truncatingIfNeeded: len >> 24)); out.append(UInt8(truncatingIfNeeded: len >> 16))
            out.append(UInt8(truncatingIfNeeded: len >> 8)); out.append(UInt8(truncatingIfNeeded: len))
            out.append(contentsOf: UnsafeBufferPointer(start: base + s, count: len))
        }
        return out.isEmpty ? nil : out
    }
}
