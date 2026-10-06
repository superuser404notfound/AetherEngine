import Foundation
import Testing
@testable import AetherEngine

/// 片源字节缓存（引擎补丁 P22，`SourceByteCache`）：按偏移存、按连续覆盖取、大小对不上作废、超预算按最近使用淘汰。
/// 缓存给出的字节必须与写进去的逐字节一致——错一个字节就是花屏或解码失败。
struct SourceByteCacheTests {
    private let block = Int(SourceByteCache.blockSize)

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func read(_ cache: SourceByteCache, _ key: String, at offset: Int64, max: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        let n = buffer.withUnsafeMutableBufferPointer { cache.read(key: key, offset: offset, into: $0.baseAddress!, maxLen: max) }
        return Data(buffer.prefix(n))
    }

    @Test func servesExactlyWhatWasWrittenAcrossBlocks() {
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let key = "t-\(UUID())"
        // 从块中间开始、跨过两个块边界的一段
        let start = Int64(block / 2)
        let data = bytes(block * 2 + 1000, seed: 7)
        cache.write(key: key, offset: start, data: data)
        #expect(cache.contiguousEnd(key: key, from: start) == start + Int64(data.count))
        #expect(read(cache, key, at: start, max: data.count) == data)
        // 从中间任意位置读：给出的就是对应的那几个字节
        let mid = start + 12345
        #expect(read(cache, key, at: mid, max: 4096) == data.subdata(in: 12345 ..< 12345 + 4096))
        // 覆盖之外：不给（读取器转去问源站）
        #expect(read(cache, key, at: start - 1, max: 10).isEmpty)
        #expect(read(cache, key, at: start + Int64(data.count), max: 10).isEmpty)
        cache.purgeAll()
    }

    @Test func sequentialChunksMergeIntoOneRun() {
        // 网络按顺序一块块到：相连的写入合并成连续覆盖，读的时候一次给到尾
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let key = "t-\(UUID())"
        let whole = bytes(block + 50_000, seed: 3)
        var offset = 0
        for size in [16_384, 65_536, 300_000, whole.count - 16_384 - 65_536 - 300_000] {
            cache.write(key: key, offset: Int64(offset), data: whole.subdata(in: offset ..< offset + size))
            offset += size
        }
        #expect(cache.contiguousEnd(key: key, from: 0) == Int64(whole.count))
        #expect(read(cache, key, at: 0, max: whole.count) == whole)
        cache.purgeAll()
    }

    @Test func gapStopsTheRun() {
        // 中间有洞：连续覆盖到洞前为止，洞后面的另算
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let key = "t-\(UUID())"
        cache.write(key: key, offset: 0, data: bytes(100_000, seed: 1))
        cache.write(key: key, offset: Int64(block) * 3, data: bytes(100_000, seed: 2))
        #expect(cache.contiguousEnd(key: key, from: 0) == 100_000)
        #expect(read(cache, key, at: 50_000, max: 200_000).count == 50_000)
        #expect(read(cache, key, at: Int64(block) * 3, max: 10) == bytes(10, seed: 2))
        cache.purgeAll()
    }

    @Test func headAndTailCopiesForReopen() {
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let key = "t-\(UUID())"
        let head = bytes(200_000, seed: 9)
        cache.write(key: key, offset: 0, data: head)
        #expect(cache.copy(key: key, offset: 0, length: 100_000) == head.prefix(100_000))
        // 要的比缓存里有的长：不给半截
        #expect(cache.copy(key: key, offset: 0, length: 300_000) == nil)
        cache.purgeAll()
    }

    @Test func sizeMismatchDropsTheSource() {
        // 连接报的文件大小与缓存记的对不上：源站上的文件换过了，已缓存的字节整份作废
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let key = "t-\(UUID())"
        cache.noteContentLength(key: key, length: 1_000_000)
        cache.write(key: key, offset: 0, data: bytes(4096, seed: 4))
        cache.noteContentLength(key: key, length: 1_000_000)
        #expect(cache.contiguousEnd(key: key, from: 0) == 4096)
        cache.noteContentLength(key: key, length: 2_000_000)
        #expect(cache.contiguousEnd(key: key, from: 0) == 0)
        #expect(cache.contentLength(key: key) == 2_000_000)
        cache.purgeAll()
    }

