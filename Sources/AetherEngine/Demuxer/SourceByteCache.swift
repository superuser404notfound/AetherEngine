import CryptoKit
import Darwin
import Foundation

/// [MovieClaw P22] 片源字节缓存：同一场播放里，同一个片源的每个字节只从源站下一次。
///
/// ## 为什么要有
/// 引擎里好几条路径会重读已经下过的字节，每条都要再找源站要一遍：
/// - 换音轨、回前台、出错恢复都是整场重建（`reloadWithAudioOverride`），攒好的前向缓冲整段作废；
///   MP4 还要把文件尾的索引（大片几十 MB）再下一遍；
/// - 往回跳进分片缓存的连续段、段后是空档时，生产者从跳转目标重启，已缓存那几段的源字节再读一遍；
/// - 软件通路往后跳会丢掉历史，跳回看过的位置重下；
/// - 画中画的字幕旁路是第二条连接，在 MKV / TS 上把音视频字节再下一遍。
/// 2026-09-28 模拟器实测：MKV 换一次音轨多下约 35 秒的量（61 MB），UHD 原盘往回跳多下 460 MB。
///
/// ## 怎么做
/// `AVIOReader` 从网络收到的每一块都按文件偏移写进这里（本机临时目录里的稀疏文件），读的时候窗口
/// 给不了就先查这里；重新打开时缓存里已有文件头就当预热数据接管、一个请求都不发，读到缓存没有的
/// 位置才按那个位置连源站（读取循环本来就这样做）。换音轨后从播放点重读的整段前向缓冲、MP4 索引、
/// 回跳重产的那几段，都直接从本机拿。
///
/// ## 键
/// 取流地址每次都带新令牌，不能拿地址当键。主机在装载时给一个稳定的键（`LoadOptions.sourceCacheKey`，
/// MovieClaw 用「文件 id + 大小」），引擎把本次地址登记到这个键上（`bind`），之后打开同一地址的所有
/// 读取者（探测、播放、重建、字幕旁路）都落到同一份缓存。连接报的文件大小与缓存记的对不上，说明源站
/// 上的文件换过了，整份作废。
///
/// ## 预算与清理
/// 全进程共用一个预算，默认 min(1 GiB, 临时目录可用空间的 1/8)，每来一个新片源按当时的可用空间重算。按 1 MiB
/// 的块记最近使用，超了先丢最久没用的块（在稀疏文件上打洞，空间立刻还回去），丢到预算的九成为止，块丢光的片源
/// 整条删掉。关掉播放器不清：退出再进同一部片、断线重连换了引擎实例，续播点附近都直接从本机起播。
///
/// ## [MovieClaw P42] 跨启动保留：续播从本机起播
/// 原来 App 每次启动都把上次的缓存清掉（记账只在内存里，文件内容无从核对）。可真实使用里续播占七成多
/// （2026-09-30 NAS 播放记录），续播要读的正是上一场下过的字节：文件头、索引（MP4 的 moov、MKV 的 Cues）、
/// 续播点所在的那一段。现在共享实例落在 Caches 目录，每个片源两个文件，按键的哈希命名：`.bin` 是稀疏数据，
/// `.idx` 是记账（文件大小与每块的连续覆盖）。记账随写入在后台队列上防抖落盘；淘汰时先落记账、再打洞——
/// 记账永远不会说一块在、数据却已被打了洞（读出全零就是花屏）；写记账之前先对数据文件做写屏障同步，突然断电也不会
/// 认下还没落到闪存的块。进程被杀时记账最多落后几秒，只会少认几块，不会多认。
/// 某个片源第一次被访问时按需从磁盘恢复（连接报的文件大小对不上照样整份作废）；App 启动时 `sweep` 整理一次：
/// 删孤儿文件、30 天没用过的，总量超过保留预算时按最近使用整条删。测试自建的实例不落盘（与原来一样用临时目录）。
///
/// ## [MovieClaw P32] 写盘与淘汰在后台串行队列上做
/// 读取器收到网络数据后调 `write`，原来是当场 `pwrite` 进稀疏文件、超预算时当场逐块打洞，全程持锁、占着取数线程。
/// 真机实测（2026-09-29，iPhone Air）：缓冲外跳转后第一次写缓存要 1.2～2.6 秒——跳到几个 GB 之外，稀疏文件第一次在远处
/// 落盘很慢——这段时间取数线程一直等着，跳转因此多等 1～2.6 秒（UHD 原盘 +600 秒跳转 3.8 秒里的 2.6 秒）。
/// 缓存只是加速，写晚一点不影响对错，所以共享实例改成：`write` 只把数据交给后台串行队列就返回；落盘、记账、超预算淘汰都在
/// 队列上做，而且淘汰只在记账时持锁（从账上删掉），打洞放在锁外。读者看不到还没落盘的块，照常走网络；被淘汰的块先从账上删
/// 再打洞，同一队列上后来的写入排在打洞之后，不会被误清。积压超过 `maxPendingBytes` 时新写入直接不缓存，内存不会堆起来。
final class SourceByteCache: @unchecked Sendable {

    static let shared = SourceByteCache(
        asynchronous: true, persistentDirectory: AetherEngine.persistsSourceByteCache ? persistentRoot : nil)

