import Foundation

/// Converts between the two time axes a session exposes (AE#105).
///
/// - **Source-PTS axis**: the timestamps the decoder/producer/subtitle readers work in. For a normal file
///   this starts at ~0; for a Blu-ray/DVD title it starts at clip 0's STC base (the TRON multi-clip titles
///   start at 599s / 4199s), because the raw m2ts/VOB clocks are not zero-based.
/// - **Display axis**: the 0-based `[0, duration]` axis the scrubber shows and the host seeks against. A disc
///   title's `duration` is the 0-based MPLS/IFO playlist length, so the published playhead must match it.
///
/// `sourcePresentationOrigin` is the source PTS that maps to display-0 (0 for normal/live, clip 0's base for a
/// disc title). These helpers keep every public playhead/seek conversion in one place so the sign is obvious
/// and unit-testable; `sourceTime` and the internal producer/subtitle axes stay on the source-PTS axis.
enum PresentationAxis {
    /// Published playhead / seek-target on the 0-based display axis, from a source-PTS value.
    /// Inverse of `source(displayTime:origin:)`. Identity when `origin == 0`.
    static func display(sourcePTS: Double, origin: Double) -> Double {
        sourcePTS - origin
    }

    /// Source PTS from a 0-based display value (host seek input, resume position).
    /// Inverse of `display(sourcePTS:origin:)`. Identity when `origin == 0`.
    static func source(displayTime: Double, origin: Double) -> Double {
        displayTime + origin
    }

    /// The origin a container's chapters are rebased onto, per backend, so that a published chapter start
    /// is the value `seek(to:)` and `currentTime` use for it (`mediaChapters`). Live keeps origin 0 on both
    /// routes (`PresentationOriginPolicy`).
    ///
    /// - `.native`: the origin the native session latches for a VOD source, the container start
    ///   (`HLSVideoEngine.sourceStartSeconds`).
    /// - `.software`: the session zero of the software clock. Once the host has anchored its clock that is
    ///   the zero it reports (`softwareClockZero`), which is authoritative. Until then it is predicted the
    ///   way the host derives it: `SWClockAnchorPolicy.resumeSessionZero` of the host's origin, the
    ///   container start backed up by the video stream's own start (`sourceStartOrigin`), which is zero
    ///   within the 2 s tolerance.
    /// - Anything else (`.none`, the audio-only backends) has no established origin here, so the
    ///   chapters stay on the raw container axis, as they were published before this rule.
    static func containerChapterOrigin(backend: PlaybackBackend, formatStartSeconds: Double,
                                       sourceStartOrigin: Double, softwareClockZero: Double? = nil,
                                       isLive: Bool) -> Double {
        if isLive, backend == .native || backend == .software { return 0 }
        switch backend {
        case .native:
            return Swift.max(0, formatStartSeconds)
        case .software:
            return softwareClockZero ?? SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: sourceStartOrigin)
        default:
            return 0
        }
    }

    /// The `seek(to:)` target for a disc chapter. Disc chapters are title-relative (0-based), the chapter's
    /// source PTS is `sourceStartSeconds` (the source start origin) plus its start, and `seek(to:)` takes the
    /// published axis of the active backend.
    ///
    /// - `.software`: the published axis is the session axis, source PTS minus the clock's session zero,
    ///   and the host adds that zero back before the seek reaches the demuxer. A container start past the
    ///   2 s tolerance becomes the session zero (`SWClockAnchorPolicy`), so adding the full
    ///   `sourceStartSeconds` here as well applied the start twice and landed one start late. Only the part
    ///   of the start the zero did not take is added: all of it inside the tolerance (zero 0), none of it
    ///   past it. The host reports its zero through a main-actor hop, so until it arrives the zero is
    ///   predicted the way the host derives it at load (`SWClockAnchorPolicy.resumeSessionZero`), which
    ///   gives 0 for a start inside the tolerance.
    /// - `.native`: the published axis is the 0-based display axis, the same one the disc chapters and the
    ///   title duration are on (AE#105: a disc title's display origin is the playlist shift itself, and
    ///   `seek(to:)` adds it back before it subtracts the shift again). Adding the shift here as well put
    ///   the target a whole clip base past the chapter, beyond the title on a base of 599 s.
    /// - Any other backend keeps the base it was written with, `playlistShiftSeconds`.
    ///
    /// `sourceStartSeconds` must be the origin the host derives its zero from
    /// (`Demuxer.resolvedSourceStartOrigin`), so the zero cancels it on the software route.
    ///
    /// Never negative: the floor only covers a zero that re-anchored past the chapter's source PTS (a
    /// first sample later than the chapter), which would otherwise ask for a position before the title.
    static func discChapterSeekTarget(chapterStart: Double, backend: PlaybackBackend,
                                      sourceStartSeconds: Double, playlistShiftSeconds: Double,
                                      softwareClockZero: Double?) -> Double {
        let base: Double
        switch backend {
        case .software:
            base = sourceStartSeconds - (softwareClockZero
                ?? SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: sourceStartSeconds))
        case .native:
            base = 0
        default:
            base = playlistShiftSeconds
        }
        return Swift.max(0, chapterStart + base)
    }
}

/// Which source PTS maps to display-0 for a session (AE#105, AE#270).
///
/// `duration` is 0-based for every source, so the published playhead has to be too, and the origin is
/// the source PTS that `duration` is measured from. A VOD loopback session takes it from the container
/// (`HLSVideoEngine.sourceStartSeconds`) the moment the session starts; this policy decides what the
/// producer's later shift publications may do to it:
///
/// - A disc title re-reads it from every publish: its raw PTS starts at clip 0's STC base, that same
///   base is what each publish carries, and a title switch inside one session moves it (AE#105).
/// - Any other VOD source keeps what it has. The first publish still seeds it when nothing else did,
///   but later publishes fold producer drift into the shift (1.96 s on the measured run), so following
///   them would drag the display axis around under a picture that has not moved.
/// - Live keeps origin 0: its public axis is the source axis by contract, which is what the live edge
///   and the DVR window are expressed against.
///
/// Without the VOD latch the published clock kept the origin in it: a 60 s-origin transport stream
/// opened its scrubber at 1:02 of a ten-minute item, and at broadcast scale a seek target computed on
/// that axis resolved outside the item and landed at the start of the file (AE#270).
enum PresentationOriginPolicy {

    /// - Parameter latched: origin already latched for this session, nil before the first publish.
    static func origin(
        latched: Double?,
        publishedShift: Double,
        isLive: Bool,
        isDisc: Bool
    ) -> Double {
        if isLive { return 0 }
        if isDisc { return publishedShift }
        return latched ?? publishedShift
    }
}
