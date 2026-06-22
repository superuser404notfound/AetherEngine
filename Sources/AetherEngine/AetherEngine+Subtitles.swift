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
        guard let url = loadedURL else { return }
        // Custom sources: side demuxer needs an independent cursor; no-op if reader cannot clone.
        var customClone: IOReader? = nil
        if isCustomSource {
            guard let clone = customReader?.makeIndependentReader() else { return }
            customClone = clone
        }
        cancelSidecarTask()
        cancelEmbeddedSubtitleReader()

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true
        activeEmbeddedSubtitleStreamIndex = Int32(index)

        // Native mov_text rendition (#55, all-tracks) is fed by the dedicated multi-decode reader at load; this inline path only drives subtitleCues for the host overlay.
        // sourceTime is the unified source-PTS playhead; pre-fold AVPlayer clock would land playlistShiftSeconds early ("subs 3-5 s late" repro on Cars with ~3.92 s shift).
        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: sourceTime)
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
        cancelEmbeddedSubtitleReader(channel: .secondary)

        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        isLoadingSecondarySubtitles = true
        activeSecondaryEmbeddedSubtitleStreamIndex = Int32(index)

        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: sourceTime, channel: .secondary)
    }

    /// Spawn the side-demuxer Task; cancellable at `cancel()`. Captures URL, stream index, start position, source video dims.
    func startEmbeddedSubtitleTask(url: URL, reader: IOReader?, formatHint: String?, streamIndex: Int32, startAt: Double, channel: SubtitleChannel = .primary) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let headers = loadedOptions.httpHeaders
        // Secondary never drives libass; raw ASS event lines would leak into the overlay (issue #47).
        let preserveASS = (channel == .primary) ? loadedOptions.preserveASSMarkup : false
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            await self?.runEmbeddedSubtitleReader(
                url: url, reader: reader, formatHint: formatHint,
                headers: headers, streamIndex: streamIndex, startAt: startAt,
                videoWidth: w, videoHeight: h, preserveASSMarkup: preserveASS,
                channel: channel
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
        channel: SubtitleChannel = .primary
    ) async {
        let demuxer = Demuxer()
        // markClosed makes AVIO-blocked reads return promptly (Task.cancel() only fires between readPacket calls). Without it a stalled side demuxer survives track switches and keeps reconnecting into the next session.
        // Stale-task guard: if already cancelled (A->B switch where B registered first), overwriting hijacks B's abort handle, leaving B's reader unabortable.
        let registered = await MainActor.run { [weak self] () -> Bool in
            guard !Task.isCancelled, let self else { return false }
            self.setSubtitleSideDemuxer(demuxer, for: channel)
            return true
        }
        guard registered else {
            reader?.close()
            return
        }
        defer {
            Task { @MainActor [weak self, weak demuxer] in
                if let self, let demuxer, self.subtitleSideDemuxer(for: channel) === demuxer {
                    self.setSubtitleSideDemuxer(nil, for: channel)
                }
            }
        }
        do {
            if let reader = reader {
                try demuxer.open(reader: reader, formatHint: formatHint)
            } else {
                try demuxer.open(url: url, extraHeaders: headers)
            }
        } catch {
            EngineLog.emit("[AetherEngine] embedded subtitle open failed: \(error)", category: .engine)
            reader?.close()
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }  // Stale-task guard: cancelled track-switch must not clear successor's spinner.
                self?.setLoadingSubtitles(false, for: channel)
            }
            return
        }
        // Side demuxer owns the clone reader; close after demuxer is torn down.
        defer {
            demuxer.close()
            reader?.close()
        }

        // MKV cue index lives at EOF; without this prewarm the playhead seek lands inaccurately (same technique HLSVideoEngine uses).
        let duration = demuxer.duration
        if duration > 0 {
            demuxer.seek(to: duration * 0.5)
        }

        // Re-sample the live playhead after the slow open + prewarm: startAt was captured pre-open, and unpaused playback may have advanced several seconds, causing the first cues to arrive behind the playhead (tens-of-seconds delay in issue #52). `max` only seeks forward to catch up, never behind the anchor.
        let freshPlayhead = await MainActor.run { [weak self] in self?.sourceTime }
        let effectiveStart = max(startAt, freshPlayhead ?? startAt)

        // -2 s lead-in: PGS/DVB/HDMV need their SETUP segments before the first END/EVENT (#52).
        let seekTo = max(0, effectiveStart - 2.0)
        demuxer.seek(to: seekTo)

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

    /// Cancel task + markClosed the demuxer. markClosed is required because Task.cancel() is only observed between reads; an AVIO-parked demuxer would otherwise survive teardown.
    func cancelEmbeddedSubtitleReader(channel: SubtitleChannel = .primary) {
        switch channel {
        case .primary:
            embeddedSubtitleTask?.cancel()
            embeddedSubtitleTask = nil
            activeSubtitleSideDemuxer?.markClosed()
            activeSubtitleSideDemuxer = nil
        case .secondary:
            secondaryEmbeddedSubtitleTask?.cancel()
            secondaryEmbeddedSubtitleTask = nil
            secondarySubtitleSideDemuxer?.markClosed()
            secondarySubtitleSideDemuxer = nil
        }
    }

    /// Fetch and decode a sidecar subtitle file (.srt / .ass / .vtt / .ssa) via `SubtitleDecoder.decodeFile`, replacing `subtitleCues` atomically. `httpHeaders` nil forwards `LoadOptions.httpHeaders` (same auth as the media, #32).
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1

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
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        cancelNativeSubtitleReaders()
        nativeVideoSession?.nativeSubtitleCueStoresForSession.forEach { $0.clear() }
        nativeVideoSession?.nativeSubtitleCueStoresForSession = []
        nativeVideoSession?.nativeSubtitleLanguagesForSession = []
        nativeVideoSession?.producer?.subtitleCueStores = []
        nativeVideoSession?.producer?.nativeSubtitleLanguages = []
        nativeSubtitleRenditionAvailable = false
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
    func startNativeSubtitleReaders(url: URL, stores: [NativeSubtitleCueStore]) {
        cancelNativeSubtitleReaders()
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
        let startAt = sourceTime
        let reader = customClone
        nativeSubtitleReadersTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runNativeSubtitleReaders(
                url: url, reader: reader, formatHint: formatHint, headers: headers,
                pairs: pairs, startAt: startAt, videoWidth: w, videoHeight: h
            )
        }
    }

    /// Cancel the multi-decode reader + markClosed its side demuxer (mirrors `cancelEmbeddedSubtitleReader`).
    func cancelNativeSubtitleReaders() {
        nativeSubtitleReadersTask?.cancel()
        nativeSubtitleReadersTask = nil
        nativeSubtitleReadersDemuxer?.markClosed()
        nativeSubtitleReadersDemuxer = nil
    }

    /// Multi-stream side-demuxer pass: one EmbeddedSubtitleDecoder per text stream, writing to NativeSubtitleCueStores (not subtitleCues). Mirrors `runEmbeddedSubtitleReader` (prewarm, re-sample, -2 s lead-in, park). Always plain text: mov_text muxer carries no ASS markup.
    nonisolated private func runNativeSubtitleReaders(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String],
        pairs: [(streamIndex: Int32, store: NativeSubtitleCueStore)],
        startAt: Double, videoWidth: Int32, videoHeight: Int32
    ) async {
        let demuxer = Demuxer()
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
                try demuxer.open(reader: reader, formatHint: formatHint)
            } else {
                try demuxer.open(url: url, extraHeaders: headers)
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

        // Prewarm MKV cue index (lives at EOF), same as the inline reader.
        let duration = demuxer.duration
        if duration > 0 {
            demuxer.seek(to: duration * 0.5)
        }
        let freshPlayhead = await MainActor.run { [weak self] in self?.sourceTime }
        let effectiveStart = max(startAt, freshPlayhead ?? startAt)
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

            // Park to keep 90 s read-ahead > 60 s producer buffer, stopping the connection draining at line rate.
            if let pktSeconds, pktSeconds > playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
                while !Task.isCancelled {
                    guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime }) else {
                        break readLoop
                    }
                    playheadSnapshot = fresh
                    if pktSeconds <= playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds { break }
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

        EngineLog.emit(
            "[AetherEngine] native subtitle readers exited (cancelled=\(Task.isCancelled)) totalCues=\(totalCues)",
            category: .engine
        )
    }

    /// Select or deselect the native mov_text track by ordinal (#55). nil deselects all. Matches by `extendedLanguageTag` first (language-rank-aware for same-language duplicates), falls back to positional index. No-op when no legible group or ordinal out of range.
    public func setNativeSubtitleSelected(track ordinal: Int?) {
        guard let item = currentAVPlayer?.currentItem else { return }
        // Capture track list; avoid capturing self to keep MainActor re-entrancy to one hop.
        let tracks = nativeSubtitleTracks
        Task { @MainActor in
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
            item.select(option, in: group)
        }
    }
}
