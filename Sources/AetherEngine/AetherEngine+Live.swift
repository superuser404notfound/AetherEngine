import Foundation
import CoreGraphics

extension AetherEngine {

    /// A frame from the live DVR window at `atSessionSeconds` (the
    /// `seekableLiveRange` timeline), decoded locally from the engine's
    /// own segment cache: no network, no server round-trip. The session
    /// time is converted to the raw output timeline via the seam history
    /// before the segment lookup and the extractor seek, mirroring the
    /// inverse of the `$currentTime` fold. Returns nil when no native
    /// live session is active, the time is outside the resident window,
    /// or decoding fails. Never throws.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive, let session = nativeVideoSession else { return nil }
        // Session -> output conversion: the published seekableLiveRange is
        // output-time + shift (seam-resolved), while the segment table and
        // the muxed tfdt live on the raw output timeline. Resolve the seam
        // whose output-domain span contains the converted value, newest
        // first (mirrors the $currentTime fold, inverted).
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
        // A zap/stop while the detached read was in flight cleared the
        // LRU (stopInternal); inserting now would revive a dead-session
        // extractor whose per-session segment indices collide with the
        // next channel's, serving frames from the PREVIOUS channel.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = liveThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            // Move hit to the back so it's the last to be evicted (true LRU).
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

    /// Drive the live surfaces at 1 Hz for the lifetime of a native live
    /// session. Replaces nothing: the `$currentTime` sink still publishes
    /// on every playback tick; this covers the paused case.
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

    /// Live resume clamp. While paused the live edge keeps advancing (the
    /// 1 Hz window timer keeps `liveWindow` fresh), and a pause longer
    /// than the retention window leaves the playhead on content the
    /// sliding window has already evicted. AVPlayer would then fetch
    /// evicted segments (fast-404'd by the provider) instead of cleanly
    /// resuming, so jump the playhead back inside the window: to just
    /// above the DVR window's lower bound when a DVR window exists, or to
    /// the live edge for live-only sessions (their server-side retention
    /// floor is 60 s; clamping at 45 s leaves headroom before eviction).
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
            // Live-only: seek(to:) refuses targets without a DVR window,
            // so route through the edge snap (which drives the host
            // directly).
            guard w.behindLiveSeconds > 45 else { return }
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(String(format: "%.1f", w.behindLiveSeconds))s "
                + "window=live-only -> edge snap",
                category: .session
            )
            Task { await self.seekToLiveEdge() }
        }
    }

    /// Update the live DVR window from a path's reported edge and publish the
    /// four live surfaces (`liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`,
    /// `behindLiveSeconds`). Path-agnostic: the native tick and the SW
    /// tick both call this with their session-relative edge time. No-op when
    /// no live window is active.
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

    /// Seek to the current live edge. No-op when not live. With DVR enabled this
    /// resolves to `behind = 0` -> `clockTarget = seekableEnd`, i.e. the edge.
    public func seekToLiveEdge() async {
        guard isLive, let w = liveWindow else { return }
        // Live-only (no DVR window): seek(to:) refuses every target since
        // there is no rewind range, but snapping TO the edge is always
        // legal, and it is the recovery move after a long pause leaves
        // the playhead on evicted content. Drive the native host directly
        // at its own seekable end (the SW live-only path has no ring and
        // plays at the edge by construction; nothing to do there).
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
