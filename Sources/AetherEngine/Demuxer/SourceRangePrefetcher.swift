import Foundation

// MARK: - [MovieClaw P39] 按字节范围预取进片源字节缓存（刷片）
//
// 刷片（docs/design/reels.md）要在一条片段还在播的时候，把下一条「从原片中间起播」要读的数据先下到本机：
// 文件头（打开时探测要读）、索引（MKV 的 Cues / MP4 的 moov，跳到起点时要读）、起点后约 4 秒（出第一个画面
// 要读）。这三段的位置由服务端从容器索引里算好给出，这里只负责按范围拉下来、写进片源字节缓存（补丁 P22）。
//
// 为什么写进 P22 缓存而不是像 #551 预热那样存内存：
// - 预热只认「从 0 开始的文件头」且按带令牌的完整地址匹配；刷片要的是文件中间的几段，而且下一条真正装载时
//   用的取流地址令牌可能不同。P22 按宿主给的稳定键（MovieClaw 用「文件 id + 大小」）认同一个文件；
// - AVIOReader 打开时缓存里有从 0 起的文件头就当预热数据接管、一个请求都不发（`byteCacheWarm`），远跳超过
//   8 MiB 与回跳时先查缓存——跳到起点、读尾部索引正好走这两条路，读的全是本机字节。
//
// 取舍：
// - **按 1 MiB 块对齐**：缓存每块只记一段连续覆盖，范围起止不对齐时两端的块只覆盖一半、边界处会断开。起点往下、
//   终点往上各对齐到块边界，最多多拉 2 MiB。
// - **分 4 MiB 一段拉**：每段都是一次独立的 Range 请求，占用源站名额的时间短，不和正在播的那条抢线路太久；
//   内存里最多压一段。
// - **沿用预热的名额规则**：源站限成一次只能一个请求时直接放弃（那一个名额是正在播的那条要用的）；暂时没有
//   空闲名额就稍等重试，等太久也放弃——预取只是加速，不值得和播放抢。
// - **写入限流**：缓存的写盘在后台串行队列上做（P32），积压超过上限的新写入会被直接丢弃。每写一段之前先等
//   积压降到 32 MiB 以下。

/// 要预取的一段：[offset, offset + length)
public struct SourceByteRange: Sendable, Equatable {
    public let offset: Int64
    public let length: Int64

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

/// 一次范围预取的结果
public struct SourceRangePrefetchReport: Sendable, Equatable {
    /// 这次从源站拉下来的字节数
    public let fetchedBytes: Int64
    /// 本来就在缓存里、跳过没拉的字节数
    public let alreadyCachedBytes: Int64
    /// 没拉完的原因；nil 表示全部范围都已在缓存里
    public let declined: String?
}

enum SourceRangePrefetcher {

    static let chunkBytes: Int64 = 4 << 20
    /// 写入前等缓存积压降到这以下
    static let pendingWriteCeiling = 32 << 20
    /// 等源站空闲名额：每次 100 毫秒、最多 3 秒
    static let slotRetryInterval: Duration = .milliseconds(100)
    static let slotRetryLimit = 30

    private static let session: URLSession = URLSession(
        configuration: AVIOReader.makeSessionConfig(),
        delegate: EngineTLS.sessionDelegate,
        delegateQueue: nil)

    static func prefetch(url: URL,
                         key: String,
                         ranges: [SourceByteRange],
                         extraHeaders: [String: String],
                         cache: SourceByteCache = .shared) async -> SourceRangePrefetchReport {
        var fetched: Int64 = 0
        var cached: Int64 = 0
        func report(_ declined: String?) -> SourceRangePrefetchReport {
            if let declined {
                EngineLog.emit("[RangePrefetch] [MovieClaw P39] \(key): stopped after \(fetched)B (\(declined))",
                               category: .demux)
            }
            return SourceRangePrefetchReport(fetchedBytes: fetched, alreadyCachedBytes: cached, declined: declined)
        }
        guard !OriginRequestBudget.shared.requiresSerialRequests(url) else {
            return report("origin allows one request at a time; the playing session needs it")
        }
        let block = SourceByteCache.blockSize
        var total = cache.contentLength(key: key)
        for range in ranges where range.length > 0 && range.offset >= 0 {
            var end = ((range.offset + range.length + block - 1) / block) * block
            if let total { end = min(end, total) }
            var position = (range.offset / block) * block
            while position < end {
                if Task.isCancelled { return report("cancelled") }
                let have = min(cache.contiguousEnd(key: key, from: position), end)
                if have > position {
                    cached += have - position
                    position = have
                    continue
                }
                let length = Int(min(chunkBytes, end - position))
                var result: RangeFetch.Result?
                for _ in 0 ..< slotRetryLimit {
                    do {
                        result = try await RangeFetch.run(url: url,
                                                          extraHeaders: extraHeaders,
                                                          requestedStart: position,
                                                          requestedLength: length,
                                                          label: "rangePrefetch",
                                                          session: session)
                        break
                    } catch let decline as PrewarmDecline where decline.reason.hasPrefix("no origin request slot") {
                        try? await Task.sleep(for: slotRetryInterval)
                        if Task.isCancelled { return report("cancelled") }
                    } catch {
                        return report("\(error)")
                    }
                }
                guard let result else { return report("no origin request slot free for 3s") }
                if total == nil || total != result.total {
                    total = result.total
                    cache.noteContentLength(key: key, length: result.total)
                    end = min(end, result.total)
                }
                guard !result.body.isEmpty else { break }
                var waited = 0
                while cache.pendingWriteBytes > pendingWriteCeiling, waited < 250 {
                    try? await Task.sleep(for: .milliseconds(20))
                    waited += 1
                }
                cache.write(key: key, offset: position, data: result.body)
                fetched += Int64(result.body.count)
                position += Int64(result.body.count)
            }
        }
        return report(nil)
    }
}
