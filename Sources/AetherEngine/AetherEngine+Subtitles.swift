import Foundation
import AVFoundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import os

/// Which subtitle output path a reader / apply / cancel call targets.
/// `.primary` maps to the original single-track storage and behavior;
/// `.secondary` maps to the independent companion track (issue #47).
public enum SubtitleChannel: Sendable {
    case primary
    case secondary
}

extension SubtitleForwardPrefetcher {
    /// #151: on the 6.60.0-atlas.1 device run, refusals fell from roughly 150 to 21, but every 429
    /// after the pump went quiet came from this best-effort reader reopening every 4 to 10 seconds.
    /// A paced or single-slot origin keeps the pump's tap-fed subtitles and yields the speculative
    /// far-ahead window, the same trade already documented for serial source requests.
    static func shouldHold(originPaced: Bool, originSerial: Bool) -> Bool {
        originPaced || originSerial
    }
}

extension AetherEngine {

    // MARK: - Channel routing


    func isSubtitleActive(for channel: SubtitleChannel) -> Bool {
        switch channel {
        case .primary:   return isSubtitleActive
        case .secondary: return isSecondarySubtitleActive
        }
    }

    /// Activate an embedded subtitle stream. #112 rework: the producer pump keeps every embedded
    /// subtitle stream and harvests its packets into the session's SubtitlePacketStore; a
    /// playhead-paced drainer decodes the selected stream into the overlay. No side demuxer,
    /// no second connection, selection is instant and rides seeks/restarts with the producer.
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text) and bitmap codecs (PGS / DVB /
    /// DVD). XSUB is classified as bitmap by the decoder too, but the shipped FFmpeg build compiles
    /// no xsub decoder, so such a track selects and then decodes to nothing; it is deliberately not
    /// claimed anywhere in the documentation.
    public func selectSubtitleTrack(index: Int) {
        hostExplicitSubtitleAction = true
        selectSubtitleTrack(index: index, startAt: sourceTime)
    }

    /// `selectSubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the live
    /// `sourceTime`; the preferred-subtitle-language auto-select at load passes the resume position so the side
    /// demuxer seeks to the playhead instead of burst-reading from byte 0 on a resumed mid-file load (#73).
    func selectSubtitleTrack(index: Int, startAt: Double) {
        // Phase D: every selection change disarms the OCR worker first; the embedded bitmap
        // branch below re-arms it (cursors persist, so a reselect resumes coverage).
        cancelSubtitleOCRWorker()
        // #316: an external track the remote-HLS proxy declared as a rendition is rendered by AVPlayer
        // itself, so it must NOT also start a sidecar decode; the overlay would draw the same cues a
        // second time, and only the rendition survives PiP / AirPlay / an external display.
        if let renditionName = injectedSubtitleRenditionNames[index] {
            selectInjectedSubtitleRendition(id: index, name: renditionName)
            return
        }
        // #88: external ids route onto the sidecar decode path; no side demuxer, no loadedURL needed.
        if let external = externalSubtitleRegistry[index] {
            selectExternalSubtitleTrack(id: index, track: external)
            return
        }
        // AE#154: remote-HLS bypass ids drive AVMediaSelection; AVPlayer renders the cues itself.
        if RemoteHLSMediaSelection.ordinal(forTrackID: index) != nil {
            selectRemoteHLSSubtitleTrack(id: index)
            return
        }
        // AE#359: a live SUBTITLES rendition carries no packets in this demuxer; its cues come from the
        // rendition's own WebVTT playlist, fetched only now that the host has actually asked for it.
        if Self.isLiveSubtitleRenditionTrackID(index) {
            selectLiveSubtitleRendition(id: index)
            return
        }
        guard index < Self.externalSubtitleTrackIDBase else { return }  // unknown external id: no-op
        guard loadedURL != nil else { return }

        // #77: in-band CEA-608/708 is fed by the always-on producer CC tap (set up at load), not a side
        // demuxer. Selecting it just makes it the active track and mirrors the tap's cue snapshot. Tear down
        // any running embedded reader first (no reuse: CC won't touch the side demuxer, so don't pin a remote
        // connection open while it plays).
        if let codec = subtitleTracks.first(where: { $0.id == index })?.codec,
           Self.isEmbeddedClosedCaptionCodec(codec) {
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary)   // #112 rework: CC is tap-fed, not drained
            isSubtitleActive = true
            activeEmbeddedSubtitleStreamIndex = Int32(index)
            activeSubtitleTrackIndex = index
            isLoadingSubtitles = false
            subtitleCues = ccCueSnapshot
            return
        }

        // #112 rework: every embedded track (text and bitmap, VOD and live) is served by the
        // playhead-paced drainer from the session's packet store. The producer keeps all subtitle
        // streams from init, so selection needs no side demuxer, no positioning, and no recovery:
        // the immediate drainer tick backfills the window around the playhead synchronously.
        cancelSidecarTask()
        isSubtitleActive = true
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        activeEmbeddedSubtitleStreamIndex = Int32(index)
        activeSubtitleTrackIndex = index
        subtitleDrainTargets[.primary] = Int32(index)
        subtitleDrainDecoders[.primary] = nil
        subtitleDrainCursors[.primary] = nil
        // Phase D: a bitmap track additionally arms the OCR worker feeding its native rendition.
        // Armed BEFORE the prefetcher start so the raised lead is picked up.
        if let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: index, in: nativeSubtitleTrackTable),
           nativeSubtitleTrackTable[ordinal].needsOCR {
            startSubtitleOCRWorker(ordinal: ordinal, streamIndex: Int32(index))
        }
        startSubtitleDrainer()
        startSubtitleForwardPrefetcher(startAt: startAt)   // #151
        isLoadingSubtitles = false
        EngineLog.emit(
            "[AetherEngine] overlay fed by packet-store drainer for stream=\(index) "
            + "(backfilled \(subtitleCues.count) cues)",
            category: .engine
        )
    }

    /// Apply `LoadOptions.preferredSubtitleLanguages` at the end of a successful load: activate the best-ranked
    /// subtitle track whose language matches a preference (scanned in order; see `selectSubtitleIndex`), else
    /// leave subtitles off (the default). Uses the host-overlay path (equivalent to a `selectSubtitleTrack`
    /// call); `startAnchor` is the
    /// load's resume position so a mid-file resume seeks the side demuxer to the playhead instead of byte 0.
    /// A no-op when the list is empty, no track matches, or the host already activated a subtitle. The resolved
    /// index is published via `activeSubtitleTrackIndex`. Independent of `prepareNativeSubtitles`. (#73)
    func applyPreferredSubtitleSelection(startAnchor: Double?, sourceDuration: Double?) {
        guard !loadedOptions.preferredSubtitleLanguages.isEmpty, !isSubtitleActive,
              !hostExplicitSubtitleAction else { return }
        guard let index = Self.selectSubtitleIndex(
            tracks: subtitleTracks,
            preferredLanguages: loadedOptions.preferredSubtitleLanguages
        ) else { return }
        EngineLog.emit(
            "[AetherEngine] preferred-subtitle auto-select stream=\(index) langs=\(loadedOptions.preferredSubtitleLanguages)",
            category: .engine
        )
        // Bound the anchor to the probe duration (synchronously known here; the published `duration` is set
        // asynchronously and is still 0 at this point). A stale resume > duration would otherwise seek the
        // side demuxer past EOF and the auto-selected subtitle would silently never appear. Unknown duration
        // (probe failure / live) leaves the anchor unclamped. Mirrors seek()'s clamp.
        var anchor = max(0, startAnchor ?? 0)
        if let duration = sourceDuration, duration > 0 { anchor = min(anchor, duration) }
        selectSubtitleTrack(index: Int(index), startAt: anchor > 0 ? anchor : sourceTime)
    }

    /// Activate an embedded subtitle stream as the secondary companion track (issue #47). Text-only; bitmap codecs are rejected. Runs a second side demuxer concurrently. External ids (#88) route onto the secondary sidecar decode.
    public func selectSecondarySubtitleTrack(index: Int) {
        selectSecondarySubtitleTrack(index: index, startAt: sourceTime)
    }

    /// `selectSecondarySubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the
    /// live `sourceTime`; the audio-switch reload passes the pre-stopInternal snapshot, because a sourceTime read
    /// mid-reload has collapsed to the playlist axis and would re-arm the side demuxer ~producer-shift seconds
    /// behind the playhead (#112, matching the primary `selectSubtitleTrack(index:startAt:)` split).
    func selectSecondarySubtitleTrack(index: Int, startAt: Double) {
        hostExplicitSubtitleAction = true
        if let external = externalSubtitleRegistry[index] {
            cancelSidecarTask(channel: .secondary)
            clearSubtitleDrainTarget(channel: .secondary)   // #112 rework
            activeSecondaryEmbeddedSubtitleStreamIndex = -1
            activeSecondaryExternalSubtitleTrackID = index
            startSecondarySidecarDecode(url: external.url, httpHeaders: external.httpHeaders,
                                        sourceStreamIndex: external.sourceStreamIndex)
            return
        }
        guard index < Self.externalSubtitleTrackIDBase else { return }
        activeSecondaryExternalSubtitleTrackID = nil
        guard loadedURL != nil else { return }
        cancelSidecarTask(channel: .secondary)

        // #112 rework: secondary embedded tracks ride the same packet-store drainer on their
        // own channel; the immediate tick backfills synchronously.
        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        activeSecondaryEmbeddedSubtitleStreamIndex = Int32(index)
        subtitleDrainTargets[.secondary] = Int32(index)
        subtitleDrainDecoders[.secondary] = nil
        subtitleDrainCursors[.secondary] = nil
        startSubtitleDrainer()
        startSubtitleForwardPrefetcher(startAt: startAt)   // #151
        isLoadingSecondarySubtitles = false
    }




    /// #112 round 8: wall-clock budget for one side-reader positioning seek (prewarm / lead-in / reconstruct).
    /// A timestamp seek on an index-less remote MPEG-TS binary-searches via read_timestamp and can otherwise sit
    /// in starved range reads for minutes while the video pipeline owns the origin.
    nonisolated static let sideReaderSeekBudgetSeconds: TimeInterval = 8.0





    /// #112 full umbau: the bitmap (image) cues visible at `playhead` - those whose window covers it. An audio-track
    /// switch does not move the playhead, so the engine snapshots these before the pipeline reload and restores them
    /// after, keeping the on-screen PGS line up instead of tearing it down and reconstructing it from a back-scan.
    /// Image-only: text tracks re-decode from their index cheaply and need no preservation.
    nonisolated static func activeImageCues(in cues: [SubtitleCue], at playhead: Double) -> [SubtitleCue] {
        cues.filter { cue in
            guard case .image = cue.body else { return false }
            return cue.startTime <= playhead && playhead < cue.endTime
        }
    }


    // MARK: - #112 rework: playhead-paced overlay drainer

    /// The active session's packet store: the HLS producer tap or the SW-host tap.
    /// nil when no session is loaded.
    var activeSubtitlePacketStore: SubtitlePacketStore? {
        nativeVideoSession?.subtitlePacketStore ?? softwareSubtitlePacketStore
    }

    /// Build a fresh overlay decoder for the stream on whichever host owns the session demuxer.
    func makeSubtitleDrainDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        nativeVideoSession?.makeOverlayDecoder(streamIndex: streamIndex)
            ?? softwareHost?.makeOverlayDecoder(streamIndex: streamIndex)
    }

    /// Start (or keep) the 500ms drain loop. Performs an immediate tick so a fresh selection
    /// backfills from the packet store synchronously, matching the #32 tap-overlay UX.
    func startSubtitleDrainer() {
        subtitleDrainTick()
        guard subtitleDrainerTask == nil else { return }
        subtitleDrainerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AetherEngine.subtitleDrainTickNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.subtitleDrainTick()
            }
        }
    }

    func stopSubtitleDrainer() {
        subtitleDrainerTask?.cancel()
        subtitleDrainerTask = nil
        subtitleDrainDecoders.removeAll()
        subtitleDrainCursors.removeAll()
        subtitleDrainLastTickUptime = nil   // #271
        subtitleResolutionLastFrontier.removeAll()   // #250
        subtitleResolutionCoverageStated.removeAll()   // #318
        subtitleDeliveryLastOutcome.removeAll()   // #357
        cancelSubtitleForwardPrefetcher()   // #151
    }

    /// Clear one channel's drain target; stops the loop when no channel remains active.
    func clearSubtitleDrainTarget(channel: SubtitleChannel) {
        subtitleDrainTargets[channel] = nil
        subtitleDrainDecoders[channel] = nil
        subtitleDrainCursors[channel] = nil
        subtitleResolutionLastFrontier[channel] = nil   // #250
        subtitleResolutionCoverageStated.remove(channel)   // #318
        subtitleDeliveryLastOutcome[channel] = nil   // #357
        refreshSubtitleStoreProtection()   // #166
        if subtitleDrainTargets.isEmpty { stopSubtitleDrainer() }
    }

    /// #166: keep the store's aggregate-eviction protected set in sync with the active drain
    /// targets, so the coldest non-selected streams evict first and the window the drainer reads
    /// is never dropped. Called on every drain-target change and re-asserted each drain tick.
    func refreshSubtitleStoreProtection() {
        activeSubtitlePacketStore?.setProtectedStreams(Set(subtitleDrainTargets.values))
    }

    func subtitleDrainTick() {
        guard !subtitleDrainTargets.isEmpty, let store = activeSubtitlePacketStore else { return }
        store.setProtectedStreams(Set(subtitleDrainTargets.values))   // #166: re-assert protection
        let playhead = sourceTime
        // #416: the pump is rendering the frame at the playhead, so it has necessarily read from
        // wherever it opened up to here. That is what the pump can state without a hook in its read
        // loop, and it is exactly the stretch a landing claim rests on: the ground between a set
        // decoded behind the playhead and the playhead itself. Its lookahead beyond the playhead
        // comes from the packets it harvests, which the store notes as it takes them.
        store.noteHarvestReach(.pump, through: playhead)
        // #271: wall time since the previous tick, so a tick that itself ran long cannot be read as
        // a seek by the next one. See SubtitleOverlayDrainer.drainPlan.
        let tickUptime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let elapsed = subtitleDrainLastTickUptime.map { tickUptime - $0 } ?? 0
        subtitleDrainLastTickUptime = tickUptime
        var prefetchNeedsReanchor = false
        for (channel, streamIndex) in subtitleDrainTargets {
            let hadCursor = subtitleDrainCursors[channel] != nil
            let plan = SubtitleOverlayDrainer.drainPlan(
                cursor: subtitleDrainCursors[channel],
                playhead: playhead,
                lead: Self.subtitleDrainLeadSeconds,
                backscan: Self.subtitleDrainBackscanSeconds,
                jumpThreshold: Self.subtitleDrainJumpThresholdSeconds,
                elapsedSinceLastPlan: elapsed)
            if Self.subtitleForwardPrefetchNeedsReanchor(plan: plan, hadCursor: hadCursor) {
                prefetchNeedsReanchor = true
            }
            let window: (from: Double, through: Double)
            // #250: a reset starts a fresh contiguous decoded run; a steady tick extends the one
            // already running.
            var coverageStart = subtitleDrainCursors[channel]?.coverageStart
            // #276: the run retained across seeks. Folded here, banked after the decode.
            var retained = subtitleDrainCursors[channel]?.retained
            let isReset: Bool
            switch plan {
            case .idle:
                subtitleDrainCursors[channel]?.lastPlayhead = playhead
                // #276: an idle tick decoded nothing, so it banks nothing into the retained run.
                // The frontier may well have moved under it; folding that in would claim
                // determination the drainer never performed.
                emitSubtitleResolutionStatementIfTransitioned(channel: channel,
                                                              streamIndex: streamIndex,
                                                              playhead: playhead)
                continue
            case .decode(let from, let through):
                isReset = false
                window = (from, through)
            case .resetAndDecode(let from, let through):
                isReset = true
                coverageStart = from
                retained = SubtitleResolutionStatement.fold(retained, windowFrom: from)
                subtitleDrainDecoders[channel] = nil
                // Fresh selection or seek: the backscan decodes compositions BEHIND the
                // playhead. Run them through the gate's reconstruction admission so the
                // currently-active line is emitted once at the playhead instead of being
                // held as a stale arrival until the next composition trims it (the old
                // reader's lead-in behavior; without this, enabling subs mid-sentence
                // shows nothing until the next line).
                // #357: the gate's hold and candidate belong to the position this tick is leaving.
                // A held cue keeps its open-ended placeholder end, so the first post-seek trim
                // (`resolveHeld`) closes it at a successor start AHEAD of the new playhead and
                // republishes pre-seek history as the active line, the same defect the store-side
                // close below prevents. Nothing is lost by dropping it: the backscan re-decodes the
                // window from the packet store, so anything that can still claim this landing comes
                // back through `admitDuringReconstruction`.
                var gate = pgsStaleArrivalGates[channel] ?? PGSStaleArrivalGate()
                gate.reset()
                gate.reconstructing = true
                pgsStaleArrivalGates[channel] = gate
                window = (from, through)
            }
            if subtitleDrainDecoders[channel] == nil {
                subtitleDrainDecoders[channel] = makeSubtitleDrainDecoder(streamIndex: streamIndex)
            }
            guard let decoder = subtitleDrainDecoders[channel] else {
                // #357: a channel holding a drain target whose decoder cannot be built delivers
                // nothing for the rest of the session, and the tick used to skip it in silence.
                var tally = SubtitleDeliveryStatement.Tally()
                tally.decoderMissing = true
                emitSubtitleDeliveryStatementIfTransitioned(
                    channel: channel, streamIndex: streamIndex, playhead: playhead,
                    tally: tally, isReset: isReset)
                continue
            }
            let entries = store.entries(streamIndex: streamIndex,
                                        from: window.from, through: window.through)
            // #271: bound the batch, on a PTS boundary. The window is bounded in seconds of
            // content, so on a dense track it is thousands of packets and this loop has no
            // suspension point.
            let batchEnd = SubtitleOverlayDrainer.batchEnd(
                count: entries.count,
                cap: Self.subtitleDrainMaxPacketsPerTick,
                ptsAt: { entries[$0].ptsSeconds })
            // #362: stop at a hole the harvest is still filling instead of decoding across it and
            // moving the cursor to its far side, which is how a stretch of the film loses its
            // subtitles entirely: after a seek the pump refills from behind the landing while an
            // island the previous run harvested sits further ahead, and the cursor never comes back.
            // The hold is anchored on the near side and budgeted in ticks, so a boundary the harvest
            // never closes costs a bounded delay and then decodes exactly as before.
            var decodeEnd = batchEnd
            var gapHoldAt: Double? = nil
            var gapHoldSequence: UInt64 = 0
            var gapHoldTicksLeft = 0
            let held = subtitleDrainCursors[channel]
            // The playhead catching up to the hold ends it whatever the budget says: from there on
            // the island is what the viewer is about to need, and waiting would dark the overlay
            // for content that IS stored. That, not the tick budget, is the real bound.
            if let heldAt = held?.harvestGapAt, heldAt >= playhead,
               (held?.harvestGapTicksLeft ?? 0) > 0, !isReset,
               !SubtitleOverlayDrainer.harvestGapHoldResumes(
                firstSequence: entries.first?.sequence,
                heldSequence: held?.harvestGapSequence ?? 0) {
                // Still waiting: the window past the hold begins with the same island as before.
                decodeEnd = 0
                gapHoldAt = heldAt
                gapHoldSequence = held?.harvestGapSequence ?? 0
                gapHoldTicksLeft = (held?.harvestGapTicksLeft ?? 0) - 1
            } else if let cut = SubtitleOverlayDrainer.harvestGapCut(
                count: batchEnd,
                ptsAt: { entries[$0].ptsSeconds },
                sequenceAt: { entries[$0].sequence },
                resumeFrom: isReset ? nil : held.map { ($0.lastDecodedPts, $0.lastDecodedSequence) },
                notBefore: playhead), held?.harvestGapAt != cut.at || (held?.harvestGapTicksLeft ?? 0) > 0 {
                decodeEnd = cut.index
                gapHoldAt = cut.at
                gapHoldSequence = cut.sequence
                gapHoldTicksLeft = held?.harvestGapAt == cut.at
                    ? (held?.harvestGapTicksLeft ?? 0) - 1 : Self.subtitleDrainHarvestGapTicks
            }
            // #271: bind the channel's cue array ONCE for the whole batch. `subtitleCues` is
            // `@Published`, whose wrapper exposes get/set and no `_modify`, so passing it inout per
            // event both copy-on-writes the array and publishes it: every consumer then walks a
            // cumulative snapshot once per decoded packet, O(n) each, for a batch that added a
            // handful of cues. One bind, one publish, and only when the batch changed something.
            var cues = retainedSubtitleCues(for: channel)
            var didMutate = false
            // #357: a cue still carrying its open-ended placeholder end cannot claim this landing.
            // Its successor's trim is what closes it, and a jump past it outran that successor; see
            // alignCueEnds.
            if isReset, Self.closeOpenEndedCues(&cues, startingBefore: window.from) {
                didMutate = true
            }
            // #357: what this tick did, counted as it happens. The cursor below advances over every
            // packet whether or not the decoder built anything from it, so without these counts a
            // window of undecodable packets is indistinguishable in the log from a window that
            // delivered normally.
            var tally = SubtitleDeliveryStatement.Tally()
            tally.packets = decodeEnd
            // The cursor only advances to an actually-decoded packet's PTS: a window that is
            // empty because the producer has not reached it yet must be rescanned next tick.
            var lastDecoded = subtitleDrainCursors[channel]?.lastDecodedPts
            // #362: the cursor's own harvest sequence rides with it, so the next tick can tell
            // whether its first entry was read by the same run or is the far side of a hole.
            var lastDecodedSequence = subtitleDrainCursors[channel]?.lastDecodedSequence ?? 0
            for entry in entries[..<decodeEnd] {
                if let event = Self.decodeStoredSubtitlePacket(entry, with: decoder) {
                    tally.events += 1
                    tally.cues += event.cues.count
                    // A cue-less event still matters: a PGS clear composition carries only
                    // pgsTrimAt and is what removes the line during silence.
                    if !event.cues.isEmpty || event.pgsTrimAt != nil {
                        let applied = applySubtitleEvent(event, to: &cues, channel: channel)
                        tally.admitted += applied.admitted
                        tally.published += applied.published
                        tally.landingWithheld += applied.landingWithheld   // #416
                        if applied.changed { didMutate = true }
                    }
                }
                lastDecoded = entry.ptsSeconds
                lastDecodedSequence = entry.sequence
            }
            if case .resetAndDecode = plan, batchEnd == 0 {
                // Fresh window with nothing stored yet: anchor just behind the window start so
                // steady ticks rescan it without re-triggering the discontinuity path.
                lastDecoded = window.from
                lastDecodedSequence = 0
            }
            // #276: floor now, ceiling after the statement below states it.
            let runRetained = retained ?? .init(from: coverageStart ?? window.from, through: nil)
            subtitleDrainCursors[channel] = SubtitleDrainCursor(
                lastDecodedPts: lastDecoded ?? window.from,
                lastDecodedSequence: lastDecoded == nil ? 0 : lastDecodedSequence,
                lastPlayhead: playhead,
                coverageStart: coverageStart ?? window.from,
                retained: runRetained,
                harvestGapAt: gapHoldAt,
                harvestGapSequence: gapHoldSequence,
                harvestGapTicksLeft: gapHoldTicksLeft)
            // #143/#204: a renderable composition at/after the playhead ends reconstruction while
            // decoding above. If the pass remains active with a candidate after the whole window,
            // finalize it. Raw packet presence cannot answer this: the landing line's own zero-object
            // CLEAR is stored ahead and trims the candidate, but carries no cues that can end the pass.
            //
            // #271: "after the whole window" is now literal. A capped batch leaves the rest of the
            // window undecoded, and its successor composition may sit in the remainder, so the pass
            // carries into the next tick instead of finalizing on a partial view.
            // #362: a hole hold is not a partial view of the landing. Holes are honoured only at or
            // after the playhead, so everything that can seed the candidate has decoded, and the
            // remainder sits beyond a gap the harvest has not closed. Waiting for that would keep
            // the overlay dark for the whole hold budget, which is the one thing #143 exists to
            // prevent; the successor trims the published line when the hole does fill.
            if decodeEnd == entries.count || gapHoldAt != nil,
               SubtitleOverlayDrainer.shouldFinalizeReconstruction(
                reconstructing: pgsStaleArrivalGates[channel]?.reconstructing ?? false,
                hasCandidate: pgsStaleArrivalGates[channel]?.hasReconstructionCandidate ?? false) {
                // The candidate is the genuinely active line at the seek target, so it bypasses
                // `admit`, whose steady-state stale check would re-hold a landing line sitting more
                // than the epsilon behind the playhead and re-dark the overlay this fix exists to light.
                for cue in pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
                    .finalizeReconstruction(playhead: playhead) {
                    // #357: a finalized candidate is a delivery like any other, and counting it as
                    // one is what keeps a landing that published only through this path from
                    // reading as `held`.
                    tally.admitted += 1
                    if insertSorted(cue, into: &cues) {
                        didMutate = true
                        tally.published += 1
                    }
                }
            }
            tally.reconstructing = pgsStaleArrivalGates[channel]?.reconstructing ?? false
            tally.harvestGapAt = gapHoldAt
            // #362: every bitmap cue takes its end from the next packet the store holds on this
            // stream. Run over the whole retained array rather than this batch's cues: a set left
            // open by an earlier tick (its successor not harvested yet, the batch cap, the window's
            // forward edge) is closed by the first tick that finds the answer stored, without waiting
            // for the drain window to reach it. Runs before the boundary close can launder it and
            // before the publish below, so the host never sees the placeholder at all.
            // Round 2: this is also the only correction an end derived across a hole ever gets. The
            // drain cursor moves forward only, so the packets that fill the hole land BEHIND it and
            // are never decoded; their `pgsTrimAt` never runs, and the too-late end stood until the
            // session ended. Re-deriving from the store each tick needs no decode and no revisit.
            // Round 2: and it may look exactly as far as the harvest is designed to lead, no
            // further. The prefetch parks a margin PAST the drain window precisely so the set at
            // the window's forward edge has its own clear stored (round 1), so inside that horizon
            // a stored packet is evidence the harvest was here and found this. Beyond it the store
            // holds whatever earlier runs left behind, and the first thing after a set can be the
            // far side of a stretch nobody read: a real packet, not this set's successor (report:
            // 145.187 closed at 223.306, its own clear at 150.192, 18 s past the window's edge).
            // Refusing there costs a tick or two of an open cue, which the next answer closes,
            // against an end that is wrong by a minute and that nothing downstream can tell from an
            // authored one.
            let derivationHorizon = window.through + Self.subtitleForwardPrefetchLeadMarginSeconds
            if Self.alignCueEnds(&cues, toNextPacket: {
                guard let pts = store.firstPTS(streamIndex: streamIndex, after: $0) else { return nil }
                guard pts <= derivationHorizon else {
                    tally.endsWithheld += 1
                    return nil
                }
                return pts
            }) {
                didMutate = true
            }
            // Retention prune, once per batch instead of once per event: it depends only on the
            // playhead, which the batch does not move.
            if isSubtitleActive(for: channel),
               Self.pruneCues(&cues, before: playhead - subtitleCueRetentionSeconds) {
                didMutate = true
            }
            if didMutate { publishRetainedSubtitleCues(cues, for: channel) }
            // #357: state what the tick did before the resolution line states how far it reached.
            // The two answer different questions and a report needs both: determination can keep
            // pace with every landing while delivery is empty, and that pairing is the whole
            // ambiguity this line removes.
            emitSubtitleDeliveryStatementIfTransitioned(
                channel: channel, streamIndex: streamIndex, playhead: playhead,
                tally: tally, isReset: isReset)
            // #250: the post-seek window has decoded, so state how far determination reaches.
            // #276: one statement value per decoding tick, built whether or not it is printed. Its
            // `resolvedThrough` is this run's determined end under the fence that is live RIGHT
            // NOW, and banking it here is the only place it can be had: by the next reset tick the
            // seek generation has moved on and the outgoing run's frontier no longer passes its
            // own fence.
            var statement = subtitleResolutionStatement(
                channel: channel, streamIndex: streamIndex,
                reason: isReset ? .reconstruction : .frontier, playhead: playhead)
            subtitleDrainCursors[channel]?.retained = SubtitleResolutionStatement.extend(
                runRetained, with: statement.resolvedThrough)
            // #318: a reset starts a fresh run, and whether THAT run reaches the playhead is a
            // fresh question. Cleared before the decision below so a reconstruction line that
            // already states coverage can latch it again on the way out.
            if isReset { subtitleResolutionCoverageStated.remove(channel) }
            if let reason = SubtitleResolutionStatement.transitionReason(
                statement, playhead: playhead, isReset: isReset,
                coverageStated: subtitleResolutionCoverageStated.contains(channel),
                lastFrontier: subtitleResolutionLastFrontier[channel]) {
                statement.reason = reason
                emitSubtitleResolutionStatement(statement, channel: channel, playhead: playhead)
            }
        }
        // #151: a jump (seek / producer re-anchor) moves the drain window out from under the
        // prefetcher's read position; restart it at the new playhead. Once per tick, not per
        // channel: both channels ride the same playhead and the same side demuxer.
        if prefetchNeedsReanchor { startSubtitleForwardPrefetcher() }
        // #125: the packet store is NOT time-pruned here. A trailing playhead-relative prune
        // (was: playhead - retentionSeconds) evicted packets a backward seek could still land on:
        // a backward jump into segment-cache-resident content is served without a producer restart,
        // and the pump (the store's only writer) stays parked forward, so that region is never
        // re-harvested. Once pruned, the drain window landed permanently empty and cues starved
        // (every re-arm logged "backfilled 0 cues"). Retention is byte-bounded instead, via
        // SubtitlePacketStore.perStreamByteCap (evict-oldest per stream): text tracks keep the whole
        // session, bitmap tracks keep a wide trailing window. Mirrors the segment cache retaining
        // history for backward seeks rather than clamping to a time window ahead of the playhead.
    }

    // MARK: - #151: subtitle forward prefetch

    /// #151: forward prefetch runs for VOD sessions only (live content past the edge does not
    /// exist and the pump already rides it), needs an embedded drain target (external/sidecar
    /// tracks hold whole files, CC is tap-fed) and a loaded source to open a side demuxer on.
    nonisolated static func shouldRunSubtitleForwardPrefetch(
        isLive: Bool, hasEmbeddedDrainTargets: Bool, hasSource: Bool
    ) -> Bool {
        !isLive && hasEmbeddedDrainTargets && hasSource
    }

    /// #151: a drain-tick jump with an existing cursor (seek / producer re-anchor) restarts the
    /// prefetcher at the new playhead. A fresh selection (nil cursor) does not: the selection
    /// path starts it itself, with the #73 resume anchor the tick cannot know.
    nonisolated static func subtitleForwardPrefetchNeedsReanchor(
        plan: SubtitleDrainPlan, hadCursor: Bool
    ) -> Bool {
        if case .resetAndDecode = plan { return hadCursor }
        return false
    }

    /// Start (or re-anchor) the forward prefetcher: a subtitle-only side demuxer that fills the
    /// session packet store past playhead + subtitleDrainLeadSeconds independent of the
    /// producer's forward park (#102), so `$subtitleCues` holds cues a host-applied ADVANCE sync
    /// offset can find, text and bitmap alike. Best effort: if it wedges or fails to open, the
    /// drainer keeps working off the pump's harvest exactly as before.
    func startSubtitleForwardPrefetcher(startAt: Double? = nil) {
        let anchor = max(0, startAt ?? sourceTime)
        // Phase D: while the OCR worker is armed the prefetcher must out-run the worker's
        // 240 s window, or the packet store never holds what the worker wants to decode.
        // #362: otherwise it parks a margin BEYOND the drain window, so the set at the window's
        // forward edge has its own clear stored and can be closed where the author closed it.
        let lead = subtitleOCRArmedOrdinal != nil
            ? Self.subtitleOCRPrefetchLeadSeconds
            : Self.subtitleDrainLeadSeconds + Self.subtitleForwardPrefetchLeadMarginSeconds
        // #240: a live session moves its own cursor. Only a changed lead still needs a rebuild
        // (the loop captures it at start), and only a live task can be handed the request at all.
        if let reanchor = subtitleForwardPrefetchReanchor,
           subtitleForwardPrefetchTask != nil,
           subtitleForwardPrefetchActiveLead == lead {
            // #250: the seek this move serves rides along, so the read position it banks after the
            // reposition is fenced to that seek rather than to the one the session started under.
            reanchor.request(anchor, seekGeneration: currentSeekGeneration)
            return
        }
        cancelSubtitleForwardPrefetcher()
        guard Self.shouldRunSubtitleForwardPrefetch(
            isLive: isLive,
            hasEmbeddedDrainTargets: !subtitleDrainTargets.isEmpty,
            hasSource: loadedURL != nil),
            let store = activeSubtitlePacketStore,
            let url = loadedURL else { return }
        let isCustom = isCustomSource
        if isCustom, customReader == nil { return }
        let headers = loadedOptions.httpHeaders
        let formatHint = customFormatHint
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        let titleID = activeDiscTitleID
        subtitleForwardPrefetchActiveLead = lead
        let link = SideReaderLinkArbiter(gate: sideReaderLinkGate)
        subtitleForwardPrefetchTask = Task.detached(priority: .utility) { [weak self] in
            // #231: the loop used to end on the first failed read and only a seek or producer
            // re-anchor could bring it back, so a viewer who does not seek lost every cue beyond
            // the pump's own park for the rest of the session, silently. Restart on a read error,
            // bounded, re-anchored at the playhead the failure left behind.
            var budget = SubtitleForwardPrefetcher.RestartBudget(
                maxConsecutiveFailures: AetherEngine.subtitleForwardPrefetchMaxConsecutiveFailures,
                maxRestarts: AetherEngine.subtitleForwardPrefetchMaxRestarts,
                backoffNanoseconds: AetherEngine.subtitleForwardPrefetchRestartBackoffNanoseconds)
            var resumeAt = anchor
            var holdingForMeteredOrigin = false
            while !Task.isCancelled {
                let originPaced = OriginRequestBudget.shared.isPaced(url)
                let originSerial = OriginRequestBudget.shared.requiresSerialRequests(url)
                if SubtitleForwardPrefetcher.shouldHold(
                    originPaced: originPaced, originSerial: originSerial
                ) {
                    if !holdingForMeteredOrigin {
                        EngineLog.emit(
                            "[AetherEngine] #151 forward prefetch holding: origin is metered "
                            + "(paced=\(originPaced) serial=\(originSerial))",
                            category: .engine)
                        holdingForMeteredOrigin = true
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    continue
                }
                if holdingForMeteredOrigin {
                    EngineLog.emit(
                        "[AetherEngine] #151 forward prefetch resuming: origin is no longer metered",
                        category: .engine)
                    holdingForMeteredOrigin = false
                }
                // A custom source needs its own independent reader per attempt: the previous one
                // is closed by the session that failed.
                var attemptReader: IOReader? = nil
                if isCustom {
                    guard let clone = await MainActor.run(body: { [weak self] in
                        self?.customReader?.makeIndependentReader()
                    }) else { return }
                    attemptReader = clone
                }
                guard let self else { return }
                let outcome = await self.runSubtitleForwardPrefetchSession(
                    url: url, reader: attemptReader, formatHint: formatHint, headers: headers,
                    startAt: resumeAt, callerProbesize: probesize,
                    callerMaxAnalyzeDuration: maxAnalyzeDuration,
                    selectTitleID: titleID, store: store, leadSeconds: lead, link: link)
                guard outcome.exit.isRestartable, !Task.isCancelled else { return }

                guard let backoff = budget.chargeFailure(harvested: outcome.harvested) else {
                    EngineLog.emit(
                        "[AetherEngine] #151 forward prefetch giving up after \(budget.restarts) "
                        + "restarts (\(budget.consecutiveFailures) consecutive): cues beyond the "
                        + "pump's forward park will not be filled for the rest of this session",
                        category: .engine)
                    return
                }
                do { try await Task.sleep(nanoseconds: backoff) } catch { return }
                guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime })
                else { return }
                resumeAt = max(0, fresh)
                EngineLog.emit(
                    "[AetherEngine] #151 forward prefetch restarting after a read failure "
                    + "(restart \(budget.restarts)) at \(String(format: "%.2f", resumeAt))s",
                    category: .engine)
            }
        }
    }

    /// Cancel the prefetcher + markClosed its side demuxer so a parked AVIO read cannot survive
    /// teardown (same rule as the native readers).
    func cancelSubtitleForwardPrefetcher() {
        subtitleForwardPrefetchTask?.cancel()
        subtitleForwardPrefetchTask = nil
        subtitleForwardPrefetchDemuxer?.markClosed()
        subtitleForwardPrefetchDemuxer = nil
        subtitleForwardPrefetchReanchor = nil
        subtitleForwardPrefetchActiveLead = nil
    }

    /// Open + position the prefetch side demuxer, then hand off to the packet loop. Mirrors
    /// `runNativeSubtitleReaders`' open/registration/positioning (memory rule: all side readers
    /// share every positioning fix); differs in routing bitmap streams too and writing compressed
    /// packets to the SubtitlePacketStore instead of decoded cues to native stores.
    nonisolated private func runSubtitleForwardPrefetchSession(
        url: URL, reader: IOReader?, formatHint: String?, headers: [String: String],
        startAt: Double, callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?,
        selectTitleID: Int?, store: SubtitlePacketStore, leadSeconds: Double,
        link: SideReaderLinkArbiter?
    ) async -> SubtitleForwardPrefetcher.Outcome {
        let demuxer = Demuxer()
        let openProfile = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration).withReaderLabel("prefetch")
        let registered = await MainActor.run { [weak self] () -> Bool in
            guard !Task.isCancelled, let self else { return false }
            self.subtitleForwardPrefetchDemuxer = demuxer
            return true
        }
        guard registered else {
            reader?.close()
            return SubtitleForwardPrefetcher.Outcome(exit: .cancelled, harvested: 0)
        }
        defer {
            Task { @MainActor [weak self, weak demuxer] in
                if let self, let demuxer, self.subtitleForwardPrefetchDemuxer === demuxer {
                    self.subtitleForwardPrefetchDemuxer = nil
                    // #240: the box belongs to this session's demuxer. Dropping it with the demuxer
                    // means a jump arriving between two restart attempts rebuilds (the only thing
                    // that can work then) rather than posting a request nothing will read.
                    self.subtitleForwardPrefetchReanchor = nil
                }
            }
        }
        // #93: a second WAN demuxer opened during a producer restart competes with the restart for
        // a starved link. Poll until the restart settles (bounded), same rule as the lazy native
        // readers; the jump-respawn path lands here exactly when a seek restart is likely in flight.
        //
        // #240: the restart itself is over in ~100 ms, but the seek it serves is not, and this open
        // costs the container header, the cue-index prewarm and the positioning seek, each a bounded
        // range the origin delivers in full. So the wait covers the whole seek, not just the restart.
        // It stays bounded by the same deadline: a source that never leaves the seek state must end
        // up with a reader that opened late, not with no reader at all.
        let restartDeadline = DispatchTime.now() + 30.0
        while !Task.isCancelled, DispatchTime.now() < restartDeadline {
            let busy = await MainActor.run { [weak self] in
                self?.nativeVideoSession?.restartInFlight == true
            }
            if !busy, link?.shouldDeferOpen() != true { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else {
            reader?.close()
            return SubtitleForwardPrefetcher.Outcome(exit: .cancelled, harvested: 0)
        }
        do {
            if let reader {
                try demuxer.open(reader: reader, formatHint: formatHint, profile: openProfile,
                                 selectTitleID: selectTitleID, discCacheKey: url.absoluteString)
            } else {
                try demuxer.open(url: url, extraHeaders: headers, profile: openProfile,
                                 selectTitleID: selectTitleID)
            }
        } catch {
            EngineLog.emit("[AetherEngine] #151 forward prefetch open failed: \(error)", category: .engine)
            reader?.close()
            return SubtitleForwardPrefetcher.Outcome(exit: .openFailed, harvested: 0)
        }
        defer {
            demuxer.close()
            reader?.close()
        }

        let streams = demuxer.subtitleStreamIndices()
        guard !streams.isEmpty else {
            return SubtitleForwardPrefetcher.Outcome(exit: .openFailed, harvested: 0)
        }
        let assembly = demuxer.splitDisplaySetSubtitleStreamIndices()
        // #230: one non-subtitle stream stays deliverable at AVDISCARD_NONKEY so the loop has a
        // read-position control point between cues. AVDISCARD_ALL is applied inside av_read_frame,
        // so a fully discarded source hands the loop nothing at all between two subtitle packets
        // and a single read call walks whatever lies between them.
        let pacing = demuxer.prefetchPacingStreamIndex()
        demuxer.discardAllStreamsExcept(streams, pacing: pacing)

        // Prewarm MKV cue index (lives at EOF), then bounded positioning with the verified
        // byte-estimate fallback, both budgeted (#112 round 10). Skip prewarm for disc (#76).
        let duration = demuxer.duration
        if duration > 0, !demuxer.isDiscSource {
            demuxer.seekBounded(to: duration * 0.5, timeout: Self.sideReaderSeekBudgetSeconds)
        }
        // #234: anchor the positioning on the subtitle axis explicitly. A -1 seek lets libavformat
        // pick the reference stream by score, and `discard != AVDISCARD_ALL` is worth +200 there:
        // before #230 the subtitle stream was the only stream not fully discarded and won that
        // vote by accident, after #230 the pacing stream outranks it and the seek lands on a video
        // keyframe instead. On Matroska that is a different cluster, so a landing cue further back
        // than one keyframe is behind the read head before the first packet arrives and the seek
        // destination stays dark. Lowest index matches what the score used to elect.
        let seekAnchor = streams.min() ?? -1
        let engineDisplayDuration = await MainActor.run { [weak self] in self?.duration ?? 0 }
        let landed = SubtitleForwardPrefetcher.reposition(
            demuxer: demuxer, to: startAt, anchorStreamIndex: seekAnchor,
            fallbackDuration: engineDisplayDuration,
            timeout: Self.sideReaderSeekBudgetSeconds)
        // #416: this session reads forwards from here, and nothing below it is this reader's to
        // claim. Stated even when the positioning fell back or failed: what the loop then reads is
        // still forwards from wherever it sits, and the anchor is the earliest it can be.
        store.noteHarvestAnchor(.prefetch, at: startAt)
        if landed != .seek {
            EngineLog.emit(
                "[AetherEngine] #151 forward prefetch seek to \(String(format: "%.2f", startAt))s timed out "
                + "or failed; byte-estimate fallback \(landed == .byteEstimate ? "applied" : "unavailable")",
                category: .engine)
        }

        // #240: hand the running loop its own anchor box, so a playhead jump moves the cursor
        // instead of rebuilding the session. Captures this session's positioning inputs, so an
        // in-place move cannot drift from the rules above.
        let reanchor = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorStreamIndex: seekAnchor,
            fallbackDuration: engineDisplayDuration,
            seekTimeout: Self.sideReaderSeekBudgetSeconds)
        // #250: the fence this session's read positions belong to, captured in the same hop that
        // adopts the anchor box. An in-place move re-stamps the seek half from the request itself.
        let adopted = await MainActor.run { [weak self] () -> SubtitleResolutionStatement.Fence? in
            guard !Task.isCancelled, let self, self.subtitleForwardPrefetchDemuxer === demuxer
            else { return nil }
            self.subtitleForwardPrefetchReanchor = reanchor
            return self.subtitleResolutionFence
        }
        guard let fence = adopted else {
            return SubtitleForwardPrefetcher.Outcome(exit: .cancelled, harvested: 0)
        }

        EngineLog.emit(
            "[AetherEngine] #151 forward prefetch started: streams=\(streams.sorted()) "
            + "pacing=\(pacing) anchor=\(seekAnchor) "
            + "startAt=\(String(format: "%.2f", startAt))s lead=\(leadSeconds)s",
            category: .engine)
        let outcome = await SubtitleForwardPrefetcher.run(
            demuxer: demuxer, store: store,
            streamIndices: streams, assemblyIndices: assembly,
            pacingIndex: pacing,
            leadSeconds: leadSeconds,
            parkPollNanoseconds: Self.subtitleForwardPrefetchParkPollNanoseconds,
            link: link,
            reanchor: reanchor,
            fence: fence,
            playhead: { [weak self] in
                await MainActor.run(body: { [weak self] in self?.sourceTime })
            })
        EngineLog.emit(
            "[AetherEngine] #151 forward prefetch exited (reason=\(outcome.exit) "
            + "cancelled=\(Task.isCancelled)) harvested=\(outcome.harvested)",
            category: .engine)
        // #250: EOF is the one exit that strengthens the claim rather than weakening it. Everything
        // ahead of the playhead is read, so the window is determined in full and a harness can
        // treat an empty position as "no cue here" instead of "not yet".
        if outcome.exit == .endOfFile {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.emitSubtitleResolutionStatements(reason: .eof)
            }
        }
        return outcome
    }

    /// Rebuild an AVPacket from a stored entry and decode it. PTS/duration ride a 1/1000
    /// time base carrying the harvested seconds; flags are restored for bitmap acquisition
    /// points. Runs on the MainActor tick; subtitle decode is a parse plus, for bitmap, a
    /// bounded blit, the same work the side reader did per packet.
    nonisolated static func decodeStoredSubtitlePacket(
        _ entry: StoredSubtitlePacket,
        with decoder: EmbeddedSubtitleDecoder
    ) -> EmbeddedSubtitleDecoder.SubtitleEvent? {
        let size = entry.payload.count
        guard size > 0, let pkt = av_packet_alloc() else { return nil }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        guard av_new_packet(pkt, Int32(size)) >= 0 else { return nil }
        entry.payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = pkt.pointee.data {
                memcpy(dst, base, size)
            }
        }
        pkt.pointee.pts = Int64((entry.ptsSeconds * 1000).rounded())
        pkt.pointee.dts = pkt.pointee.pts
        pkt.pointee.duration = Int64((entry.durationSeconds * 1000).rounded())
        pkt.pointee.flags = entry.flags
        // #233: WebVTT placement lives in side data, not in the payload, so it has to be put back.
        if let settings = entry.webvttSettings {
            WebVTTCueSettings.attach(settings: settings, to: pkt)
        }
        return decoder.decode(packet: pkt, streamTimeBase: AVRational(num: 1, den: 1000))
    }

    /// #271: the channel's retained array, bound once per drain tick. Reading it here and writing it
    /// back once at the end of the batch is what keeps `$subtitleCues` to one publication per tick.
    private func retainedSubtitleCues(for channel: SubtitleChannel) -> [SubtitleCue] {
        switch channel {
        case .primary:   return subtitleCues
        case .secondary: return secondarySubtitleCues
        }
    }

    private func publishRetainedSubtitleCues(_ cues: [SubtitleCue], for channel: SubtitleChannel) {
        switch channel {
        case .primary:   subtitleCues = cues
        case .secondary: secondarySubtitleCues = cues
        }
    }

    /// Returns what the event did to the array (#357). An event that decodes but resolves to nothing
    /// new (a re-decoded cue the store already holds, a trim matching no open window) must not cost a
    /// publication: on a dense track that is the common case, and each publication makes every
    /// consumer walk the whole cumulative snapshot (#271).
    @discardableResult
    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent,
                                    to cues: inout [SubtitleCue],
                                    channel: SubtitleChannel) -> SubtitleDeliveryStatement.Application {
        guard isSubtitleActive(for: channel) else { return .init() }

        // #357: primary-only, and budgeted per seek generation rather than per load, so a seek
        // sequence stays observable to its end. The playhead is `sourceTime`, the axis cue
        // timestamps are on; `currentTime` rides beside it because their difference is the playlist
        // shift, and reading the two as one clock has cost a round of diagnosis before.
        if channel == .primary, let firstCue = event.cues.first,
           subtitleCueDiagnosticBudget.claim(generation: currentSeekGeneration) {
            // #407: a PGS composition carries no end of its own, so the decoder stamps it with
            // `end_display_time = UINT32_MAX` and the successor's `pgsTrimAt` closes it. Printed
            // raw, that placeholder reads as a 49.7-day cue and has already been reported as an
            // unsigned-32-bit overflow. Name it for what it is.
            let openEnded = firstCue.endTime - firstCue.startTime >= Self.subtitleOpenEndedWindowSeconds
            EngineLog.emit(
                "[applySubtitleEvent] " +
                "cueStart=\(String(format: "%.3f", firstCue.startTime))s " +
                "cueEnd=\(openEnded ? "open-ended (closed by the successor)" : String(format: "%.3fs", firstCue.endTime)) " +
                "sourceTime=\(String(format: "%.3f", sourceTime))s " +
                "engine.currentTime=\(String(format: "%.3f", currentTime))s " +
                "seekGen=\(currentSeekGeneration)",
                category: .engine
            )
        }

        return applyEventMutations(event, to: &cues, channel: channel)
    }

    /// PGS clear-event trim + sorted insert. Native mov_text stores (#55) are NOT fed here; those are owned by the multi-decode reader.
    /// #271: retention pruning moved to the drain tick (once per batch, not once per event) and the
    /// return value reports whether `cues` actually changed.
    @MainActor
    @discardableResult
    private func applyEventMutations(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, to cues: inout [SubtitleCue], channel: SubtitleChannel = .primary) -> SubtitleDeliveryStatement.Application {
        var applied = SubtitleDeliveryStatement.Application()
        if let trimAt = event.pgsTrimAt {
            for i in 0..<cues.count {
                guard case .image = cues[i].body else { continue }
                let cue = cues[i]
                if cue.startTime < trimAt && cue.endTime > trimAt {
                    cues[i] = cue.with(endTime: trimAt)
                    applied.changed = true
                }
            }
            // #100: this event is the held stale arrival's successor; its start closes the held
            // cue's true window. Publish it only if that window covers the playhead (it is the
            // genuinely active cue), drop replayed history silently.
            for cue in pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
                .resolveHeld(trimAt: trimAt, playhead: sourceTime) {
                applied.admitted += 1
                if insertSorted(cue, into: &cues) {
                    applied.changed = true
                    applied.published += 1
                }
            }
        }
        // #107: teletext page-state semantics; every event (content or erase) closes earlier
        // open text cues at its start, since libzvbi emits pages open-ended ("until replaced").
        if let trimAt = event.textTrimAt, Self.trimTextCues(&cues, at: trimAt) {
            applied.changed = true
        }
        // #100: a PGS event whose cues start well behind the playhead is a catch-up replay; its
        // open-ended placeholder window would cover the playhead the instant it inserts and flash
        // stale history through the overlay until the successor trims it. Hold it instead.
        // #112/#143: during a reconstruction pass any decoded composition at/behind the playhead becomes the
        // held active-line candidate, emitted once when the decode reaches the playhead (see
        // PGSStaleArrivalGate.admitDuringReconstruction).
        // #416: a bitmap set decoded behind the playhead claims to be the line still on screen
        // there, and that claim rests on the store being empty between the two. Ask the harvest
        // whether it ever read that stretch before reading its silence as an answer.
        // Asked for bitmap events only: a text cue carries its own duration, so it claims nothing
        // about the ground behind it, and a dense text track would pay the lookup per packet.
        let groundIsRead = event.isPGS
            ? subtitleLandingGroundIsRead(cues: event.cues, playhead: sourceTime)
            : true
        // A false answer here means an actual refusal: the helper returns true when the event
        // carries no cue behind the playhead, so there is nothing that could have been refused.
        if !groundIsRead { applied.landingWithheld += 1 }
        let admitted = pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
            .admit(cues: event.cues, isPGS: event.isPGS,
                   isSelfContained: event.isSelfContainedPGS, playhead: sourceTime,
                   groundIsRead: groundIsRead)
        applied.admitted += admitted.count
        for cue in admitted {
            if insertSorted(cue, into: &cues) {
                applied.changed = true
                applied.published += 1
            }
        }
        return applied
    }


    @MainActor
    @discardableResult
    private func insertSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) -> Bool {
        Self.insertCueSorted(cue, into: &cues, nextID: &nextRetainedSubtitleCueID)
    }

    /// #416: was the source between the newest of these cues that lies behind `playhead` and the
    /// playhead itself actually read by some harvest run?
    ///
    /// Only that one cue matters: it is the one the gate would make the landing's active line, and
    /// the only stretch its claim depends on is the one between it and the playhead. Cues at or
    /// after the playhead need no ground, and an event carrying none behind it asks nothing here.
    ///
    /// Coverage is a property of the SOURCE, not of a stream: a reader demuxes every stream it
    /// passes over, so a span one of them read is read for all of them.
    private func subtitleLandingGroundIsRead(cues: [SubtitleCue], playhead: Double) -> Bool {
        guard let store = activeSubtitlePacketStore else { return true }
        guard let newestBehind = cues.lazy.map(\.startTime).filter({ $0 <= playhead }).max()
        else { return true }
        return store.hasReadSpan(from: newestBehind, through: playhead)
    }

    /// #107: close every non-image cue (text or rich text) whose window covers `trimAt` (teletext
    /// page-state semantics: each page transmission or erase replaces what came before it). Image
    /// cues are untouched; they have their own PGS trim. Static and pure for unit tests.
    /// Returns whether any cue was actually closed (#271).
    @discardableResult
    nonisolated static func trimTextCues(_ cues: inout [SubtitleCue], at trimAt: Double) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            if case .image = cues[i].body { continue }
            let cue = cues[i]
            if cue.startTime < trimAt && cue.endTime > trimAt {
                cues[i] = cue.with(endTime: trimAt)
                changed = true
            }
        }
        return changed
    }

    /// #112 full umbau: sorted insert of a decoded cue into the retained store, keeping ascending start order. An
    /// image cue sharing a start AND geometry with an existing image cue REPLACES it: a PGS composition has a
    /// unique start PTS, so a same-start same-geometry image cue is the same object re-decoded (the audio-switch
    /// preserved placeholder vs its reconstruction), and a duplicate would render the bitmap twice until the next
    /// composition trims it. #146: the start PTS is unique per COMPOSITION, not per composition OBJECT; N objects
    /// of one display set (forced sign + dialogue) legitimately share a start and differ in geometry (position and
    /// pixel size, both deterministic across re-decodes via the alpha-bounding-box crop), so geometry is part of
    /// the replacement key and sibling objects are all kept. Text cues at the same start are distinct simultaneous
    /// speakers and are both kept.
    ///
    /// #121: `nextID` stamps every materialized cue with a session-monotonic id and de-dupes a non-image cue
    /// (text or rich text) already present with the same window + content. On a seek the overlay decoder is
    /// rebuilt (`.resetAndDecode`) with an empty `seenKeys` and a `nextCueID` reset to zero, so its backscan
    /// re-decodes cues still retained here; without a store-level guard the cues accumulate (report: 4 -> 7 -> 11)
    /// and the reset ids collide with retained ids (`ForEach(id:)` "occurs multiple times"). The retained store
    /// is the session-wide source of truth, so the invariant lives here, not on the ephemeral decoder.
    ///
    /// #271: both same-start lookups below run over the equal-start RUN found by binary search, not
    /// over the whole array. The store is kept sorted by startTime by the insert at the bottom, and
    /// both keys require an exact startTime match, so the run is the only place a match can live. On
    /// a dense typeset track the retained array is thousands of cues and every decoded packet used
    /// to walk all of them. Returns whether a cue was actually inserted or replaced.
    @discardableResult
    nonisolated static func insertCueSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue], nextID: inout Int) -> Bool {
        // Index range, deliberately not an ArraySlice: a live slice keeps a second reference to the
        // array's buffer, so the insert below would copy-on-write the whole store on every call.
        let lower = lowerBoundByStartTime(cue.startTime, in: cues)
        var upper = lower
        while upper < cues.count, cues[upper].startTime == cue.startTime { upper += 1 }

        // A non-image cue already present with the same start and flattened text is a re-decode of a retained
        // line, not a new one. `cue.text` flattens both `.text` and `.richText` (#107 coloured teletext pages)
        // and is nil for `.image`, so image cues correctly skip this guard and use their own same-start replace
        // below. Content (not id) is compared: two simultaneous speakers differ in text and both survive; a
        // genuine repeat at a new time has a different start and is inserted. endTime is deliberately NOT part
        // of the key: a retained teletext cue may have been trimmed by its successor (#107) while the re-decode
        // emits the original open-ended window; the retained (trimmed) cue stays authoritative. Deduped cues
        // consume no id.
        if let text = cue.text {
            for i in lower..<upper where cues[i].text == text { return false }
        }

        let stamped = cue.with(id: nextID)
        nextID += 1

        if case .image(let stampedImage) = stamped.body {
            for i in lower..<upper {
                guard case .image(let otherImage) = cues[i].body else { continue }
                if otherImage.position == stampedImage.position
                    && otherImage.cgImage.width == stampedImage.cgImage.width
                    && otherImage.cgImage.height == stampedImage.cgImage.height {
                    cues[i] = stamped
                    return true
                }
            }
        }
        cues.insert(stamped, at: lower)
        return true
    }

    /// First index of the start-sorted retained array whose cue starts at or after `startTime`.
    /// Also the insert position for a cue with that start: a new cue goes in front of the cues
    /// already sharing it, which is where the pre-#271 linear insert put it too.
    nonisolated static func lowerBoundByStartTime(_ startTime: Double, in cues: [SubtitleCue]) -> Int {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime < startTime { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Legacy 2-arg entry that preserves the caller's cue id (test / utility use). The engine path uses the `nextID`
    /// overload so ids stay session-monotonic across decoder rebuilds (#121).
    @discardableResult
    nonisolated static func insertCueSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) -> Bool {
        var id = cue.id
        return insertCueSorted(cue, into: &cues, nextID: &id)
    }

    /// #357: close every cue still carrying its open-ended placeholder window that began before
    /// `boundary`, at `boundary`. Called on a reset tick, where `boundary` is the start of the
    /// window the reconstruction is about to decode (playhead minus backscan).
    ///
    /// Two mechanisms bound an open PGS cue in steady state and neither one survives a seek past it.
    /// The trim needs a SUCCESSOR (`applySubtitleEvent`, `pgsTrimAt`), which after a jump arrives
    /// only when the new landing point's first composition does, seconds or tens of seconds later.
    /// `pruneCues` filters on `endTime`, and a placeholder end is by construction never older than
    /// the retention window, however far the playhead moved. So the pre-seek cue stays in the
    /// published window with a window that covers the new playhead, and every host that asks which
    /// cue is active renders it (report: a cue from 2549.8 s shown at 2855.15 s for 24.5 s).
    ///
    /// The reconstruction window is the right boundary because it is the one the engine already
    /// defines as how far it looks back at a landing: nothing before it is re-decoded, so nothing
    /// before it can be confirmed as still open. Cues stay in the retained store for a backward
    /// seek, only their unconfirmed end is retired. An authored duration is untouched, which is what
    /// separates this from a blanket "drop the pre-seek set": a long ASS sign keeps its own end.
    /// Returns whether any cue was closed.
    ///
    /// #362: this is the LAST resort, not the first. `alignCueEnds(_:toNextPacket:)` closes an
    /// open set at the packet the author put there; only a set with no stored successor at all
    /// reaches this boundary, and its end is then owned by the seek rather than by the author.
    @discardableResult
    nonisolated static func closeOpenEndedCues(_ cues: inout [SubtitleCue],
                                               startingBefore boundary: Double) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            let cue = cues[i]
            guard cue.startTime < boundary, cue.endTime > boundary,
                  cue.endTime - cue.startTime > subtitleOpenEndedWindowSeconds else { continue }
            cues[i] = cue.with(endTime: boundary)
            changed = true
        }
        return changed
    }

    /// #362: close every cue still carrying the placeholder window at the PTS of the next packet
    /// stored on its stream, which for a bitmap set is its authored end (its own clear composition,
    /// or the successor that replaces it, whichever the author put there first).
    ///
    /// The drain decodes a window bounded at `playhead + lead`, and that forward edge falls wherever
    /// it falls. When it lands between a set and the clear a few seconds later, the set publishes
    /// open, the cursor moves on, and nothing goes back for the clear: the next reset starts at a new
    /// landing, so the set is closed by whatever composition turns up next, tens or hundreds of
    /// seconds away (report: 3.55 s authored, 76.7 s delivered, and 817 s in the same session).
    ///
    /// The answer was already in the store. The pump harvests packets far ahead of the drain window,
    /// so the clear is retained at the moment the set publishes and no decode is needed to read its
    /// PTS: the successor's own `pgsTrimAt` would set exactly this end when the window eventually
    /// reaches it. Where the store has nothing after the set (the harvest frontier, a cut file) the
    /// cue stays open, because there is no authored answer there and the alternatives are all
    /// laundered ends. Returns whether any cue was changed.
    ///
    /// #362 round 2: for a bitmap set this holds whether or not the cue still carries the
    /// placeholder, and gating it on that was the defect. A burst leaves the store holding an island
    /// an earlier run harvested, so the first packet after a set can be the far side of a stretch
    /// nobody has read: a real packet, but not this set's successor (report: 75.117 closed at
    /// 144.978, its own clear at 78.579). Publishing it is still right, because the true successor
    /// can only be NEARER, so the answer is an upper bound and the alternative is a placeholder that
    /// renders until something else closes it. Keeping it was not: the clear that lands a second
    /// later, whose entire job is to trim that set, found a cue no longer eligible. A bitmap set has
    /// no end of its own, so every stored packet after it is a bound on its end and taking the
    /// nearest is monotone, it can only ever shorten. That is what makes the bound self-correcting
    /// rather than merely bounded, which is what the first round claimed and did not deliver.
    ///
    /// The rule stays PGS-shaped on purpose. A text event carries its own duration and a packet
    /// following it says nothing about it, so text cues keep the placeholder gate: only an
    /// unconfirmed end is anyone else's to set.
    @discardableResult
    nonisolated static func alignCueEnds(_ cues: inout [SubtitleCue],
                                         toNextPacket nextPacketPTS: (Double) -> Double?) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            let cue = cues[i]
            var isBitmap = false
            if case .image = cue.body { isBitmap = true }
            guard isBitmap || cue.endTime - cue.startTime > subtitleOpenEndedWindowSeconds,
                  let end = nextPacketPTS(cue.startTime),
                  end > cue.startTime, end < cue.endTime else { continue }
            cues[i] = cue.with(endTime: end)
            changed = true
        }
        return changed
    }

    /// Prune cues whose `endTime` is older than the retention window. The caller passes
    /// `sourceTime - subtitleCueRetentionSeconds` because cue.startTime/endTime are absolute source
    /// PTS seconds (see EmbeddedSubtitleDecoder.decode). Returns whether anything was dropped (#271).
    nonisolated static func pruneCues(_ cues: inout [SubtitleCue], before cutoff: Double) -> Bool {
        guard !cues.isEmpty, cutoff > 0 else { return false }
        let before = cues.count
        cues.removeAll { $0.endTime < cutoff }
        return cues.count != before
    }


    // MARK: - External subtitle tracks (#88)

    /// Register an external subtitle file as a first-class track (AetherEngine#88): it appears in
    /// `subtitleTracks` with a synthetic id and `isExternal == true` and is selectable via
    /// `selectSubtitleTrack(index:)`. Overlay-only (no native WebVTT rendition / PiP); declare via
    /// `LoadOptions.externalSubtitles` for rendition eligibility. If `preferredSubtitleLanguages`
    /// is set, nothing is active, and the host made no explicit choice yet, the preference re-runs
    /// so a late-added matching track auto-activates.
    @discardableResult
    public func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let info = registerExternalSubtitleTrack(track)
        applyPreferredSubtitleSelection(startAnchor: sourceTime,
                                        sourceDuration: duration > 0 ? duration : nil)
        return info
    }

    /// #88: seat the load-declared external tracks in `subtitleTracks`. On the probe path this runs
    /// BEFORE preferred-language selection and the native rendition table are built from the list.
    ///
    /// #170: a session-preserving reload seeds the previous session's registry verbatim instead:
    /// mid-session adds survive with their ids (and, registered pre-table, become rendition-eligible on
    /// the reloaded item); mid-session removals stay removed; the host's subtitle authority carries over
    /// so the load-end auto-selection cannot override it.
    ///
    /// #316: the nativeRemoteHLS bypass and the AE#154 reroute return long before the probe path reaches
    /// this point, so both call it themselves. Without that a host declaring sidecars on a remote-HLS
    /// source got nothing back and no diagnostic: the option was read, then dropped at the branch.
    func registerDeclaredExternalSubtitles(_ options: LoadOptions) {
        if let carryover = options.subtitleSessionCarryover {
            applySubtitleSessionCarryoverRegistrations(carryover)
        } else {
            for track in options.externalSubtitles { registerExternalSubtitleTrack(track) }
        }
    }

    /// Registration without the preference re-run; the load path runs its own selection at load end.
    @discardableResult
    func registerExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = Self.externalSubtitleTrackIDBase + nextExternalSubtitleOrdinal
        nextExternalSubtitleOrdinal += 1
        externalSubtitleRegistry[id] = track
        let info = track.makeTrackInfo(id: id, fallbackNumber: nextExternalSubtitleOrdinal)
        subtitleTracks.append(info)
        return info
    }

    /// #88: activate a registered external track. A finished native store holds the whole file's
    /// cues (decoded plain-text at load), so the overlay backfills instantly with no re-download.
    /// Styled ASS wants raw markup, which the store strips, so it re-decodes via the sidecar path.
    private func selectExternalSubtitleTrack(id: Int, track: ExternalSubtitleTrack) {
        let codec = ExternalSubtitleTrack.codecName(url: track.url, formatHint: track.formatHint)
        let wantsStyledASS = loadedOptions.preserveASSMarkup && codec == "ass"
        if !wantsStyledASS,
           let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
           // Phase D: an OCR store holds recognized TEXT; the bitmap overlay must re-decode
           // the sidecar for its images, never backfill from that store.
           !nativeSubtitleTrackTable[ordinal].needsOCR,
           let store = nativeStore(atOrdinal: ordinal),
           store.isFinished, store.cueCount > 0 {
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary)   // #112 rework
            activeEmbeddedSubtitleStreamIndex = -1
            loadedSidecarURL = track.url
            sidecarASSHeader = nil
            isSubtitleActive = true
            activeSubtitleTrackIndex = id
            subtitleCues = store.snapshotCues()
            isLoadingSubtitles = false
            EngineLog.emit("[AetherEngine] external subtitle backfilled from finished store: id=\(id) cues=\(subtitleCues.count)", category: .engine)
            return
        }
        startSidecarDecode(url: track.url, httpHeaders: track.httpHeaders, externalTrackID: id,
                           sourceStreamIndex: track.sourceStreamIndex)
    }

    /// Store lookup for the external backfill: test-hook override first, else the live session's stores.
    func nativeStore(atOrdinal ordinal: Int) -> NativeSubtitleCueStore? {
        #if DEBUG
        if let hooked = testHookNativeStores, ordinal < hooked.count { return hooked[ordinal] }
        #endif
        guard let stores = nativeVideoSession?.nativeSubtitleCueStoresForSession,
              ordinal < stores.count else { return nil }
        return stores[ordinal]
    }

    /// #88: fill the native stores of load-declared external tracks with one whole-file decode each
    /// (plain text, matching the WebVTT rendition), then markFinished so the .vtt handler can serve
    /// complete files and the overlay select can backfill instantly. No side demuxer, no pacing.
    func startExternalNativeStoreFill(session: HLSVideoEngine) {
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        let jobs = Self.externalSubtitleFillJobs(
            table: nativeSubtitleTrackTable,
            registry: externalSubtitleRegistry,
            stores: session.nativeSubtitleCueStoresForSession,
            defaultHeaders: loadedOptions.httpHeaders)
        guard !jobs.isEmpty else { return }
        externalNativeStoreFillTask = Task.detached(priority: .utility) { [jobs] in
            for job in jobs {
                if Task.isCancelled { return }
                await AetherEngine.runExternalSubtitleFill(job: job)
            }
        }
    }

    /// #266: fill one container's stores from a single decode pass. A pass covering several streams
    /// fails as a whole (an out-of-range index throws), so on failure the targets are retried
    /// individually: one host-side index mistake must not blank the container's other tracks. A
    /// store that could not be filled stays UNfinished, or the rendition would serve a complete but
    /// blank .vtt.
    nonisolated static func runExternalSubtitleFill(job: ExternalSubtitleFillJob) async {
        if let results = try? await SubtitleDecoder.decodeFile(
            url: job.url, httpHeaders: job.headers,
            sourceStreamIndices: job.targets.map(\.streamIndex)
        ) {
            for (target, result) in zip(job.targets, results) {
                target.store.appendCues(result.cues)
                target.store.markFinished()
            }
            return
        }
        guard job.targets.count > 1 else {
            EngineLog.emit("[AetherEngine] external native store fill failed: \(job.url.lastPathComponent)", category: .engine)
            return
        }
        EngineLog.emit("[AetherEngine] external native store fill: shared pass over \(job.url.lastPathComponent) failed, retrying \(job.targets.count) targets individually", category: .engine)
        for target in job.targets {
            if Task.isCancelled { return }
            guard let result = try? await SubtitleDecoder.decodeFile(
                url: job.url, httpHeaders: job.headers, sourceStreamIndex: target.streamIndex
            ) else {
                EngineLog.emit("[AetherEngine] external native store fill failed: \(job.url.lastPathComponent) stream=\(target.streamIndex.map(String.init) ?? "auto")", category: .engine)
                continue
            }
            target.store.appendCues(result.cues)
            target.store.markFinished()
        }
    }

    /// Unregister an external track: delist + drop the registry entry; an active selection
    /// (primary or secondary) is cleared. Embedded ids no-op.
    public func removeExternalSubtitleTrack(id: Int) {
        guard externalSubtitleRegistry.removeValue(forKey: id) != nil else { return }
        subtitleTracks.removeAll { $0.id == id }
        if activeSubtitleTrackIndex == id { clearSubtitle() }
        if activeSecondaryExternalSubtitleTrackID == id { clearSecondarySubtitle() }
    }

    /// Fetch and decode a sidecar subtitle file (.srt / .ass / .vtt / .ssa) via `SubtitleDecoder.decodeFile`, replacing `subtitleCues` atomically. `httpHeaders` nil forwards `LoadOptions.httpHeaders` (same auth as the media, #32). Prefer registering via `addExternalSubtitleTrack` + `selectSubtitleTrack` (#88), which keeps the track listed and `activeSubtitleTrackIndex` populated; this API stays for compatibility and one-shot use.
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        hostExplicitSubtitleAction = true
        startSidecarDecode(url: url, httpHeaders: httpHeaders, externalTrackID: nil)
    }

    /// Shared sidecar-decode start: the pre-#88 selectSidecarSubtitle body, parameterized on which
    /// track id (if any) to publish as active. Also clears the pump-tap overlay stream so a prior
    /// tap-fed selection stops forwarding into the sidecar's cues (latent pre-#88 bug: the tap
    /// forward-guard matched the stale index and kept appending).
    func startSidecarDecode(url: URL, httpHeaders: [String: String]?, externalTrackID: Int?,
                            sourceStreamIndex: Int32? = nil) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        clearSubtitleDrainTarget(channel: .primary)   // #112 rework
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = externalTrackID

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        sidecarASSHeader = nil
        isLoadingSubtitles = true

        let effectiveHeaders = httpHeaders ?? loadedOptions.httpHeaders
        // ASS/SSA sidecars honour preserveASSMarkup so hosts can drive a styled renderer. SRT/VTT fall back to plain text regardless.
        let preserveASS = loadedOptions.preserveASSMarkup
        sidecarTask = Task { [weak self] in
            let result: SidecarDecodeResult
            do {
                result = try await SubtitleDecoder.decodeFile(
                    url: url, httpHeaders: effectiveHeaders,
                    preserveASSMarkup: preserveASS,
                    sourceStreamIndex: sourceStreamIndex
                )
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    // Stale-task guard: A->B switch; isSubtitleActive alone doesn't catch it (true again for B by the time A's error lands).
                    guard !Task.isCancelled, let self = self else { return }
                    if self.isSubtitleActive { self.isLoadingSubtitles = false }
                }
                return
            }

            await MainActor.run {
                // Stale-task guard: superseded load A must not overwrite B's cues (isSubtitleActive is true again for B).
                guard !Task.isCancelled, let self = self else { return }
                guard self.isSubtitleActive else { return }
                // Sidecar cues are in source PTS; host renders against engine.sourceTime (which folds playlistShiftSeconds).
                self.subtitleCues = result.cues
                self.sidecarASSHeader = result.assHeader
                self.isLoadingSubtitles = false
                // Native mov_text moov is declared at load; runtime sidecars drive only the host overlay (#55).
                // Phase D: an external bitmap sidecar fills its OCR rendition store from THIS
                // decode's image cues (no second download).
                self.startSidecarOCRFillIfNeeded(externalTrackID: externalTrackID, cues: result.cues)
            }
        }
    }

    /// Decode a sidecar as the secondary companion track (issue #47), independent of the primary.
    public func selectSecondarySidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        hostExplicitSubtitleAction = true
        cancelSidecarTask(channel: .secondary)
        clearSubtitleDrainTarget(channel: .secondary)   // #112 rework
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        activeSecondaryExternalSubtitleTrackID = nil
        startSecondarySidecarDecode(url: url, httpHeaders: httpHeaders)
    }

    /// Shared secondary sidecar-decode start (#88): the pre-#88 selectSecondarySidecarSubtitle body.
    func startSecondarySidecarDecode(url: URL, httpHeaders: [String: String]?,
                                     sourceStreamIndex: Int32? = nil) {
        loadedSecondarySidecarURL = url
        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        isLoadingSecondarySubtitles = true

        let effectiveHeaders = httpHeaders ?? loadedOptions.httpHeaders
        secondarySidecarTask = Task { [weak self] in
            let result: SidecarDecodeResult
            do {
                // Secondary is plain text only (never drives libass, mirroring embedded secondary #47).
                result = try await SubtitleDecoder.decodeFile(
                    url: url, httpHeaders: effectiveHeaders, sourceStreamIndex: sourceStreamIndex)
            } catch {
                EngineLog.emit("[AetherEngine] secondary sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    guard !Task.isCancelled, let self = self else { return }
                    if self.isSecondarySubtitleActive { self.isLoadingSecondarySubtitles = false }
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled, let self = self else { return }
                guard self.isSecondarySubtitleActive else { return }
                self.secondarySubtitleCues = result.cues
                self.isLoadingSecondarySubtitles = false
            }
        }
    }

    /// Disable primary subtitles, clear cues, cancel sidecar task + side demuxer, cancel multi-decode reader, clear native mov_text stores (#55, all-tracks). `nativeSubtitleTracks` is NOT cleared: the host needs the list to re-select after an audio/subtitle switch; only `stop()` / `load()` reset it.
    public func clearSubtitle() {
        hostExplicitSubtitleAction = true
        // AE#359: subtitles off ends the rendition poll. The renditions themselves stay listed, only
        // the fetching stops, so re-selecting the track starts fresh from the current window.
        liveSubtitleFetchTask?.cancel()
        liveSubtitleFetchTask = nil
        // AE#154: a remote-HLS legible selection lives in AVMediaSelection, not the overlay
        // pipeline; deselect it on the item (criteria pinned manual so system caption prefs
        // don't immediately re-select).
        // #316: an injected external rendition is the same kind of selection, under an external id.
        if let active = activeSubtitleTrackIndex,
           RemoteHLSMediaSelection.ordinal(forTrackID: active) != nil
            || injectedSubtitleRenditionNames[active] != nil,
           let item = currentAVPlayer?.currentItem {
            Task { @MainActor in
                self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
                item.select(nil, in: group)
            }
        }
        cancelSidecarTask()
        cancelSubtitleOCRWorker()   // Phase D: subtitles off = worker off (cursors persist)
        clearSubtitleDrainTarget(channel: .primary)   // #112 rework
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        cancelNativeSubtitleReaders()
        // Sodalite#32 Phase 2: with the pump tap active the stores are the session's cue source of
        // truth (the tap's decoder dedup would never refill a cleared store), so subtitles-off keeps
        // them; only the reader-driven path tears them down.
        if nativeVideoSession?.subtitleTapActive != true {
            nativeVideoSession?.nativeSubtitleCueStoresForSession.forEach { $0.clear() }
            nativeVideoSession?.nativeSubtitleCueStoresForSession = []
            nativeVideoSession?.nativeSubtitleLanguagesForSession = []
            nativeSubtitleRenditionAvailable = false
        }
    }

    func cancelSidecarTask(channel: SubtitleChannel = .primary) {
        switch channel {
        case .primary:
            sidecarTask?.cancel()
            sidecarTask = nil
        case .secondary:
            secondarySidecarTask?.cancel()
            secondarySidecarTask = nil
        }
    }

    /// Turn the secondary subtitle off and clear its cues. Tears down
    /// the secondary sidecar decode task and the secondary side reader.
    public func clearSecondarySubtitle() {
        hostExplicitSubtitleAction = true
        cancelSidecarTask(channel: .secondary)
        clearSubtitleDrainTarget(channel: .secondary)   // #112 rework
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        activeSecondaryExternalSubtitleTrackID = nil
        loadedSecondarySidecarURL = nil
        isSecondarySubtitleActive = false
        secondarySubtitleCues = []
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        isLoadingSecondarySubtitles = false
    }

    // MARK: - Native multi-track decode (#55, all-tracks)

    /// Launch the multi-decode reader that fills every text track's store in one side-demuxer pass (#55, all-tracks). Separate from the inline host-overlay path (subtitleCues). Idempotent: cancels any prior reader first. `stores` is ordinal-aligned with `nativeSubtitleTrackTable`.
    /// `readToEOF` reads straight through without the read-ahead parking and marks the stores finished at EOF.
    /// `startAtSeconds` overrides the read anchor (default: the current playhead). Sodalite#32: eager readers
    /// anchor at the SESSION START POSITION, not 0; a from-0 read behind a resume position spent the whole
    /// session catching up over a remote link and never covered the playhead (device: readMax 48s vs playhead
    /// 304s, every .vtt served empty).
    func startNativeSubtitleReaders(url: URL, stores: [NativeSubtitleCueStore],
                                    readToEOF: Bool = false, startAtSeconds: Double? = nil) {
        cancelNativeSubtitleReaders()
        nativeSubtitleReadersRunToEOF = readToEOF
        var pairs: [(streamIndex: Int32, store: NativeSubtitleCueStore)] = []
        for (ordinal, entry) in nativeSubtitleTrackTable.enumerated() {
            // Phase D: OCR ordinals are worker-fed; the reader would open a demuxer only to
            // skip their bitmap routes.
            guard ordinal < stores.count, let src = entry.sourceStreamIndex, !entry.needsOCR else { continue }
            pairs.append((Int32(src), stores[ordinal]))
        }
        guard !pairs.isEmpty else { return }

        var customClone: IOReader? = nil
        if isCustomSource {
            guard let clone = customReader?.makeIndependentReader() else { return }
            customClone = clone
        }
        let headers = loadedOptions.httpHeaders
        let formatHint = customFormatHint
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let startAt = startAtSeconds ?? sourceTime
        let reader = customClone
        // #76: same bounded-probe + active-title open as the inline reader.
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        let titleID = activeDiscTitleID
        let link = SideReaderLinkArbiter(gate: sideReaderLinkGate)
        nativeSubtitleReadersTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runNativeSubtitleReaders(
                url: url, reader: reader, formatHint: formatHint, headers: headers,
                pairs: pairs, startAt: startAt, videoWidth: w, videoHeight: h,
                callerProbesize: probesize, callerMaxAnalyzeDuration: maxAnalyzeDuration,
                selectTitleID: titleID, readToEOF: readToEOF, link: link
            )
        }
    }

    /// #93 residual: start the lazy readers only when no producer restart is executing. PiP entry
    /// mid-restart opened a second WAN demuxer that competed with the restart for the starved
    /// link (device: readers started during a 44 s restart, exited with 0 cues). While a restart
    /// is in flight, poll until it settles (bounded), then start; the pump tap keeps covering the
    /// produced region meanwhile, so only the AVKit-prefetch-burst coverage is deferred.
    func startLazyNativeSubtitleReadersWhenIdle() {
        guard nativeSubtitleReadersTask == nil, let params = nativeSubtitleReaderParams else { return }
        var restartBusy = nativeVideoSession?.restartInFlight == true
        #if DEBUG
        if let override = testHookRestartInFlightOverride { restartBusy = override }
        #endif
        guard restartBusy else {
            startNativeSubtitleReaders(url: params.url, stores: params.stores)
            return
        }
        nativeSubtitleReaderDeferralTask?.cancel()
        nativeSubtitleReaderDeferralTask = Task { @MainActor [weak self] in
            let deadline = DispatchTime.now() + 30.0
            while !Task.isCancelled, DispatchTime.now() < deadline {
                guard let self else { return }
                var busy = self.nativeVideoSession?.restartInFlight == true
                #if DEBUG
                if let override = self.testHookRestartInFlightOverride { busy = override }
                #endif
                if !busy { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            guard self.nativeSubtitleReadersTask == nil,
                  let params = self.nativeSubtitleReaderParams else { return }
            EngineLog.emit("[AetherEngine] deferred native subtitle readers starting (restart settled)", category: .engine)
            self.startNativeSubtitleReaders(url: params.url, stores: params.stores)
        }
    }

    /// Cancel the multi-decode reader + markClosed its side demuxer so a parked AVIO read cannot survive teardown.
    func cancelNativeSubtitleReaders() {
        nativeSubtitleReaderCoverageStart = nil
        nativeSubtitleReaderDeferralTask?.cancel()
        nativeSubtitleReaderDeferralTask = nil
        nativeSubtitleReadersTask?.cancel()
        nativeSubtitleReadersTask = nil
        nativeSubtitleReadersDemuxer?.markClosed()
        nativeSubtitleReadersDemuxer = nil
        nativeSubtitleReadersRunToEOF = false
    }

    /// Multi-stream side-demuxer pass: one EmbeddedSubtitleDecoder per text stream, writing to NativeSubtitleCueStores (not subtitleCues). Prewarm, re-sample, -2 s lead-in, park (the pacing the old inline reader used). Always plain text: mov_text muxer carries no ASS markup.
    nonisolated private func runNativeSubtitleReaders(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String],
        pairs: [(streamIndex: Int32, store: NativeSubtitleCueStore)],
        startAt: Double, videoWidth: Int32, videoHeight: Int32,
        callerProbesize: Int64? = nil, callerMaxAnalyzeDuration: Int64? = nil,
        selectTitleID: Int? = nil, readToEOF: Bool = false,
        link: SideReaderLinkArbiter? = nil
    ) async {
        let demuxer = Demuxer()
        let openProfile = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration).withReaderLabel("nativesubs")
        let registered = await MainActor.run { [weak self] () -> Bool in
            guard !Task.isCancelled, let self else { return false }
            self.nativeSubtitleReadersDemuxer = demuxer
            return true
        }
        guard registered else {
            reader?.close()
            return
        }
        defer {
            Task { @MainActor [weak self, weak demuxer] in
                if let self, let demuxer, self.nativeSubtitleReadersDemuxer === demuxer {
                    self.nativeSubtitleReadersDemuxer = nil
                }
            }
        }
        do {
            if let reader = reader {
                try demuxer.open(reader: reader, formatHint: formatHint, profile: openProfile, selectTitleID: selectTitleID, discCacheKey: url.absoluteString)
            } else {
                try demuxer.open(url: url, extraHeaders: headers, profile: openProfile, selectTitleID: selectTitleID)
            }
        } catch {
            EngineLog.emit("[AetherEngine] native subtitle readers open failed: \(error)", category: .engine)
            reader?.close()
            return
        }
        defer {
            demuxer.close()
            reader?.close()
        }

        // Prewarm MKV cue index (lives at EOF), same as the inline reader. Skip for disc sources (#76).
        // #112 round 10: bounded like the inline reader's; on an index-less remote source the unbounded
        // timestamp seek is the same minutes-long wedge the embedded path had.
        let duration = demuxer.duration
        if duration > 0, !demuxer.isDiscSource {
            demuxer.seekBounded(to: duration * 0.5, timeout: Self.sideReaderSeekBudgetSeconds)
        }
        let freshPlayhead = await MainActor.run { [weak self] in self?.sourceTime }
        // Sodalite#32: a whole-program read must start at `startAt` (0) regardless of the playhead; the usual
        // max-with-playhead (so the PiP reader doesn't start behind the playhead) would drop all cues before it.
        let effectiveStart = readToEOF ? startAt : max(startAt, freshPlayhead ?? startAt)
        let seekTo = max(0, effectiveStart - 2.0)
        await MainActor.run { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.nativeSubtitleReaderCoverageStart = seekTo
        }
        // #112 round 10: same bounded positioning + verified byte-estimate fallback as the embedded reader
        // (memory rule: both side readers share every positioning fix). A whole-program read (readToEOF)
        // starts at 0 and needs no fallback.
        //
        // #234: anchored on the routed subtitle axis for the same reason the prefetcher is, arrived at from
        // the other direction. This seek runs before the discard flags below, so every stream still scores
        // `av_find_default_stream_index`'s +200 for `discard != AVDISCARD_ALL` and video takes the reference
        // on its own +75. Unlike the prefetcher there was never an accidental subtitle anchor here to lose,
        // so this is not part of the #230 regression, but the landing cue it drops is the same one.
        let seekAnchor = pairs.map(\.streamIndex).min() ?? -1
        if !demuxer.seekBounded(to: seekTo, anchorStreamIndex: seekAnchor,
                                timeout: Self.sideReaderSeekBudgetSeconds) {
            demuxer.markTimestampSeekUnreliable()
            let engineDisplayDuration = await MainActor.run { [weak self] in self?.duration ?? 0 }
            let fellBack = demuxer.seekByteEstimate(
                to: seekTo, knownDuration: duration > 0 ? duration : engineDisplayDuration,
                timeout: Self.sideReaderSeekBudgetSeconds)
            EngineLog.emit(
                "[AetherEngine] native subtitle readers seek to \(String(format: "%.2f", seekTo))s timed out "
                + "or failed; byte-estimate fallback \(fellBack ? "applied" : "unavailable")",
                category: .engine)
        }

        // A decoder that fails to open is skipped (track gets no cues).
        var routes: [Int32: (decoder: EmbeddedSubtitleDecoder, store: NativeSubtitleCueStore, tb: AVRational)] = [:]
        for pair in pairs {
            guard let stream = demuxer.stream(at: pair.streamIndex),
                  let decoder = EmbeddedSubtitleDecoder(
                      stream: stream,
                      sourceVideoWidth: videoWidth,
                      sourceVideoHeight: videoHeight,
                      preserveASSMarkup: false
                  )
            else {
                EngineLog.emit("[AetherEngine] native subtitle decoder open failed for stream=\(pair.streamIndex)", category: .engine)
                continue
            }
            // Bitmap codecs excluded at load-time, but guard here too: bitmap bodies cannot become mov_text samples.
            if EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) { continue }
            routes[pair.streamIndex] = (decoder, pair.store, stream.pointee.time_base)
        }
        guard !routes.isEmpty else { return }

        // #104: discard video/audio (and any non-routed subtitle stream) on this side demuxer. Without it the
        // reader pulls and allocs EVERY video+audio sample byte-for-byte through a second AVIOReader just to
        // reach the sparse mov_text samples (mov_read_packet reads the sample unless AVDISCARD_ALL). On a file
        // with many subtitle tracks that meant streaming the whole program through a parallel connection, RSS
        // growing with playback position until jetsam. Matches the main pump / FrameDecodeContext, which already
        // discard.
        //
        // #230: AVDISCARD_ALL drops inside av_read_frame, so a fully discarded source delivers this loop
        // NOTHING between two subtitle packets and the park below (which is evaluated per delivered packet,
        // routed or not) never runs across a dialogue-free stretch. What "fast-walks the index, no I/O" was
        // measured on is mov: `mov_read_packet` skips the avio_seek + read entirely at AVDISCARD_ALL. Matroska
        // does not, `ebml_parse` reads each cluster's blocks off the wire and `matroska_parse_block` only then
        // checks discard, so on MKV the bytes are pulled regardless. Leaving one stream at AVDISCARD_NONKEY
        // restores a control point (one packet per IRAP) at a cost that ends as soon as the park engages.
        // readToEOF wants no park at all, so it wants no pacing stream either.
        let pacing = readToEOF ? -1 : demuxer.prefetchPacingStreamIndex()
        demuxer.discardAllStreamsExcept(Set(routes.keys), pacing: pacing)

        EngineLog.emit(
            "[AetherEngine] native subtitle readers started: streams=\(routes.keys.sorted()) " +
            "startAt=\(String(format: "%.2f", startAt))s effectiveStart=\(String(format: "%.2f", effectiveStart))s " +
            "seekTo=\(String(format: "%.2f", seekTo))s anchor=\(seekAnchor)",
            category: .engine
        )

        var playheadSnapshot = effectiveStart
        /// #240: the valve's grant window and the post-anchor head start, see the prefetcher's loop.
        var valveGrantedUntil: DispatchTime? = nil
        let anchorGraceUntil = DispatchTime.now()
            + (link?.anchorGraceSeconds ?? SideReaderLinkPolicy.anchorGraceSeconds)
        var parkLogged = false
        var timeBaseCache: [Int32: AVRational] = [:]
        var totalCues = 0

        readLoop: while !Task.isCancelled {
            // #240: the video path owns the link; this reader is lookahead. Same rule as the #151
            // prefetcher, same reason (on Matroska this reader pulls every video and audio byte to
            // reach the sparse subtitle packets). A whole-program pass has no lead to spend and is
            // not gated: `readToEOF` serves a .vtt request that is already waiting on it.
            if let link, !readToEOF, valveGrantedUntil.map({ DispatchTime.now() > $0 }) ?? true {
                var yielded: Double = 0
                while !Task.isCancelled,
                      link.shouldYield(inAnchorGrace: DispatchTime.now() < anchorGraceUntil,
                                       yieldedSeconds: yielded) {
                    guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime })
                    else { break readLoop }
                    playheadSnapshot = fresh
                    do { try await Task.sleep(nanoseconds: link.pollNanoseconds) } catch { break readLoop }
                    yielded += link.pollSeconds
                }
                if yielded >= link.maxYieldSeconds {
                    valveGrantedUntil = DispatchTime.now() + link.valveGrantSeconds
                    // Same line the #151 prefetcher emits, because a grant that is not logged
                    // reads from the outside like a reader taking the link without permission.
                    EngineLog.emit(
                        "[AetherEngine] native subtitle readers yielded the link for "
                        + "\(Int(yielded))s; taking \(Int(link.valveGrantSeconds))s of it back "
                        + "(the video path is not releasing it)",
                        category: .engine)
                }
            }
            guard let pkt = try? demuxer.readPacket() else { break }
            let streamIdx = pkt.pointee.stream_index

            // #230: a pacing packet is placed by DTS, the read position the park bounds; a routed
            // subtitle packet keeps its PTS. Shares the prefetcher's resolver so a transient lookup
            // failure is not memoized into a park-free session (#220).
            var pktSeconds: Double?
            if let ptb = SubtitleForwardPrefetcher.resolveTimeBase(
                streamIndex: streamIdx, cache: &timeBaseCache,
                lookup: { demuxer.stream(at: $0)?.pointee.time_base }) {
                pktSeconds = SubtitleForwardPrefetcher.packetSeconds(
                    pts: pkt.pointee.pts, dts: pkt.pointee.dts,
                    timeBase: ptb, preferDecodeOrder: routes[streamIdx] == nil)
            }

            if let route = routes[streamIdx] {
                let event = route.decoder.decode(packet: pkt, streamTimeBase: route.tb)
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                if let event, !event.cues.isEmpty {
                    totalCues += event.cues.count
                    route.store.appendCues(event.cues)
                    let hasCues = route.store.cueCount > 0  // Snapshot locally; route can't be captured in the MainActor closure (Sendable).

                    if hasCues {
                        await MainActor.run { [weak self] in
                            guard !Task.isCancelled, let self else { return }
                            self.nativeSubtitleRenditionAvailable = true
                        }
                    }
                }
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }

            // #15: keep the native readers ahead of AVPlayer's ~240s subtitle prefetch burst (larger lead than
            // the inline overlay reader), so the served .vtt segments carry cues instead of being fetched empty
            // and cached empty for the VOD rendition. Only runs while a native rendition is selected (PiP).
            // Sodalite#32: a whole-program .vtt must hold EVERY cue, so read straight to EOF without parking
            // (cue data is tiny). markFinished after the loop lets the .vtt handler wait for a complete file.
            if !readToEOF, let pktSeconds, pktSeconds > playheadSnapshot + Self.nativeSubtitleReadAheadSeconds {
                while !Task.isCancelled {
                    guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime }) else {
                        break readLoop
                    }
                    playheadSnapshot = fresh
                    if pktSeconds <= playheadSnapshot + Self.nativeSubtitleReadAheadSeconds { break }
                    if !parkLogged {
                        parkLogged = true
                        EngineLog.emit(
                            "[AetherEngine] native subtitle readers parked: " +
                            "demuxPos=\(String(format: "%.1f", pktSeconds))s " +
                            "playhead=\(String(format: "%.1f", playheadSnapshot))s",
                            category: .engine
                        )
                    }
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break readLoop }
                }
            }
        }

        // Sodalite#32: reaching here without cancellation means the side demuxer hit EOF, so every cue for the
        // whole program is now in the stores; signal completeness for the whole-program .vtt handler.
        if readToEOF && !Task.isCancelled {
            for pair in pairs { pair.store.markFinished() }
        }

        EngineLog.emit(
            "[AetherEngine] native subtitle readers exited (cancelled=\(Task.isCancelled)) totalCues=\(totalCues) readToEOF=\(readToEOF)",
            category: .engine
        )
    }

    /// #93 PiP skips: debounced re-anchor after a far rendered-time jump. Waits for the skip
    /// storm to settle, then, if the readers do not cover the playhead while a rendition is
    /// selected, restarts them at the new position by replaying the remembered selection (whose
    /// pre-fill + deselect/reselect also busts AVKit's cached empty .vtt windows, #32). The
    /// whole-program eager reader is left alone: it converges on full coverage by itself.
    func scheduleNativeSubtitleReanchor() {
        guard nativeSubtitleReapplyOrdinal != nil,
              !nativeSubtitleReadersRunToEOF,
              nativeVideoSession != nil else { return }
        nativeSubtitleReanchorTask?.cancel()
        nativeSubtitleReanchorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AetherEngine.subtitleReanchorSettleNanos)
            guard !Task.isCancelled, let self else { return }
            guard let ordinal = self.nativeSubtitleReapplyOrdinal,
                  !self.nativeSubtitleReadersRunToEOF,
                  self.nativeVideoSession != nil else { return }
            let position = self.sourceTime
            let readMax = self.nativeSubtitleReaderParams.flatMap { params in
                ordinal < params.stores.count ? params.stores[ordinal].readMaxCueEnd() : nil
            } ?? 0
            if Self.nativeSubtitleReadersCover(
                position: position,
                coverageStart: self.nativeSubtitleReaderCoverageStart,
                readMax: readMax
            ) { return }
            EngineLog.emit(
                "[AetherEngine] native subtitle readers re-anchoring: playhead "
                + "\(String(format: "%.2f", position))s outside coverage "
                + "(start=\(self.nativeSubtitleReaderCoverageStart.map { String(format: "%.2f", $0) } ?? "none") "
                + "readMax=\(String(format: "%.2f", readMax))); replaying selection ordinal=\(ordinal)",
                category: .engine
            )
            self.cancelNativeSubtitleReaders()
            self.setNativeSubtitleSelected(track: ordinal)
        }
    }


    /// Select or deselect the native mov_text track by ordinal (#55). nil deselects all. Matches by `extendedLanguageTag` first (language-rank-aware for same-language duplicates), falls back to positional index. No-op when no legible group or ordinal out of range.
    public func setNativeSubtitleSelected(track ordinal: Int?) {
        // Remembered before any guard: the #93 recovery reload replays the host's last request
        // onto the fresh item even when this call raced a not-yet-current player.
        nativeSubtitleReapplyOrdinal = ordinal
        // #15: lazy readers, run the side-demuxer only while a native track is selected (PiP), idle otherwise.
        // Sodalite#32: an eager read-to-EOF reader survives deselect (it is building whole-session coverage;
        // cancelling it on PiP exit left the store frozen at ~48s and every later .vtt served empty).
        if ordinal != nil {
            startLazyNativeSubtitleReadersWhenIdle()
        } else if !nativeSubtitleReadersRunToEOF {
            cancelNativeSubtitleReaders()
        }
        guard let item = currentAVPlayer?.currentItem else { return }
        // Capture track list; avoid capturing self to keep MainActor re-entrancy to one hop.
        let tracks = nativeSubtitleTracks
        Task { @MainActor in
            // #15: with automatic media-selection criteria on (the default), AVKit can override/not-render an
            // explicit legible selection until a view refresh. Pin manual selection so the explicit choice
            // renders immediately and survives.
            currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            guard !group.options.isEmpty else { return }
            guard let ordinal else {
                item.select(nil, in: group)
                return
            }
            // Rank-based selection through the ISO-synonym matcher: AVFoundation normalizes HLS
            // LANGUAGE tags (matroska "ger" reads back as extendedLanguageTag "de"), so the old
            // prefix compare found nothing and its positional fallback selected a WRONG-LANGUAGE
            // option (device: the second German track rendered the English rendition in PiP).
            // Language-tagged tracks now select nothing on a failed match; only language-less
            // tracks keep the positional fallback.
            var selected: AVMediaSelectionOption?
            if ordinal < tracks.count, let lang = tracks[ordinal].language {
                let rank = NativeSubtitleTrack.sameLanguageRank(of: ordinal, in: tracks)
                let tags = group.options.map { $0.extendedLanguageTag }
                if let idx = Self.nativeOptionIndex(forLanguage: lang, rank: rank, optionLanguageTags: tags) {
                    selected = group.options[idx]
                }
            } else if ordinal < group.options.count {
                selected = group.options[ordinal]
            }
            guard let option = selected else {
                EngineLog.emit("[AetherEngine] native subtitle select: no matching option for ordinal=\(ordinal) lang=\(ordinal < tracks.count ? (tracks[ordinal].language ?? "nil") : "?") groupOpts=\(group.options.count)", category: .engine)
                return
            }
            // #15: pre-fill BEFORE selecting, so AVPlayer fetches a populated rendition instead of racing the
            // reader (empty .vtt). Done here (off the loopback connection) rather than blocking the .vtt handler,
            // which serializes the connection and stalls the legible pipeline.
            // Sodalite#32: AVKit prefetches the ENTIRE forward subtitle window (~3 min observed) in ONE burst at
            // selection and caches whatever it gets, never re-fetching a segment it already pulled. A +5s pre-fill
            // left ~45/46 segments empty (device-confirmed). Pre-fill far enough ahead to cover that burst; break
            // early when the reader stops making progress (EOF / read-ahead parked) so we never wait the full
            // deadline for content with little remaining.
            if let stores = nativeSubtitleReaderParams?.stores, ordinal < stores.count {
                let store = stores[ordinal]
                let target = currentTime + 240.0
                let deadline = Date().addingTimeInterval(15.0)
                var lastMax = 0.0
                var stall = 0
                while store.readMaxCueEnd() < target, Date() < deadline {
                    let m = store.readMaxCueEnd()
                    if m > lastMax {
                        lastMax = m
                        stall = 0
                    } else if lastMax > 0 {
                        // Only treat a flat readMax as "reader done/parked" AFTER it has started producing;
                        // before the first cue lands (seek + demux latency) readMax is legitimately 0, and an
                        // early break would skip the pre-fill entirely (Sodalite#32 regression).
                        stall += 1
                    }
                    if stall >= 6 { break }   // ~900ms with no new cues after producing => EOF / read-ahead parked
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                EngineLog.emit("[AetherEngine] native subtitle pre-fill done: readMax=\(String(format: "%.1f", store.readMaxCueEnd())) target=\(String(format: "%.1f", target)) cues=\(store.cueCount)", category: .engine)
            }
            // #15: AVKit attaches the legible renderer to whatever selection is active when the rendering
            // pipeline is established; a selection made mid-playback updates state + downloads cues but is not
            // drawn until re-asserted. Deselect, hop one runloop, then reselect to force the renderer to attach
            // (documented workaround; the same effect a PiP round-trip had). Needs the manual-criteria pin above.
            let itemID = String(UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xffff, radix: 16)
            EngineLog.emit("[AetherEngine] native subtitle select: item=\(itemID) opt=\(option.displayName) groupOpts=\(group.options.count) criteriaAuto=\(currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically ?? true) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
            item.select(nil, in: group)
            try? await Task.sleep(nanoseconds: 100_000_000)
            item.select(option, in: group)
            let after = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
            EngineLog.emit("[AetherEngine] native subtitle select done: selected=\(after) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
            // Sodalite#32: a select landing inside a stall recovery gets dropped outright by AVFoundation
            // (device: PiP entry 0.1s after waitingToPlay -> playing read back nil and STAYED nil; the same
            // select succeeded on the previous entry). Re-assert briefly until it sticks or the item changes.
            var retries = 0
            while item.currentMediaSelection.selectedMediaOption(in: group) == nil,
                  retries < 4,
                  currentAVPlayer?.currentItem === item {
                retries += 1
                try? await Task.sleep(nanoseconds: 700_000_000)
                item.select(option, in: group)
                let retried = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
                EngineLog.emit("[AetherEngine] native subtitle select retry #\(retries): selected=\(retried)", category: .engine)
            }
        }
    }

    /// #88: ordinal of the table entry backing an active track id: embedded ids match
    /// sourceStreamIndex, external ids match externalID.
    nonisolated static func nativeSubtitleOrdinal(forActiveTrack id: Int, in table: [NativeSubtitleTrackEntry]) -> Int? {
        table.firstIndex { $0.sourceStreamIndex == id || $0.externalID == id }
    }

    /// #266: group the load-declared external tracks into one fill job per container, so a URL
    /// backing several tracks (an MKV with three subtitle streams) is read once instead of once per
    /// track. Headers are part of the grouping key: differing auth means differing requests.
    /// Duplicate registrations of one stream stay separate targets, both stores get the cues.
    /// Ordering is by first appearance in the table, so the jobs are deterministic.
    nonisolated static func externalSubtitleFillJobs(
        table: [NativeSubtitleTrackEntry],
        registry: [Int: ExternalSubtitleTrack],
        stores: [NativeSubtitleCueStore],
        defaultHeaders: [String: String]
    ) -> [ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
        }
        var order: [Key] = []
        var targetsByKey: [Key: [ExternalSubtitleFillJob.Target]] = [:]
        for (ordinal, entry) in table.enumerated() {
            // Phase D: OCR entries defer to the selection-time sidecar decode (OCR of a whole
            // .sup at load would violate the selection gating).
            guard !entry.needsOCR, let extID = entry.externalID,
                  let track = registry[extID], ordinal < stores.count else { continue }
            let key = Key(url: track.url, headers: track.httpHeaders ?? defaultHeaders)
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.sourceStreamIndex, store: stores[ordinal]))
        }
        return order.map {
            ExternalSubtitleFillJob(url: $0.url, headers: $0.headers, targets: targetsByKey[$0] ?? [])
        }
    }

    /// Phase D: bitmap tracks eligible for an OCR-fed rendition. VOD only; embedded entries carry
    /// their source stream index (the worker's packet-store key), external .sup entries their
    /// synthetic id (the sidecar OCR fill key).
    nonisolated static func bitmapOCRSubtitleEntries(
        from tracks: [TrackInfo], isLive: Bool
    ) -> [NativeSubtitleTrackEntry] {
        guard !isLive else { return [] }
        return tracks.filter { isBitmapSubtitleCodec($0.codec) }.map { track in
            NativeSubtitleTrackEntry(sourceStreamIndex: track.isExternal ? nil : track.id,
                                     externalID: track.isExternal ? track.id : nil,
                                     language: track.language,
                                     isForced: track.isForced,
                                     needsOCR: true)
        }
    }

    /// Rendition metadata for the master's EXT-X-MEDIA tags. HLS requires NAME to be unique within
    /// a group; duplicate names made AVFoundation collapse same-language renditions into ONE
    /// legible option (device: three declared, groupOpts=2, and the second German track ended up
    /// selecting the English option through the old positional fallback). Same-language duplicates
    /// get a numbered suffix; the forced disposition is carried for FORCED=YES.
    nonisolated static func nativeSubtitleRenditionInfos(
        for entries: [NativeSubtitleTrackEntry]
    ) -> [NativeSubtitleRenditionInfo] {
        var counts: [String: Int] = [:]
        return entries.enumerated().map { i, entry in
            let base = entry.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
                ?? "Subtitle \(i + 1)"
            let n = (counts[base] ?? 0) + 1
            counts[base] = n
            return NativeSubtitleRenditionInfo(
                language: entry.language,
                name: n == 1 ? base : "\(base) \(n)",
                isForced: entry.isForced
            )
        }
    }

    /// Index of the legible option backing (track language, same-language rank). AVFoundation
    /// normalizes HLS LANGUAGE tags (matroska "ger" reads back as extendedLanguageTag "de", often
    /// with a region subtag), so matching goes through the ISO-synonym table on the primary
    /// subtag, not a prefix compare. Deliberately NO cross-language fallback: selecting a
    /// wrong-language option is worse than selecting nothing (device: German pick rendered the
    /// English rendition in PiP).
    nonisolated static func nativeOptionIndex(
        forLanguage language: String?, rank: Int, optionLanguageTags: [String?]
    ) -> Int? {
        guard let language, rank >= 0 else { return nil }
        let matching = optionLanguageTags.indices.filter { idx in
            guard let tag = optionLanguageTags[idx],
                  let primary = tag.split(separator: "-").first else { return false }
            return languageMatches(String(primary), language)
        }
        guard rank < matching.count else { return nil }
        return matching[rank]
    }

    /// #15 / Sodalite#34: select the native track matching the currently-active subtitle so AVKit renders it
    /// itself whenever the video leaves the host's own view hierarchy (a PiP window, an AirPlay receiver, or a
    /// wired external display), where the host's on-frame overlay cannot draw; `active == false` deselects when
    /// the video returns to fullscreen inside the app. Maps the active subtitle's source stream (embedded) or
    /// synthetic id (load-declared external, #88) to the native ordinal. No-op (no native subtitle) when the
    /// active subtitle has no native text equivalent: a bitmap (PGS/DVB), CEA-708 (608 now rides a native
    /// rendition, #98), or a track added after load (dynamic external / one-shot sidecar).
    public func setNativeSubtitleRendering(_ active: Bool) {
        // #170: the AirPlay flip triggers both the engine's LAN-swap reload and the host's
        // documented rendering call; landing mid-reload the active track is transiently nil and
        // this call would be misread as a deselect. Latch the newest request instead;
        // restoreSubtitleSelection applies it once the reload has re-established the selection.
        if sessionPreservingReloadInFlight {
            pendingNativeRenderingRequest = active
            return
        }
        guard active, let activeIdx = activeSubtitleTrackIndex,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: activeIdx, in: nativeSubtitleTrackTable)
        else {
            setNativeSubtitleSelected(track: nil)
            return
        }
        setNativeSubtitleSelected(track: ordinal)
    }

    // MARK: - Session-preserving reload carryover (#170)

    /// True when `nativeSubtitleReapplyOrdinal` equals the active track's mapping through the
    /// current rendition table, i.e. the ordinal came from `setNativeSubtitleRendering` rather
    /// than a host-positional `setNativeSubtitleSelected`. Decides recompute-vs-positional replay.
    func currentReapplyOrdinalMatchesActiveTrack() -> Bool {
        guard let ordinal = nativeSubtitleReapplyOrdinal,
              let active = activeSubtitleTrackIndex else { return false }
        return Self.nativeSubtitleOrdinal(forActiveTrack: active, in: nativeSubtitleTrackTable) == ordinal
    }

    /// #170: snapshot the subtitle session state a from-scratch `load()` would wipe. Taken by
    /// `reloadAtCurrentPosition` before the reload; seeded back via
    /// `LoadOptions.subtitleSessionCarryover` and `restoreSubtitleSelection`.
    func captureSubtitleSessionCarryover() -> SubtitleSessionCarryover {
        var carryover = SubtitleSessionCarryover()
        carryover.externalTracks = externalSubtitleRegistry
            .sorted { $0.key < $1.key }
            .map { .init(id: $0.key, track: $0.value) }
        carryover.nextExternalOrdinal = nextExternalSubtitleOrdinal
        carryover.hostExplicitSubtitleAction = hostExplicitSubtitleAction
        carryover.activeSubtitleTrackIndex = activeSubtitleTrackIndex
        carryover.primarySidecarURL = (isSubtitleActive && activeSubtitleTrackIndex == nil
            && activeEmbeddedSubtitleStreamIndex < 0) ? loadedSidecarURL : nil
        carryover.secondaryTrackIndex = activeSecondaryExternalSubtitleTrackID
            ?? (activeSecondaryEmbeddedSubtitleStreamIndex >= 0
                ? Int(activeSecondaryEmbeddedSubtitleStreamIndex) : nil)
        carryover.secondarySidecarURL = (isSecondarySubtitleActive && carryover.secondaryTrackIndex == nil)
            ? loadedSecondarySidecarURL : nil
        carryover.nativeReapplyOrdinal = nativeSubtitleReapplyOrdinal
        carryover.reapplyOrdinalMatchesActiveTrack = currentReapplyOrdinalMatchesActiveTrack()
        return carryover
    }

    /// #170: seed the fresh session's external registry from the carryover, id-exactly (removal
    /// gaps preserved), and restore the host's subtitle authority so the load-end
    /// preferred-language auto-selection cannot override an explicit pick. Called by `load()` at
    /// the #88 registration point, BEFORE the native rendition table is built, so mid-session
    /// tracks become rendition-eligible on the reloaded item.
    func applySubtitleSessionCarryoverRegistrations(_ carryover: SubtitleSessionCarryover) {
        for entry in carryover.externalTracks {
            externalSubtitleRegistry[entry.id] = entry.track
            subtitleTracks.append(entry.track.makeTrackInfo(
                id: entry.id,
                fallbackNumber: entry.id - Self.externalSubtitleTrackIDBase + 1))
        }
        nextExternalSubtitleOrdinal = max(nextExternalSubtitleOrdinal, carryover.nextExternalOrdinal)
        if carryover.hostExplicitSubtitleAction { hostExplicitSubtitleAction = true }
    }

    /// #170: re-establish the pre-reload subtitle selection on the reloaded session instead of
    /// leaving the re-run auto-selection in charge, then replay the native-rendition pick the way
    /// the #65 recovery does (a latched mid-reload `setNativeSubtitleRendering` is newer intent
    /// and wins over the snapshot).
    func restoreSubtitleSelection(from carryover: SubtitleSessionCarryover, resumeAnchor: Double?) {
        // Anchor mirrors applyPreferredSubtitleSelection: the reload's resume position (clamped
        // when the duration is already known) so the drainer/prefetcher arm at the playhead, else
        // the live sourceTime.
        var anchor = max(0, resumeAnchor ?? 0)
        if duration > 0 { anchor = min(anchor, duration) }
        let startAt = anchor > 0 ? anchor : sourceTime
        switch Self.subtitleSelectionRestoreAction(
            previousActiveIndex: carryover.activeSubtitleTrackIndex,
            previousSidecarURL: carryover.primarySidecarURL,
            hostHadExplicitAction: carryover.hostExplicitSubtitleAction,
            postLoadActiveIndex: activeSubtitleTrackIndex,
            postLoadSubtitleActive: isSubtitleActive
        ) {
        case .reselect(let index):
            selectSubtitleTrack(index: index, startAt: startAt)
        case .sidecar(let url):
            startSidecarDecode(url: url, httpHeaders: nil, externalTrackID: nil)
        case .clear:
            clearSubtitle()
        case .none:
            break
        }
        if let secondary = carryover.secondaryTrackIndex {
            selectSecondarySubtitleTrack(index: secondary, startAt: startAt)
        } else if let url = carryover.secondarySidecarURL {
            selectSecondarySidecarSubtitle(url: url)
        }
        if let pending = pendingNativeRenderingRequest {
            pendingNativeRenderingRequest = nil
            setNativeSubtitleRendering(pending)
        } else if let ordinal = Self.nativeOrdinalToReplay(
            previousOrdinal: carryover.nativeReapplyOrdinal,
            matchesActiveTrack: carryover.reapplyOrdinalMatchesActiveTrack,
            previousActiveTrack: carryover.activeSubtitleTrackIndex,
            currentOrdinal: nativeSubtitleReapplyOrdinal,
            table: nativeSubtitleTrackTable
        ) {
            EngineLog.emit(
                "[AetherEngine] #170 re-applying native subtitle ordinal=\(ordinal) after session-preserving reload",
                category: .engine
            )
            setNativeSubtitleSelected(track: ordinal)
        }
    }

    /// Sodalite#38: the native WebVTT legible rendition exists only for PiP / AirPlay; fullscreen uses the
    /// host's on-frame overlay. AVKit AUTO-SELECTS the legible group at readyToPlay when the user has a
    /// system caption preference (Accessibility "Closed Captions + SDH", or a preferred subtitle language),
    /// which overrides the rendition's DEFAULT=NO,AUTOSELECT=NO, and the forced system caption WINDOW (the
    /// grey box) cannot be styled transparent via textStyleRules. So pin the group DESELECTED at load.
    /// `appliesMediaSelectionCriteriaAutomatically = false` alone does NOT stop it: a system caption pref
    /// counts as the explicit user request that overrides the flag (device-tested, the reverted 0baa98d);
    /// only a manual `select(nil)` sticks (device-confirmed: the PiP round-trip workaround, which ends in
    /// exactly this deselect, cleared the subtitle). So `select(nil)` is asserted UNCONDITIONALLY the moment
    /// the group loads (a manual deselect registered before AVKit's ready-time pass keeps it from engaging),
    /// then re-asserted on a tight 40 ms cadence for the first second, where the old 250 ms cadence let
    /// auto-selected cues flash for up to ~0.5 s at start (iOS device).
    /// Bails the instant the host requests a native track (`setNativeSubtitleRendering` / PiP, AirPlay, or
    /// external-display entry sets `nativeSubtitleReapplyOrdinal`), which owns selection from then on. A no-op
    /// when native subtitles are not prepared (no legible group, e.g. tvOS overlay-only).
    ///
    /// Sodalite#65: the load-time burst is not enough, because the system also selects the rendition
    /// LATER. iOS 26's automatic captions (Settings > Accessibility > Subtitles & Captioning: "show when
    /// muted", "show when skipping back", "show when languages differ") turn captions on minutes into a
    /// session, and once the burst had run out nothing held them back: AVKit rendered the rendition the
    /// host keeps around for PiP and AirPlay only, as an empty grey caption box over the frame (the text
    /// itself stayed invisible under the host's transparent style rules). So the burst hands over to a
    /// media-selection observer that stays armed for the item's whole life and deselects again on every
    /// foreign selection, bounded only against a selection fight it cannot win.
    func forceNativeLegibleDeselectedUntilHostSelects() {
        cancelNativeLegibleDeselectPin()
        guard nativeSubtitleReapplyOrdinal == nil, let item = currentAVPlayer?.currentItem else { return }
        currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
        nativeLegibleDeselectPinTask = Task { @MainActor [weak self] in
            guard let self,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else { return }
            var attempts = 0
            while attempts < 25,
                  self.nativeSubtitleReapplyOrdinal == nil,
                  self.currentAVPlayer?.currentItem === item {
                if attempts == 0 || item.currentMediaSelection.selectedMediaOption(in: group) != nil {
                    item.select(nil, in: group)
                    EngineLog.emit("[AetherEngine] Sodalite#38 native legible force-deselected (attempt \(attempts))", category: .engine)
                }
                attempts += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            guard self.nativeSubtitleReapplyOrdinal == nil,
                  self.currentAVPlayer?.currentItem === item else { return }
            self.armNativeLegibleReselectionObserver(item: item, group: group)
        }
    }

    /// Sodalite#65: hold the deselect for the rest of the session. `mediaSelectionDidChangeNotification`
    /// fires for the system's automatic captions as well as for the engine's own selects, so the handler
    /// only acts on a selection that is present while the host has not asked for a native track; the
    /// engine's own `select(nil)` reads back as nil and re-enters nothing.
    private func armNativeLegibleReselectionObserver(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        nativeLegibleDeselectPinItem = item
        nativeLegibleDeselectPinGroup = group
        nativeLegibleDeselectPinObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // Delivered on .main (queue: .main above), so assert MainActor to reach @MainActor state.
            MainActor.assumeIsolated {
                guard let self,
                      let pinned = self.nativeLegibleDeselectPinItem,
                      let group = self.nativeLegibleDeselectPinGroup,
                      pinned === self.currentAVPlayer?.currentItem else { return }
                // The host owns selection from the moment it asks for a native track (PiP, AirPlay,
                // external display); its own select fires this notification too.
                guard self.nativeSubtitleReapplyOrdinal == nil else {
                    self.cancelNativeLegibleDeselectPin()
                    return
                }
                guard let selected = pinned.currentMediaSelection.selectedMediaOption(in: group) else { return }
                guard self.nativeLegibleDeselectPinBurst.admit(now: Date().timeIntervalSinceReferenceDate) else {
                    EngineLog.emit(
                        "[AetherEngine] Sodalite#65: the system keeps re-selecting legible option "
                        + "\"\(selected.displayName)\"; standing down, the caption box stays",
                        category: .engine)
                    self.cancelNativeLegibleDeselectPin()
                    return
                }
                pinned.select(nil, in: group)
                EngineLog.emit(
                    "[AetherEngine] Sodalite#65: legible option \"\(selected.displayName)\" was selected "
                    + "from outside the engine (iOS automatic captions); deselected again, "
                    + "publishing the request (lang=\(selected.extendedLanguageTag ?? "none"))",
                    category: .engine)
                // The selection is the only trace of the user's automatic-captions settings, which have
                // no read API. Hand it to the host, which can render it in its own subtitle presentation.
                self.systemCaptionRequest.send(SystemCaptionRequest(language: selected.extendedLanguageTag))
            }
        }
    }

    /// Drops the pin's task, observer and burst budget. Called by the next `load()`, by `stopInternal`,
    /// and by the pin itself once the host takes over selection.
    func cancelNativeLegibleDeselectPin() {
        nativeLegibleDeselectPinTask?.cancel()
        nativeLegibleDeselectPinTask = nil
        if let observer = nativeLegibleDeselectPinObserver {
            NotificationCenter.default.removeObserver(observer)
            nativeLegibleDeselectPinObserver = nil
        }
        nativeLegibleDeselectPinItem = nil
        nativeLegibleDeselectPinGroup = nil
        nativeLegibleDeselectPinBurst.reset()
    }

    // MARK: - Remote-HLS bypass legible selection (AE#154)

    /// Surface the bypass item's legible AVMediaSelectionGroup as `subtitleTracks` (synthetic ids,
    /// see `RemoteHLSMediaSelection`). Runs once per load; after readiness it mirrors a selection
    /// AVKit or system caption preferences already made so host pickers start truthful. Deliberately
    /// no force-deselect here (unlike Sodalite#38 on the loopback path): this bypass has no on-frame
    /// overlay, AVPlayer's own legible renderer IS the subtitle output, so system prefs stay honored.
    ///
    /// AE#154 follow-up (jihongboo, macOS 27 beta): the legible group is usually populated once the
    /// master playlist is parsed, well before readyToPlay (device: macOS 26 surfaces all renditions at
    /// ~0.5 s). But on some OS versions `loadMediaSelectionGroup(for:)` returns an empty group until the
    /// item reaches readyToPlay, and a one-shot load then silently dropped every rendition. Retry once
    /// after readiness before giving up, so an early-empty group no longer leaves `subtitleTracks` empty.
    func publishRemoteHLSSubtitleTracks(host: NativeAVPlayerHost) {
        remoteHLSSubtitleDiscoveryTask?.cancel()
        guard let item = host.avPlayer.currentItem else { return }
        remoteHLSSubtitleDiscoveryTask = Task { @MainActor [weak self] in
            var group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            if group?.options.isEmpty ?? true {
                // Early-empty group: wait for readyToPlay (AVFoundation's guarantee point for HLS
                // media selection) and load once more. Cancelled by the next load()/stop().
                for await ready in host.$isReady.values where ready { break }
                guard !Task.isCancelled else { return }
                group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            }
            guard let group, !group.options.isEmpty else { return }
            guard let self, !Task.isCancelled,
                  self.currentAVPlayer?.currentItem === item else { return }
            var snapshots: [RemoteHLSMediaSelection.LegibleOption] = []
            for option in group.options {
                snapshots.append(RemoteHLSMediaSelection.LegibleOption(
                    displayName: option.displayName,
                    extendedLanguageTag: option.extendedLanguageTag,
                    isDefault: group.defaultOption == option,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                    isSDH: option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                        && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility),
                    playlistName: await RemoteHLSMediaSelection.playlistName(of: option)))
            }
            // #316: merge, don't assign; the host's load-declared external tracks must survive. The
            // renditions the proxy injected for those same tracks are dropped here: they are already
            // listed under their external ids, and a second entry would offer one file as two tracks.
            let injected = Set(self.injectedSubtitleRenditionNames.values)
            self.subtitleTracks = RemoteHLSMediaSelection.mergedSubtitleTracks(
                existing: self.subtitleTracks, legible: snapshots, injectedNames: injected)
            EngineLog.emit(
                "[AetherEngine] AE#154: remote-HLS legible group surfaced \(group.options.count) subtitle "
                + "rendition(s)\(injected.isEmpty ? "" : ", \(injected.count) of them engine-injected (#316)")",
                category: .engine)
            // Selection mirror after readiness: AVKit / caption-pref auto-select runs at readyToPlay,
            // later than the group load above.
            for await ready in host.$isReady.values where ready { break }
            guard !Task.isCancelled, self.currentAVPlayer?.currentItem === item,
                  !self.hostExplicitSubtitleAction else { return }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let ordinal = group.options.firstIndex(of: selected) {
                // #316: an auto-selected injected rendition mirrors back as the EXTERNAL id it was
                // declared under, not as a second identity in the legible id range.
                let selectedName = await RemoteHLSMediaSelection.playlistName(of: selected)
                    ?? selected.displayName
                self.activeSubtitleTrackIndex = self.injectedSubtitleRenditionNames
                    .first { $0.value == selectedName }?.key
                    ?? RemoteHLSMediaSelection.subtitleTrackIDBase + ordinal
                self.isSubtitleActive = true
                EngineLog.emit(
                    "[AetherEngine] AE#154: mirrored auto-selected legible option ordinal=\(ordinal)",
                    category: .engine)
            }
        }
    }

    /// #316: activate a sidecar the proxy declared in the served master. The track keeps the external id
    /// the host registered it under, but the selection is an `AVMediaSelection` one, so AVPlayer renders
    /// it and it survives leaving the view hierarchy.
    ///
    /// Matched by NAME: the rewriter guarantees uniqueness within the group (it disambiguates against the
    /// origin's own names), and `AVMediaSelectionOption.displayName` is the rendition's NAME attribute.
    /// A miss leaves the previous selection alone and says so rather than silently reporting success.
    func selectInjectedSubtitleRendition(id: Int, name: String) {
        guard let item = currentAVPlayer?.currentItem else { return }
        cancelSidecarTask()
        clearSubtitleDrainTarget(channel: .primary)
        activeEmbeddedSubtitleStreamIndex = -1
        // AVPlayer owns the drawing here; leaving overlay cues behind would double up.
        subtitleCues = []
        loadedSidecarURL = nil
        isSubtitleActive = true
        activeSubtitleTrackIndex = id
        isLoadingSubtitles = false
        Task { @MainActor in
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            var match: AVMediaSelectionOption?
            var seen: [String] = []
            for option in group.options {
                let playlistName = await RemoteHLSMediaSelection.playlistName(of: option)
                seen.append(playlistName ?? option.displayName)
                if match == nil, playlistName == name || option.displayName == name { match = option }
            }
            guard let option = match else {
                EngineLog.emit(
                    "[AetherEngine] #316: injected rendition \"\(name)\" is not in the item's legible "
                    + "group (\(seen.joined(separator: ", ")))",
                    category: .engine)
                return
            }
            item.select(option, in: group)
            EngineLog.emit("[AetherEngine] #316: selected injected rendition \"\(name)\" for external id=\(id)",
                           category: .engine)
        }
    }

    /// Select a remote-HLS legible option by synthetic track id (AE#154). AVPlayer renders the cues
    /// itself on this bypass; there is no overlay pipeline, so activation only drives
    /// AVMediaSelection (criteria pinned manual so the explicit choice sticks, #15).
    func selectRemoteHLSSubtitleTrack(id: Int) {
        guard let ordinal = RemoteHLSMediaSelection.ordinal(forTrackID: id),
              let item = currentAVPlayer?.currentItem else { return }
        cancelSidecarTask()
        subtitleCues = []
        isSubtitleActive = true
        activeSubtitleTrackIndex = id
        isLoadingSubtitles = false
        Task { @MainActor in
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  ordinal < group.options.count else { return }
            item.select(group.options[ordinal], in: group)
            EngineLog.emit(
                "[AetherEngine] AE#154: remote-HLS legible select ordinal=\(ordinal) (\(group.options[ordinal].displayName))",
                category: .engine)
        }
    }
}
