import Foundation
import CoreGraphics

extension AetherEngine {

    /// Frame from the live DVR window at `atSessionSeconds` (seekableLiveRange axis), decoded
    /// locally with no network.
    ///
    /// Two sessions can answer, and both read a buffer the session already holds rather than opening
    /// a second connection (a live source is forward-only, so a second demuxer could not seek it).
    /// A native session decodes from its DVR segment cache after converting stable session time to
    /// raw output. A software session has no such cache, so it decodes out of its own
    /// packet ring (#544), which is the same buffer the scrubber seeks within. nil when neither is
    /// live, when the time is outside the resident window, or when the decode fails.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive else { return nil }
        guard let session = nativeVideoSession else {
            guard let host = softwareHost else { return nil }
            let gen = loadGeneration
            let image = await host.liveScrubStill(atSessionSeconds: seconds, maxWidth: maxWidth)
            // A zap between the request and the frame would hand the new channel the old one's picture.
            return loadGeneration == gen ? image : nil
        }
        guard session.yieldsStills else { return nil }
        // Segment table and tfdt use continuous output time, including across source PTS rebases.
        let outputSeconds = seconds - liveSessionShiftSeconds
        let gen = loadGeneration
        let source = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.scrubThumbnailSource(atSeconds: outputSeconds)
        }.value
        guard let source else { return nil }
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices collide with the next channel's.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = scrubThumbnailExtractors.remove(at: idx)
            scrubThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            guard let reader = source.makeReader() else { return nil }
            extractor = FrameExtractor(reader: reader, formatHint: "mp4")
            scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            while scrubThumbnailExtractors.count > 2 {
                let evicted = scrubThumbnailExtractors.removeFirst()
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
                guard !self.liveItemPlacementPending else { continue }
                self.publishLiveWindow(edgeSessionTime: host.seekableEnd
                                       + self.liveSessionShiftSeconds + self.liveItemAxisOffsetSeconds)
            }
        }
    }

    /// How far behind a live-only session (no DVR window) must be on resume before the playhead counts as
    /// evicted rather than merely behind. A live-only source retains seconds, not minutes.
    nonisolated static let liveOnlyResumeSnapSeconds: Double = 45
    /// Landing margin above the retained floor, so the resume does not start on the very segment the next
    /// eviction takes.
    nonisolated static let liveResumeClampMarginSeconds: Double = 5

    /// What resuming a behind-live session should do to the playhead, as one pure decision (AE#444).
    ///
    /// Both non-`none` outcomes are recoveries from a position that no longer exists, not policy about
    /// where a viewer should be: a live-only source retains seconds, and a DVR window that has slid past
    /// the playhead has evicted it. `clampsToWindow == false` hands that judgement to the host, which is
    /// the only place semantics like "a pause longer than 90 s re-tunes" can live.
    enum LiveResumeAction: Equatable {
        case none
        /// Live-only: `seek(to:)` refuses targets without a DVR window, so this drives the host directly.
        case edgeSnap
        case seek(to: Double)
    }

    nonisolated static func liveResumeAction(
        clampsToWindow: Bool,
        windowSeconds: Double?,
        behindLiveSeconds: Double,
        seekableLowerBound: Double?,
        edgeTime: Double
    ) -> LiveResumeAction {
        guard clampsToWindow else { return .none }
        let margin = liveResumeClampMarginSeconds
        guard let window = windowSeconds else {
            return behindLiveSeconds > liveOnlyResumeSnapSeconds ? .edgeSnap : .none
        }
        // AE#441 follow-up: the LANDING has read the cache's real floor since 6.52.0, but the TRIGGER
        // was still `behind > window - margin`, pure window arithmetic. The two disagree in exactly the
        // regime the retest confirmed on a real strip: retention short of the window (window 420 s,
        // advertised depth ~405 s). A resume between the real depth and the window then found no clamp
        // for a position the cache no longer held. Measure both from the same bound.
        //
        // The margin belongs to the sliding regime only. Before the window fills, the floor is the
        // session's own start rather than an eviction frontier, so nothing is coming to take it and a
        // margin there would only shove a resume near the start forward.
        let floor = seekableLowerBound ?? Swift.max(0, edgeTime - window)
        let playhead = edgeTime - behindLiveSeconds
        let sliding = edgeTime > window
        guard playhead < floor + (sliding ? margin : 0) else { return .none }
        return .seek(to: (seekableLowerBound ?? edgeTime) + margin)
    }

    /// After a long pause the sliding DVR window may have evicted the playhead. Clamp to the retained
    /// floor plus a margin, or for live-only (no DVR) snap to the edge when far enough behind.
    func clampLiveResumeIfBehindWindow() {
        guard isLive, let w = liveWindow else { return }
        let scheduledLoadGeneration = loadGeneration
        let scheduledSeekGeneration = currentSeekGeneration
        let action = Self.liveResumeAction(
            clampsToWindow: loadedOptions.clampsLiveResumeToWindow,
            windowSeconds: w.windowSeconds,
            behindLiveSeconds: w.behindLiveSeconds,
            seekableLowerBound: w.seekableRange?.lowerBound,
            edgeTime: w.edgeTime
        )
        let behind = String(format: "%.1f", w.behindLiveSeconds)
        let window = w.windowSeconds.map { String(format: "%.0f", $0) } ?? "live-only"
        switch action {
        case .none:
            // AE#444: a resume the host owns says so. Silence here is indistinguishable from a resume
            // that was never behind, and this option exists precisely so somebody else decides.
            if !loadedOptions.clampsLiveResumeToWindow,
               w.behindLiveSeconds > Self.liveOnlyResumeSnapSeconds {
                EngineLog.emit(
                    "[AetherEngine] live resume clamp deferred to host: behind=\(behind)s window=\(window)",
                    category: .session
                )
            }
        case .edgeSnap:
            Task {
                guard loadGeneration == scheduledLoadGeneration,
                      currentSeekGeneration == scheduledSeekGeneration else { return }
                EngineLog.emit(
                    "[AetherEngine] live resume clamp: behind=\(behind)s window=live-only -> edge snap",
                    category: .session
                )
                // The whole distance is skipped, and the resume is at the edge.
                liveResumeClamped.send(LiveResumeClamp(skippedSeconds: w.behindLiveSeconds,
                                                       behindLiveSeconds: 0))
                await self.seekToLiveEdge()
            }
        case .seek(let t):
            Task {
                // An explicit Return to Live (or a newer scrub) owns the clock.
                // A clamp decided by an earlier play() must not seek it backward.
                guard loadGeneration == scheduledLoadGeneration,
                      currentSeekGeneration == scheduledSeekGeneration else { return }
                EngineLog.emit(
                    "[AetherEngine] live resume clamp: behind=\(behind)s window=\(window) "
                    + "-> seek \(String(format: "%.1f", t))",
                    category: .session
                )
                liveResumeClamped.send(LiveResumeClamp(
                    skippedSeconds: Swift.max(0, t - (w.edgeTime - w.behindLiveSeconds)),
                    behindLiveSeconds: Swift.max(0, w.edgeTime - t)))
                await self.seek(to: t)
            }
        }
    }

    /// AE#441: the segment cache's oldest contiguously-playable position, lifted onto the session axis
    /// the live surfaces speak. nil on every path with no such cache to ask (software live), which
    /// leaves `seekableLiveRange` on window arithmetic exactly as before.
    ///
    /// Same stable output-to-session conversion as `liveScrubThumbnail`, inverted.
    func residentLiveFloorSessionSeconds() -> Double? {
        guard let session = nativeVideoSession,
              let outputFloor = session.residentFloorOutputSeconds() else { return nil }
        return outputFloor + liveSessionShiftSeconds
    }

    /// AE#446 round 4: measure how far the current item's own timeline sits below the session's.
    ///
    /// A live item's zero is the first segment ITS playlist listed. The producer's window floor and
    /// the item's own floor slide together, because one rule sizes both (`LiveWindowSizing` is the
    /// single source of truth for the playlist's first visible segment and the cache's eviction), so
    /// their difference is the offset and it holds still while both ends move. Measured on the harness
    /// across twelve seconds of sliding: 50.00 s at every sample, while the item's floor walked from
    /// 0.00 to 15.00 and the producer's from 51.40 to 66.40.
    ///
    /// Latched per item, because it is a property of the playlist that item loaded, and re-measured
    /// when the item under the host changes.
    ///
    /// Round 5: the measurement below is the FALLBACK. Where the engine serves the playlist it also
    /// knows the axis exactly, and it states it (see `noteServedLiveItemAxis`); the difference used
    /// to be reconstructed for every item except the one a rejoin placed, which left the session's
    /// own first item on the reconstruction as well. The reading that shows the cost: on 6.57.0 it
    /// read 0 for an item whose playlist began 6.76s in (AE#454 round 2).
    ///
    /// Round 6: the 0.05s a device reconstructed on 6.60.0 was published here as a defect and is not
    /// one. That item's playlist really does begin at 0.050s, because a live item's zero is the
    /// PRESENTATION time of its first frame while the axis anchor pins the first DECODE time to 0, so
    /// a source with frame reordering starts one presentation lead above zero (AE#446,
    /// cmcpherson274). What that reading does show is the branch in
    /// `liveItemStatedAxisReconstructionError`: the reconstruction had nothing at the instant of the
    /// statement, so it could only latch from a later sample.
    @MainActor
    func measureLiveItemAxisOffset() {
        guard isLive, let host = nativeHost else { return }
        // AE#454 round 2: the playlist that placed this item also STATED the axis it placed it on,
        // and a statement outranks a reconstruction. The measurement below is a difference between
        // two independently sampled quantities (the producer's resident floor and the item's own
        // seekable start), so it is only as good as the older of the two samples, it is latched for
        // the item's whole life on the first tick that produces any number at all, and it cannot tell
        // "this item has no offset" from "the sample I had did not belong to this item". Reported from
        // a device on 6.57.0: the session's first swap read an axis of 0 while the item's own playlist
        // began 6.76 s into the session, which put a correctly placed item through a correcting seek
        // and left every published number 6.76 s away from the picture.
        //
        // AE#446 round 5: this used to be gated on the item having carried a rejoin PLACEMENT, which
        // is an unrelated condition. Every live build knows which segment it listed first, so every
        // live item's axis is stated, and the gate is now the item attach that armed the statement.
        // The paths that gained it: the session's own first item, the #130 media fallback (documented
        // to run after the window slid), the #35 gate reloads, an AirPlay hop, and the rejoin branch
        // whose target had been evicted, which arms no placement and therefore had none.
        //
        // Tested BEFORE the per-item latch below, and allowed to overrule it: the serve and the
        // engine's 100 ms tick are not ordered, so a tick that finds a range in the gap between the
        // swap and the serve would otherwise latch a measurement the playlist is about to contradict,
        // and the latch is for the item's whole life.
        if Self.liveItemAxisStatementApplies(armedGeneration: liveItemAxisArmedGeneration,
                                             itemGeneration: host.itemGeneration,
                                             statedGeneration: liveItemAxisStatedGeneration),
           let stated = nativeVideoSession?.servedLiveItemAxisOutputSeconds {
            liveItemStatedAxisReconstructionError(stated: Swift.max(0, stated), host: host)
            liveItemAxisStatedGeneration = host.itemGeneration
            liveItemAxisOffsetGeneration = host.itemGeneration
            liveItemAxisOffsetSeconds = Swift.max(0, stated)
            EngineLog.emit(
                "[AetherEngine] #454 the playlist this item loaded begins "
                + "\(String(format: "%.2f", liveItemAxisOffsetSeconds))s into the session, so that is "
                + "the axis it came up on; stated by the manifest that placed it rather than measured "
                + "off the cache afterwards",
                category: .engine)
            return
        }
        guard host.itemGeneration != liveItemAxisOffsetGeneration else { return }
        // AE#454: everything below this line establishes the axis; until it succeeds there is no
        // measurement for THIS item, and the one above it belongs to the item that just left. See
        // `liveItemAxisUnmeasuredAfterSwap` for what the clock does in the meantime.

        // A range of zero width is an item that has not reported yet, not an item at the origin.
        guard host.seekableEnd > host.seekableStart,
              let producerFloor = residentLiveFloorSessionSeconds() else { return }
        let offset = Self.liveItemAxisOffset(producerFloorSession: producerFloor,
                                             itemSeekableStart: host.seekableStart,
                                             shift: liveSessionShiftSeconds)
        guard offset.isFinite else { return }
        liveItemAxisOffsetGeneration = host.itemGeneration
        liveItemAxisOffsetSeconds = offset
        guard liveItemAxisOffsetSeconds > 0.01 else { return }
        EngineLog.emit(
            "[AetherEngine] #446 this item's playlist began \(String(format: "%.2f", liveItemAxisOffsetSeconds))s "
            + "into the session, so its own clock reads that much below the session's; folding it into "
            + "every conversion for as long as this item is the one playing",
            category: .engine)
    }

    /// AE#454: a fresh item has no position for the session until it says it can play.
    ///
    /// Two readings are wrong in the window between an in-place swap and the fresh item's readiness,
    /// and they were both being published as the session's playhead:
    ///
    /// - The axis offset is latched per item and re-measured when the item under the host changes,
    ///   but the re-measurement needs the fresh item to have reported a seekable range of its own.
    ///   Until then the RETIRED item's offset was folded into the fresh item's clock, which reads ~0,
    ///   so the session published the retired item's zero: 70 to 80 s below the place it held in the
    ///   field, 80.27 s below it on the harness.
    /// - Even with the axis established, AVPlayer's clock before readiness names the segment it
    ///   fetched first rather than where it will start. Measured on the harness after the placement
    ///   moved into the playlist: the item was placed at 50.14 s and reported 40.17 s, one segment
    ///   below, for 192 ms.
    ///
    /// Neither is a reading of where the session is, and both flowed into `LiveWindow.noteEdge`, which
    /// is a running maximum a single wrong sample latches. So the clock and the window hold across the
    /// hand-off. The hold is bounded by readiness, which every other part of the session already
    /// depends on; an item that never becomes ready leaves the clock on the frame that is actually on
    /// screen, which is the honest report of that session.
    ///
    /// False for the first item of a session, where nothing has been accepted yet and the cold join
    /// publishes exactly as before.
    var liveItemPlacementPending: Bool {
        guard isLive, let host = nativeHost else { return false }
        return Self.liveItemPlacementPending(
            acceptedGeneration: liveAcceptedItemGeneration,
            itemGeneration: host.itemGeneration,
            axisGeneration: liveItemAxisOffsetGeneration,
            itemReportsRange: host.seekableEnd > host.seekableStart)
    }

    /// AE#454: from here on, what the item under the host reports IS what the session reports.
    ///
    /// Taken at readiness on every ordinary path, and one step later on a rejoin: an item that is
    /// ready but has not been placed yet is playing where the playlist put it, not where the session
    /// decided to be, and the placement can still be a seek away.
    @MainActor
    func acceptCurrentItemForPublishing() {
        liveAcceptedItemGeneration = nativeHost?.itemGeneration ?? -1
    }

    /// AE#454: the rule above, on its own so the case can be stated without a session.
    nonisolated static func liveItemPlacementPending(
        acceptedGeneration: Int,
        itemGeneration: Int,
        axisGeneration: Int,
        itemReportsRange: Bool
    ) -> Bool {
        guard acceptedGeneration != -1 else { return false }
        if itemGeneration != acceptedGeneration { return true }
        // Ready and axis-less is not a contradiction: they are separate signals and their order is
        // AVFoundation's business, so the second reading is guarded on its own input.
        return itemGeneration != axisGeneration && !itemReportsRange
    }

    /// AE#446 round 5: what the reconstruction this statement replaces would have said, on the line
    /// where the statement is made.
    ///
    /// The error was only ever visible where the two samples were far enough apart to notice, which
    /// is why it survived from 6.56.5 to 6.60.0 (on one device as a 6.76 s reading that was
    /// attributed to something else first). Both terms are known at this instant and neither costs
    /// anything to take, so the difference is stated rather than left to be inferred from a later
    /// disagreement between two logs.
    ///
    /// One line per item attach, and the case where the reconstruction has nothing yet is itself the
    /// answer: it means the measurement would have been taken from a sample this item had not
    /// produced.
    ///
    /// AE#446 round 6: which term is missing is named, because the branch is TIMING and not the item
    /// kind. A start item usually takes it and a rejoin usually does not, but a source that delivers
    /// fast enough wins the race on a start item too (cmcpherson274 measured one; here, the same
    /// harness command takes opposite branches on two seeds that differ only in frame reordering,
    /// gate-open at 0.11 s against 0.39 s). Naming the term is what separates "the item has not
    /// reported yet" from "the producer holds nothing yet" without reading this file.
    @MainActor
    private func liveItemStatedAxisReconstructionError(stated: Double, host: NativeAVPlayerHost) {
        let floor = residentLiveFloorSessionSeconds()
        guard host.seekableEnd > host.seekableStart, let producerFloor = floor else {
            let gap = Self.liveAxisReconstructionGap(
                itemReportsRange: host.seekableEnd > host.seekableStart,
                hasProducerFloor: floor != nil) ?? ""
            EngineLog.emit(
                "[AetherEngine] #446 the reconstruction this replaces had nothing to say yet "
                + "(\(gap)), so it would have been latched from a later sample",
                category: .engine)
            return
        }
        let reconstructed = Self.liveItemAxisOffset(producerFloorSession: producerFloor,
                                                    itemSeekableStart: host.seekableStart,
                                                    shift: liveSessionShiftSeconds)
        EngineLog.emit(
            "[AetherEngine] #446 the reconstruction this replaces would have said "
            + "\(String(format: "%.2f", reconstructed))s, \(String(format: "%.2f", reconstructed - stated))s "
            + "off the axis the manifest states",
            category: .engine)
    }

    /// AE#446 round 6: which of the reconstruction's two terms is missing, for the line above.
    ///
    /// nil is "neither", which the caller never reaches: it is here so the case is stated rather than
    /// left as an unreachable branch, and so the mapping can be tested without a session.
    nonisolated static func liveAxisReconstructionGap(
        itemReportsRange: Bool, hasProducerFloor: Bool
    ) -> String? {
        switch (itemReportsRange, hasProducerFloor) {
        case (true, true): return nil
        case (false, true): return "the item reports no seekable range yet"
        case (true, false): return "the producer holds no resident floor yet"
        case (false, false):
            return "the item reports no seekable range yet and the producer holds no resident floor yet"
        }
    }

    /// AE#446 round 5: whether an axis a build stated describes the item under the host right now.
    ///
    /// Two conditions, and they are different questions. The statement has to have been armed by THIS
    /// item's own attach, or it belongs to the item that just left; and the item must not already
    /// carry one, because an item's zero is the FIRST playlist it loaded and later builds of a sliding
    /// window state a smaller offset against the very same content.
    nonisolated static func liveItemAxisStatementApplies(
        armedGeneration: Int, itemGeneration: Int, statedGeneration: Int
    ) -> Bool {
        itemGeneration == armedGeneration && itemGeneration != statedGeneration
    }

    /// AE#446 round 4: the arithmetic behind `measureLiveItemAxisOffset`, on its own so the case can
    /// be stated without a session.
    ///
    /// The producer's floor is on the session axis; the item's floor is on the item's own. One rule
    /// sizes both, so their difference is what separates the axes, and it is a difference rather than
    /// an assumption. Negative is not a case that can be acted on (an item claiming to hold content
    /// older than the producer does), and it folds to 0, which is the pre-swap behaviour.
    nonisolated static func liveItemAxisOffset(
        producerFloorSession: Double, itemSeekableStart: Double, shift: Double
    ) -> Double {
        Swift.max(0, producerFloorSession - (itemSeekableStart + shift))
    }

    /// AE#684: what a native live item starts ON, once per item.
    ///
    /// Reported from the field: after an item rebuild placed mid-segment (`segment 26 + 1.91s`) sound
    /// and picture were slightly apart, and together again after the next rebuild, which landed on a
    /// boundary (`segment 129 + 0.03s`). The served media measures aligned on the harness (see
    /// `docs/cli.md`), and nothing on macOS can observe what AVPlayer's audio renderer does with it,
    /// so the line states the two facts a device capture needs beside the viewer's verdict: where in
    /// which segment the item started, and where that segment's sound begins against its picture.
    /// The AE#440 line beside it says whether the start was forced with `playImmediately`, which in
    /// that capture was true for the one item reported out of sync and for none of the other four.
    @MainActor
    func noteLiveItemStart() {
        guard isLive, let host = nativeHost, let session = nativeVideoSession else { return }
        let itemSeconds = host.currentTime
        let outputSeconds = itemSeconds + liveItemAxisOffsetSeconds
        EngineLog.emit(
            Self.liveItemStartAccount(
                item: host.itemGeneration, itemSeconds: itemSeconds,
                heads: session.liveSegmentHeads(atOutputSeconds: outputSeconds)),
            category: .engine)
    }

    nonisolated static func liveItemStartAccount(
        item: Int, itemSeconds: Double,
        heads: (index: Int, secondsIntoSegment: Double, pictureStart: Double, sound: (first: Double, last: Double)?)?
    ) -> String {
        let head = "[AetherEngine] #684 item #\(item) starts at its own "
            + "\(String(format: "%.3f", itemSeconds))s"
        guard let heads else { return head + ", in no segment the producer lists yet" }
        let place = ": segment \(heads.index) + \(String(format: "%.3f", heads.secondsIntoSegment))s, "
            + "whose picture opens at \(String(format: "%.3f", heads.pictureStart))s"
        guard let sound = heads.sound else { return head + place + " and whose sound was not recorded" }
        let lead = (heads.pictureStart - sound.first) * 1000
        return head + place + " and whose sound runs "
            + "\(String(format: "%.3f", sound.first))..\(String(format: "%.3f", sound.last))s "
            + "(it opens \(String(format: "%.0f", abs(lead))) ms "
            + (lead >= 0 ? "before" : "after") + " the picture)"
    }

    /// AE#446 round 4: the three readings a rejoin's placement is argued from, on one line.
    ///
    /// They were only ever available separately, which is why an item's clock and an item's seekable
    /// range could disagree for a whole investigation without anyone being able to say so. Bounded to
    /// the seconds after a swap, so a live session does not pay for it.
    @MainActor
    func auditLiveRejoinPlacement() {
        guard let until = liveRejoinAuditUntil, let host = nativeHost else { return }
        let now = Date()
        guard now < until else { liveRejoinAuditUntil = nil; return }
        if let last = liveRejoinAuditLastEmit, now.timeIntervalSince(last) < 1.0 { return }
        liveRejoinAuditLastEmit = now
        let producer = residentLiveRangeSessionSeconds()
        EngineLog.emit(
            "[AetherEngine] #446 placement audit: item clock \(String(format: "%.2f", nativeClockSeconds))s "
            + "in item range \(String(format: "%.2f", host.seekableStart))..\(String(format: "%.2f", host.seekableEnd))s, "
            + "session shift \(String(format: "%.2f", liveSessionShiftSeconds))s + item offset "
            + "\(String(format: "%.2f", liveItemAxisOffsetSeconds))s -> session \(String(format: "%.2f", currentTime))s; "
            + "the producer holds "
            + (producer.map { "\(String(format: "%.2f", $0.lowerBound))..\(String(format: "%.2f", $0.upperBound))s" } ?? "nothing it can state"),
            category: .engine)
    }

    /// AE#446 round 4: what the producer holds right now, on the session axis, both ends.
    ///
    /// This is the range a rejoin is measured against, and it is deliberately not either of the two
    /// the engine publishes. `LiveWindow.edgeTime` is a running maximum an outage freezes BELOW the
    /// playhead that legitimately ran past it, and a freshly swapped item's `seekableEnd` is a range
    /// it has not finished reporting at the readiness instant the rejoin replays in (measured on the
    /// harness: 43.4 s while the place held was 71.4 s and the producer was cutting past 100 s). The
    /// cache is the only party that is neither ahead of nor behind itself.
    ///
    /// nil where there is no cache to ask, which leaves the rejoin exactly where it was.
    func residentLiveRangeSessionSeconds() -> ClosedRange<Double>? {
        guard let session = nativeVideoSession,
              let floorOutput = session.residentFloorOutputSeconds(),
              let ceilingOutput = session.residentCeilingOutputSeconds() else { return nil }
        let floor = floorOutput + liveSessionShiftSeconds
        let ceiling = ceilingOutput + liveSessionShiftSeconds
        guard ceiling >= floor else { return nil }
        return floor...ceiling
    }

    /// AE#442: the TARGETDURATION the live playlist is serving, nil on every path that serves none
    /// (remote HLS live, the software live path, and before the first playlist build).
    public var liveTargetDurationSeconds: Double? {
        nativeVideoSession?.sealedLiveTargetDurationSeconds().map(Double.init)
    }

    /// The current native item's usable live edge on the engine's display timeline.
    /// Nil before the item has a range and on software routes. Uses the asynchronous
    /// host mirror rather than AVPlayerItem's synchronous seekableTimeRanges getter.
    /// If that mirror predates retained history, only already-played resident media is admitted.
    public var currentItemLiveEdgeTime: Double? {
        guard isLive, videoRoute != .software, nativeItemSeekableEnd > 0 else { return nil }
        let edge = nativeItemSeekableEnd + liveSessionShiftSeconds + liveItemAxisOffsetSeconds
        guard edge.isFinite else { return nil }
        // The effective allowance, which a lease renewal or expiry moves (#714), not the load option.
        if liveWindow?.windowSeconds != nil,
           let fallback = Self.nativePlayedResidentEdge(reportedEdge: edge, playedTime: currentTime,
                publishedEdge: liveWindow?.edgeTime ?? currentTime,
                residentRange: residentLiveRangeSessionSeconds()) {
            return fallback
        }
        return edge
    }

    /// The same session-axis fallback for publication and an actual native seek. A stale
    /// item edge cannot disqualify already-played resident history, and a prefetched ceiling
    /// cannot create history. Preserve the published played frontier across a backward seek.
    nonisolated static func nativePlayedResidentEdge(
        reportedEdge: Double, playedTime: Double, publishedEdge: Double,
        residentRange: ClosedRange<Double>?
    ) -> Double? {
        guard let resident = residentRange,
              resident.lowerBound.isFinite, resident.upperBound.isFinite,
              reportedEdge.isFinite, reportedEdge <= resident.lowerBound,
              playedTime.isFinite, publishedEdge.isFinite else { return nil }
        return min(max(max(playedTime, publishedEdge), resident.lowerBound), resident.upperBound)
    }

    /// Update native HLS retention without load/reload, source requests, or a second player.
    /// Supply a fresh temporary-volume capacity and its monotonic expiry deadline.
    /// False for software/remote/unready sessions. Their conservative load options are untouched.
    @discardableResult
    public func setNativeLiveDVRLimits(_ limits: LiveDVRLimits, availableCapacityBytes: Int64?) -> Bool {
        guard isLive, isSessionReady, videoRoute == .loopback, let session = nativeVideoSession,
              session.setNativeLiveDVRLimits(limits, availableCapacityBytes: availableCapacityBytes) else { return false }
        // Capacity lease renewal alone must not add clock publications to the existing tick rate.
        if liveWindow?.windowSeconds != session.nativeLiveDVRWindow?.windowSeconds {
            publishLiveWindow(edgeSessionTime: liveWindow?.edgeTime ?? currentTime)
        }
        return true
    }

    /// Bound the software packet spool without stopping its source, decoders or clock.
    /// Requires LoadOptions.softwareDVRRetention. Expiry withdraws optional history
    /// and falls back to the caller-selected playback cushion.
    @discardableResult
    public func setSoftwareLiveDVRLimits(_ limits: LiveDVRLimits, availableCapacityBytes: Int64?) -> Bool {
        guard isLive, isSessionReady, videoRoute == .software, let host = softwareHost else { return false }
        return host.setLiveDVRLimits(limits, availableBytes: availableCapacityBytes)
    }
    public var softwareLiveDVRBytes: Int64? { softwareHost?.liveDVRBytes.map(Int64.init) }

    /// Finite pinned playback payload that may exceed the optional retention allowance.
    /// Does not include muxer staging, init/subtitle data, AVPlayer buffers, or recording output.
    public var nativeLiveDVRMandatoryBytes: Int64? {
        guard isLive, videoRoute == .loopback, let session = nativeVideoSession else { return nil }
        return Int64(session.nativeLiveDVRMandatoryBytes)
    }

    /// Publish the live timeline after reconciling actual resident history.
    func publishLiveWindow(edgeSessionTime: Double) {
        guard var w = liveWindow else { return }
        if videoRoute == .loopback, let limits = nativeVideoSession?.nativeLiveDVRWindow {
            w.setWindowSeconds(limits.windowSeconds)
        } else if videoRoute == .software {
            // The software spool owns both actual retained history and capacity expiry.
            // A route transition never transfers expanded native retention into it.
            w.setWindowSeconds(softwareHost?.liveDVRWindowSeconds)
        }
        // Resident media bounds the allowance on both playback routes.
        var residentFloor = videoRoute == .software ? softwareHost?.liveDVRResidentFloor : residentLiveFloorSessionSeconds()
        // An empty/delayed AVPlayer seekableTimeRanges mirror yields only the item's zero
        // (plus its axis offset). It must not pin a ready native DVR window at that zero
        // while its real cache and played clock advance. Admit only already-played,
        // contiguous resident media; never promote the producer's prefetched frontier.
        // `w.windowSeconds` is the effective (renewed or expired) allowance set just above.
        var reportedEdge = edgeSessionTime
        if videoRoute == .loopback, w.windowSeconds != nil,
           let floor = residentFloor, floor.isFinite, reportedEdge <= floor,
           let resident = residentLiveRangeSessionSeconds(),
           let fallback = Self.nativePlayedResidentEdge(
                reportedEdge: reportedEdge, playedTime: currentTime,
                publishedEdge: w.edgeTime, residentRange: resident) {
            residentFloor = resident.lowerBound
            reportedEdge = fallback
        }
        w.noteEdge(reportedEdge)
        w.notePlayhead(currentTime)
        w.noteResidentFloor(residentFloor)
        // Sodalite#104 round 4: the cadence the playlist declares, which outranks how the source
        // happened to deliver. nil on the paths that serve no playlist of ours.
        w.noteTargetDuration(liveTargetDurationSeconds)
        // Sodalite#104 round 2: does this tick describe a session keeping up by playback alone? Only
        // such a tick's distance says what THIS source costs a client at the edge, and the samples are
        // rate-limited so twelve of them span a stretch of media rather than a stretch of ticks (the
        // publish rate follows `$currentTime`, not the wall clock).
        let advance = lastPublishedLivePlayhead.map { currentTime - $0 } ?? 0
        let sampleDue = lastLiveCadenceSamplePlayhead.map { currentTime - $0 >= 0.5 } ?? true
        let tracking = state == .playing && !isSeeking && advance > 0 && advance < 1.5 && sampleDue
        if tracking { lastLiveCadenceSamplePlayhead = currentTime }
        w.settleEdgeVerdict(tracking: tracking)
        auditLiveRejoinPlacement()
        liveWindow = w
        // AE#442: tick-to-tick advancement, not a running maximum: a backward DVR seek drops the
        // playhead, and the next advancing publish has to be able to record the new, larger distance.
        if let previous = lastPublishedLivePlayhead, currentTime > previous + 0.05 {
            liveBehindWhenLastAdvancing = w.behindLiveSeconds
        }
        lastPublishedLivePlayhead = currentTime
        // Sodalite#104: one line per TRANSITION of the edge verdict, with every number that decided
        // it. A host draws its LIVE badge and its DVR rail from this flag, so a report of "the bar
        // jumped back to live" is otherwise unanswerable from a device: the distance alone does not
        // say what it was judged against, and the tolerance follows the cadence now.
        if clock.isAtLiveEdge != w.isAtEdge {
            EngineLog.emit(
                "[AetherEngine] #104 live edge verdict \(w.isAtEdge ? "AT EDGE" : "BEHIND"): "
                + "behind=\(String(format: "%.2f", w.behindLiveSeconds))s "
                + "playhead=\(String(format: "%.2f", currentTime))s "
                + "edge=\(String(format: "%.2f", w.edgeTime))s "
                + "lastEdgeStep=\(String(format: "%.2f", w.lastEdgeStepSeconds))s "
                + "targetDuration=\(w.targetDurationSeconds.map { String(format: "%.2f", $0) + "s" } ?? "none") "
                + "trackingCadence=\(w.trackingCadenceSeconds.map { String(format: "%.2f", $0) + "s" } ?? "none") "
                + "tolerance=\(String(format: "%.2f", w.edgeToleranceSeconds))s "
                + "exitAbove=\(String(format: "%.2f", w.edgeToleranceSeconds + LiveWindow.edgeExitSlack))s",
                category: .session
            )
        }
        clock.liveEdgeTime = w.edgeTime
        clock.seekableLiveRange = w.seekableRange
        clock.isAtLiveEdge = w.isAtEdge
        clock.behindLiveSeconds = w.behindLiveSeconds
        logLiveCushionIfDue(window: w)
    }

    /// AE#524: one line when the client's own runway gets thin, which is what precedes a stall.
    ///
    /// This was a per-second probe while the defect was open, and that is what it was for: the
    /// reconstruction it replaced produced two incompatible readings of the same minute. What it
    /// measured is now understood, so only the part worth a line in a shipped session survives.
    ///
    /// The healthy shape, measured over 92 s on a 6 s-segment source with the fix in: the playhead
    /// sits between 5 and 13 s behind the newest cut, sawtoothing by one delivery interval as each
    /// batch lands, and what AVPlayer has FETCHED never drops under 3 s. So the fetched runway is the
    /// number that says a stall is coming, and the two distances either side of it are context.
    @MainActor
    func logLiveCushionIfDue(window w: LiveWindow) {
        let now = Date()
        if let last = lastLiveCushionLogAt, now.timeIntervalSince(last) < 1.0 { return }
        lastLiveCushionLogAt = now
        let playhead = currentTime
        let edge = w.edgeTime
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ahead = await self.avPlayerBufferAheadSeconds()
            let generation = self.nativeHost?.itemGeneration ?? -1
            guard ahead < Self.liveThinRunwaySeconds else {
                // This item has held the floor, so a thin reading on it from here on is a decay.
                self.liveRunwayHealthyGeneration = generation
                self.liveThinRunwayNoted = false
                return
            }
            guard Self.reportsThinLiveRunway(itemGeneration: generation,
                                             healthyGeneration: self.liveRunwayHealthyGeneration,
                                             alreadyNoted: self.liveThinRunwayNoted)
            else { return }
            self.liveThinRunwayNoted = true
            EngineLog.emit(
                "[AetherEngine] #524 the client is running thin: it holds "
                + "\(String(format: "%.2f", ahead))s of fetched runway, playhead "
                + "\(String(format: "%.2f", playhead))s against a seekable edge of "
                + "\(String(format: "%.2f", edge))s",
                category: .session
            )
        }
    }

    /// AE#524: under this much fetched content a live client is one late delivery from a stall.
    /// Measured on a healthy session: the sawtooth bottoms out around 3 s.
    static let liveThinRunwaySeconds: Double = 2.0

    /// AE#524 round 2: whether a thin reading is a session decaying, or an item that has not fetched yet.
    ///
    /// The line was born from a session that decayed: 57 s of healthy fetching, then a deficit that
    /// accumulated until the runway was gone. A fresh mount reads identically and means the opposite.
    /// Reported from the field on AE#440, 17 ms after a load: `0.00s of fetched runway, playhead 0.00s
    /// against a seekable edge of 0.00s`, a non-measurement in the shape of a measurement.
    ///
    /// Time since load does not separate the two, because an in-place swap (#446 rejoin) mounts an
    /// empty item on a session whose playhead and edge are real and holds nothing for about 190 ms.
    /// The ITEM separates them: a thin reading counts once the item being measured has been seen
    /// holding the floor, and health does not travel across a swap.
    ///
    /// A join that never reaches the floor therefore never reports here, and that is the intent: it
    /// never had a runway to run thin on, and the join's own lines and `playbackStalled` describe it.
    /// This line answers one question, whether a session that was healthy is decaying.
    nonisolated static func reportsThinLiveRunway(
        itemGeneration: Int,
        healthyGeneration: Int?,
        alreadyNoted: Bool
    ) -> Bool {
        guard let healthyGeneration, healthyGeneration == itemGeneration else { return false }
        return !alreadyNoted
    }

    /// AE#446 round 4: who asked for a seek. The two differ in exactly two places, both about a live
    /// session that advertises no DVR window: whether the seek is refused outright, and whether its
    /// landing is measured against what the session offers or against what the item holds.
    ///
    /// A host that draws no scrubber can still have a place to come back to. Reported from a device:
    /// the outage swap carried the held position, the replay went out through the public `seek(to:)`
    /// like any host scrub, and the live-only guard refused it before it could land.
    enum SeekOrigin: Sendable {
        /// A scrub the host asked for, bound by the contract `seekableLiveRange` states.
        case host
        /// The engine coming back to a position it decided itself (the AE#446 outage swap, AE#442's
        /// in-place recovery reload). Not a scrub, and not bound by the scrubber's contract.
        case liveRejoin
    }

    /// AE#446 round 4: whether a live seek is refused for having no DVR window to land in.
    ///
    /// The refusal is the host contract's defence-in-depth: hosts hide the scrubber when
    /// `seekableLiveRange` is nil, and one that does not must not put the item somewhere it cannot
    /// play from. It says nothing about the engine's own rejoin, which picked its position out of
    /// content the session itself served.
    nonisolated static func liveSeekRefusedWithoutDVR(origin: SeekOrigin, windowSeconds: Double?) -> Bool {
        guard origin == .host else { return false }
        return windowSeconds == nil
    }

    /// AE#446 round 3: where a live seek lands, decided from ONE sample of the item's own clock.
    ///
    /// The two halves used to read different clocks. The target was clamped against
    /// `LiveWindow.edgeTime`, a running maximum folded over every publish tick of the session, and the
    /// conversion then subtracted that same edge from a `seekableEnd` sampled now. The pair only
    /// agrees while both describe the same epoch, and the two moments where they do not are exactly
    /// the ones a rejoin runs in:
    ///
    /// - An outage freezes the edge. The item that saw the ENDLIST never reloads its playlist, so
    ///   nothing advances `edgeTime` while the playhead legitimately runs on through the runway. The
    ///   held position is then ABOVE the published edge, the clamp pulls it back down onto it,
    ///   `behind` collapses to zero, and the fresh item joins the live edge. Measured on a device: a
    ///   viewer 31 s behind rejoined 29 s of content past the place it held, with its timeshift gone.
    /// - A rebase moves the shift. An edge published on the new shift against an item still
    ///   presenting the old one lands the seek BACKWARD by their difference (reported: 47 s of
    ///   re-watched content, 49.06 s of rebase).
    ///
    /// The edge comes from the item being seeked. For loopback live, callers pass its stable
    /// session axis: source PTS seams cannot invert a timestamp rollback unambiguously.
    nonisolated static func liveSeekLanding(
        requested: Double,
        window: LiveWindow,
        itemEnd: Double,
        shift: Double,
        axis: PresentationAxisMap,
        origin: SeekOrigin = .host,
        residentRange: ClosedRange<Double>? = nil,
        itemAxisOffset: Double = 0,
        nativePlayedTime: Double? = nil
    ) -> (sessionTarget: Double, clockTarget: Double) {
        // An item with no seekable range of its own yet has nothing to sample; the window's own edge
        // is then the only edge there is, and clamping against `shift` alone would collapse the range.
        let reportedEdge = itemEnd + shift + itemAxisOffset
        let playedResidentEdge = nativePlayedTime.flatMap {
            Self.nativePlayedResidentEdge(reportedEdge: reportedEdge, playedTime: $0,
                                          publishedEdge: window.edgeTime, residentRange: residentRange)
        }
        // Positive but stale mirrors need the same fallback as publication. A valid positive
        // item range still clamps against the item's own edge, preserving rejoin/axis semantics.
        let edge = playedResidentEdge ?? (itemEnd > 0 ? reportedEdge : window.edgeTime)
        var landingWindow = window
        if playedResidentEdge != nil, let resident = residentRange {
            landingWindow.noteResidentFloor(resident.lowerBound)
        }
        // AE#446 round 4: a host scrub is bound by what the session ADVERTISES, and the engine's own
        // rejoin by what the producer HOLDS. They are different questions, and at the moment a rejoin
        // runs they have different answers: the advertised range is measured against an edge that is
        // stale in one direction or the other (see `residentLiveRangeSessionSeconds`), while the
        // carried position is content this same session cut and served, so the only thing that can
        // disqualify it is eviction.
        let sessionTarget: Double
        if origin == .liveRejoin, let resident = residentRange {
            sessionTarget = Swift.min(Swift.max(requested, resident.lowerBound), resident.upperBound)
        } else {
            sessionTarget = landingWindow.clamp(requested, edge: edge)
        }
        // AE#446 round 4: and then down onto the item's own axis, which for an item attached after
        // the window slid begins above the session's zero. See `measureLiveItemAxisOffset`.
        let mappedClockTarget = Swift.max(
            0, (axis.itemSeconds(forSourceSeconds: sessionTarget) ?? (sessionTarget - shift))
               - itemAxisOffset)
        // Floating-point axis inversion can put an edge seek a few picoseconds beyond the
        // item's measured end. Keep host seeks within that end; stale-edge recovery and live
        // rejoin deliberately use their resident bounds instead.
        let clockTarget = origin == .host && itemEnd > 0 && playedResidentEdge == nil
            ? Swift.min(mappedClockTarget, itemEnd) : mappedClockTarget
        return (sessionTarget, clockTarget)
    }

    /// Sodalite#104 round 3: where a software live seek lands, given where it was asked to land.
    ///
    /// The software path plays out of a ring the reader fills at the rate the source delivers, so a
    /// landing AT the frontier has nothing ahead of it: the pump finds the ring dry, the clock parks,
    /// and it resumes once `rebufferResumeLeadSeconds` of audio stands ahead of it. On a real-time
    /// source that lead arrives exactly as slowly as it is deep, and the frontier moves on by the same
    /// amount meanwhile, so the session resumes that far behind the frontier after a frozen picture
    /// of the same length. Measured from a device on a tuner: `lead=0.13s` to `lead=2.05s` in 1.92 s
    /// on every Return to Live, while a rewind into content the ring already held reached its first
    /// frame in 223 to 258 ms.
    ///
    /// Landing the lead behind the frontier reaches the same place with the same cushion and spends
    /// nothing on the way. A target the ring already holds that lead for is untouched.
    nonisolated static func softwareLiveLanding(requested: Double, window: LiveWindow) -> Double {
        window.clamp(Swift.min(requested, window.edgeTime - AudioLookaheadPolicy.rebufferResumeLeadSeconds))
    }

    /// AE#454: how close the fresh item has to be to the place it was asked for before the correcting
    /// seek is not worth its cost.
    ///
    /// Tight on purpose. `EXT-X-START` with `PRECISE=YES` places an item exactly (measured on the
    /// harness: 6 ms from the target), so anything a segment boundary or an ignored tag could produce
    /// is far outside this and still gets the seek. It is a test of whether the placement WORKED, not
    /// a tolerance on where a rejoin may land.
    nonisolated static let liveRejoinPlacementSatisfiedSeconds: Double = 0.5

    /// AE#454 round 2: the item-axis position a rejoin's placement resolves to, and where the number
    /// came from.
    ///
    /// Two ways to name the same content, and only one of them is a statement. The playlist SAID where
    /// it placed the item, in the units the item counts in, so where that value exists it is the
    /// answer and the check needs no axis at all. The reconstruction is what the check used to ask
    /// instead: the session target, minus the seam shift, minus a separately measured axis offset, and
    /// that last term is exactly the one a fresh item cannot supply yet.
    ///
    /// nil when neither is available, which leaves the correcting seek to run as it always did.
    nonisolated static func liveRejoinPlacementTarget(
        served: Double?, reconstructed: Double?
    ) -> (target: Double, stated: Bool)? {
        if let served { return (served, true) }
        if let reconstructed { return (reconstructed, false) }
        return nil
    }

    /// AE#454: the item-axis position a live rejoin target resolves to right now, or nil with nothing
    /// to resolve it against. Same pure landing rule the seek itself uses, so the comparison cannot
    /// drift from the seek it decides to skip.
    @MainActor
    func liveRejoinItemAxisTarget(_ sessionTarget: Double) -> Double? {
        guard isLive, let window = liveWindow, let host = nativeHost else { return nil }
        return Self.liveSeekLanding(
            requested: sessionTarget,
            window: window,
            itemEnd: host.seekableEnd,
            shift: liveSessionShiftSeconds,
            axis: liveSessionSeekAxis,
            origin: .liveRejoin,
            residentRange: residentLiveRangeSessionSeconds(),
            itemAxisOffset: liveItemAxisOffsetSeconds
        ).clockTarget
    }

    /// Seek behind the current live edge by a caller-selected offset, clamped to
    /// retained media. Zero preserves the default edge-seek behavior. Negative or
    /// nonfinite offsets are treated as zero; choosing a safety margin belongs to the host.
    public func seekToLiveEdge(offsetSeconds: Double = 0) async {
        let offset = offsetSeconds.isFinite ? Swift.max(0, offsetSeconds) : 0
        // Sodalite#104 round 3: both early exits discard a press the viewer made, so both say so, the
        // same way `seek(to:)` logs its refusals. Silence here reads exactly like a press that never
        // arrived.
        guard isLive, let w = liveWindow else {
            EngineLog.emit("[AetherEngine] seekToLiveEdge() ignored: no live session (state=\(state), live=\(isLive))",
                           category: .engine)
            return
        }
        // Live-only (no DVR window): seek(to:) refuses; drive the native host directly.
        guard w.windowSeconds != nil else {
            guard let host = nativeHost else {
                EngineLog.emit("[AetherEngine] seekToLiveEdge() ignored: live-only session with no native item to snap",
                               category: .engine)
                return
            }
            let edge = Swift.max(0, host.seekableEnd)
            let floor = Swift.min(edge, Swift.max(0, host.seekableStart))
            let clockTarget = Swift.max(floor, edge - offset)
            EngineLog.emit(
                "[AetherEngine] live-only edge seek: target=\(String(format: "%.1f", clockTarget)) "
                + "edge=\(String(format: "%.1f", host.seekableEnd)) "
                + "offset=\(String(format: "%.1f", offset))",
                category: .engine
            )
            let loadGen = loadGeneration
            let seekGen = advanceSeekGeneration()
            await host.seek(to: clockTarget)
            // Audit CORE-7: the native host survives a native-to-native zap, so this seek can finish
            // against the next channel's item, and a scrub started meanwhile owns the clock too.
            guard loadGeneration == loadGen, currentSeekGeneration == seekGen else {
                EngineLog.emit("[AetherEngine] live-only edge snap superseded; clock left to the successor",
                               category: .engine)
                return
            }
            nativeClockSeconds = clockTarget
            clock.currentTime = clockTarget + liveSessionShiftSeconds + liveItemAxisOffsetSeconds
            return
        }
        let edge = Swift.min(w.edgeTime, currentItemLiveEdgeTime ?? w.edgeTime)
        let floor = w.seekableRange(edge: edge)?.lowerBound ?? edge
        let target = Swift.max(floor, edge - offset)
        await seek(to: target)
    }
}
