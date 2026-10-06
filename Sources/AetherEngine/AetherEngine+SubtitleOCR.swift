import Foundation

// Phase D: selection-armed worker feeding a bitmap track's native WebVTT rendition with
// OCR-recognized text cues, so PGS/DVB/DVD subtitles survive PiP / AirPlay / external display
// on the native path. Packet source is the session SubtitlePacketStore (#112 harvest); the tick
// plans and resolves on the MainActor, decodes off it (AE#628), and Vision runs on a dedicated thread.
extension AetherEngine {

    /// Arm for the selected embedded bitmap track. The per-ordinal cursor survives re-arming.
    func startSubtitleOCRWorker(ordinal: Int, streamIndex: Int32) {
        cancelSubtitleOCRWorker()
        guard let store = nativeStore(atOrdinal: ordinal) else { return }
        subtitleOCRArmedOrdinal = ordinal
        let language = ordinal < nativeSubtitleTrackTable.count
            ? nativeSubtitleTrackTable[ordinal].language : nil
        EngineLog.emit("[SubtitleOCR] worker armed: ordinal=\(ordinal) stream=\(streamIndex)", category: .engine)
        subtitleOCRWorkerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // AE#628: plan on the MainActor, decode here, off it, then resolve ends back on it.
                // The decode is the bitmap blit, the heaviest frame of the report's profile.
                let planned = await MainActor.run { [weak self] () -> SubtitleOCRTickPlan? in
                    guard !Task.isCancelled, let self else { return nil }
                    return self.subtitleOCRPlanTick(ordinal: ordinal, streamIndex: streamIndex)
                }
                let decoded = planned?.decodeHandoff.decode().first ?? []
                let batch = await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, let planned else { return [SubtitleCue]() }
                    let batch = self.subtitleOCRFinishTick(planned, events: decoded)
                    self.subtitleOCRBatchInFlight = !batch.isEmpty
                    return batch
                }
                if !batch.isEmpty {
                    await SubtitleImageOCR.appendRecognized(cues: batch, language: language, to: store)
                    await MainActor.run {
                        if !Task.isCancelled { self.subtitleOCRBatchInFlight = false }
                    }
                }
                try? await Task.sleep(nanoseconds: AetherEngine.subtitleDrainTickNanoseconds)
            }
        }
    }

    /// Completed coverage survives a re-arm; an abandoned batch must be collected again.
    func cancelSubtitleOCRWorker() {
        if subtitleOCRBatchInFlight, let ordinal = subtitleOCRArmedOrdinal {
            subtitleOCRCursors.removeValue(forKey: ordinal)
            subtitleOCRPendingStates.removeValue(forKey: ordinal)
        }
        subtitleOCRBatchInFlight = false
        subtitleOCRArmedOrdinal = nil
        subtitleOCRWorkerTask?.cancel()
        subtitleOCRWorkerTask = nil
        subtitleOCRSidecarFillTask?.cancel()
        subtitleOCRSidecarFillTask = nil
        subtitleOCRDecoder = nil
        subtitleOCRLastTickUptime = nil   // #271
    }

    // MARK: - [MovieClaw P21] 文字识别只在系统画原生字幕时跑

    /// 进画中画 / 隔空播放时：当前选中的是内封图形字幕、识别还没在跑，就现在启动，连同读到 270 秒之后的旁路预读。
    /// 返回这次是否新启动（新启动的要冲一次系统缓存的空字幕窗口）
    @discardableResult
    func armNativeBitmapOCRIfNeeded(ordinal: Int) -> Bool {
        guard ordinal < nativeSubtitleTrackTable.count else { return false }
        let entry = nativeSubtitleTrackTable[ordinal]
        guard entry.needsOCR, let stream = entry.sourceStreamIndex, subtitleOCRArmedOrdinal != ordinal else {
            return false
        }
        startSubtitleOCRWorker(ordinal: ordinal, streamIndex: Int32(stream))
        startSubtitleForwardPrefetcher()
        return true
    }

    /// 画中画结束：识别与长预读都停（识别过的区域记着，下次进画中画不重识别）
    func stopNativeBitmapOCR() {
        nativeOCRCacheBustTask?.cancel()
        nativeOCRCacheBustTask = nil
        guard subtitleOCRArmedOrdinal != nil else { return }
        cancelSubtitleOCRWorker()
        cancelSubtitleForwardPrefetcher(reason: .nativeRenderingEnded)
    }

    /// 刚启动识别时，系统已经按选中原生字幕轨的那一刻拉走了一批字幕窗口，那时还没识别出来，会被当成空的缓存住。
    /// 等识别覆盖到播放点后 60 秒（最多 8 秒），「取消再选中」一次原生字幕轨，让系统重新拉（#32 同一手法）
    func scheduleNativeOCRCacheBust(ordinal: Int) {
        nativeOCRCacheBustTask?.cancel()
        nativeOCRCacheBustTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                let covered = self.nativeStore(atOrdinal: ordinal)?.readMaxCueEnd() ?? 0
                if covered >= self.sourceTime + 60 { break }
            }
            guard !Task.isCancelled, let self, self.nativeSubtitleRenderingRequested,
                  self.nativeSubtitleReapplyOrdinal == ordinal else { return }
            EngineLog.emit("[AetherEngine] [MovieClaw P21] OCR warmed for ordinal=\(ordinal); "
                           + "reselecting the native rendition to refetch empty cached windows",
                           category: .engine)
            self.setNativeSubtitleSelected(track: nil)
            self.setNativeSubtitleSelected(track: ordinal)
        }
    }

    /// Load/stop teardown: forget covered-region state too (new session, new axis).
    func resetSubtitleOCRState() {
        nativeOCRCacheBustTask?.cancel()
        nativeOCRCacheBustTask = nil
        cancelSubtitleOCRWorker()
        subtitleOCRCursors.removeAll()
        subtitleOCRPendingStates.removeAll()
    }

    /// MainActor half before the decode: plan the window (drainer pacing, larger lead) and pick the
    /// stored packets (bounded per tick). The decode runs off the MainActor (AE#628) and
    /// `subtitleOCRFinishTick` resolves composition ends into CLOSED cues for off-main OCR.
    fileprivate func subtitleOCRPlanTick(ordinal: Int, streamIndex: Int32) -> SubtitleOCRTickPlan? {
        guard let packetStore = activeSubtitlePacketStore else { return nil }
        let playhead = sourceTime
        // #271: same rule as the overlay drainer, a tick that ran long is not a seek.
        let tickUptime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let elapsed = subtitleOCRLastTickUptime.map { tickUptime - $0 } ?? 0
        subtitleOCRLastTickUptime = tickUptime
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: subtitleOCRCursors[ordinal], playhead: playhead,
            lead: Self.subtitleOCRLeadSeconds,
            backscan: Self.subtitleDrainBackscanSeconds,
            jumpThreshold: Self.subtitleDrainJumpThresholdSeconds,
            elapsedSinceLastPlan: elapsed)
        let window: (from: Double, through: Double)
        switch plan {
        case .idle:
            subtitleOCRCursors[ordinal]?.lastPlayhead = playhead
            return SubtitleOCRTickPlan(ordinal: ordinal, playhead: playhead, plan: plan,
                                       window: (playhead, playhead), decoder: nil, batch: [])
        case .decode(let from, let through):
            window = (from, through)
        case .resetAndDecode(let from, let through):
            subtitleOCRDecoder = nil
            window = (from, through)
        }
        if subtitleOCRDecoder == nil {
            subtitleOCRDecoder = makeSubtitleDrainDecoder(streamIndex: streamIndex)
        }
        guard let decoder = subtitleOCRDecoder else {
            return SubtitleOCRTickPlan(ordinal: ordinal, playhead: playhead, plan: .idle,
                                       window: window, decoder: nil, batch: [])
        }
        let entries = packetStore.entries(streamIndex: streamIndex,
                                          from: window.from, through: window.through)
        // #271: the cap has to fall on a PTS boundary. The cursor is a bare PTS advanced by
        // `lastDecodedPts.nextUp`, so a cut inside a same-PTS run skips its remainder instead of
        // resuming it next tick. One composition per PTS is the norm on a bitmap track, but a
        // container that splits a display set across packets (see splitDisplaySetSubtitleStreamIndices)
        // shares one, and half a display set OCRs to nothing.
        let batchEnd = SubtitleOverlayDrainer.batchEnd(
            count: entries.count, cap: Self.subtitleOCRMaxPacketsPerTick,
            ptsAt: { entries[$0].ptsSeconds })
        return SubtitleOCRTickPlan(ordinal: ordinal, playhead: playhead, plan: plan, window: window,
                                   decoder: decoder, batch: entries[..<batchEnd])
    }

    /// MainActor half after the decode: resolve composition ends and return the CLOSED cues. A
    /// batch whose decoder was replaced while it decoded (seek, re-arm) is dropped with its cursor
    /// unmoved, so the next tick plans that window again.
    fileprivate func subtitleOCRFinishTick(_ tick: SubtitleOCRTickPlan,
                                           events: [EmbeddedSubtitleDecoder.SubtitleEvent?]) -> [SubtitleCue] {
        let ordinal = tick.ordinal
        var pending = subtitleOCRPendingStates[ordinal] ?? SubtitleOCRPendingState()
        var closed: [SubtitleCue] = []
        defer {
            closed.append(contentsOf: pending.expired(asOf: tick.playhead))
            subtitleOCRPendingStates[ordinal] = pending
        }
        guard let decoder = tick.decoder else { return closed }
        guard subtitleOCRArmedOrdinal == ordinal, subtitleOCRDecoder === decoder else { return closed }
        if case .resetAndDecode = tick.plan { pending = SubtitleOCRPendingState() }
        var lastDecoded = subtitleOCRCursors[ordinal]?.lastDecodedPts
        for (entry, decoded) in zip(tick.batch, events) {
            if let event = decoded {
                closed.append(contentsOf: pending.consume(
                    eventPts: entry.ptsSeconds, cues: event.cues, trimAt: event.pgsTrimAt))
            }
            lastDecoded = entry.ptsSeconds
        }
        if case .resetAndDecode = tick.plan, tick.batch.isEmpty {
            lastDecoded = tick.window.from
        }
        subtitleOCRCursors[ordinal] = SubtitleDrainCursor(
            lastDecodedPts: lastDecoded ?? tick.window.from, lastPlayhead: tick.playhead)
        return closed
    }

    /// #88 external .sup path: fill the needsOCR ordinal's store from the overlay sidecar
    /// decode's OWN image cues (no second download); markFinished so the PiP pre-fill and the
    /// whole-file .vtt handler see complete coverage.
    func startSidecarOCRFillIfNeeded(externalTrackID: Int?, cues: [SubtitleCue]) {
        guard let id = externalTrackID,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
              nativeSubtitleTrackTable[ordinal].needsOCR,
              let store = nativeStore(atOrdinal: ordinal),
              !store.isFinished else { return }
        let language = nativeSubtitleTrackTable[ordinal].language
        subtitleOCRSidecarFillTask?.cancel()
        EngineLog.emit("[SubtitleOCR] sidecar fill starting: track=\(id) cues=\(cues.count)", category: .engine)
        subtitleOCRSidecarFillTask = Task.detached(priority: .utility) {
            await SubtitleImageOCR.appendRecognized(cues: cues, language: language, to: store)
            if !Task.isCancelled { store.markFinished() }
        }
    }
}

/// AE#628: one OCR worker tick between its MainActor halves. `decoder` is nil for a tick that
/// decodes nothing (idle, or no decoder could be built), which still expires pending cues.
fileprivate struct SubtitleOCRTickPlan: @unchecked Sendable {
    let ordinal: Int
    let playhead: Double
    let plan: SubtitleDrainPlan
    let window: (from: Double, through: Double)
    let decoder: EmbeddedSubtitleDecoder?
    let batch: ArraySlice<StoredSubtitlePacket>

    var decodeHandoff: SubtitleDrainDecodeHandoff {
        SubtitleDrainDecodeHandoff(jobs: decoder.map { [($0, batch)] } ?? [])
    }
}
