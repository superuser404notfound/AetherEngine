import AVFoundation
import Foundation

// Phase D: native-selection-armed worker feeding a bitmap track's native WebVTT rendition with
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
        subtitleOCRWorkerTask = BlockingWork.detached(priority: .utility) { [weak self] in
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

    /// The OCR rendition only matters while the host shows it (PiP / AirPlay / external display), so
    /// the worker follows the native selection instead of the overlay selection. Armed, it also
    /// raises the forward prefetch to `subtitleOCRPrefetchLeadSeconds`, and on Matroska that reader
    /// pulls every cluster: measured on a 4K remux, ten times the bytes of the overlay-only lead,
    /// which a viewer who never leaves fullscreen paid for nothing (DerPicknicker, A10X).
    func syncSubtitleOCRWithNativeSelection(ordinal: Int?) {
        let wanted = ordinal.flatMap { o -> (ordinal: Int, stream: Int32)? in
            guard o < nativeSubtitleTrackTable.count, nativeSubtitleTrackTable[o].needsOCR,
                  let source = nativeSubtitleTrackTable[o].sourceStreamIndex,
                  Int32(source) == activeEmbeddedSubtitleStreamIndex else { return nil }
            return (o, Int32(source))
        }
        if let wanted {
            guard subtitleOCRArmedOrdinal != wanted.ordinal else { return }
            startSubtitleOCRWorker(ordinal: wanted.ordinal, streamIndex: wanted.stream)
        } else {
            guard subtitleOCRArmedOrdinal != nil else { return }
            cancelSubtitleOCRWorker()
        }
        // Rebuilds the running session only when the lead actually changed.
        startSubtitleForwardPrefetcher()
    }

    /// Whether the worker has recognized every stored composition through the window AVKit takes in
    /// one burst at selection. A worker armed on demand starts that window empty, and AVKit caches
    /// what it is handed, so the native select waits for this instead of the cue-end heuristic.
    func subtitleOCRCoversNativeWindow(ordinal: Int) -> Bool {
        guard subtitleOCRArmedOrdinal == ordinal, !subtitleOCRBatchInFlight,
              ordinal < nativeSubtitleTrackTable.count,
              let source = nativeSubtitleTrackTable[ordinal].sourceStreamIndex,
              let packets = activeSubtitlePacketStore,
              let cursor = subtitleOCRCursors[ordinal] else { return false }
        let from = sourceTime
        var through = from + Self.subtitleOCRLeadSeconds
        if duration > 0 { through = min(through, duration) }
        return Self.subtitleOCRWindowCovered(
            harvestRead: packets.hasReadSpan(from: from, through: through),
            undecodedPackets: packets.entries(streamIndex: Int32(source),
                                              from: cursor.lastDecodedPts.nextUp,
                                              through: through).count)
    }

    /// What `subtitleOCRCoversNativeWindow` saw, for the line that reports a gate that never opened.
    func subtitleOCRCoverageState(ordinal: Int) -> String {
        let from = sourceTime
        var through = from + Self.subtitleOCRLeadSeconds
        if duration > 0 { through = min(through, duration) }
        let cursor = subtitleOCRCursors[ordinal].map { String(format: "%.2f", $0.lastDecodedPts) } ?? "nil"
        var read = "?", undecoded = "?"
        if ordinal < nativeSubtitleTrackTable.count,
           let source = nativeSubtitleTrackTable[ordinal].sourceStreamIndex,
           let packets = activeSubtitlePacketStore {
            read = "\(packets.hasReadSpan(from: from, through: through))"
            if let c = subtitleOCRCursors[ordinal] {
                undecoded = "\(packets.entries(streamIndex: Int32(source), from: c.lastDecodedPts.nextUp, through: through).count)"
            }
        }
        return "armed=\(subtitleOCRArmedOrdinal.map(String.init) ?? "nil") inFlight=\(subtitleOCRBatchInFlight) "
            + "window=\(String(format: "%.1f", from))-\(String(format: "%.1f", through)) read=\(read) "
            + "cursor=\(cursor) undecoded=\(undecoded)"
    }

    nonisolated static func subtitleOCRWindowCovered(harvestRead: Bool, undecodedPackets: Int) -> Bool {
        harvestRead && undecodedPackets == 0
    }

    /// Polls `subtitleOCRCoversNativeWindow` until it holds, the store finished, or the request moved
    /// on (track change, deselect, new item). No deadline: refusing an empty rendition leaves nothing
    /// that retries it, and selecting a partial one makes AVKit cache the rest empty, while a slow
    /// first recognition is real (Vision took over 60 s for one 4K composition in 2 of 7 Mac runs).
    /// Returns the reason, for the pre-fill line.
    func awaitSubtitleOCRCoverage(ordinal: Int, store: NativeSubtitleCueStore,
                                  item: AVPlayerItem) async -> String {
        let reportAt = Date().addingTimeInterval(Self.subtitleOCRPrefillReportSeconds)
        var reported = false
        while true {
            if store.isFinished { return "finished" }
            if subtitleOCRCoversNativeWindow(ordinal: ordinal) { return "covered" }
            guard nativeSubtitleReapplyOrdinal == ordinal, currentAVPlayer?.currentItem === item
            else { return "superseded" }
            if !reported, Date() >= reportAt {
                reported = true
                EngineLog.emit("[AetherEngine] native subtitle OCR pre-fill still waiting after "
                               + "\(Int(Self.subtitleOCRPrefillReportSeconds))s: "
                               + subtitleOCRCoverageState(ordinal: ordinal), category: .engine)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Load/stop teardown: forget covered-region state too (new session, new axis).
    func resetSubtitleOCRState() {
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

    /// #88 external .sup path: fill the needsOCR ordinal's store from the overlay sidecar's OWN
    /// packets (no second download); markFinished so the PiP pre-fill and the whole-file .vtt
    /// handler see complete coverage. #921: decoded a batch at a time on its own decoder, so each
    /// picture lives only as long as its recognition.
    func startSidecarOCRFillIfNeeded(externalTrackID: Int?, source: SidecarBitmapSource) {
        guard let id = externalTrackID,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
              nativeSubtitleTrackTable[ordinal].needsOCR,
              let store = nativeStore(atOrdinal: ordinal),
              !store.isFinished else { return }
        let language = nativeSubtitleTrackTable[ordinal].language
        subtitleOCRSidecarFillTask?.cancel()
        EngineLog.emit("[SubtitleOCR] sidecar fill starting: track=\(id) packets=\(source.packets.count)", category: .engine)
        subtitleOCRSidecarFillTask = BlockingWork.detached(priority: .utility) {
            await source.forEachDecodedBatch(isCancelled: { Task.isCancelled }) { batch in
                await SubtitleImageOCR.appendRecognized(cues: batch, language: language, to: store)
            }
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
