import Foundation
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil
import os

/// Which subtitle output path a reader / apply / cancel call targets.
/// `.primary` maps to the original single-track storage and behavior;
/// `.secondary` maps to the independent companion track (issue #47).
public enum SubtitleChannel: Sendable {
    case primary
    case secondary
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
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text) and bitmap codecs (PGS / DVB / DVD / XSUB).
    public func selectSubtitleTrack(index: Int) {
        hostExplicitSubtitleAction = true
        selectSubtitleTrack(index: index, startAt: sourceTime)
    }

    /// `selectSubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the live
    /// `sourceTime`; the preferred-subtitle-language auto-select at load passes the resume position so the side
    /// demuxer seeks to the playhead instead of burst-reading from byte 0 on a resumed mid-file load (#73).
    func selectSubtitleTrack(index: Int, startAt: Double) {
        // #88: external ids route onto the sidecar decode path; no side demuxer, no loadedURL needed.
        if let external = externalSubtitleRegistry[index] {
            selectExternalSubtitleTrack(id: index, track: external)
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
        startSubtitleDrainer()
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
            startSecondarySidecarDecode(url: external.url, httpHeaders: external.httpHeaders)
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
    private func makeSubtitleDrainDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
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
    }

    /// Clear one channel's drain target; stops the loop when no channel remains active.
    func clearSubtitleDrainTarget(channel: SubtitleChannel) {
        subtitleDrainTargets[channel] = nil
        subtitleDrainDecoders[channel] = nil
        subtitleDrainCursors[channel] = nil
        if subtitleDrainTargets.isEmpty { stopSubtitleDrainer() }
    }

    private func subtitleDrainTick() {
        guard !subtitleDrainTargets.isEmpty, let store = activeSubtitlePacketStore else { return }
        let playhead = sourceTime
        for (channel, streamIndex) in subtitleDrainTargets {
            let plan = SubtitleOverlayDrainer.drainPlan(
                cursor: subtitleDrainCursors[channel],
                playhead: playhead,
                lead: Self.subtitleDrainLeadSeconds,
                backscan: Self.subtitleDrainBackscanSeconds,
                jumpThreshold: Self.subtitleDrainJumpThresholdSeconds)
            let window: (from: Double, through: Double)
            switch plan {
            case .idle:
                subtitleDrainCursors[channel]?.lastPlayhead = playhead
                continue
            case .decode(let from, let through):
                window = (from, through)
            case .resetAndDecode(let from, let through):
                subtitleDrainDecoders[channel] = nil
                // Fresh selection or seek: the backscan decodes compositions BEHIND the
                // playhead. Run them through the gate's reconstruction admission so the
                // currently-active line is emitted once at the playhead instead of being
                // held as a stale arrival until the next composition trims it (the old
                // reader's lead-in behavior; without this, enabling subs mid-sentence
                // shows nothing until the next line).
                pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()].reconstructing = true
                window = (from, through)
            }
            if subtitleDrainDecoders[channel] == nil {
                subtitleDrainDecoders[channel] = makeSubtitleDrainDecoder(streamIndex: streamIndex)
            }
            guard let decoder = subtitleDrainDecoders[channel] else { continue }
            let entries = store.entries(streamIndex: streamIndex,
                                        from: window.from, through: window.through)
            // The cursor only advances to an actually-decoded packet's PTS: a window that is
            // empty because the producer has not reached it yet must be rescanned next tick.
            var lastDecoded = subtitleDrainCursors[channel]?.lastDecodedPts
            for entry in entries {
                // A cue-less event still matters: a PGS clear composition carries only
                // pgsTrimAt and is what removes the line during silence.
                if let event = Self.decodeStoredSubtitlePacket(entry, with: decoder),
                   !event.cues.isEmpty || event.pgsTrimAt != nil {
                    applySubtitleEvent(event, channel: channel)
                }
                lastDecoded = entry.ptsSeconds
            }
            if case .resetAndDecode = plan, entries.isEmpty {
                // Fresh window with nothing stored yet: anchor just behind the window start so
                // steady ticks rescan it without re-triggering the discontinuity path.
                lastDecoded = window.from
            }
            subtitleDrainCursors[channel] = SubtitleDrainCursor(
                lastDecodedPts: lastDecoded ?? window.from,
                lastPlayhead: playhead)
        }
        store.prune(before: playhead - SubtitlePacketStore.retentionSeconds)
    }

    /// Rebuild an AVPacket from a stored entry and decode it. PTS/duration ride a 1/1000
    /// time base carrying the harvested seconds; flags are restored for bitmap acquisition
    /// points. Runs on the MainActor tick; subtitle decode is a parse plus, for bitmap, a
    /// bounded blit, the same work the side reader did per packet.
    nonisolated private static func decodeStoredSubtitlePacket(
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
        return decoder.decode(packet: pkt, streamTimeBase: AVRational(num: 1, den: 1000))
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
            // #100: this event is the held stale arrival's successor; its start closes the held
            // cue's true window. Publish it only if that window covers the playhead (it is the
            // genuinely active cue), drop replayed history silently.
            for cue in pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
                .resolveHeld(trimAt: trimAt, playhead: sourceTime) {
                insertSorted(cue, into: &cues)
            }
        }
        // #100: a PGS event whose cues start well behind the playhead is a catch-up replay; its
        // open-ended placeholder window would cover the playhead the instant it inserts and flash
        // stale history through the overlay until the successor trims it. Hold it instead.
        // #112: a self-contained composition (acquisition point / epoch start) during a reconstruction pass is
        // the current line and publishes immediately (see PGSStaleArrivalGate.admit).
        let admitted = pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
            .admit(cues: event.cues, isPGS: event.isPGS,
                   isSelfContained: event.isSelfContainedPGS, playhead: sourceTime)
        for cue in admitted {
            insertSorted(cue, into: &cues)
        }
        pruneOldSubtitleCues(&cues)
    }


    @MainActor
    private func insertSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) {
        Self.insertCueSorted(cue, into: &cues)
    }

    /// #112 full umbau: sorted insert of a decoded cue into the retained store, keeping ascending start order. An
    /// image cue sharing a start with an existing image cue REPLACES it: a PGS composition has a unique start PTS, so
    /// a same-start image cue is the same line re-decoded (the audio-switch preserved placeholder vs its
    /// reconstruction), and a duplicate would render the bitmap twice until the next composition trims it. Text cues
    /// at the same start are distinct simultaneous speakers and are both kept.
    nonisolated static func insertCueSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) {
        if case .image = cue.body,
           let existing = cues.firstIndex(where: { other in
               if case .image = other.body { return other.startTime == cue.startTime }
               return false
           }) {
            cues[existing] = cue
            return
        }
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime < cue.startTime { lo = mid + 1 } else { hi = mid }
        }
        cues.insert(cue, at: lo)
    }

    /// Prune cues whose `endTime` is older than the retention window. Uses `sourceTime` because cue.startTime/endTime are absolute source PTS seconds (see EmbeddedSubtitleDecoder.decode).
    @MainActor
    private func pruneOldSubtitleCues(_ cues: inout [SubtitleCue]) {
        guard !cues.isEmpty else { return }
        let cutoff = sourceTime - subtitleCueRetentionSeconds
        guard cutoff > 0 else { return }
        cues.removeAll { $0.endTime < cutoff }
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
        startSidecarDecode(url: track.url, httpHeaders: track.httpHeaders, externalTrackID: id)
    }

    /// Store lookup for the external backfill: test-hook override first, else the live session's stores.
    private func nativeStore(atOrdinal ordinal: Int) -> NativeSubtitleCueStore? {
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
        var jobs: [(url: URL, headers: [String: String], store: NativeSubtitleCueStore)] = []
        for (ordinal, entry) in nativeSubtitleTrackTable.enumerated() {
            guard let extID = entry.externalID,
                  let track = externalSubtitleRegistry[extID],
                  ordinal < session.nativeSubtitleCueStoresForSession.count else { continue }
            jobs.append((track.url,
                         track.httpHeaders ?? loadedOptions.httpHeaders,
                         session.nativeSubtitleCueStoresForSession[ordinal]))
        }
        guard !jobs.isEmpty else { return }
        externalNativeStoreFillTask = Task.detached(priority: .utility) { [jobs] in
            for job in jobs {
                if Task.isCancelled { return }
                if let result = try? await SubtitleDecoder.decodeFile(url: job.url, httpHeaders: job.headers) {
                    job.store.appendCues(result.cues)
                    job.store.markFinished()
                } else {
                    EngineLog.emit("[AetherEngine] external native store fill failed: \(job.url.lastPathComponent)", category: .engine)
                }
            }
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
    func startSidecarDecode(url: URL, httpHeaders: [String: String]?, externalTrackID: Int?) {
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
        hostExplicitSubtitleAction = true
        cancelSidecarTask(channel: .secondary)
        clearSubtitleDrainTarget(channel: .secondary)   // #112 rework
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        activeSecondaryExternalSubtitleTrackID = nil
        startSecondarySidecarDecode(url: url, httpHeaders: httpHeaders)
    }

    /// Shared secondary sidecar-decode start (#88): the pre-#88 selectSecondarySidecarSubtitle body.
    func startSecondarySidecarDecode(url: URL, httpHeaders: [String: String]?) {
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
        hostExplicitSubtitleAction = true
        cancelSidecarTask()
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
        if !demuxer.seekBounded(to: seekTo, timeout: Self.sideReaderSeekBudgetSeconds) {
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
        // discard. AVDISCARD_ALL drops before AVPacket alloc; seeks stay index-driven, park pacing rides the
        // subtitle PTS (av_read_frame fast-walks the discarded index between cues, no I/O).
        demuxer.discardAllStreamsExcept(Set(routes.keys))

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
    static func nativeSubtitleOrdinal(forActiveTrack id: Int, in table: [NativeSubtitleTrackEntry]) -> Int? {
        table.firstIndex { $0.sourceStreamIndex == id || $0.externalID == id }
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
        guard active, let activeIdx = activeSubtitleTrackIndex,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: activeIdx, in: nativeSubtitleTrackTable)
        else {
            setNativeSubtitleSelected(track: nil)
            return
        }
        setNativeSubtitleSelected(track: ordinal)
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
    /// auto-selected cues flash for up to ~0.5 s at start (iOS device), and relaxes to 250 ms afterwards.
    /// Bails the instant the host requests a native track (`setNativeSubtitleRendering` / PiP, AirPlay, or
    /// external-display entry sets `nativeSubtitleReapplyOrdinal`), which owns selection from then on. A no-op
    /// when native subtitles are not prepared (no legible group, e.g. tvOS overlay-only).
    func forceNativeLegibleDeselectedUntilHostSelects() {
        guard nativeSubtitleReapplyOrdinal == nil, let item = currentAVPlayer?.currentItem else { return }
        currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
        Task { @MainActor [weak self] in
            guard let self,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else { return }
            var attempts = 0
            while attempts < 29,
                  self.nativeSubtitleReapplyOrdinal == nil,
                  self.currentAVPlayer?.currentItem === item {
                if attempts == 0 || item.currentMediaSelection.selectedMediaOption(in: group) != nil {
                    item.select(nil, in: group)
                    EngineLog.emit("[AetherEngine] Sodalite#38 native legible force-deselected (attempt \(attempts))", category: .engine)
                }
                attempts += 1
                try? await Task.sleep(nanoseconds: attempts < 25 ? 40_000_000 : 250_000_000)
            }
        }
    }
}
