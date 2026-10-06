import Foundation

/// [MovieClaw P25] 存储紧张时照样能放（MovieClaw 补丁，见 PATCHES.md）。
///
/// 换封装通路把切好的分片写进临时目录（`SegmentCache`：前方 10 段、后方 20 段，另有留存预算），
/// UHD 原盘一段 30～45 MB，光这两个硬窗口就要 1 GB 上下；片源字节缓存（P22）与软件通路的读前缓存也落在同一个卷。
/// 手机存储快满时分片写不进去，起播直接失败，App 原来只好在可用空间低于 512 MB 时改走服务端流。
///
/// 这里给宿主两样东西：
/// 1. `LoadOptions.backwardBufferSegments`：后方窗口可设（前方窗口本来就有 `forwardBufferSegments`），
///    宿主按剩余空间把两个窗口一起收小，自研引擎在存储紧张时照样能放；
/// 2. 写分片遇到 ENOSPC 记下「存储已满」（补丁 P8 的延伸：P8 只认建分片目录失败），最终报 `storageExhausted`，
///    宿主据此收小窗口原位重开，而不是当成「解不了」换播放器。
/// 另有两个测试钩子，用来在模拟器上复现「手机存储快满」与「播放中被写满」。
extension AetherEngine {
    /// 测试用：假装临时目录所在的卷只剩这么多字节（nil = 读真实值）。分片留存预算、片源字节缓存预算、
    /// 软件通路读前缓存预算都按它算
    public nonisolated(unsafe) static var volumeAvailableBytesOverrideForTesting: Int64?

    /// 测试用：在这个系统运行时刻（`ProcessInfo.systemUptime`）之前，写分片一律按 ENOSPC 失败
    public nonisolated(unsafe) static var simulateStorageFullUntilUptimeForTesting: TimeInterval?

    /// 临时目录所在卷的可用字节（测试覆盖优先）。`importantUsage` 沿用各处原来的读法：iOS 上分片与
    /// 片源缓存按「重要用途可用」（含系统可清掉的空间）算，tvOS 没有这个键，一律按普通可用。
    ///
    /// [MovieClaw P44] 带 10 秒缓存：「重要用途可用」在真机上每次约 17 毫秒，起播一次要查好几回——宿主定落盘计划、
    /// 分片留存预算（在会话启动的关键路径上）、片源字节缓存预算（持着缓存的锁），片刻之间剩余空间变不了多少。
    /// 宿主在点播放时从后台先查一次，后面几处都命中缓存
    public nonisolated static func temporaryVolumeAvailableBytes(importantUsage: Bool) -> Int64? {
        if let override = volumeAvailableBytesOverrideForTesting { return override }
        if let cached = VolumeAvailableCache.value(importantUsage: importantUsage) { return cached }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var bytes: Int64?
        #if !os(tvOS)
        if importantUsage {
            bytes = (try? temp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            VolumeAvailableCache.store(bytes, importantUsage: true)
            return bytes
        }
        #endif
        bytes = (try? temp.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        VolumeAvailableCache.store(bytes, importantUsage: importantUsage)
        return bytes
    }

    /// 测试钩子是否正在模拟「存储已满」
    nonisolated static var storageFullSimulated: Bool {
        guard let until = simulateStorageFullUntilUptimeForTesting else { return false }
        return ProcessInfo.processInfo.systemUptime < until
    }
}

/// [MovieClaw P44] 最近一次查到的可用空间（两种口径各一份），10 秒内都算数。任何线程读写
nonisolated enum VolumeAvailableCache {
    static let maxAge: TimeInterval = 10
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [Bool: (bytes: Int64?, at: TimeInterval)] = [:]

    static func value(importantUsage: Bool) -> Int64?? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = values[importantUsage],
              ProcessInfo.processInfo.systemUptime - entry.at < maxAge else { return nil }
        return .some(entry.bytes)
    }

    static func store(_ bytes: Int64?, importantUsage: Bool) {
        lock.lock(); defer { lock.unlock() }
        values[importantUsage] = (bytes, ProcessInfo.processInfo.systemUptime)
    }
}