    @Test func evictsLeastRecentlyUsedBlocksOverBudget() {
        // 预算 4 块：写满 6 块后丢最久没用的，只剩预算九成以内
        let cache = SourceByteCache(budgetBytes: Int64(block) * 4)
        let key = "t-\(UUID())"
        for index in 0 ..< 6 {
            cache.write(key: key, offset: Int64(block * index), data: bytes(block, seed: UInt8(index)))
        }
        #expect(cache.cachedBytes <= Int64(block) * 4)
        // 最早写的块没了，最新写的还在、内容不变
        #expect(read(cache, key, at: 0, max: 10).isEmpty)
        #expect(read(cache, key, at: Int64(block * 5), max: block) == bytes(block, seed: 5))
        cache.purgeAll()
    }

    @Test func emptiedSourcesAreDropped() {
        // 预算 3 块：旧片源的 2 块被新片源的 2 块挤光后，整条删掉（不留空条目占着文件句柄）
        let cache = SourceByteCache(budgetBytes: Int64(block) * 3)
        let old = "t-\(UUID())", new = "t-\(UUID())"
        cache.noteContentLength(key: old, length: 10 << 20)
        cache.write(key: old, offset: 0, data: bytes(block * 2, seed: 1))
        cache.write(key: new, offset: 0, data: bytes(block * 2, seed: 2))
        #expect(cache.contentLength(key: old) == nil)
        #expect(read(cache, new, at: 0, max: block * 2) == bytes(block * 2, seed: 2))
        cache.purgeAll()
    }

    @Test func rebindingAKeyForgetsTheOldToken() {
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let first = URL(string: "http://nas:3000/api/v1/playback/files/7/stream?token=a")!
        let second = URL(string: "http://nas:3000/api/v1/playback/files/7/stream?token=b")!
        cache.bind(url: first, key: "file-7-100")
        cache.bind(url: second, key: "file-7-100")
        #expect(cache.key(for: second) == "file-7-100")
        #expect(cache.key(for: first) == nil)
        cache.purgeAll()
    }

    /// P32：共享实例的写盘在后台队列上做，写完即返回；落盘后照样读得到、超预算照样淘汰
    @Test func backgroundWritesLandAndEvict() {
        let block = Int(SourceByteCache.blockSize)
        let cache = SourceByteCache(budgetBytes: Int64(block) * 4, asynchronous: true)
        let key = "async"
        for index in 0 ..< 6 {
            cache.write(key: key, offset: Int64(block * index), data: bytes(block, seed: UInt8(index)))
        }
        cache.drain()
        #expect(cache.cachedBytes <= Int64(block) * 4)
        // 最新写的那块还在
        #expect(read(cache, key, at: Int64(block * 5), max: block) == bytes(block, seed: 5))
        // 最早的已被淘汰
        #expect(read(cache, key, at: 0, max: block).isEmpty)
    }

    @Test func keysBindPerURL() {
        // 每个地址各自登记到自己的键上（原盘目录每个文件一个）
        let cache = SourceByteCache(budgetBytes: 64 << 20)
        let first = URL(string: "http://nas:3000/api/v1/playback/files/7/stream?token=a")!
        let second = URL(string: "http://nas:3000/api/v1/playback/files/7/stream?token=b")!
        let disc = URL(string: "http://nas:3000/api/v1/playback/files/9/disc/BDMV/STREAM/00001.m2ts?token=a")!
        cache.bind(url: first, key: "file-7-100")
        cache.bind(url: disc, key: "file-9-200/BDMV/STREAM/00001.m2ts")
        #expect(cache.key(for: first) == "file-7-100")
        #expect(cache.key(for: disc) == "file-9-200/BDMV/STREAM/00001.m2ts")
        #expect(cache.key(for: second) == nil)
        #expect(cache.key(for: URL(string: "http://nas:3000/other")!) == nil)
        cache.purgeAll()
        #expect(cache.key(for: first) == nil)
    }

    // MARK: - P46 元数据区后淘汰

