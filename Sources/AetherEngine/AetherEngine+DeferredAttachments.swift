import Foundation

/// AE#1129: where a load reads a Matroska source's attached files (the fonts of its ASS subtitles, a
/// cover image). libavformat reads the whole Attachments element inside `avformat_open_input`, so
/// reading them during the session's own open puts every byte of them in front of the first frame:
/// 94 MB of fonts cost 11.2 s over a 68 Mbit/s link. The default reads them on a second reader once
/// the first frame is up instead.
enum AttachmentReadPlan: Equatable, Sendable {
    /// `LoadOptions.skipsContainerAttachments`: never read.
    case skip
    /// Read by the session's own open, before the first frame. The associated text says why.
    case atOpen(reason: String)
    /// The session's open passes over them; `startDeferredAttachmentRead()` fetches them after the
    /// first frame on the attachment side reader.
    case afterFirstFrame

    var readsAtOpen: Bool {
        if case .atOpen = self { return true }
        return false
    }
}

extension AetherEngine {

    /// The plan for one load. A second reader is what the default needs, so every origin or reader
    /// that cannot take one keeps the old read at open: a live source (a second connection can cost a
    /// tuner), `sequentialOrigin` and `heldSourceConnection` (origins that punish a second request), an
    /// origin already limited to one request at a time, and a custom reader without an independent
    /// cursor. `customReaderCanFork` is nil for a URL source.
    nonisolated static func attachmentReadPlan(
        skips: Bool, readsAtOpen: Bool, isLive: Bool, sequentialOrigin: Bool,
        heldSourceConnection: Bool, originSerial: Bool, customReaderCanFork: Bool?
    ) -> AttachmentReadPlan {
        if skips { return .skip }
        if readsAtOpen { return .atOpen(reason: "readsContainerAttachmentsAtOpen") }
        if isLive { return .atOpen(reason: "live source") }
        if sequentialOrigin { return .atOpen(reason: "sequentialOrigin") }
        if heldSourceConnection { return .atOpen(reason: "heldSourceConnection") }
        if originSerial { return .atOpen(reason: "the origin is limited to one request at a time") }
        if customReaderCanFork == false { return .atOpen(reason: "the custom reader has no independent cursor") }
        return .afterFirstFrame
    }

    /// Resolves the plan for the load that is starting. Runs once per load, after `isCustomSource`,
    /// `customReader` and `loadedOptions` are set and before the first open, because forking a custom
    /// reader to find out whether it can be forked has a cost of its own.
    func resolveAttachmentReadPlan(options: LoadOptions, url: URL) -> AttachmentReadPlan {
        let plan = Self.attachmentReadPlan(
            skips: options.skipsContainerAttachments,
            readsAtOpen: options.readsContainerAttachmentsAtOpen,
            isLive: options.isLive,
            sequentialOrigin: options.sequentialOrigin,
            heldSourceConnection: options.heldSourceConnection,
            originSerial: !isCustomSource && OriginRequestBudget.shared.requiresSerialRequests(url),
            customReaderCanFork: options.skipsContainerAttachments || options.readsContainerAttachmentsAtOpen
                || !isCustomSource ? nil : Self.canForkCustomReader(customReader)
        )
        if case .atOpen(let reason) = plan, !options.readsContainerAttachmentsAtOpen {
            EngineLog.emit("[Attachments] read at open: \(reason)", category: .demux)
        }
        return plan
    }

    /// Whether the side read has anything to do once the session is up. Only Matroska carries
    /// attachments that the open passes over; every other container ignores `skip_attachments`.
    nonisolated static func deferredAttachmentReadApplies(
        plan: AttachmentReadPlan, containerFormat: String?
    ) -> Bool {
        guard plan == .afterFirstFrame, let containerFormat else { return false }
        return containerFormat.lowercased().contains("matroska")
    }

