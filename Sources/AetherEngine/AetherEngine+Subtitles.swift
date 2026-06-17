import Foundation
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

    /// Activate an embedded subtitle stream from the source. A side
    /// Demuxer opens the source independently of the main HLS pump,
    /// seeks to (just before) the current playback position, and
    /// streams subtitle packets through an `EmbeddedSubtitleDecoder`.
    /// Cues land in `subtitleCues` typically within 1-2 seconds of
    /// activation.
    ///
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text)
    /// and bitmap codecs (PGS / DVB / DVD / XSUB) with full canvas-
    /// relative positioning.
    ///
    /// Why a side demuxer instead of routing through the main HLS
    /// pump: when activation happens mid-playback, the main pump has
    /// already raced ~60-80 s ahead of the playhead and discarded
    /// every subtitle packet in that window. Re-reading from the
    /// playhead via a side demuxer is the cheapest way to catch cues
    /// for content the user is about to see. The side demuxer also
    /// re-seeks on `engine.seek` so scrubs surface cues at the new
    /// position immediately.
    public func selectSubtitleTrack(index: Int) {
        guard let url = loadedURL else { return }
        // Embedded-subtitle selection runs a side demuxer concurrently with
        // playback. For custom sources the side demuxer needs an independent
        // second cursor; if the reader cannot clone, no-op. Mint the clone
        // after the loadedURL guard so it is never leaked on an early return.
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

        // Side-demuxer seeks in source PTS. sourceTime is the unified
        // source-PTS playhead (equal to currentTime now that the native
        // clock folds in playlistShiftSeconds), so it hands the demuxer
        // the true source position directly. Reading the pre-fold AVPlayer
        // clock here would land `playlistShiftSeconds` early and the first
        // emitted cue would read as "subs are 3-5 s late" — repro on Cars
        // at a restart-driven shift of ~3.92 s.
        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: sourceTime)
    }

    /// Activate an embedded subtitle stream as the SECONDARY companion
    /// track, independent of the primary selection (issue #47). Text-only:
    /// bitmap codecs are rejected by the reader. A second side demuxer runs
    /// concurrently with the primary one.
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

    /// Spin up the side-demuxer Task that streams cues into the
    /// engine. Captured-on-init: the URL, the stream index, the
    /// start position, and the source video dimensions. The Task's
    /// run loop is cancellable; `cancel()` triggers a clean exit.
    func startEmbeddedSubtitleTask(url: URL, reader: IOReader?, formatHint: String?, streamIndex: Int32, startAt: Double, channel: SubtitleChannel = .primary) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let headers = loadedOptions.httpHeaders
        let preserveASS = loadedOptions.preserveASSMarkup
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

    /// Side-demuxer read loop. Opens a fresh `Demuxer` against the
    /// source URL, prewarms the cue table by seeking mid-file (so the
    /// MKV demuxer's cue index is loaded before the real seek), then
    /// seeks slightly before the requested start time and streams
    /// subtitle packets through an `EmbeddedSubtitleDecoder`, emitting
    /// cues back into the engine on the main actor. The loop paces
    /// itself against the playhead (`embeddedSubtitleReadAheadSeconds`)
    /// instead of racing to EOF; see the constant's doc for why.
    nonisolated private func runEmbeddedSubtitleReader(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String], streamIndex: Int32, startAt: Double,
        videoWidth: Int32, videoHeight: Int32, preserveASSMarkup: Bool = false,
        channel: SubtitleChannel = .primary
    ) async {
        let demuxer = Demuxer()
        // Register for abort: Task.cancel() is only observed BETWEEN
        // readPacket calls, but a side demuxer blocked inside the AVIO
        // reconnect loop against a stalled source survived stop()/track
        // switches and kept its connection reconnecting into the next
        // session, the same orphan class the probe-abort hook fixed for
        // load(). markClosed (from the cancel sites) makes the blocked
        // read return promptly.
        let registered = await MainActor.run { [weak self] () -> Bool in
            // Stale-task guard: if this task was already cancelled (track
            // switch A->B where B's registration landed first), overwriting
            // would hijack B's abort handle. The cancel sites would then
            // markClosed the wrong demuxer and A's identity-guarded defer
            // would nil B's registration, leaving B's reader unabortable.
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
                // Stale-task guard: a cancelled reader (track switch in
                // flight) must not clear the SUCCESSOR's loading spinner.
                guard !Task.isCancelled else { return }
                self?.setLoadingSubtitles(false, for: channel)
            }
            return
        }
        // The side demuxer owns the clone reader (the bridge does not close
        // it); close it after the demuxer is torn down.
        defer {
            demuxer.close()
            reader?.close()
        }

        // Prewarm the cue table by seeking mid-file before the actual
        // playhead seek. MKV cues live at the end of the file; a fresh
        // demuxer doesn't load them until first seek. Without this
        // prewarm, the seek-to-playhead lands inaccurately and we
        // either miss subtitle packets near the playhead or land far
        // away from where we asked. HLSVideoEngine does the same thing
        // for the same reason; we mirror it on the side demuxer.
        let duration = demuxer.duration
        if duration > 0 {
            demuxer.seek(to: duration * 0.5)
        }

        // Now the real seek. Slightly before the playhead so bitmap
        // subtitle codecs (PGS / DVB / HDMV) catch their state-machine
        // SETUP segments before the first END / EVENT segment.
        let seekTo = max(0, startAt - 2.0)
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
                // Stale-task guard: a cancelled reader (track switch in
                // flight) must not clear the SUCCESSOR's loading spinner.
                guard !Task.isCancelled else { return }
                self?.setLoadingSubtitles(false, for: channel)
            }
            return
        }

        // Secondary channel is text-only (issue #47): a bitmap codec
        // (PGS / DVB / DVD / XSUB) cannot stack as a companion line, so
        // refuse it here as the safety net behind the host's track filter.
        if channel == .secondary, EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) {
            EngineLog.emit("[AetherEngine] secondary subtitle rejected: bitmap codec=\(decoder.codecID.rawValue) not supported as companion track", category: .engine)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.setLoadingSubtitles(false, for: .secondary)
                self?.isSecondarySubtitleActive = false
            }
            return
        }

        let tb = stream.pointee.time_base
        let streamStartTime = stream.pointee.start_time

        // Comprehensive offset diagnostics: log every PTS-reference
        // value we have access to so we can correlate cue startTime
        // (source PTS based) with AVPlayer.currentTime (HLS playlist
        // based). If videoStream.start_time or format.start_time is
        // non-zero, that's the offset between source-time and
        // playlist-time.
        let formatStart = demuxer.formatStartTime
        let videoStream = demuxer.videoStreamIndex >= 0 ? demuxer.stream(at: demuxer.videoStreamIndex) : nil
        let videoStreamStart = videoStream?.pointee.start_time ?? 0
        let videoTb = videoStream?.pointee.time_base ?? AVRational(num: 1, den: 1)
        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader started: stream=\(streamIndex) " +
            "startAt=\(String(format: "%.2f", startAt))s seekTo=\(String(format: "%.2f", seekTo))s " +
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

        // Playhead pacing (AetherEngine#31): track demux progress via
        // every packet's timestamp (video/audio packets included; the
        // subtitle stream alone is too sparse to gate on) and park the
        // loop once it runs `embeddedSubtitleReadAheadSeconds` past
        // the playhead. `playheadSnapshot` is refreshed lazily from
        // the MainActor only when the threshold trips, which in steady
        // state is a couple of hops per second at the lead boundary.
        var playheadSnapshot = startAt
        var parkLogged = false
        var timeBaseCache: [Int32: AVRational] = [:]

        readLoop: while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else {
                break
            }
            totalPacketsRead += 1
            let streamIdx = pkt.pointee.stream_index

            // Packet position in source-PTS seconds, from the packet's
            // own stream timebase. NOPTS-valued packets don't advance
            // the pacing clock.
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
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled else { return }
                        self?.applySubtitleEvent(event, channel: channel)
                    }
                }
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }

            // Park until the playhead catches up to within the read-
            // ahead window. Task cancellation (track switch, seek,
            // stop) is observed by Task.sleep, which throws
            // immediately on a cancelled task.
            if let pktSeconds, pktSeconds > playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
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

        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader exited (cancelled=\(Task.isCancelled)) " +
            "packetsRead=\(totalPacketsRead) subtitlePackets=\(subtitlePacketsRead) " +
            "cuesEmitted=\(cuesEmitted)",
            category: .engine
        )
    }

    /// Apply a decoded subtitle event from HLSVideoEngine's embedded
    /// decoder. Handles PGS clear-event semantics (trim previously
    /// displayed bitmap cues so they actually disappear at the right
    /// moment) and inserts new cues sorted by start time so the
    /// overlay's lookup stays correct after backward scrubs.
    @MainActor
    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, channel: SubtitleChannel) {
        guard isSubtitleActive(for: channel) else { return }

        // Per-session diagnostic logging stays primary-only to keep the
        // in-app overlay readable.
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
            applyEventMutations(event, to: &subtitleCues)
        case .secondary:
            applyEventMutations(event, to: &secondarySubtitleCues)
        }
    }

    /// Shared cue-array mutation: PGS clear-event trim, sorted insert, prune.
    /// Operates on whichever channel's cue store the caller passes in.
    @MainActor
    private func applyEventMutations(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, to cues: inout [SubtitleCue]) {
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

    /// Remove subtitle cues whose `endTime` has fallen further behind
    /// the current source-PTS position than the retention window.
    /// Compares against `sourceTime` because cue start / end timestamps
    /// are in absolute source PTS seconds (see EmbeddedSubtitleDecoder.decode
    /// docstring). sourceTime now equals currentTime (the clock is unified
    /// onto source PTS), so either is correct; sourceTime keeps the intent
    /// explicit.
    @MainActor
    private func pruneOldSubtitleCues(_ cues: inout [SubtitleCue]) {
        guard !cues.isEmpty else { return }
        let cutoff = sourceTime - subtitleCueRetentionSeconds
        guard cutoff > 0 else { return }
        cues.removeAll { $0.endTime < cutoff }
    }

    /// Cancel the embedded-subtitle side reader: cancel the task AND
    /// abort its demuxer. The markClosed matters because Task.cancel()
    /// is only observed between reads; a side demuxer parked in a
    /// network read (or the AVIO reconnect loop) would otherwise
    /// survive the teardown (see runEmbeddedSubtitleReader).
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

    /// Decode a sidecar subtitle file (`.srt` / `.ass` / `.vtt` /
    /// `.ssa` served alongside the media). The whole file is fetched
    /// and decoded up-front via `SubtitleDecoder.decodeFile`, then the
    /// resulting cues replace `subtitleCues` atomically.
    /// `isLoadingSubtitles` flips on for the duration so the host can
    /// show a spinner. Subsequent calls cancel any in-flight sidecar
    /// decode.
    ///
    /// `httpHeaders`: extra headers for the subtitle fetch (WebDAV
    /// auth and friends, #32). nil forwards the loaded session's
    /// `LoadOptions.httpHeaders`, so a subtitle served by the same
    /// authenticated host as the media works without repeating the
    /// headers; pass an explicit dictionary (or `[:]`) to override.
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true

        let effectiveHeaders = httpHeaders ?? loadedOptions.httpHeaders
        sidecarTask = Task { [weak self] in
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url, httpHeaders: effectiveHeaders)
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    // Stale-task guard: a superseded sidecar load (A->B
                    // switch) must not clear the SUCCESSOR's loading
                    // spinner. isSubtitleActive alone doesn't cover this:
                    // it is true again for B by the time A's error lands.
                    guard !Task.isCancelled, let self = self else { return }
                    if self.isSubtitleActive {
                        self.isLoadingSubtitles = false
                    }
                }
                return
            }

            await MainActor.run {
                // Stale-task guard, mirroring the embedded path: without
                // it a superseded load A whose decode outlives the A->B
                // switch overwrites B's cues (isSubtitleActive is true
                // again for B, so that check alone can't catch it).
                guard !Task.isCancelled, let self = self else { return }
                guard self.isSubtitleActive else { return }
                // Sidecar cues stay in source PTS; host renders
                // against `engine.sourceTime`, which already adds the
                // active producer's playlist shift to AVPlayer's clock.
                self.subtitleCues = cues
                self.isLoadingSubtitles = false
            }
        }
    }

    /// Decode a sidecar subtitle file as the SECONDARY companion track
    /// (issue #47), independent of the primary selection.
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
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url, httpHeaders: effectiveHeaders)
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
                self.secondarySubtitleCues = cues
                self.isLoadingSecondarySubtitles = false
            }
        }
    }

    /// Turn subtitles off and clear cached cues. Tears down both the
    /// sidecar SRT decode task and the side-demuxer embedded reader.
    public func clearSubtitle() {
        cancelSidecarTask()
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
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
}
