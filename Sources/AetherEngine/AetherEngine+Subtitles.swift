import Foundation
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

/// Which subtitle output path a reader / apply / cancel call targets.
/// `.primary` maps to the original single-track storage and behavior;
/// `.secondary` maps to the independent companion track (issue #47).
public enum SubtitleChannel: Sendable {
    case primary
    case secondary
}

/// Result of acquiring a side demuxer for a subtitle reader: the open container plus whether it was reused
/// from the retained slot (#76 part 2) or freshly created. Crosses the MainActor boundary out of the acquire.
private struct SideDemuxerAcquisition: Sendable {
    let demuxer: Demuxer
    let reused: Bool
}

extension AetherEngine {

    // MARK: - Channel routing

    func subtitleSideDemuxer(for channel: SubtitleChannel) -> Demuxer? {
        switch channel {
        case .primary:   return activeSubtitleSideDemuxer
        case .secondary: return secondarySubtitleSideDemuxer
        }
    }

    func setSubtitleSideDemuxer(_ demuxer: Demuxer?, for channel: SubtitleChannel) {
        switch channel {
        case .primary:   activeSubtitleSideDemuxer = demuxer
        case .secondary: secondarySubtitleSideDemuxer = demuxer
        }
    }

    func subtitleSideDemuxerKey(for channel: SubtitleChannel) -> String? {
        switch channel {
        case .primary:   return activeSubtitleSideDemuxerKey
        case .secondary: return secondarySubtitleSideDemuxerKey
        }
    }

    func setSubtitleSideDemuxerKey(_ key: String?, for channel: SubtitleChannel) {
        switch channel {
        case .primary:   activeSubtitleSideDemuxerKey = key
        case .secondary: secondarySubtitleSideDemuxerKey = key
        }
    }

    /// The reuse identity for a side demuxer: same source URL + disc title means the open container can be
    /// reused across subtitle track switches and seeks (#76 part 2).
    func subtitleSideDemuxerReuseKey(url: URL, titleID: Int?) -> String {
        "\(url.absoluteString)#\(titleID ?? -1)"
    }

    func setLoadingSubtitles(_ value: Bool, for channel: SubtitleChannel) {
        switch channel {
        case .primary:   isLoadingSubtitles = value
        case .secondary: isLoadingSecondarySubtitles = value
        }
    }

    func isSubtitleActive(for channel: SubtitleChannel) -> Bool {
        switch channel {
        case .primary:   return isSubtitleActive
        case .secondary: return isSecondarySubtitleActive
        }
    }

    /// Activate an embedded subtitle stream via a side Demuxer. Side demuxer is used because the main HLS pump races ~60-80 s ahead mid-playback and discards the subtitle packets; seeking the side demuxer to the playhead is cheaper than re-reading the main pump. Re-seeks on `engine.seek`. Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text) and bitmap codecs (PGS / DVB / DVD / XSUB).
    public func selectSubtitleTrack(index: Int) {
        selectSubtitleTrack(index: index, startAt: sourceTime)
    }

