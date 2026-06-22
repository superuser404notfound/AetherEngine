import Foundation
import CoreGraphics

extension AetherEngine {

    /// Frame from the DVR segment cache at `atSessionSeconds` (seekableLiveRange axis). No network: converts session time to raw output via seam history, then decodes locally. nil when no native live session, time outside resident window, or decode fails.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive, let session = nativeVideoSession else { return nil }
        // seekableLiveRange is output-time + seam shift; segment table and tfdt live on raw output. Resolve newest seam (inverts $currentTime fold).
        let outputSeconds: Double
        if let seam = liveShiftSeams.last(where: { seconds - $0.shift >= $0.activateAt }) {
            outputSeconds = seconds - seam.shift
        } else {
            outputSeconds = seconds - playlistShiftSeconds
        }
        let gen = loadGeneration
        let source = await Task.detached(priority: .userInitiated) { [session] in
            session.liveScrubThumbnailSource(atSeconds: outputSeconds)
        }.value
        guard let source else { return nil }
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices collide with the next channel's.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = liveThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = liveThumbnailExtractors.remove(at: idx)
            liveThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            extractor = FrameExtractor(reader: DataIOReader(data: source.data), formatHint: "mp4")
            liveThumbnailExtractors.append((source.segmentIndex, extractor))
            while liveThumbnailExtractors.count > 2 {
                let evicted = liveThumbnailExtractors.removeFirst()
                Task { await evicted.extractor.shutdown() }
            }
        }
        return await extractor.thumbnail(at: outputSeconds, maxWidth: maxWidth)
    }

    /// 1 Hz timer to update live surfaces while paused (the `$currentTime` sink already covers the playing case).
    func startLiveWindowTimer(host: NativeAVPlayerHost) {
        liveWindowTimerTask?.cancel()
        guard isLive else { return }
        liveWindowTimerTask = Task { [weak self, weak host] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let host else { return }
                guard self.isLive else { continue }
                self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
            }
        }
    }

    /// After a long pause the sliding DVR window may have evicted the playhead. Clamp to DVR lower bound + 5 s margin, or for live-only (no DVR, 60 s server retention) snap to the edge when > 45 s behind.
    func clampLiveResumeIfBehindWindow() {
        guard isLive, let w = liveWindow else { return }
        let margin: Double = 5
        if let win = w.windowSeconds {
            guard w.behindLiveSeconds > (win - margin) else { return }
            let t = (w.seekableRange?.lowerBound ?? w.edgeTime) + margin
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(String(format: "%.1f", w.behindLiveSeconds))s "
                + "window=\(String(format: "%.0f", win)) -> seek \(String(format: "%.1f", t))",
                category: .session
            )
            Task { await self.seek(to: t) }
        } else {
            // Live-only: seek(to:) refuses targets without a DVR window; drive the host directly via seekToLiveEdge.
            guard w.behindLiveSeconds > 45 else { return }
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(String(format: "%.1f", w.behindLiveSeconds))s "
                + "window=live-only -> edge snap",
                category: .session
            )
            Task { await self.seekToLiveEdge() }
        }
    }

    /// Publish `liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`, `behindLiveSeconds`. Path-agnostic; no-op when no live window is active.
    @MainActor
    func publishLiveWindow(edgeSessionTime: Double) {
        guard var w = liveWindow else { return }
        w.noteEdge(edgeSessionTime)
        w.notePlayhead(currentTime)
        liveWindow = w
        clock.liveEdgeTime = w.edgeTime
        clock.seekableLiveRange = w.seekableRange
        clock.isAtLiveEdge = w.isAtEdge
        clock.behindLiveSeconds = w.behindLiveSeconds
    }

    /// Seek to the current live edge. No-op when not live.
    public func seekToLiveEdge() async {
        guard isLive, let w = liveWindow else { return }
        // Live-only (no DVR window): seek(to:) refuses; drive native host directly to seekableEnd as the recovery move after eviction.
        guard w.windowSeconds != nil else {
            if let host = nativeHost {
                let clockTarget = max(0, host.seekableEnd)
                EngineLog.emit(
                    "[AetherEngine] live-only edge snap: clockTarget=\(String(format: "%.1f", clockTarget))",
                    category: .engine
                )
                await host.seek(to: clockTarget)
                nativeClockSeconds = clockTarget
                clock.currentTime = clockTarget + playlistShiftSeconds
                clock.sourceTime = currentTime
            }
            return
        }
        await seek(to: w.edgeTime)
    }
}