    /// Start the side read for the loaded session. Called at the end of `load()` next to
    /// `startAtmosConfirmation()`. It waits until playback has a cushion (`attachmentReadMayStart`) so
    /// its bytes never compete with the startup, and it inherits the session's request headers, so a
    /// token rotated meanwhile (`updateRequestHeaders(_:)`) reaches it too.
    func startDeferredAttachmentRead() {
        cancelDeferredAttachmentRead()
        guard Self.deferredAttachmentReadApplies(plan: attachmentReadPlan, containerFormat: sourceContainerFormat),
              let url = loadedURL else { return }
        let reader: IOReader? = isCustomSource ? customReader?.makeIndependentReader() : nil
        if isCustomSource, reader == nil {
            EngineLog.emit("[Attachments] skipped: the custom reader gave no independent cursor", category: .demux)
            return
        }
        let token = UUID()
        deferredAttachmentToken = token
        let profile = DemuxerOpenProfile.attachmentSideReader
            .withSourceOpenPolicy(loadedOptions.sourceOpenPolicy)
            .withDiagnosticContext(loadedOptions.sourceDiagnosticsContext)
            .withRequestHeaders(sessionRequestHeaders)
        let headers = loadedOptions.httpHeaders
        let formatHint = customFormatHint
        let hasPicture = sessionPublishesVideoDisplaySignal && !loadedOptions.audioOnly
        let budgetURL = isCustomSource ? nil : url
        let testDelay = deferredAttachmentReadDelayNanosForTesting
        deferredAttachmentTask = Task { @MainActor [weak self] in
            await self?.awaitAttachmentReadStart(hasPicture: hasPicture)
            guard let self, !Task.isCancelled, self.deferredAttachmentToken == token else {
                reader?.close()
                return
            }
            // An origin the budget lowered to one request since the load (429 / 503 on the pump)
            // would take this read as one more refusal, or stall the pump behind it.
            if let budgetURL, OriginRequestBudget.shared.requiresSerialRequests(budgetURL) {
                EngineLog.emit("[Attachments] skipped: the origin dropped to one request at a time; "
                    + "fontAttachments stays empty", category: .demux)
                reader?.close()
                return
            }
            let demuxer = Demuxer()
            self.deferredAttachmentDemuxer = demuxer
            if testDelay > 0 { try? await Task.sleep(nanoseconds: testDelay) }
            let started = DispatchTime.now().uptimeNanoseconds
            let result = await BlockingWork.detached(priority: .utility) {
                Self.readAttachments(demuxer: demuxer, url: url, reader: reader, formatHint: formatHint,
                                     headers: headers, profile: profile)
            }.value
            if self.deferredAttachmentDemuxer === demuxer { self.deferredAttachmentDemuxer = nil }
            guard !Task.isCancelled, self.deferredAttachmentToken == token else { return }
            let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            guard let result else {
                EngineLog.emit("[Attachments] side read failed after \(ms) ms; fontAttachments stays empty",
                               category: .demux)
                return
            }
            self.publishDeferredAttachments(fonts: result.fonts, artwork: result.artwork)
            let bytes = result.fonts.reduce(0) { $0 + $1.data.count }
            EngineLog.emit(
                "[Attachments] side read: \(result.fonts.count) font(s), \(bytes) B, "
                    + "cover=\(result.artwork == nil ? "no" : "yes"), \(ms) ms",
                category: .demux)
        }
    }

    /// Teardown with the item. `markClosed()` aborts an open parked in `avformat_open_input`.
    func cancelDeferredAttachmentRead() {
        deferredAttachmentToken = nil
        deferredAttachmentTask?.cancel()
        deferredAttachmentTask = nil
        deferredAttachmentDemuxer?.markClosed()
        deferredAttachmentDemuxer = nil
    }

    /// Whether the side read may start: the first frame is up (on a session that shows one) and
    /// playback holds `deferredAttachmentBufferSeconds` ahead, or everything is buffered already. A bulk
    /// read of tens of megabytes started at the first frame, when the forward buffer is thinnest,
    /// would compete with exactly the segments that keep the picture going.
    nonisolated static func attachmentReadMayStart(
        hasPicture: Bool, firstFrame: Bool, currentTime: Double, bufferedPosition: Double, duration: Double
    ) -> Bool {
        if hasPicture, !firstFrame { return false }
        if bufferedPosition - currentTime >= deferredAttachmentBufferSeconds { return true }
        return duration > 0 && bufferedPosition >= duration - 0.5
    }

    nonisolated static let deferredAttachmentBufferSeconds: Double = 15

    /// Waits for `attachmentReadMayStart` in two bounded steps: up to 30 s for the first frame, then up
    /// to `deferredAttachmentCushionWaitNanos` for the cushion, so a session whose buffer stays shallow
    /// (a link near the stream's bitrate) still gets its fonts. A 100 ms check on the main actor: the
    /// wait normally ends within a few seconds, and a Combine subscription across the task boundary is
    /// not Sendable.
    private func awaitAttachmentReadStart(hasPicture: Bool) async {
        let frameDeadline = DispatchTime.now().uptimeNanoseconds + Self.deferredAttachmentFirstFrameTimeoutNanos
        while hasPicture, !hasFirstFrameReadyForDisplay, !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < frameDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let cushionDeadline = DispatchTime.now().uptimeNanoseconds + deferredAttachmentCushionWaitNanos
        while !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < cushionDeadline,
              !Self.attachmentReadMayStart(hasPicture: hasPicture, firstFrame: hasFirstFrameReadyForDisplay,
                                           currentTime: currentTime, bufferedPosition: bufferedPosition,
                                           duration: duration) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The bound on the first-frame wait. Long enough for any healthy start, short of leaving a session
    /// without its fonts.
    nonisolated static let deferredAttachmentFirstFrameTimeoutNanos: UInt64 = 30_000_000_000

    /// Open, read, close. Nil when the source does not open; a background enrichment never throws.
    nonisolated static func readAttachments(
        demuxer: Demuxer, url: URL, reader: IOReader?, formatHint: String?, headers: [String: String],
        profile: DemuxerOpenProfile = .attachmentSideReader
    ) -> (fonts: [FontAttachment], artwork: Data?)? {
        defer {
            demuxer.close()
            reader?.close()
        }
        do {
            if let reader {
                try demuxer.open(reader: reader, formatHint: formatHint, profile: profile)
            } else {
                try demuxer.open(url: url, extraHeaders: headers, profile: profile)
            }
        } catch {
            return nil
        }
        return (demuxer.fontAttachmentInfos(), demuxer.mediaMetadata().artworkData)
    }
}