    @Test func metadataBlocksOutliveThePlayback() {
        // 文件头、文件尾（moov / Cues 所在）打开时读一次，之后顺序播放写了一大段：超预算先丢播放的旧块，头尾留着给下次续播
        let cache = SourceByteCache(budgetBytes: Int64(block) * 8)
        let key = "t-\(UUID())"
        let length = Int64(block) * 200
        cache.noteContentLength(key: key, length: length)
        cache.write(key: key, offset: 0, data: bytes(block, seed: 1))
        cache.write(key: key, offset: length - Int64(block), data: bytes(block, seed: 2))
        for index in 50 ..< 62 {
            cache.write(key: key, offset: Int64(block * index), data: bytes(block, seed: UInt8(index)))
        }
        #expect(read(cache, key, at: 0, max: 10) == bytes(10, seed: 1))
        #expect(read(cache, key, at: length - Int64(block), max: 10) == bytes(10, seed: 2))
        #expect(read(cache, key, at: Int64(block * 50), max: 10).isEmpty)
        #expect(read(cache, key, at: Int64(block * 61), max: 10) == bytes(10, seed: 61))
        cache.purgeAll()
    }

    @Test func metadataShareIsCapped() {
        // 元数据区也不能无限占（最多预算四分之一，至少一个片源的头尾 40 块）：六部旧片的文件头共 48 块，
        // 再播一部把总量推过预算时，先按最近使用丢最旧那部的文件头
        let cache = SourceByteCache(budgetBytes: Int64(block) * 48)
        let length = Int64(block) * 400
        let old = (0 ..< 6).map { _ in "t-\(UUID())" }
        for (index, key) in old.enumerated() {
            cache.noteContentLength(key: key, length: length)
            cache.write(key: key, offset: 0, data: Data(repeating: UInt8(index + 1), count: block * 8))
        }
        let playing = "t-\(UUID())"
        cache.noteContentLength(key: playing, length: length)
        for index in 100 ..< 102 {
            cache.write(key: playing, offset: Int64(block * index), data: Data(repeating: 0xAA, count: block))
        }
        #expect(read(cache, old[0], at: 0, max: 10).isEmpty)
        #expect(read(cache, old[1], at: 0, max: 10) == Data(repeating: 2, count: 10))
        #expect(read(cache, playing, at: Int64(block * 101), max: 10) == Data(repeating: 0xAA, count: 10))
        #expect(cache.cachedBytes <= Int64(block) * 48)
        cache.purgeAll()
    }

    // MARK: - P42 跨启动保留