    /// 记账与淘汰的粒度。每块只记一段连续覆盖（网络数据按顺序到，够用；零散写入不连续时以新的为准）
    static let blockSize: Int64 = 1 << 20

    /// 不落盘的实例（测试自建的）放这里；P42 之前共享实例也在这里，`sweep` 顺手清掉旧版留下的
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-bytecache", isDirectory: true)
    }

    /// [MovieClaw P42] 跨启动保留的共享缓存放 Caches：系统存储紧张时可以回收，不进备份
    static var persistentRoot: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("aether-bytecache", isDirectory: true)
    }

    /// [MovieClaw P42] 记账多久落一次盘（写入之后）。进程被杀最多丢这么久的记账：只会少认几块，不会多认。
    /// 每次落盘前要对数据文件做写屏障同步（见 `flushIndexOnQueue`），所以不必太勤；App 进后台时另有一次立即落盘
    static let indexFlushDelay: TimeInterval = 5

    private struct Block {
        var lo: Int64
        var hi: Int64
        var lastUse: UInt64
    }

    /// [MovieClaw P42] `.idx` 里存的记账：块号、覆盖起止、最近使用（只用来排新旧）
    private struct IndexFile: Codable {
        var version = 1
        var key: String
        var contentLength: Int64?
        var blocks: [[Int64]]
    }

    private final class Entry {
        let key: String
        let fd: Int32
        let path: String
        /// [MovieClaw P42] 落盘的记账文件；nil = 不落盘（测试实例）
        let indexPath: String?
        var contentLength: Int64?
        var blocks: [Int64: Block] = [:]
        /// [MovieClaw P50] 每块另记的一段（与 `blocks` 那段不相连、数据已经写进文件），只在内存里：
        /// 尾部预读先占了块尾，moov / 索引再从块中间顺序写过来时，原来每一小段都因「比已记的短」被丢账，
        /// 下次打开整块得重下。暂记在这里，长到与主段相接就并进去，比主段长就互换
        var spare: [Int64: (lo: Int64, hi: Int64)] = [:]
        /// [MovieClaw P42] 记账有没落盘的变化、是否已排了落盘
        var indexDirty = false
        var indexFlushScheduled = false
        /// [MovieClaw P42] 被淘汰动过几次：落盘分两步（锁外同步数据、锁里写记账），中间被淘汰过就放弃这份快照
        var evictionGeneration: UInt64 = 0

        init(key: String, fd: Int32, path: String, indexPath: String?) {
            self.key = key
            self.fd = fd
            self.path = path
            self.indexPath = indexPath
        }

        deinit {
            // 整份作废（淘汰光了、源站文件换了）才会走到这里：数据与记账一起删。进程退出时不会走到，文件留给下次
            close(fd)
            unlink(path)
            if let indexPath { unlink(indexPath) }
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// 本次取流地址（含令牌）→ 键
    private var keysByURL: [String: String] = [:]
    private var useClock: UInt64 = 0
    private var totalBytes: Int64 = 0
    private var budgetBytes: Int64?
    /// 临时目录建不出来 / 写失败过：本进程不再缓存（照常走网络，不影响播放）
    private var disabled = false

    /// 测试给定的预算；nil = 按可用空间算（`budgetLocked`）
    private let fixedBudget: Int64?

    /// [MovieClaw P32] 写盘与淘汰放到后台串行队列（共享实例默认开；测试自建的实例默认同步，写完即可读）。
    /// 宿主可在装载前关掉（真机新旧对照用）
    var asynchronous: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _asynchronous }
        set { lock.lock(); _asynchronous = newValue; lock.unlock() }
    }
    private var _asynchronous: Bool
    private let ioQueue = DispatchQueue(label: "aether.source-byte-cache.io", qos: .utility)
    /// 已交给后台队列、还没落盘的字节
    private var pendingBytes = 0
    static let maxPendingBytes = 64 << 20

    /// [MovieClaw P42] 跨启动保留的目录；nil = 不落盘（测试自建的实例，文件在临时目录、随实例删掉）
    private let persistentDirectory: URL?

    init(budgetBytes: Int64? = nil, asynchronous: Bool = false, persistentDirectory: URL? = nil) {
        self.fixedBudget = budgetBytes
        self._asynchronous = asynchronous
        self.persistentDirectory = persistentDirectory
    }

    /// 等后台队列上已交出的写入都落完盘（测试用）
    func drain() {
        ioQueue.sync {}
    }

    /// [MovieClaw P39] 已交给后台队列、还没落盘的字节数：范围预取成段写入前据此限流，
    /// 免得积压超过 `maxPendingBytes` 被直接丢弃
    var pendingWriteBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingBytes
    }
    #if DEBUG
    /// 开发期统计：累计写入 / 从缓存供出的字节，每 5 秒打一行（核对换轨、回跳到底省了多少）
    private var debugWritten: Int64 = 0
    private var debugServed: Int64 = 0
    private var debugLastLog = Date.distantPast

    private func debugTallyLocked(written: Int64 = 0, served: Int64 = 0) {
        debugWritten += written
        debugServed += served
        guard Date().timeIntervalSince(debugLastLog) >= 5 else { return }
        debugLastLog = Date()
        EngineLog.emit("[SourceByteCache] [MovieClaw P22] written \(debugWritten >> 20) MB, "
                       + "served from cache \(debugServed >> 20) MB, resident \(totalBytes >> 20) MB",
                       category: .demux)
    }
    #endif

    // MARK: 键

    /// 把本次地址登记到稳定的键上；键为 nil 时撤销登记（这个地址不缓存）。
    /// 同一个键以前登记过的旧地址（旧令牌）一并忘掉：已经打开的读取者在初始化时就取走了键，不受影响
    func bind(url: URL, key: String?) {
        lock.lock(); defer { lock.unlock() }
        if let key {
            for (old, bound) in keysByURL where bound == key && old != url.absoluteString {
                keysByURL.removeValue(forKey: old)
            }
        }
        keysByURL[url.absoluteString] = key
    }

    func key(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keysByURL[url.absoluteString]
    }

    // MARK: 读写

    /// 网络收到的一块，按它在文件里的偏移记下。共享实例（P32）交给后台队列就返回，不在调用方线程上等磁盘
    func write(key: String, offset: Int64, data: Data) {
        guard !data.isEmpty, offset >= 0 else { return }
        lock.lock()
        guard _asynchronous else {
            defer { lock.unlock() }
            guard !disabled, let entry = entryLocked(key) else { return }
            let written = Self.pwriteAll(entry.fd, data, offset)
            guard written else {
                failWriteLocked(key)
                return
            }
            recordWriteLocked(entry: entry, offset: offset, count: data.count)
            Self.apply(evictOverBudgetLocked())
            return
        }
        guard !disabled, pendingBytes + data.count <= Self.maxPendingBytes, let entry = entryLocked(key) else {
            lock.unlock()
            return
        }
        pendingBytes += data.count
        lock.unlock()
        ioQueue.async { [self] in
            let written = Self.pwriteAll(entry.fd, data, offset)
            lock.lock()
            pendingBytes -= data.count
            // 落盘期间这份被作废了（源站文件换了、播放器清了缓存）：不再记账
            guard entries[key] === entry else {
                lock.unlock()
                return
            }
            guard written else {
                failWriteLocked(key)
                lock.unlock()
                return
            }
            recordWriteLocked(entry: entry, offset: offset, count: data.count)
            let eviction = evictOverBudgetLocked()
            lock.unlock()
            // 打洞在锁外：块已从账上删掉，读者不会再读它们；同一队列上后来的写入排在这之后。
            // 落盘的记账先于打洞写好（P42）
            Self.apply(eviction)
        }
    }

    private static func pwriteAll(_ fd: Int32, _ data: Data, _ offset: Int64) -> Bool {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return pwrite(fd, base, data.count, off_t(offset))
        }
        return written == data.count
    }

    /// 写失败（多半是磁盘满了）：这份作废，本进程不再缓存。调用方持锁
    private func failWriteLocked(_ key: String) {
        EngineLog.emit("[SourceByteCache] [MovieClaw P22] write failed (errno=\(errno)); caching off",
                       category: .demux)
        disabled = true
        dropLocked(key)
    }

    /// 记账：这一段已经落盘。调用方持锁
    private func recordWriteLocked(entry: Entry, offset: Int64, count dataCount: Int) {
        useClock += 1
        #if DEBUG
        debugTallyLocked(written: Int64(dataCount))
        #endif
        var cursor = offset
        let end = offset + Int64(dataCount)
        while cursor < end {
            let index = cursor / Self.blockSize
            let blockEnd = min(end, (index + 1) * Self.blockSize)
            let before = coveredLocked(entry, block: index)
            // [MovieClaw P50] 新写的这段、已记的主段、暂记的另一段：相接或重叠的并成一段，最长的当主段（读、落盘都只认它），
            // 次长的留作暂记，再短的丢账（数据还在文件里，只是不认）
            var ranges: [(lo: Int64, hi: Int64)] = [(cursor, blockEnd)]
            if let block = entry.blocks[index] { ranges.append((block.lo, block.hi)) }
            if let spare = entry.spare[index] { ranges.append(spare) }
            ranges.sort { $0.lo < $1.lo }
            var merged: [(lo: Int64, hi: Int64)] = []
            for range in ranges {
                if let last = merged.last, range.lo <= last.hi {
                    merged[merged.count - 1].hi = max(last.hi, range.hi)
                } else {
                    merged.append(range)
                }
            }
            merged.sort { $0.hi - $0.lo > $1.hi - $1.lo }
            entry.blocks[index] = Block(lo: merged[0].lo, hi: merged[0].hi, lastUse: useClock)
            entry.spare[index] = merged.count > 1 && AetherEngine.sourceByteCacheKeepsSpareRuns ? merged[1] : nil
            totalBytes += coveredLocked(entry, block: index) - before
            cursor = blockEnd
        }
        markIndexDirtyLocked(entry)
    }

    /// [MovieClaw P50] 这一块记着的字节（主段加暂记的一段），算预算用。调用方持锁
    private func coveredLocked(_ entry: Entry, block index: Int64) -> Int64 {
        (entry.blocks[index].map { $0.hi - $0.lo } ?? 0) + (entry.spare[index].map { $0.hi - $0.lo } ?? 0)
    }

    /// 从 `offset` 起有多少连续缓存就读多少（至多 `maxLen`），返回读到的字节数；0 = 没有
    func read(key: String, offset: Int64, into dst: UnsafeMutablePointer<UInt8>, maxLen: Int) -> Int {
        guard maxLen > 0, offset >= 0 else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard let entry = existingEntryLocked(key) else { return 0 }
        let available = contiguousEndLocked(entry, from: offset) - offset
        guard available > 0 else { return 0 }
        let count = Int(min(Int64(maxLen), available))
        let got = pread(entry.fd, dst, count, off_t(offset))
        guard got > 0 else { return 0 }
        useClock += 1
        #if DEBUG
        debugTallyLocked(served: Int64(got))
        #endif
        var index = offset / Self.blockSize
        while index * Self.blockSize < offset + Int64(got) {
            entry.blocks[index]?.lastUse = useClock
            index += 1
        }
        return got
    }

    /// 从 `offset` 起连续缓存到哪里（不含）；没有缓存时就是 `offset`
    func contiguousEnd(key: String, from offset: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let entry = existingEntryLocked(key) else { return offset }
        return contiguousEndLocked(entry, from: offset)
    }

    /// 缓存里 [offset, offset + length) 完整时复制出来（打开时当预热的文件头 / 文件尾用）
    func copy(key: String, offset: Int64, length: Int) -> Data? {
        guard length > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = existingEntryLocked(key), contiguousEndLocked(entry, from: offset) >= offset + Int64(length) else {
            return nil
        }
        var data = Data(count: length)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return pread(entry.fd, base, length, off_t(offset))
        }
        return got == length ? data : nil
    }

    // MARK: 文件大小（校验缓存还是不是同一个文件）

    /// 连接报了文件大小：与缓存记的对不上就整份作废（源站上的文件换过了），然后记下这个大小
    func noteContentLength(key: String, length: Int64) {
        guard length > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if let known = existingEntryLocked(key)?.contentLength, known != length {
            EngineLog.emit("[SourceByteCache] [MovieClaw P22] \(key): size \(known)B -> \(length)B, "
                           + "the source changed; dropping its cached bytes", category: .demux)
            dropLocked(key)
        }
        guard !disabled, let entry = entryLocked(key) else { return }
        if entry.contentLength != length {
            entry.contentLength = length
            markIndexDirtyLocked(entry)
        }
    }

    func contentLength(key: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return existingEntryLocked(key)?.contentLength
    }

    // MARK: 清理

    /// 播放器关了：这一场的字节都不要了
    func purgeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        keysByURL.removeAll()
        totalBytes = 0
    }

    /// App 启动时调（后台线程）：清掉临时目录里不落盘的旧缓存（P42 之前共享实例也放那里），再整理跨启动保留的那份
    /// （`trimPersisted`）。清扫可能晚于刚开始的播放，所以本进程正开着的文件一律跳过
    static func sweep() {
        let live = shared.livePaths()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files {
            let path = directory.appendingPathComponent(name).path
            if !live.contains(path) { unlink(path) }
        }
        shared.trimPersisted()
    }

    private func livePaths() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.values.flatMap { [$0.path, $0.indexPath].compactMap { $0 } })
    }

    // MARK: - [MovieClaw P42] 跨启动保留

    /// 跨启动保留的总量上限：运行时预算的一半（默认 512 MiB）。上一场看的片子留得住续播点附近、文件头与索引就够了
    private var persistedBudgetBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return budgetLocked() / 2
    }

    /// 多久没用过的片源整条删
    static let persistedMaxAge: TimeInterval = 30 * 24 * 3600

    /// 整理跨启动保留的缓存（`sweep` 调，后台线程）：只有数据没有记账（或反过来）的删掉；太久没用的删掉；
    /// 总量超过保留上限时按记账最后一次落盘的时间从旧到新整条删。本进程正开着的跳过
    func trimPersisted() {
        guard let dir = persistentDirectory else { return }
        let live = livePaths()
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var stems: [String: (bin: Bool, idx: Bool)] = [:]
        for name in names {
            let url = URL(fileURLWithPath: name)
            let stem = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension {
            case "bin": stems[stem, default: (false, false)].bin = true
            case "idx": stems[stem, default: (false, false)].idx = true
            default: unlink(dir.appendingPathComponent(name).path)   // 写记账的临时文件等
            }
        }
        var complete: [(stem: String, usedAt: Date, bytes: Int64)] = []
        let now = Date()
        for (stem, has) in stems {
            let bin = dir.appendingPathComponent(stem + ".bin").path
            let idx = dir.appendingPathComponent(stem + ".idx").path
            guard !live.contains(bin), !live.contains(idx) else { continue }
            guard has.bin, has.idx else {
                unlink(bin); unlink(idx)
                continue
            }
            var info = stat()
            let usedAt = (try? fm.attributesOfItem(atPath: idx)[.modificationDate] as? Date) ?? .distantPast
            // 稀疏文件按实际占用算（st_blocks 以 512 字节计）
            let bytes = stat(bin, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
            if now.timeIntervalSince(usedAt) > Self.persistedMaxAge {
                unlink(bin); unlink(idx)
                continue
            }
            complete.append((stem, usedAt, bytes))
        }
        var total = complete.reduce(0) { $0 + $1.bytes }
        let budget = persistedBudgetBytes
        // [MovieClaw P51] 超了保留上限：先从旧到新缩——每份丢元数据区（P46 的文件头 8 MiB、文件尾 32 MiB——moov、Cues、
        // SeekHead 所在，续播一打开就要读）以外的块，按块的最近使用从旧到新丢，丢够超额就停（最近看到的那几分钟、也就是续播点
        // 附近的留着），缩完仍超才从旧到新整条删。原来直接整条删：看一会儿高码率片缓存就涨到几百 MB，
        // 超过上限（运行预算的一半，至多 512 MiB），下次启动这一份——正是要续播的那部——连头尾一起没了，续播又得全部重下
        // （真机：4K60 片热身 18 秒写了 398 MB，下次启动整理赶在装载之前跑完就整条删掉，开容器重下 10 MB 的 moov，415 毫秒）
        complete.sort { $0.usedAt < $1.usedAt }
        let before = total
        var shrunk = 0, dropped = 0
        if total > budget, AetherEngine.sourceByteCacheTrimKeepsMetadata {
            for i in complete.indices where total > budget {
                guard let after = shrinkIfNotLive(
                    bin: dir.appendingPathComponent(complete[i].stem + ".bin").path,
                    idx: dir.appendingPathComponent(complete[i].stem + ".idx").path,
                    usedAt: complete[i].usedAt, excess: total - budget) else { continue }
                total -= complete[i].bytes - after
                complete[i].bytes = after
                shrunk += 1
            }
        }
        for item in complete where total > budget {
            unlink(dir.appendingPathComponent(item.stem + ".bin").path)
            unlink(dir.appendingPathComponent(item.stem + ".idx").path)
            total -= item.bytes
            dropped += 1
        }
        if shrunk + dropped > 0 {
            EngineLog.emit(
                "[SourceByteCache] [MovieClaw P51] 启动整理：跨启动缓存 \(before >> 20) MB 超过上限 \(budget >> 20) MB，"
                + "\(shrunk) 份缩小（文件头尾留着）、\(dropped) 份整条删，剩 \(total >> 20) MB", category: .demux)
        }
    }

    /// [MovieClaw P51] 持锁缩：装载时的恢复（`restoreLocked`）也在这把锁里，两者不会交错——先缩完的，恢复读到的就是缩过的
    /// 记账；先恢复的，这里看到它已经开着就不动。不能只靠开头取的「正开着」快照：整理在后台线程上跑，与第一次装载几乎同时，
    /// 恢复要是落在快照之后、打洞之前，恢复出来的那份会把刚打成洞的块当成数据，读出全零（整条删没有这个问题：已打开的文件删了照样能读）
    private func shrinkIfNotLive(bin: String, idx: String, usedAt: Date, excess: Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard !entries.values.contains(where: { $0.path == bin }) else { return nil }
        return Self.shrinkKeepingMetadata(bin: bin, idx: idx, usedAt: usedAt, excess: excess)
    }

    /// [MovieClaw P51] 缩一份跨启动缓存：元数据区以外的块按最近使用从旧到新丢，丢够 `excess` 字节就停。先写缩过的记账
    /// （保留原来的修改时间，新旧次序不变），再给丢掉的块打洞——同淘汰，记账先于打洞，进程在中间被杀也只是少认几块。
    /// 返回缩完的实际占用；记账读不出、不知道文件大小（算不出文件尾）、本来就只有元数据区的，返回 nil 不动
    private static func shrinkKeepingMetadata(bin: String, idx: String, usedAt: Date, excess: Int64) -> Int64? {
        guard let data = FileManager.default.contents(atPath: idx),
              var file = try? JSONDecoder().decode(IndexFile.self, from: data), file.version == 1,
              let length = file.contentLength, length > 0 else { return nil }
        func isMetadata(_ row: [Int64]) -> Bool {
            guard row.count == 4 else { return false }
            return row[0] * blockSize < pinnedHeadBytes || (row[0] + 1) * blockSize > length - pinnedTailBytes
        }
        var dropped: [[Int64]] = []
        var freed: Int64 = 0
        // 最近使用相同（同一次写入的几块）时先丢文件里靠前的：续播点在后面的可能大
        for row in file.blocks.filter({ $0.count == 4 && !isMetadata($0) })
            .sorted(by: { $0[3] != $1[3] ? $0[3] < $1[3] : $0[0] < $1[0] }) {
            guard freed < excess else { break }
            dropped.append(row)
            freed += row[2] - row[1]
        }
        guard !dropped.isEmpty else { return nil }
        let droppedIndexes = Set(dropped.map { $0[0] })
        file.blocks = file.blocks.filter { $0.count == 4 && !droppedIndexes.contains($0[0]) }
        guard let encoded = try? JSONEncoder().encode(file) else { return nil }
        writeIndex(encoded, to: idx)
        try? FileManager.default.setAttributes([.modificationDate: usedAt], ofItemAtPath: idx)
        let fd = open(bin, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        for row in dropped where row.count == 4 && row[0] >= 0 {
            var range = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(row[0] * blockSize),
                                     fp_length: off_t(blockSize))
            _ = fcntl(fd, F_PUNCHHOLE, &range)
        }
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_blocks) * 512 : nil
    }

    /// 把还没落盘的记账都写下去（宿主在 App 进后台时调）。在后台队列上排队，排在已交出的写入之后
    func flushIndexes() {
        ioQueue.async { [self] in
            lock.lock()
            let dirty = entries.values.filter { $0.indexDirty }
            lock.unlock()
            for entry in dirty { flushIndexOnQueue(entry) }
        }
    }

    /// 在后台队列上把一份的记账写下去，分两步：先在锁外对数据文件做写屏障同步，再在锁里核对这期间没被淘汰动过、
    /// 按此刻的账写记账。这样记账落到闪存时，它认的数据一定已经在闪存上——突然断电（或内核崩溃）之后也不会认下
    /// 还没写到闪存、读出来是全零的块。后台写盘模式下写入与淘汰都在这个队列上，两步之间账不会变；
    /// 同步写盘模式（调试开关）下别的线程可能在中间淘汰，淘汰时已写过新记账，这份快照放弃
    private func flushIndexOnQueue(_ entry: Entry) {
        lock.lock()
        guard entries[entry.key] === entry, entry.indexDirty, entry.indexPath != nil else {
            lock.unlock()
            return
        }
        let generation = entry.evictionGeneration
        entry.indexDirty = false
        lock.unlock()
        Self.barrierSync(entry.fd)
        lock.lock(); defer { lock.unlock() }
        guard entries[entry.key] === entry, entry.evictionGeneration == generation else { return }
        if let (path, data) = indexSnapshotLocked(entry) { Self.writeIndex(data, to: path) }
    }

    /// 数据先于记账落到闪存：APFS 的写屏障同步（比完整刷盘便宜），不支持时退回 fsync
    private static func barrierSync(_ fd: Int32) {
        if fcntl(fd, F_BARRIERFSYNC) == -1 { fsync(fd) }
    }

    /// 键 → 落盘文件名（不含扩展名）。键里有文件 id，不直接拿来当文件名
    private static func fileStem(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 记账变了：排一次防抖落盘（已经排了就不再排）。调用方持锁
    private func markIndexDirtyLocked(_ entry: Entry) {
        guard entry.indexPath != nil else { return }
        entry.indexDirty = true
        guard !entry.indexFlushScheduled else { return }
        entry.indexFlushScheduled = true
        ioQueue.asyncAfter(deadline: .now() + Self.indexFlushDelay) { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.lock.lock()
            entry.indexFlushScheduled = false
            self.lock.unlock()
            // 已经作废（整条删了、换成了新的一份）或已被别处写过的，`flushIndexOnQueue` 里不写
            self.flushIndexOnQueue(entry)
        }
    }

    /// 这一份的记账（路径 + 内容）。调用方持锁
    private func indexSnapshotLocked(_ entry: Entry) -> (String, Data)? {
        guard let path = entry.indexPath else { return nil }
        let file = IndexFile(
            key: entry.key, contentLength: entry.contentLength,
            blocks: entry.blocks.map { [$0.key, $0.value.lo, $0.value.hi, Int64(truncatingIfNeeded: $0.value.lastUse)] })
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        return (path, data)
    }

    /// 记账整份替换（先写临时文件再改名）：进程在中途被杀，留下的要么是旧的一份、要么是新的一份
    private static func writeIndex(_ data: Data, to path: String) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 某个片源第一次被访问：磁盘上有上一场留下的就接着用。调用方持锁
    private func existingEntryLocked(_ key: String) -> Entry? {
        if let entry = entries[key] { return entry }
        guard !disabled, let restored = restoreLocked(key) else { return nil }
        entries[key] = restored
        budgetBytes = nil
        return restored
    }

    /// 从 `.idx` / `.bin` 恢复一份。记账与键对不上、数据文件没了、块越界的一概不认。调用方持锁
    private func restoreLocked(_ key: String) -> Entry? {
        guard let dir = persistentDirectory else { return nil }
        let stem = Self.fileStem(for: key)
        let bin = dir.appendingPathComponent(stem + ".bin").path
        let idx = dir.appendingPathComponent(stem + ".idx").path
        guard let data = FileManager.default.contents(atPath: idx) else { return nil }
        guard let file = try? JSONDecoder().decode(IndexFile.self, from: data), file.version == 1, file.key == key else {
            unlink(idx); unlink(bin)
            return nil
        }
        let fd = open(bin, O_RDWR)
        guard fd >= 0 else {
            unlink(idx)
            return nil
        }
        var info = stat()
        let size: Int64 = fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
        let entry = Entry(key: key, fd: fd, path: bin, indexPath: idx)
        entry.contentLength = file.contentLength
        // 最近使用只用来排新旧：按原来的先后重新编号，接在本进程的时钟后面
        for block in file.blocks.filter({ $0.count == 4 }).sorted(by: { $0[3] < $1[3] }) {
            let (index, lo, hi) = (block[0], block[1], block[2])
            guard index >= 0, lo >= index * Self.blockSize, lo < hi, hi <= (index + 1) * Self.blockSize, hi <= size else {
                continue
            }
            useClock += 1
            entry.blocks[index] = Block(lo: lo, hi: hi, lastUse: useClock)
            totalBytes += hi - lo
        }
        EngineLog.emit("[SourceByteCache] [MovieClaw P42] restored \(key): \(entry.blocks.count) blocks, "
                       + "\(entry.blocks.values.reduce(0) { $0 + ($1.hi - $1.lo) } >> 20) MB", category: .demux)
        return entry
    }

    var cachedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    // MARK: - 内部（调用方已持锁）

    private func entryLocked(_ key: String) -> Entry? {
        if let entry = existingEntryLocked(key) { return entry }
        budgetBytes = nil   // 新片源：按现在的可用空间重算预算
        let path: String
        var indexPath: String?
        if let dir = persistentDirectory {
            // [MovieClaw P42] 按键的哈希命名：下次启动按键找得回来。旧的一份（记账坏了、键对不上）直接覆盖
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stem = Self.fileStem(for: key)
            path = dir.appendingPathComponent(stem + ".bin").path
            indexPath = dir.appendingPathComponent(stem + ".idx").path
            if let indexPath { unlink(indexPath) }
        } else {
            let dir = Self.directory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent(UUID().uuidString).path
        }
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            disabled = true
            return nil
        }
        let entry = Entry(key: key, fd: fd, path: path, indexPath: indexPath)
        entries[key] = entry
        return entry
    }

    private func dropLocked(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.blocks.values.reduce(0) { $0 + ($1.hi - $1.lo) }
        totalBytes -= entry.spare.values.reduce(0) { $0 + ($1.hi - $1.lo) }   // [MovieClaw P50]
    }

    private func contiguousEndLocked(_ entry: Entry, from offset: Int64) -> Int64 {
        var cursor = offset
        while let block = entry.blocks[cursor / Self.blockSize], block.lo <= cursor, cursor < block.hi {
            cursor = block.hi
            // 这块没写满到块尾：连续覆盖到此为止
            if cursor % Self.blockSize != 0 { break }
        }
        return cursor
    }

    private func budgetLocked() -> Int64 {
        if let fixedBudget { return fixedBudget }
        if let budgetBytes { return budgetBytes }
        // [MovieClaw P25] 经统一入口读（测试可覆盖）
        #if os(macOS)
        let available = AetherEngine.temporaryVolumeAvailableBytes(importantUsage: false)
        #else
        let available = AetherEngine.temporaryVolumeAvailableBytes(importantUsage: true)
        #endif
        let budget = min(Int64(1) << 30, (available ?? 0) / 8)
        budgetBytes = budget
        return budget
    }

    /// 要打的洞：哪个文件（持着 Entry 保证文件还开着）、从哪到哪
    private typealias Hole = (entry: Entry, offset: Int64)

    /// 在文件上打洞，把空间还给系统。不持锁（P32：块已从账上删掉）
    private static func punch(_ holes: [Hole]) {
        guard !holes.isEmpty else { return }
        #if DEBUG
        let started = DispatchTime.now()
        #endif
        for hole in holes {
            var range = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(hole.offset), fp_length: off_t(blockSize))
            _ = fcntl(hole.entry.fd, F_PUNCHHOLE, &range)
        }
        #if DEBUG
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        EngineLog.emit("[SourceByteCache] [MovieClaw P32] 超预算淘汰：打洞 \(holes.count) 次，耗时 \(Int(ms))ms", category: .demux)
        #endif
    }

    /// 一次淘汰要做的事：打哪些洞；[MovieClaw P42] 以及打洞之前要先写下去的记账（淘汰动过、还留着的那些片源）
    private struct Eviction {
        var holes: [Hole] = []
        var indexes: [(entry: Entry, path: String, data: Data)] = []
    }

    /// 执行一次淘汰：先同步数据、写记账，再打洞。记账落在前面，进程在两步之间被杀也只是少认几块；
    /// 反过来就会认下全零的洞。记账认的留存块先写屏障同步到闪存（同 `flushIndexOnQueue`）
    private static func apply(_ eviction: Eviction) {
        for index in eviction.indexes {
            barrierSync(index.entry.fd)
            writeIndex(index.data, to: index.path)
        }
        punch(eviction.holes)
    }

    /// [MovieClaw P46] 片源头尾的「元数据区」：文件头 8 MiB、文件尾 32 MiB——MP4 的 moov（放头或放尾，大片十几 MB）、
    /// MKV 的 SeekHead 与 Cues、TS 的时长都在这里。它们只在打开时读一次，按最近使用总是最先被挤掉：看一个多小时高码率片，
    /// 1 GiB 预算只装得下最后几分钟，下次续播（P42）就得重下文件头和索引。淘汰时这些块排在最后
    static let pinnedHeadBytes: Int64 = 8 << 20
    static let pinnedTailBytes: Int64 = 32 << 20

    private func isPinnedLocked(_ entry: Entry, block index: Int64) -> Bool {
        if index * Self.blockSize < Self.pinnedHeadBytes { return true }
        guard let length = entry.contentLength else { return false }
        return (index + 1) * Self.blockSize > length - Self.pinnedTailBytes
    }

    /// 超了预算：按最近使用从旧到新丢块，丢到预算的九成（成批丢，免得每写一块都扫一遍）。
    /// 只在账上删、返回要打的洞，由调用方在锁外打（P32）。[MovieClaw P46] 元数据区的块自己超过预算四分之一时先丢到四分之一，
    /// 然后先丢普通块，普通块丢光仍超预算才轮到它们
    private func evictOverBudgetLocked() -> Eviction {
        let budget = budgetLocked()
        guard totalBytes > budget else { return Eviction() }
        var eviction = Eviction()
        var touched: [ObjectIdentifier: Entry] = [:]
        typealias Candidate = (key: String, index: Int64, lastUse: UInt64)
        var normal: [Candidate] = []
        var pinned: [Candidate] = []
        var pinnedBytes: Int64 = 0
        for (key, entry) in entries {
            for (index, block) in entry.blocks {
                if isPinnedLocked(entry, block: index) {
                    pinned.append((key, index, block.lastUse))
                    pinnedBytes += coveredLocked(entry, block: index)
                } else {
                    normal.append((key, index, block.lastUse))
                }
            }
        }
        normal.sort { $0.lastUse < $1.lastUse }
        pinned.sort { $0.lastUse < $1.lastUse }
        /// 丢一块，返回腾出的字节（已经丢过的返回 0）
        func evict(_ candidate: Candidate) -> Int64 {
            guard let entry = entries[candidate.key], let block = entry.blocks.removeValue(forKey: candidate.index) else {
                return 0
            }
            // [MovieClaw P50] 打洞是整块打的：暂记的那段一起没了
            let spare = entry.spare.removeValue(forKey: candidate.index)
            let freed = block.hi - block.lo + (spare.map { $0.hi - $0.lo } ?? 0)
            totalBytes -= freed
            eviction.holes.append((entry, candidate.index * Self.blockSize))
            touched[ObjectIdentifier(entry)] = entry
            return freed
        }
        let target = budget / 10 * 9
        // 元数据区最多占预算四分之一（至少容得下一个片源的头尾），超了先按最近使用丢最旧片源的
        let pinnedCap = max(budget / 4, Self.pinnedHeadBytes + Self.pinnedTailBytes)
        for candidate in pinned where pinnedBytes > pinnedCap { pinnedBytes -= evict(candidate) }
        for candidate in normal where totalBytes > target { _ = evict(candidate) }
        for candidate in pinned where totalBytes > target { _ = evict(candidate) }
        // 块丢光的片源整条删（关文件、删文件），免得看过的片子多了文件句柄越攒越多
        for (key, entry) in entries where entry.blocks.isEmpty {
            entries.removeValue(forKey: key)
        }
        // [MovieClaw P42] 还留着的片源：记账按淘汰后的样子重写（整条删了的，数据与记账随 Entry 一起删）
        for entry in touched.values {
            entry.evictionGeneration &+= 1
            guard entries[entry.key] === entry else { continue }
            entry.indexDirty = false
            if let snapshot = indexSnapshotLocked(entry) { eviction.indexes.append((entry, snapshot.0, snapshot.1)) }
        }
        return eviction
    }
}

