import Foundation

/// [MovieClaw P20] 运行中放大前向缓冲（MovieClaw 补丁，见 PATCHES.md）。
///
/// 上游的前向窗口（`LoadOptions.forwardBufferSegments`）在装载时定死，默认 10 段（约 40 秒）。
/// 线路比片子码率慢时（2026-09-28《哪吒》：外网 54 Mbit/s 放 76 Mbit/s 的原片），窗口一满生产者就停，
/// 用户暂停想「攒一会缓冲再看」也只能攒到这 40 秒——暂停多久都没用。
///
/// 宿主在确认线路跟不上之后（真卡过一次）调这里放大窗口：生产者停泊中途就按新窗口放行，
/// 暂停期间能一直攒到新窗口（仍受磁盘留存预算 min(2 GiB, 剩余空间 1/4) 约束）。线路够快时宿主不调，
/// 不会在蜂窝网上白白多下。
extension AetherEngine {
    /// 前向缓冲放大到「多少秒内容」。换封装通路按本场分段计划的平均段长换算成段数（段长随关键帧间隔走），
    /// 换算出的段数写回载入选项，换音轨、回前台这类原地重建沿用放大后的窗口；软件通路直接放大读前的秒数。
    /// AVPlayer 直连服务端流没有这套缓冲，记一行日志、不做事
    public func setForwardBufferDuration(_ seconds: Double) {
        if let softwareHost {
            softwareHost.setForwardBufferSeconds(seconds)
            EngineLog.emit("[AetherEngine] [MovieClaw P20] software read-ahead -> \(Int(seconds)) s", category: .engine)
            return
        }
        guard let session = nativeVideoSession else {
            EngineLog.emit(
                "[AetherEngine] [MovieClaw P20] forward buffer = \(Int(seconds)) s ignored: "
                + "route=\(videoRoute.rawValue) has no loopback segment cache",
                category: .engine
            )
            return
        }
        setLoadedForwardBufferSegments(session.setForwardWindowDuration(seconds))
    }

    /// [MovieClaw P23] 暂停下载 / 恢复。宿主在「蜂窝网或低数据模式下用户按了暂停」时调，免得暂停着也一直往前下
    /// （之后不看了就白下）：换封装通路把生产者前向窗口压到 0，软件通路让读前停在已读到的地方，AVPlayer 直连
    /// 服务端流时把它的预读压到 1 秒。状态记在引擎上，暂停期间换音轨之类的重建也照样停着
    public func setPrefetchSuspended(_ suspended: Bool) {
        prefetchSuspendedRequested = suspended
        applyPrefetchSuspension()
    }

    /// 把记着的状态落到当前会话（会话新建 / 重建后也调）
    func applyPrefetchSuspension() {
        let suspended = prefetchSuspendedRequested
        nativeVideoSession?.setPrefetchSuspended(suspended)
        softwareHost?.setPrefetchSuspended(suspended)
        guard videoRoute == .remoteBypass, let item = currentAVPlayer?.currentItem else { return }
        if suspended {
            if suspendedRemoteForwardBuffer == nil { suspendedRemoteForwardBuffer = item.preferredForwardBufferDuration }
            item.preferredForwardBufferDuration = 1
        } else if let original = suspendedRemoteForwardBuffer {
            item.preferredForwardBufferDuration = original
            suspendedRemoteForwardBuffer = nil
        }
    }
}
