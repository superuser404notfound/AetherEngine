import Foundation

public extension AetherEngine {

    /// The default number of source bytes a warm retains, 8 MB.
    ///
    /// A byte budget rather than a duration, because a duration would need the bitrate, and the
    /// bitrate is known only after the probe, which is the round trip the warm exists to remove.
    static var defaultPrewarmByteBudget: Int { SourcePrewarmFetcher.defaultByteBudget }

    /// Fetch the opening bytes of a source the engine is not playing, so that a later `load()` of
    /// the same URL starts without paying for them (#551).
    ///
    /// For a host whose UI knows what comes next: the next episode, the item under the cursor. A
    /// cold open is two to three sequential round trips before the first sample read on a
    /// non-fast-start MP4, and on a slow origin the first byte of the data connection is the whole
    /// perceived start time. Those are spendable in advance, and this is how a host spends them.
    ///
    /// `nonisolated` and `static`: warming needs no engine, no audio session and no layer, so a
    /// host warms while its player is still on the current item. Call it from a detached task.
    ///
    /// What it does: one ranged GET from byte zero for `byteBudget` bytes, plus a second one for
    /// the trailing object only where the head says a cold open would go looking for it (an MP4
    /// whose `moov` sits behind the media). The bytes are held in memory, keyed by the exact URL,
    /// and the first `load()` of that URL takes them. They do not survive the app, and they are not
    /// a download: this is a head start, not an offline copy.
    ///
    /// What it deliberately does not do:
    ///
    /// - **It never queues for the origin.** A warm takes a request slot only if one is free right
    ///   now, and declines when the origin is metered down to one request at a time or is pacing
    ///   the engine (#377). A prewarm that would have to wait for the playing session's uplink has
    ///   stopped helping, and the report says so.
    /// - **It does not apply to `LoadOptions.nativeRemoteHLS`.** On that route AVPlayer issues the
    ///   requests and the engine sees none of them, so there is nothing here to adopt.
    ///
    /// Cancelling the task cancels the fetch and stores nothing: a host that has moved on must not
    /// find half a source warm for a URL it left behind.
    ///
    /// - Parameters:
    ///   - url: The exact source URL a later `load()` will use. A signed URL warmed under one
    ///     signature is not adopted under another, which is the conservative reading and the only
    ///     one that cannot serve the wrong bytes.
    ///   - httpHeaders: The same headers the load will carry (`LoadOptions.httpHeaders`), for
    ///     origins that enforce Referer / User-Agent / Authorization.
    ///   - byteBudget: How many bytes to retain from the head. Defaults to
    ///     ``defaultPrewarmByteBudget``.
    /// - Returns: A ``SourcePrewarmReport`` naming what was retained, or why nothing was.
    @discardableResult
    nonisolated static func prewarm(url: URL,
                                    httpHeaders: [String: String] = [:],
                                    byteBudget: Int? = nil) async -> SourcePrewarmReport {
        await SourcePrewarmFetcher.warm(url: url,
                                        extraHeaders: httpHeaders,
                                        byteBudget: byteBudget ?? SourcePrewarmFetcher.defaultByteBudget)
    }

    /// Whether a source is warm right now, without consuming it.
    ///
    /// For a host that wants to skip re-warming an item it already warmed. The playing session's
    /// adoption is what empties it, so this answers false again after the load that used it.
    nonisolated static func isPrewarmed(url: URL) -> Bool {
        SourcePrewarmStore.shared.isWarm(for: url)
    }

    /// Drop every warmed source.
    ///
    /// For a host leaving the context the warms were made for (a user signing out, a server
    /// changing). Warmed bytes cost memory until they are adopted or displaced, and a host that
    /// knows they will never be adopted can say so.
    nonisolated static func discardPrewarmedSources() {
        SourcePrewarmStore.shared.clear()
    }
}

// MARK: - [MovieClaw P43] 预连
public extension AetherEngine {
    /// 预先和片源所在的源站建好连接（TCP / TLS），不读片源。宿主在知道「马上要播、但取流地址还没拿到」时调
    /// （MovieClaw：点播放的那一刻，起播协商还在路上）：`url` 是同一源站上任何一个便宜的地址，headers 同装载时的
    nonisolated static func preconnect(url: URL, httpHeaders: [String: String] = [:]) {
        AVIOReader.preconnect(url: url, headers: httpHeaders)
    }
}

// MARK: - [MovieClaw P16] 死会话缓存清扫
public extension AetherEngine {
    /// 清掉被杀掉的会话留下的分片（主力通路）与包缓存（软件通路）。两种缓存建新会话时各自顺手清一遍，
    /// 但只清同类：一直走主力通路的用户，软件通路的残留要等下一次放 VP9 / DVD 才会清。App 启动时调一次，放后台线程
    nonisolated static func sweepStaleSessionCaches() {
        SegmentCache.sweepStaleSessions()
        _ = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: FileManager.default.temporaryDirectory)
        // [MovieClaw P22 / P42] 片源字节缓存：清掉临时目录里的旧版缓存，整理跨启动保留的那份（孤儿、过期、超量）
        SourceByteCache.sweep()
    }

    /// [MovieClaw P42] 片源字节缓存的记账立刻落盘（宿主在 App 进后台时调）：进程随后可能被挂起、被杀，
    /// 平时的防抖落盘还没轮到的最后几秒写入，下次续播也认得
    nonisolated static func flushSourceByteCacheIndexes() {
        SourceByteCache.shared.flushIndexes()
    }

    /// [MovieClaw P22] 自定义片源（原盘目录）里每个文件的地址登记到稳定的键上：`load(source: .url)` 由
    /// `LoadOptions.sourceCacheKey` 自动登记，宿主自己拼的读取器（每个文件一个取流地址）要逐个登记
    nonisolated static func bindSourceCacheKey(url: URL, key: String) {
        SourceByteCache.shared.bind(url: url, key: key)
    }
}

// MARK: - [MovieClaw P39] 按字节范围预取进片源字节缓存（刷片）
public extension AetherEngine {
    /// 把一个片源的若干字节范围拉下来写进片源字节缓存（补丁 P22），之后用同一个 `sourceCacheKey` 装载时，
    /// 打开、跳到起点、读尾部索引都直接从本机拿。给刷片用：当前这条还在播，下一条「从原片中间起播」要读的
    /// 文件头 / 索引 / 起点后几秒先下好（范围由服务端从容器索引算出，见 `SourceRangePrefetcher`）。
    ///
    /// 放在后台任务里调；取消任务即停止（已写进缓存的保留）。只是加速：源站忙、积压太多都会中途放弃，
    /// 不影响随后正常装载。
    nonisolated static func prefetchSourceRanges(url: URL,
                                                 cacheKey: String,
                                                 ranges: [SourceByteRange],
                                                 httpHeaders: [String: String] = [:]) async -> SourceRangePrefetchReport {
        await SourceRangePrefetcher.prefetch(url: url, key: cacheKey, ranges: ranges, extraHeaders: httpHeaders)
    }
}