    /// `selectSubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the live
    /// `sourceTime`; the preferred-subtitle-language auto-select at load passes the resume position so the side
    /// demuxer seeks to the playhead instead of burst-reading from byte 0 on a resumed mid-file load (#73).
    func selectSubtitleTrack(index: Int, startAt: Double) {
        guard let url = loadedURL else { return }

        // #77: in-band CEA-608/708 is fed by the always-on producer CC tap (set up at load), not a side
        // demuxer. Selecting it just makes it the active track and mirrors the tap's cue snapshot. Tear down
        // any running embedded reader first (no reuse: CC won't touch the side demuxer, so don't pin a remote
        // connection open while it plays).
        if let codec = subtitleTracks.first(where: { $0.id == index })?.codec,
           Self.isEmbeddedClosedCaptionCodec(codec) {
            cancelSidecarTask()
            cancelEmbeddedSubtitleReader()
            isSubtitleActive = true
            activeEmbeddedSubtitleStreamIndex = Int32(index)
            activeSubtitleTrackIndex = index
            isLoadingSubtitles = false
            subtitleCues = ccCueSnapshot
            return
        }

        // Sodalite#32 Phase 2: text track covered by the producer's pump tap: the overlay is fed from
        // the tap (backfill the already-harvested produced region now, live events forwarded by
        // onSubtitleTapEvent). No side demuxer, so enabling subtitles over a remote source is instant.
        subtitleTapOverlayStreamIndex = nil
        if !isLive, let session = nativeVideoSession, session.subtitleTapCoversStream(Int32(index)) {
            cancelSidecarTask()
            cancelEmbeddedSubtitleReader()
            isSubtitleActive = true
            activeEmbeddedSubtitleStreamIndex = Int32(index)
            activeSubtitleTrackIndex = index
            subtitleTapOverlayStreamIndex = Int32(index)
            subtitleCues = tapOverlayBackfill(streamIndex: Int32(index))
            isLoadingSubtitles = false
            EngineLog.emit(
                "[AetherEngine] overlay fed by pump tap for stream=\(index) "
                + "(backfilled \(subtitleCues.count) cues)",
                category: .engine
            )
            return
        }

        // Custom sources: side demuxer needs an independent cursor; no-op if reader cannot clone.
        var customClone: IOReader? = nil
        if isCustomSource {
            guard let clone = customReader?.makeIndependentReader() else { return }
            customClone = clone
        }
        cancelSidecarTask()

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true
        activeEmbeddedSubtitleStreamIndex = Int32(index)
        activeSubtitleTrackIndex = index

        // The prior embedded reader (if any) is cancelled and fully drained inside startEmbeddedSubtitleTask,
        // which then reuses the already-open side demuxer for this switch instead of re-opening it (#76 part 2).
        // Native mov_text rendition (#55, all-tracks) is fed by the dedicated multi-decode reader at load; this inline path only drives subtitleCues for the host overlay.
        // startAt is the unified source-PTS playhead; pre-fold AVPlayer clock would land playlistShiftSeconds early ("subs 3-5 s late" repro on Cars with ~3.92 s shift).
        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: startAt)
    }

    /// Apply `LoadOptions.preferredSubtitleLanguages` at the end of a successful load: activate the best-ranked
    /// subtitle track whose language matches a preference (scanned in order; see `selectSubtitleIndex`), else
    /// leave subtitles off (the default). Uses the host-overlay path (equivalent to a `selectSubtitleTrack`
    /// call); `startAnchor` is the
    /// load's resume position so a mid-file resume seeks the side demuxer to the playhead instead of byte 0.
    /// A no-op when the list is empty, no track matches, or the host already activated a subtitle. The resolved
    /// index is published via `activeSubtitleTrackIndex`. Independent of `prepareNativeSubtitles`. (#73)
    func applyPreferredSubtitleSelection(startAnchor: Double?, sourceDuration: Double?) {
        guard !loadedOptions.preferredSubtitleLanguages.isEmpty, !isSubtitleActive else { return }
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

    /// Activate an embedded subtitle stream as the secondary companion track (issue #47). Text-only; bitmap codecs are rejected. Runs a second side demuxer concurrently.
    public func selectSecondarySubtitleTrack(index: Int) {
        guard let url = loadedURL else { return }
        var customClone: IOReader? = nil
        if isCustomSource {
            guard let clone = customReader?.makeIndependentReader() else { return }
            customClone = clone
        }
        cancelSidecarTask(channel: .secondary)

        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        isLoadingSecondarySubtitles = true
        activeSecondaryEmbeddedSubtitleStreamIndex = Int32(index)

        // Prior secondary reader is cancelled + drained inside startEmbeddedSubtitleTask, then its side demuxer
        // is reused for this switch (#76 part 2).
        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: sourceTime, channel: .secondary)
    }

    /// Spawn the side-demuxer Task; cancellable at `cancel()`. Captures URL, stream index, start position, source video dims.
    func startEmbeddedSubtitleTask(url: URL, reader: IOReader?, formatHint: String?, streamIndex: Int32, startAt: Double, channel: SubtitleChannel = .primary) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let headers = loadedOptions.httpHeaders
        // Secondary never drives libass; raw ASS event lines would leak into the overlay (issue #47).
        let preserveASS = (channel == .primary) ? loadedOptions.preserveASSMarkup : false
        // #76: bound the open probe + open the title the user is watching. Captured on MainActor here
        // (loadedOptions / activeDiscTitleID are MainActor-isolated, the reader is nonisolated).
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        let titleID = activeDiscTitleID
        // Reuse only for URL sources: a custom source's cloned reader is single-cursor, so its side demuxer
        // can't be shared across switches (#76 part 2). nil key disables reuse for the custom path.
        let reuseKey = reader == nil ? subtitleSideDemuxerReuseKey(url: url, titleID: titleID) : nil
        // Handoff: drain the predecessor before this reader touches the (possibly reused) side demuxer.
        // The side demuxer serializes reads internally, but the old loop seeking / reading after the new one
        // re-seeks would mis-order cues, so we wait for it to exit rather than markClosed it (markClosed is
        // irreversible and would kill a demuxer we want to reuse) (#76 part 2).
        let prior: Task<Void, Never>? = (channel == .primary) ? embeddedSubtitleTask : secondaryEmbeddedSubtitleTask
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            prior?.cancel()
            await prior?.value
            if Task.isCancelled { reader?.close(); return }
            await self?.runEmbeddedSubtitleReader(
                url: url, reader: reader, formatHint: formatHint,
                headers: headers, streamIndex: streamIndex, startAt: startAt,
                videoWidth: w, videoHeight: h, preserveASSMarkup: preserveASS,
                callerProbesize: probesize, callerMaxAnalyzeDuration: maxAnalyzeDuration,
                selectTitleID: titleID, channel: channel, reuseKey: reuseKey
            )
        }
        switch channel {
        case .primary:   embeddedSubtitleTask = task
        case .secondary: secondaryEmbeddedSubtitleTask = task
        }
    }

    /// Side-demuxer read loop: opens a fresh Demuxer, prewarms MKV cue index by seeking mid-file, seeks to just before the start time, then streams packets through EmbeddedSubtitleDecoder. Paces against the playhead via `embeddedSubtitleReadAheadSeconds` instead of racing to EOF.
    nonisolated private func runEmbeddedSubtitleReader(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String], streamIndex: Int32, startAt: Double,
        videoWidth: Int32, videoHeight: Int32, preserveASSMarkup: Bool = false,
        callerProbesize: Int64? = nil, callerMaxAnalyzeDuration: Int64? = nil,
        selectTitleID: Int? = nil,
        channel: SubtitleChannel = .primary,
        reuseKey: String? = nil
    ) async {
        // #76: cap find_stream_info so a remote disc's sparse PGS tracks don't drag the open to the
        // full 50 MB budget (the reader would be superseded before it reads a packet).
        let openProfile = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration)

        // Acquire the side demuxer. For a URL source (reuseKey set, clone reader nil) reuse the demuxer retained
        // for this exact source+title, so a track switch / seek skips the network open + find_stream_info
        // entirely (#76 part 2). For a custom source (single-cursor clone) always open fresh and let the exit
        // handler close it (original behavior). Runs on MainActor: the slot/key are MainActor state and the
        // predecessor reader has already drained (handoff), so nothing else is touching the demuxer.
        let acquired: SideDemuxerAcquisition? = await MainActor.run { [weak self] () -> SideDemuxerAcquisition? in
            guard !Task.isCancelled, let self else { return nil }
            if reader == nil, let reuseKey,
               let retained = self.subtitleSideDemuxer(for: channel),
               self.subtitleSideDemuxerKey(for: channel) == reuseKey {
                return SideDemuxerAcquisition(demuxer: retained, reused: true)
            }
            // A demuxer retained for a different source/title (or a half-open one) is stale; the predecessor
            // has drained, so tear it down before replacing it. markClosed makes any AVIO-blocked read return.
            if let stale = self.subtitleSideDemuxer(for: channel) {
                stale.markClosed()
                stale.close()
            }
            let fresh = Demuxer()
            self.setSubtitleSideDemuxer(fresh, for: channel)
            self.setSubtitleSideDemuxerKey(nil, for: channel)  // set after a successful open
            return SideDemuxerAcquisition(demuxer: fresh, reused: false)
        }
        guard let acquired else {
            reader?.close()
            return
        }
        let demuxer = acquired.demuxer
        let reused = acquired.reused

        // Exit handler: keep the open demuxer for a superseding switch / seek to reuse (cancelled AND still the
        // slot's demuxer AND a reusable URL source). Otherwise (EOF / decoder error, or a teardown that cleared
        // the slot) close it and the backing clone. Runs after the read loop has fully exited, so the unlocked
        // demuxer.stream(at:) in the loop never races a close.
        defer {
            let cancelled = Task.isCancelled
            Task { @MainActor [weak self, weak demuxer] in
                guard let demuxer else { reader?.close(); return }  // already released; Demuxer.deinit closed it
                let stillSlot = self?.subtitleSideDemuxer(for: channel) === demuxer
                if cancelled, stillSlot, reuseKey != nil {
                    return
                }
                if let self, stillSlot {
                    self.setSubtitleSideDemuxer(nil, for: channel)
                    self.setSubtitleSideDemuxerKey(nil, for: channel)
                }
                demuxer.close()
                reader?.close()
            }
        }

        // Superseded during the handoff: release the just-acquired demuxer via the exit handler without paying
        // for the open / seek.
        if Task.isCancelled { return }

        if !reused {
            // markClosed makes AVIO-blocked reads return promptly (Task.cancel() only fires between readPacket calls). Without it a stalled side demuxer survives track switches and keeps reconnecting into the next session.
            do {
                if let reader = reader {
                    try demuxer.open(reader: reader, formatHint: formatHint, profile: openProfile, selectTitleID: selectTitleID, discCacheKey: url.absoluteString)
                } else {
                    try demuxer.open(url: url, extraHeaders: headers, profile: openProfile, selectTitleID: selectTitleID)
                }
            } catch {
                EngineLog.emit("[AetherEngine] embedded subtitle open failed: \(error)", category: .engine)
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled else { return }  // Stale-task guard: cancelled track-switch must not clear successor's spinner.
                    self?.setLoadingSubtitles(false, for: channel)
                }
                return  // exit handler tears down the half-open demuxer + clears the slot
            }
            // Streams are populated; mark the demuxer reusable for the next same-source switch / seek.
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.subtitleSideDemuxer(for: channel) === demuxer {
                    self.setSubtitleSideDemuxerKey(reuseKey, for: channel)
                }
            }

            // MKV cue index lives at EOF; without this prewarm the playhead seek lands inaccurately (same technique HLSVideoEngine uses).
            // Skip it for disc sources (#76): a concat MPEG-TS / VOB has no EOF cue index, so the seek buys nothing and a cold mid-disc range read is expensive on a remote ISO.
            let duration = demuxer.duration
            if duration > 0, !demuxer.isDiscSource {
                demuxer.seek(to: duration * 0.5)
            }
        }

        // Re-sample the live playhead after the slow open + prewarm: startAt was captured pre-open, and unpaused playback may have advanced several seconds, causing the first cues to arrive behind the playhead (tens-of-seconds delay in issue #52). `max` only seeks forward to catch up, never behind the anchor.
        let freshPlayhead = await MainActor.run { [weak self] in self?.sourceTime }
        let effectiveStart = max(startAt, freshPlayhead ?? startAt)

        // -2 s lead-in: PGS/DVB/HDMV need their SETUP segments before the first END/EVENT (#52). On reuse this
        // re-seeks the already-open container to the new playhead, which is the whole point (no re-open).
        let seekTo = max(0, effectiveStart - 2.0)
        demuxer.seek(to: seekTo)

        // #87: a fresh open skips find_stream_info (codec_id comes from the container header / PMT). For the rare
        // container that does not declare the subtitle codec there, run a bounded find_stream_info before decoding.
        if !reused, demuxer.streamCodecUnresolved(at: streamIndex) {
            demuxer.resolveStreamInfo()
        }

        guard let stream = demuxer.stream(at: streamIndex),
              let decoder = EmbeddedSubtitleDecoder(
                  stream: stream,
                  sourceVideoWidth: videoWidth,
                  sourceVideoHeight: videoHeight,
                  preserveASSMarkup: preserveASSMarkup
              )
        else {
            EngineLog.emit("[AetherEngine] embedded subtitle decoder open failed for stream=\(streamIndex)", category: .engine)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }  // Stale-task guard.
                self?.setLoadingSubtitles(false, for: channel)
            }
            return
        }

        // Safety net behind host track filter: bitmap codecs cannot stack as companion lines (issue #47).
        if channel == .secondary, EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) {
            EngineLog.emit("[AetherEngine] secondary subtitle rejected: bitmap codec=\(decoder.codecID.rawValue) not supported as companion track", category: .engine)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }  // Stale-task guard.
                self?.setLoadingSubtitles(false, for: .secondary)
                self?.isSecondarySubtitleActive = false
            }
            return
        }

        let tb = stream.pointee.time_base
        let streamStartTime = stream.pointee.start_time

        // Offset diagnostics: correlate cue.startTime (source PTS) with AVPlayer.currentTime (HLS playlist). Non-zero videoStream.start_time or format.start_time is the source-time to playlist-time offset.
        let formatStart = demuxer.formatStartTime
        let videoStream = demuxer.videoStreamIndex >= 0 ? demuxer.stream(at: demuxer.videoStreamIndex) : nil
        let videoStreamStart = videoStream?.pointee.start_time ?? 0
        let videoTb = videoStream?.pointee.time_base ?? AVRational(num: 1, den: 1)
        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader started: stream=\(streamIndex) " +
            "startAt=\(String(format: "%.2f", startAt))s " +
            "effectiveStart=\(String(format: "%.2f", effectiveStart))s " +
            "seekTo=\(String(format: "%.2f", seekTo))s " +
            "codec=\(decoder.codecID.rawValue) " +
            "subTb=\(tb.num)/\(tb.den) subStart=\(streamStartTime) " +
            "videoTb=\(videoTb.num)/\(videoTb.den) videoStart=\(videoStreamStart) " +
            "format.start_time=\(formatStart)us",
            category: .engine
        )

        await MainActor.run { [weak self] in
            guard !Task.isCancelled else { return }
            self?.setLoadingSubtitles(false, for: channel)
        }

        var totalPacketsRead = 0
        var subtitlePacketsRead = 0
        var cuesEmitted = 0
        var firstCueLogged = false

        // Pacing (AetherEngine#31): park once `embeddedSubtitleReadAheadSeconds` past the playhead. Track ALL streams (subtitle stream alone is too sparse). Seed from effectiveStart (not stale startAt) or the first packet trips the gate immediately and logs a spurious park (#52).
        var playheadSnapshot = effectiveStart
        var parkLogged = false
        var timeBaseCache: [Int32: AVRational] = [:]

        // Batching (#56): one-per-hop publishing collapses demux throughput on dense ASS tracks (hops serialize against the MainActor ASS renderer). Flush in one hop per `embeddedSubtitleFlushWindowSeconds` of source time or count cap.
        var pendingEvents: [EmbeddedSubtitleDecoder.SubtitleEvent] = []
        var batchStartSeconds: Double?
        func flushPendingSubtitleEvents() async {
            guard !pendingEvents.isEmpty else { return }
            let batch = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            batchStartSeconds = nil
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                for ev in batch { self?.applySubtitleEvent(ev, channel: channel) }
            }
        }

        readLoop: while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else {
                break
            }
            totalPacketsRead += 1
            let streamIdx = pkt.pointee.stream_index

            // NOPTS-valued packets don't advance the pacing clock.
            let rawTS = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            var pktSeconds: Double?
            if rawTS != Int64.min {
                let ptb: AVRational
                if let cached = timeBaseCache[streamIdx] {
                    ptb = cached
                } else {
                    ptb = demuxer.stream(at: streamIdx)?.pointee.time_base
                        ?? AVRational(num: 0, den: 1)
                    timeBaseCache[streamIdx] = ptb
                }
                if ptb.num > 0, ptb.den > 0 {
                    pktSeconds = Double(rawTS) * Double(ptb.num) / Double(ptb.den)
                }
            }

            if streamIdx == streamIndex {
                subtitlePacketsRead += 1
                let pktPTS = pkt.pointee.pts
                let event = decoder.decode(
                    packet: pkt,
                    streamTimeBase: tb
                )
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                if let event {
                    cuesEmitted += event.cues.count
                    if !firstCueLogged, let firstCue = event.cues.first {
                        EngineLog.emit(
                            "[AetherEngine] subtitle first cue: pktPTS=\(pktPTS) → " +
                            "startTime=\(String(format: "%.3f", firstCue.startTime))s " +
                            "endTime=\(String(format: "%.3f", firstCue.endTime))s",
                            category: .engine
                        )
                        firstCueLogged = true
                    }
                    if pendingEvents.isEmpty { batchStartSeconds = pktSeconds }
                    pendingEvents.append(event)
                }
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }

            // Span measured off the demux clock (all streams), so same-region ASS clusters still flush as the reader advances.
            let batchSpan: Double? = batchStartSeconds.flatMap { start in pktSeconds.map { $0 - start } }
            if Self.shouldFlushSubtitleBatch(pendingCount: pendingEvents.count, batchSpanSeconds: batchSpan) {
                await flushPendingSubtitleEvents()
            }

            // Park until playhead catches up. Flush the batch first so decoded cues don't sit unpublished for the park interval.
            if let pktSeconds, pktSeconds > playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
                await flushPendingSubtitleEvents()
                while !Task.isCancelled {
                    guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime }) else {
                        break readLoop
                    }
                    playheadSnapshot = fresh
                    if pktSeconds <= playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
                        break
                    }
                    if !parkLogged {
                        parkLogged = true
                        EngineLog.emit(
                            "[AetherEngine] embedded subtitle reader parked: " +
                            "demuxPos=\(String(format: "%.1f", pktSeconds))s " +
                            "playhead=\(String(format: "%.1f", playheadSnapshot))s " +
                            "lead=\(Int(Self.embeddedSubtitleReadAheadSeconds))s",
                            category: .engine
                        )
                    }
                    do {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    } catch {
                        break readLoop
                    }
                }
            }
        }

        // Flush trailing batch (EOF or non-cancel break). Cancelled hops self-guard and drop.
        await flushPendingSubtitleEvents()

        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader exited (cancelled=\(Task.isCancelled)) " +
            "packetsRead=\(totalPacketsRead) subtitlePackets=\(subtitlePacketsRead) " +
            "cuesEmitted=\(cuesEmitted)",
            category: .engine
        )
    }

    /// Apply a decoded event: PGS clear-event trim + sorted insert so the overlay lookup stays correct after backward scrubs.
    @MainActor
    /// Sodalite#32 Phase 2: snapshot the tap store backing `streamIndex` for the overlay backfill.
    func tapOverlayBackfill(streamIndex: Int32) -> [SubtitleCue] {
        guard let session = nativeVideoSession,
              let ord = nativeSubtitleTrackTable.firstIndex(where: { $0.sourceStreamIndex == Int(streamIndex) }),
              ord < session.nativeSubtitleCueStoresForSession.count else { return [] }
        return session.nativeSubtitleCueStoresForSession[ord].snapshotCues()
    }

    /// Sodalite#32 Phase 2: forward the ACTIVE tap-overlay track's decoded events into the host overlay
    /// (subtitleCues), replacing the side reader's publish path. Called at load, before start().
    func armSubtitleTapOverlayForwarding(on session: HLSVideoEngine) {
        session.onSubtitleTapEvent = { [weak self] streamIndex, event in
            Task { @MainActor [weak self] in
                guard let self, self.subtitleTapOverlayStreamIndex == streamIndex else { return }
                self.applySubtitleEvent(event, channel: .primary)
            }
        }
    }

    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, channel: SubtitleChannel) {
        guard isSubtitleActive(for: channel) else { return }

        // Per-session diagnostics: primary-only, capped at 20 to keep the in-app log readable.
        if channel == .primary, subtitleCueDiagnosticCount < 20, let firstCue = event.cues.first {
            subtitleCueDiagnosticCount += 1
            EngineLog.emit(
                "[applySubtitleEvent #\(subtitleCueDiagnosticCount)] " +
                "cueStart=\(String(format: "%.3f", firstCue.startTime))s " +
                "cueEnd=\(String(format: "%.3f", firstCue.endTime))s " +
                "engine.currentTime=\(String(format: "%.3f", currentTime))s",
                category: .engine
            )
        }

        switch channel {
        case .primary:
            applyEventMutations(event, to: &subtitleCues, channel: .primary)
        case .secondary:
            applyEventMutations(event, to: &secondarySubtitleCues, channel: .secondary)
        }
    }

    /// PGS clear-event trim + sorted insert + prune. Native mov_text stores (#55) are NOT fed here; those are owned by the multi-decode reader.
    @MainActor
    private func applyEventMutations(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, to cues: inout [SubtitleCue], channel: SubtitleChannel = .primary) {
        if let trimAt = event.pgsTrimAt {
            for i in 0..<cues.count {
                guard case .image = cues[i].body else { continue }
                let cue = cues[i]
                if cue.startTime < trimAt && cue.endTime > trimAt {
                    cues[i] = SubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: trimAt,
                        body: cue.body
                    )
                }
            }
        }
        for cue in event.cues {
            var lo = 0, hi = cues.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cues[mid].startTime < cue.startTime { lo = mid + 1 } else { hi = mid }
            }
            cues.insert(cue, at: lo)
        }
        pruneOldSubtitleCues(&cues)
    }

    /// Prune cues whose `endTime` is older than the retention window. Uses `sourceTime` because cue.startTime/endTime are absolute source PTS seconds (see EmbeddedSubtitleDecoder.decode).
    @MainActor
    private func pruneOldSubtitleCues(_ cues: inout [SubtitleCue]) {
        guard !cues.isEmpty else { return }
        let cutoff = sourceTime - subtitleCueRetentionSeconds
        guard cutoff > 0 else { return }
        cues.removeAll { $0.endTime < cutoff }
    }

    /// Teardown a subtitle reader: cancel the task + markClosed the demuxer + clear the reuse slot. markClosed
    /// is required because Task.cancel() is only observed between reads; an AVIO-parked demuxer would otherwise
    /// survive teardown. Clearing the slot makes the running loop's exit handler close the demuxer (or, if it
    /// already exited and was retained for reuse, ARC + Demuxer.deinit close it). Used only by genuine teardown
    /// sites (clear / sidecar / CC / stop); same-source switch and seek reuse the demuxer via the handoff in
    /// startEmbeddedSubtitleTask instead (#76 part 2).
    func cancelEmbeddedSubtitleReader(channel: SubtitleChannel = .primary) {
        switch channel {
        case .primary:
            embeddedSubtitleTask?.cancel()
            embeddedSubtitleTask = nil
            activeSubtitleSideDemuxer?.markClosed()
            activeSubtitleSideDemuxer = nil
            activeSubtitleSideDemuxerKey = nil
        case .secondary:
            secondaryEmbeddedSubtitleTask?.cancel()
            secondaryEmbeddedSubtitleTask = nil
            secondarySubtitleSideDemuxer?.markClosed()
            secondarySubtitleSideDemuxer = nil
            secondarySubtitleSideDemuxerKey = nil
        }
    }

    /// Fetch and decode a sidecar subtitle file (.srt / .ass / .vtt / .ssa) via `SubtitleDecoder.decodeFile`, replacing `subtitleCues` atomically. `httpHeaders` nil forwards `LoadOptions.httpHeaders` (same auth as the media, #32).
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
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
                    preserveASSMarkup: preserveASS
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
            }
        }
    }

    /// Decode a sidecar as the secondary companion track (issue #47), independent of the primary.
    public func selectSecondarySidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        cancelSidecarTask(channel: .secondary)
        cancelEmbeddedSubtitleReader(channel: .secondary)
        activeSecondaryEmbeddedSubtitleStreamIndex = -1

        loadedSecondarySidecarURL = url
        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        isLoadingSecondarySubtitles = true

        let effectiveHeaders = httpHeaders ?? loadedOptions.httpHeaders
        secondarySidecarTask = Task { [weak self] in
            let result: SidecarDecodeResult
            do {
                // Secondary is plain text only (never drives libass, mirroring embedded secondary #47).
                result = try await SubtitleDecoder.decodeFile(url: url, httpHeaders: effectiveHeaders)
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
        cancelSidecarTask()
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        subtitleTapOverlayStreamIndex = nil
        cancelNativeSubtitleReaders()
        // Sodalite#32 Phase 2: with the pump tap active the stores are the session's cue source of
        // truth (the tap's decoder dedup would never refill a cleared store), so subtitles-off keeps
        // them; only the reader-driven path tears them down.
        if nativeVideoSession?.subtitleTapActive != true {
            nativeVideoSession?.nativeSubtitleCueStoresForSession.forEach { $0.clear() }
            nativeVideoSession?.nativeSubtitleCueStoresForSession = []
            nativeVideoSession?.nativeSubtitleLanguagesForSession = []
            nativeVideoSession?.producer?.subtitleCueStores = []
            nativeVideoSession?.producer?.nativeSubtitleLanguages = []
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
        cancelSidecarTask(channel: .secondary)
        cancelEmbeddedSubtitleReader(channel: .secondary)
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        loadedSecondarySidecarURL = nil
        isSecondarySubtitleActive = false
        secondarySubtitleCues = []
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
            guard ordinal < stores.count, let src = entry.sourceStreamIndex else { continue }
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
        nativeSubtitleReadersTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runNativeSubtitleReaders(
                url: url, reader: reader, formatHint: formatHint, headers: headers,
                pairs: pairs, startAt: startAt, videoWidth: w, videoHeight: h,
                callerProbesize: probesize, callerMaxAnalyzeDuration: maxAnalyzeDuration,
                selectTitleID: titleID, readToEOF: readToEOF
            )
        }
    }

    /// Cancel the multi-decode reader + markClosed its side demuxer (mirrors `cancelEmbeddedSubtitleReader`).
    func cancelNativeSubtitleReaders() {
        nativeSubtitleReadersTask?.cancel()
        nativeSubtitleReadersTask = nil
        nativeSubtitleReadersDemuxer?.markClosed()
        nativeSubtitleReadersDemuxer = nil
        nativeSubtitleReadersRunToEOF = false
    }

    /// Multi-stream side-demuxer pass: one EmbeddedSubtitleDecoder per text stream, writing to NativeSubtitleCueStores (not subtitleCues). Mirrors `runEmbeddedSubtitleReader` (prewarm, re-sample, -2 s lead-in, park). Always plain text: mov_text muxer carries no ASS markup.
    nonisolated private func runNativeSubtitleReaders(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String],
        pairs: [(streamIndex: Int32, store: NativeSubtitleCueStore)],
        startAt: Double, videoWidth: Int32, videoHeight: Int32,
        callerProbesize: Int64? = nil, callerMaxAnalyzeDuration: Int64? = nil,
        selectTitleID: Int? = nil, readToEOF: Bool = false
    ) async {
        let demuxer = Demuxer()
        let openProfile = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration)
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
        let duration = demuxer.duration
        if duration > 0, !demuxer.isDiscSource {
            demuxer.seek(to: duration * 0.5)
        }
        let freshPlayhead = await MainActor.run { [weak self] in self?.sourceTime }
        // Sodalite#32: a whole-program read must start at `startAt` (0) regardless of the playhead; the usual
        // max-with-playhead (so the PiP reader doesn't start behind the playhead) would drop all cues before it.
        let effectiveStart = readToEOF ? startAt : max(startAt, freshPlayhead ?? startAt)
        let seekTo = max(0, effectiveStart - 2.0)
        demuxer.seek(to: seekTo)

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

        EngineLog.emit(
            "[AetherEngine] native subtitle readers started: streams=\(routes.keys.sorted()) " +
            "startAt=\(String(format: "%.2f", startAt))s effectiveStart=\(String(format: "%.2f", effectiveStart))s " +
            "seekTo=\(String(format: "%.2f", seekTo))s",
            category: .engine
        )

        var playheadSnapshot = effectiveStart
        var parkLogged = false
        var timeBaseCache: [Int32: AVRational] = [:]
        var totalCues = 0

        readLoop: while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else { break }
            let streamIdx = pkt.pointee.stream_index

            let rawTS = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            var pktSeconds: Double?
            if rawTS != Int64.min {
                let ptb: AVRational
                if let cached = timeBaseCache[streamIdx] {
                    ptb = cached
                } else {
                    ptb = demuxer.stream(at: streamIdx)?.pointee.time_base ?? AVRational(num: 0, den: 1)
                    timeBaseCache[streamIdx] = ptb
                }
                if ptb.num > 0, ptb.den > 0 {
                    pktSeconds = Double(rawTS) * Double(ptb.num) / Double(ptb.den)
                }
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

    /// Select or deselect the native mov_text track by ordinal (#55). nil deselects all. Matches by `extendedLanguageTag` first (language-rank-aware for same-language duplicates), falls back to positional index. No-op when no legible group or ordinal out of range.
    public func setNativeSubtitleSelected(track ordinal: Int?) {
        // #15: lazy readers — run the side-demuxer only while a native track is selected (PiP), idle otherwise.
        // Sodalite#32: an eager read-to-EOF reader survives deselect (it is building whole-session coverage;
        // cancelling it on PiP exit left the store frozen at ~48s and every later .vtt served empty).
        if ordinal != nil {
            if nativeSubtitleReadersTask == nil, let params = nativeSubtitleReaderParams {
                startNativeSubtitleReaders(url: params.url, stores: params.stores)
            }
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
            // Rank-based selection: a naive .first { hasPrefix(lang) } always returns the first same-language option regardless of requested ordinal. Compute the rank within same-language tracks and pick the matching AVFoundation option.
            var selected: AVMediaSelectionOption?
            if ordinal < tracks.count, let lang = tracks[ordinal].language {
                let rank = NativeSubtitleTrack.sameLanguageRank(of: ordinal, in: tracks)
                let sameLangOptions = group.options.filter {
                    $0.extendedLanguageTag?.hasPrefix(lang) == true
                }
                if rank < sameLangOptions.count {
                    selected = sameLangOptions[rank]
                }
            }
            if selected == nil, ordinal < group.options.count {
                selected = group.options[ordinal]
            }
            guard let option = selected else { return }
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
                EngineLog.emit("[PiPDiag] pre-fill done: readMax=\(String(format: "%.1f", store.readMaxCueEnd())) target=\(String(format: "%.1f", target)) cues=\(store.cueCount)", category: .engine)
            }
            // #15: AVKit attaches the legible renderer to whatever selection is active when the rendering
            // pipeline is established; a selection made mid-playback updates state + downloads cues but is not
            // drawn until re-asserted. Deselect, hop one runloop, then reselect to force the renderer to attach
            // (documented workaround; the same effect a PiP round-trip had). Needs the manual-criteria pin above.
            let itemID = String(UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xffff, radix: 16)
            EngineLog.emit("[PiPDiag] select: item=\(itemID) opt=\(option.displayName) groupOpts=\(group.options.count) criteriaAuto=\(currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically ?? true) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
            item.select(nil, in: group)
            try? await Task.sleep(nanoseconds: 100_000_000)
            item.select(option, in: group)
            let after = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
            EngineLog.emit("[PiPDiag] select done: selected=\(after) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
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
                EngineLog.emit("[PiPDiag] select retry #\(retries): selected=\(retried)", category: .engine)
            }
            // Persistence probe: does AVSmartSubtitlesController drop it, or does it stay (renderer-attach issue)?
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let later = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
            EngineLog.emit("[PiPDiag] select +2.5s: selected=\(later) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
        }
    }

    /// #15: select the native mov_text track matching the currently-active subtitle so AVKit renders it inside
    /// the PiP window; nil deselects when PiP ends. Maps the active subtitle's source stream to the native
    /// ordinal. No-op (no PiP subtitle) when the active subtitle has no native text equivalent: a bitmap
    /// (PGS/DVB), CEA-608/708, or a sidecar track (sourceStreamIndex nil).
    public func setNativeSubtitleForPiP(_ active: Bool) {
        guard active, let activeIdx = activeSubtitleTrackIndex,
              let ordinal = nativeSubtitleTrackTable.firstIndex(where: { $0.sourceStreamIndex == activeIdx })
        else {
            setNativeSubtitleSelected(track: nil)
            return
        }
        setNativeSubtitleSelected(track: ordinal)
    }
}