extension AetherEngine {
    /// [MovieClaw P33] 点播换封装的分片目标时长（秒，默认 2，上游 4）。AVPlayer 要等一整段产出、送达才开画，
    /// 分片越短，起播与缓冲外跳转要先产出、先攒的数据越少。宿主可在装载前改，并按比例放大前后窗口的段数
    /// （窗口按段计，缓冲的时长不变）。夹在 1～6 秒；长 GOP 的片子分片仍按关键帧间隔切，不会短于它
    nonisolated(unsafe) public static var vodSegmentTargetSeconds: Double = 2.0 {
        didSet { vodSegmentTargetSeconds = Swift.min(6, Swift.max(1, vodSegmentTargetSeconds)) }
    }

    /// [MovieClaw P34] 探测流时把第二条起的 TrueHD 暂当附件（默认开，见 `Demuxer.parkUnsizedPGS`）。宿主做新旧对照时可关
    nonisolated(unsafe) public static var parkSecondaryTrueHDDuringProbe = true

    /// [MovieClaw P45] MKV 索引预热跳到起播点而不是片中间（默认开，见 `HLSVideoEngine.start()` 的 cue prewarm）。宿主做新旧对照时可关
    nonisolated(unsafe) public static var cuePrewarmTargetsStart = true

    /// [MovieClaw P42] 片源字节缓存跨启动保留（默认开）。只在共享实例第一次用到之前改才有效（宿主在建第一个引擎前设），
    /// 真机新旧对照用
    nonisolated(unsafe) public static var persistsSourceByteCache = true