    /// 每个用例一个空目录，模拟 Caches 下的缓存目录。上一场的实例要留到用例结束（实例释放时会删掉它开着的片源，
    /// 真机上共享实例活到进程退出，不会走到那一步）
    private func persistentDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p42-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// [MovieClaw P50] 尾部预读先写了文件最后 64 KB，moov / 索引再从最后一块的中间顺序写过来：原来每一小段都
    /// 「比已记的短」被丢账，下次打开整块重下（真机 12 部里 7 部）。现在暂记着，接上尾部那段就并成一整段
    @Test func tailFirstThenSequentialStreamKeepsTheWholeBlock() {
        let dir = persistentDir()
        let key = "file-9-\(UUID())"
        let length = Int64(block) * 3 + 700_000
        let lastBlock = Int64(block) * 3
        let tail = bytes(65_536, seed: 21)
        let previous = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: length)
        previous.write(key: key, offset: length - 65_536, data: tail)
        // moov 从块中间某处（离文件尾 60 万字节）起，按 16 KB 一小段顺序写到文件尾
        let moovStart = length - 600_000
        let moov = bytes(600_000, seed: 22)
        var offset = 0
        while offset < moov.count {
            let size = min(16_384, moov.count - offset)
            previous.write(key: key, offset: moovStart + Int64(offset), data: moov.subdata(in: offset ..< offset + size))
            offset += size
        }
        #expect(previous.contiguousEnd(key: key, from: moovStart) == length)
        #expect(read(previous, key, at: moovStart, max: moov.count) == moov)
        // 预算只算一次：并起来的一段，不重复计
        #expect(previous.cachedBytes == 600_000)
        // 跨启动也完整（落盘的只有主段，并完就是整段）
        previous.flushIndexes()
        previous.drain()
        let next = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        #expect(next.contiguousEnd(key: key, from: moovStart) == length)
        #expect(read(next, key, at: moovStart, max: moov.count) == moov)
        #expect(next.contiguousEnd(key: key, from: lastBlock) == lastBlock)   // 块头那段从没写过
        withExtendedLifetime(previous) {}
    }

    /// [MovieClaw P50] 同一块里两段一直没接上：读只认长的那段，暂记的那段算进预算，整块淘汰时一起扣掉
    @Test func spareRunIsAccountedAndEvictedWithItsBlock() {
        let cache = SourceByteCache(budgetBytes: Int64(block) * 4)
        let key = "t-\(UUID())"
        cache.write(key: key, offset: 0, data: bytes(300_000, seed: 31))
        cache.write(key: key, offset: 500_000, data: bytes(100_000, seed: 32))
        #expect(cache.contiguousEnd(key: key, from: 0) == 300_000)
        #expect(cache.contiguousEnd(key: key, from: 500_000) == 500_000)   // 暂记的不给读
        #expect(cache.cachedBytes == 400_000)
        // 再写 6 块把第 0 块挤掉：两段一起扣
        for index in 1 ... 6 {
            cache.write(key: key, offset: Int64(block) * Int64(index), data: bytes(block, seed: UInt8(index)))
        }
        #expect(cache.contiguousEnd(key: key, from: 0) == 0)
        #expect(cache.cachedBytes <= Int64(block) * 4)
        #expect(cache.cachedBytes % Int64(block) == 0)
        cache.purgeAll()
    }

    @Test func survivesRelaunch() {
        // 上一场下过的文件头、大小，下一场（新实例 = App 重启）原样拿到，一个请求都不用发
        let dir = persistentDir()
        let key = "file-7-\(UUID())"
        let data = bytes(block * 2 + 5000, seed: 11)
        let previous = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: 50 << 20)
        previous.write(key: key, offset: 0, data: data)
        previous.flushIndexes()
        previous.drain()
        let next = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        #expect(next.contentLength(key: key) == 50 << 20)
        #expect(next.contiguousEnd(key: key, from: 0) == Int64(data.count))
        #expect(read(next, key, at: 0, max: data.count) == data)
        withExtendedLifetime(previous) {}
    }

    @Test func evictedBlocksNeverComeBackAsZeros() {
        // 淘汰打了洞的块，下一场绝不能当成还在（读出全零就是花屏）：淘汰时先写记账再打洞
        let dir = persistentDir()
        let key = "file-8-\(UUID())"
        let previous = SourceByteCache(budgetBytes: Int64(block) * 4, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: 100 << 20)
        for index in 0 ..< 8 {
            previous.write(key: key, offset: Int64(block * index), data: bytes(block, seed: UInt8(index)))
        }
        previous.drain()
        let next = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        var claimed = 0
        for index in 0 ..< 8 {
            let got = read(next, key, at: Int64(block * index), max: block)
            guard !got.isEmpty else { continue }
            claimed += 1
            #expect(got == bytes(block, seed: UInt8(index)).prefix(got.count))
        }
        #expect(claimed > 0)
        // 最早写的那块早被淘汰了
        #expect(read(next, key, at: 0, max: 10).isEmpty)
        withExtendedLifetime(previous) {}
    }

    @Test func corruptIndexIsIgnored() throws {
        // 记账写坏了（或键对不上）：不认，当新片源重下
        let dir = persistentDir()
        let key = "file-9-\(UUID())"
        let previous = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: 10 << 20)
        previous.write(key: key, offset: 0, data: bytes(100_000, seed: 5))
        previous.flushIndexes()
        previous.drain()
        let idx = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix(".idx") })
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(idx))
        let next = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        #expect(next.contentLength(key: key) == nil)
        #expect(next.contiguousEnd(key: key, from: 0) == 0)
        withExtendedLifetime(previous) {}
    }

    @Test func changedSourceDropsPersistedBytes() {
        // 下一场连接报的大小对不上：源站上的文件换过了，上一场留下的整份作废
        let dir = persistentDir()
        let key = "file-10-\(UUID())"
        let previous = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: 1_000_000)
        previous.write(key: key, offset: 0, data: bytes(4096, seed: 6))
        previous.flushIndexes()
        previous.drain()
        let next = SourceByteCache(budgetBytes: 64 << 20, persistentDirectory: dir)
        #expect(next.contiguousEnd(key: key, from: 0) == 4096)
        next.noteContentLength(key: key, length: 2_000_000)
        #expect(next.contiguousEnd(key: key, from: 0) == 0)
        #expect(next.contentLength(key: key) == 2_000_000)
        withExtendedLifetime(previous) {}
    }

    /// [MovieClaw P51] 启动整理超额时先缩：看了一会儿的高码率片，下次启动文件头、文件尾还在（续播一打开就要读），
    /// 中间的按最近使用从旧到新丢、丢够超额就停，最后看到的那一块（续播点附近）留着；原来整条删，续播全部重下
    @Test func launchTrimShrinksAnOversizedSourceKeepingMetadata() {
        let dir = persistentDir()
        let key = "file-3-\(UUID())"
        let length = Int64(block) * 64   // 64 MiB：头 8 块、尾 32 块是元数据区，第 8～31 块不是
        let previous = SourceByteCache(budgetBytes: Int64(block) * 128, persistentDirectory: dir)
        previous.noteContentLength(key: key, length: length)
        previous.write(key: key, offset: 0, data: bytes(block * 2, seed: 5))                  // 文件头
        let middle = bytes(block * 8, seed: 6)   // 续播点那一段：像网络送达那样一块一块写，最近使用依次变新
        for index in 0 ..< 8 {
            previous.write(key: key, offset: Int64(block) * Int64(16 + index),
                           data: middle.subdata(in: block * index ..< block * (index + 1)))
        }
        previous.write(key: key, offset: length - Int64(block), data: bytes(block, seed: 7))  // 文件尾
        previous.flushIndexes()
        previous.drain()
        // 下次启动：保留上限是运行预算的一半（4 块），这一份 11 块超了
        let launch = SourceByteCache(budgetBytes: Int64(block) * 8, persistentDirectory: dir)
        launch.trimPersisted()
        #expect(launch.contiguousEnd(key: key, from: 0) == Int64(block) * 2)
        #expect(read(launch, key, at: 0, max: 100) == bytes(100, seed: 5))
        #expect(launch.contiguousEnd(key: key, from: length - Int64(block)) == length)
        #expect(read(launch, key, at: length - Int64(block), max: 100) == bytes(100, seed: 7))
        // 中间 8 块超额 7 块：最早写的 7 块丢掉，最后写的第 23 块（续播点附近）留着
        #expect(launch.contiguousEnd(key: key, from: Int64(block) * 16) == Int64(block) * 16)
        #expect(launch.contiguousEnd(key: key, from: Int64(block) * 23) == Int64(block) * 24)
        #expect(read(launch, key, at: Int64(block) * 23, max: 100) == middle.subdata(in: block * 7 ..< block * 7 + 100))
        #expect(launch.cachedBytes == Int64(block) * 4)
        withExtendedLifetime(previous) {}
    }

    @Test func launchTrimRemovesOrphansAndOldestOverBudget() throws {
        // 启动整理：只有数据没有记账的删掉；保留总量（运行预算的一半 = 2 块）超了，按最近使用删旧的
        let dir = persistentDir()
        let fm = FileManager.default
        fm.createFile(atPath: dir.appendingPathComponent("orphan.bin").path, contents: Data(count: 10))
        let previous = SourceByteCache(budgetBytes: Int64(block) * 4, persistentDirectory: dir)
        let old = "file-1-\(UUID())", new = "file-2-\(UUID())"
        for (key, seed) in [(old, UInt8(1)), (new, UInt8(2))] {
            previous.noteContentLength(key: key, length: 50 << 20)
            previous.write(key: key, offset: 0, data: bytes(block * 2, seed: seed))
        }
        previous.flushIndexes()
        previous.drain()
        let idxNames = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }
        #expect(idxNames.count == 2)
        let oldIdx = try #require(idxNames.first { name in
            let data = try? Data(contentsOf: dir.appendingPathComponent(name))
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return object?["key"] as? String == old
        })
        // 旧片源一小时前用过，新片源刚用过
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                             ofItemAtPath: dir.appendingPathComponent(oldIdx).path)
        // 下次启动时的整理（新实例，没有正开着的片源）
        let launch = SourceByteCache(budgetBytes: Int64(block) * 4, persistentDirectory: dir)
        launch.trimPersisted()
        let left = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(!left.contains("orphan.bin"))
        #expect(!left.contains(oldIdx))
        #expect(left.filter { $0.hasSuffix(".idx") }.count == 1)
        #expect(launch.contentLength(key: new) == 50 << 20)
        withExtendedLifetime(previous) {}
    }
}
