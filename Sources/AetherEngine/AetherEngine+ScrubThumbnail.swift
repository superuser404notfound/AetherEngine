import Foundation
import CoreGraphics

extension AetherEngine {

    /// The 2026-09-02 Whole Title trace opened 30 software decoders in 20 seconds while
    /// scrubbing three resident 100 MB segments and back. Six keeps that small working set
    /// warm; each extractor maps its segment file (audit SEG-2), so the entries hold clean
    /// file-backed pages rather than heap copies, and the bound remains fixed.
    nonisolated static let scrubThumbnailExtractorLimit = 6
    public func clearResidentPreviewFrames() {
        for entry in scrubThumbnailExtractors {
            Task { await entry.extractor.clearResidentPreviewCache() }
        }
    }

    /// Timestamped production preview. All reads come from existing resident
    /// bytes; a missing target never opens a second connection or seeks playback.
    public func scrubPreviewFrame(atSeconds seconds: Double, refined: Bool, maxWidth: Int = 320,
                                  isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard seconds.isFinite, !Task.isCancelled, !isCancelled() else { return nil }
        let gen = loadGeneration
        guard let session = nativeVideoSession else {
            guard let host = softwareHost else { return nil }
            let result = await host.scrubPreviewFrame(atSessionSeconds: seconds, refined: refined,
                                                     maxWidth: maxWidth, isCancelled: isCancelled)
            return gen == loadGeneration && !Task.isCancelled && !isCancelled() ? result : nil
        }
        guard session.yieldsStills else { return nil }
        // Freeze both axes. VOD segment indices use the plan's keyframe origin;
        // the segment's bytes retain their own epoch normalization after restart.
        let origin = sourcePresentationOrigin
        let live = isLive
        // Live: the same stable session-to-output shift `liveScrubThumbnail` uses (#712), frozen
        // here so the request and its result convert on one axis even if the shift moves meanwhile.
        let liveShift = liveSessionShiftSeconds
        let sourceTarget = PresentationAxis.source(displayTime: seconds, origin: origin)
        let output = live ? seconds - liveShift
            : sourceTarget - session.firstKeyframeSeconds
        let planOrigin = session.firstKeyframeSeconds - origin
        let source = await BlockingWork.detached(priority: .utility) { [session] in
            session.scrubThumbnailSource(atSeconds: output)
        }.value
        guard let source, let carried = source.carriedOffset,
              gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        let extractor: FrameExtractor
        if let index = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = scrubThumbnailExtractors.remove(at: index)
            if hit.extractor.residentIdentity == source.identity {
                scrubThumbnailExtractors.append(hit); extractor = hit.extractor
            } else {
                Task { await hit.extractor.shutdown() }
                guard let reader = source.makeReader() else { return nil }
                extractor = FrameExtractor(residentReader: reader, formatHint: "mp4", identity: source.identity)
                scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            }
        } else {
            guard let reader = source.makeReader() else { return nil }
            extractor = FrameExtractor(residentReader: reader, formatHint: "mp4", identity: source.identity)
            scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            trimScrubThumbnailExtractors()
        }
        guard let frame = await extractor.residentPreview(rawTarget: live ? output : sourceTarget - carried,
                    refined: refined, maxWidth: maxWidth, isCancelled: isCancelled),
              gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        let stillOwned = await BlockingWork.detached(priority: .utility) { [session] in
            guard let current = session.scrubThumbnailSource(atSeconds: output) else { return false }
            return current.identity == source.identity && current.carriedOffset == source.carriedOffset
        }.value
        guard stillOwned, gen == loadGeneration, !Task.isCancelled, !isCancelled() else { return nil }
        guard let actual = live ? Optional(frame.actualSeconds + liveShift)
            : ScrubSegmentTime.displayTime(rawPTS: frame.actualSeconds, carriedOffset: carried, displayOrigin: origin)
        else { return nil }
        let rangeStart = live ? source.startSeconds + liveShift : source.startSeconds + planOrigin
        return ScrubFrame(image: frame.image, actualSeconds: actual, refined: frame.refined,
                         validRange: rangeStart..<(rangeStart + source.durationSeconds))
    }

    /// Cache-backed scrub still for the active native session (live or VOD). Decodes from
    /// already-produced SegmentCache bytes, so it never opens a second connection and works
    /// on single-connection sources (debrid/torrent HTTP links, #106) where the
    /// FrameExtractor's second demuxer is refused. Returns nil when there is no native
    /// session, the segment is not resident (not yet produced far ahead of the playhead, or
    /// evicted past the retention budget), or decode fails; a nil is the correct
    /// "not available yet" and hosts show time-only. `seconds` is session-timeline
    /// (seekableLiveRange axis) for live, playlist/output seconds for VOD.
    public func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        if isLive {
            return await liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: maxWidth)
        }
        return await vodScrubThumbnail(atSeconds: seconds, maxWidth: maxWidth)
    }

    /// VOD arm of `scrubThumbnail`. `!isLive` guards direct callers: `nativeVideoSession` is
    /// non-nil for live too, and `scrubThumbnailSource` no longer self-gates on isLiveSession,
    /// so a VOD decode must not run against a live session (whose seam-shift axis differs).
    /// Hands the extractor exactly one segment (init + the seg containing `seconds`) and seeks
    /// to 0: thumbnail mode returns the first frame after the seek, so 0 lands on that segment's
    /// first keyframe whether its fMP4 tfdt is absolute or zero-based (post-restart). This makes
    /// the decode axis-independent and correct by construction. Per-segment granularity.
    ///
    /// A software session (AE#605) has no segments; it decodes the still out of the packet cache
    /// its seeks already land in, keyframe to target, on the same session axis `seek(to:)` takes.
    public func vodScrubThumbnail(atSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard !isLive else { return nil }
        guard let session = nativeVideoSession else {
            guard let host = softwareHost else { return nil }
            let gen = loadGeneration
            let image = await host.vodScrubStill(atSessionSeconds: seconds, maxWidth: maxWidth)
            return loadGeneration == gen ? image : nil
        }
        guard session.yieldsStills else { return nil }
        let gen = loadGeneration
        let source = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.scrubThumbnailSource(atSeconds: seconds)
        }.value
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices
        // collide with the next source's.
        guard let source, loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = scrubThumbnailExtractors.remove(at: idx)
            scrubThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            guard let reader = source.makeReader() else { return nil }
            extractor = FrameExtractor(reader: reader, formatHint: "mp4")
            scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            trimScrubThumbnailExtractors()
        }
        return await extractor.thumbnail(at: 0, maxWidth: maxWidth)
    }

    /// Enforce the cache-backed still LRU after a miss. Kept internal so the exact six-entry
    /// eviction boundary can be pinned without opening a playback session.
    func trimScrubThumbnailExtractors() {
        while scrubThumbnailExtractors.count > Self.scrubThumbnailExtractorLimit {
            let evicted = scrubThumbnailExtractors.removeFirst()
            Task { await evicted.extractor.shutdown() }
        }
    }

    /// True when the active session can serve cache-backed stills from `scrubThumbnail` with no
    /// second connection: any native session (live or VOD, SegmentCache), a software live session
    /// (DVR packet ring, #544) and a software VOD session reading a remote source (packet cache,
    /// AE#605). False before load and on a software session that plays a local file, which keeps no
    /// cache because re-reading the file is free; `makeFrameExtractor()` serves that case. Hosts on a single-connection source should gate the
    /// scrub-preview affordance on this: true means use `scrubThumbnail`; false means hide
    /// the preview rather than show blank frames from a refused second-connection
    /// FrameExtractor (#106). It reports capability, not per-frame availability: transient
    /// nils from `scrubThumbnail` while a segment is still being produced are expected. False as well
    /// on a Dolby Vision Profile 5 / 10.0 session in a build without the `DolbyVisionStillReshaping`
    /// trait, where no frame can become a correct still.
    public var supportsCacheBackedStills: Bool {
        if let session = nativeVideoSession { return session.yieldsStills }
        guard let softwareHost else { return false }
        return isLive || softwareHost.servesPacketCacheStills
    }
}