    /// [MovieClaw P50] 片源字节缓存每块另记一段暂存范围（默认开，见 `SourceByteCache.recordWriteLocked`）。关掉即每块只记一段
    /// （P50 之前的行为），真机新旧对照用
    nonisolated(unsafe) public static var sourceByteCacheKeepsSpareRuns = true

    /// [MovieClaw P51] 启动整理跨启动缓存超额时先缩到只剩元数据区、缩完仍超才整条删（默认开，见 `SourceByteCache.trimPersisted`）。
    /// 关掉即直接整条删（P51 之前的行为），真机新旧对照用
    nonisolated(unsafe) public static var sourceByteCacheTrimKeepsMetadata = true

    /// [MovieClaw P50] 删掉跨启动保留的片源字节缓存（整个目录）。只能在共享实例第一次用到之前调，真机对照每次热身前清场用
    nonisolated public static func removePersistedSourceByteCache() {
        try? FileManager.default.removeItem(at: SourceByteCache.persistentRoot)
    }

    /// [MovieClaw P32] 片源字节缓存的写盘与淘汰是否放在后台串行队列（默认开）。宿主在真机上做新旧对照时可关掉
    public static var sourceByteCacheWritesInBackground: Bool {
        get { SourceByteCache.shared.asynchronous }
        set { SourceByteCache.shared.asynchronous = newValue }
    }
}
