import Foundation
import AetherLibavcodec

/// AE#460: a session-preserving reload that changes a `LoadOption`.
///
/// Every in-place rebuild a host could ask for was tied to a selection (an audio-track switch, a
/// subtitle-track switch, a disc-title switch) or replayed the session's own options verbatim
/// (`reloadAtCurrentPosition()`). An option a host needed to CORRECT mid-session could therefore
/// only be changed by a fresh `load()`, and a fresh load is not the same rebuild: `load` cannot
/// reach `subtitleSessionCarryover` or `isLiveRejoin`, both settable only from inside the engine,
/// so the id-exact external-subtitle registry, mid-session `addExternalSubtitleTrack`
/// registrations, the host's explicit subtitle authority (subtitles explicitly OFF included) and
/// the live rejoin contract are all wiped and re-derived by auto-selection. The correction bought
/// the viewer a visible restart and lost session state on the way.
///
/// This is that same reload with the options it replays taken from the host. Three rules make it
/// safe to hand a host the whole struct:
///
/// 1. **A field that NAMES the session is not correctable.** `isLive`, `audioOnly`,
///    `nativeRemoteHLS` and `sequentialOrigin` decide which pipeline the source is opened on, and
///    the engine writes the last two itself (the #154 / #168 remote-HLS reroute, the probe's
///    no-video fallback). Changing one is a different item, not a correction of this one.
/// 2. **A refusal costs nothing.** Both the identity check and the reloadability check run before
///    any teardown, so a refused correction leaves the session exactly as it was, playing.
/// 3. **The engine states what it took.** A reload that silently applied three quarters of a
///    correction would be worse than one that refused it, so the changed fields are named in the
///    log, the refused ones in the thrown error, and all of them in the returned
///    `SessionOptionCorrectionOutcome`. The third answer, a field the session owns, is neither
///    refused nor applied, so for a while it existed only in the log; a host had to parse a
///    diagnostic to learn what its own call had done (AE#464 round 4).
extension AetherEngine {

    /// Rebuild the session at the current playhead with one or more `LoadOptions` changed (#460).
    ///
    /// The closure is handed the options the session is CURRENTLY running on, which is not always
    /// what the host passed to `load`: the engine rewrites its own routing fields on a reroute.
    /// Change what needs correcting and leave the rest alone.
    ///
    /// ```swift
    /// try await engine.reloadAtCurrentPosition { $0.httpHeaders["Authorization"] = "Bearer \(fresh)" }
    /// ```
    ///
    /// Same contract as `reloadAtCurrentPosition()`: same teardown, same native-host preservation
    /// where the load allows it, same subtitle carryover and live rejoin, and the audio pick rides
    /// the load's own override. The changed options are installed into the session before the
    /// rebuild, so the internal reopens that follow (audio switch, background reload) replay the
    /// correction rather than reverting to the load-time value.
    ///
    /// Unlike `reloadAtCurrentPosition()`, which returns silently when there is nothing to rebuild,
    /// this one throws `AetherEngineError.sessionNotReloadable`: a host correcting a session needs
    /// to tell "corrected" from "did nothing" to decide whether to fall through to a fresh load.
    ///
    /// A correction whose every changed field is the session's own (`autoplay`) is answered without
    /// a rebuild: there is nothing for one to carry, and the teardown it used to spend was a visible
    /// restart bought for a field the rebuild decides for itself. The session is left exactly as it
    /// was, which is where a rebuild would have left it too.
    ///
    /// - Returns: what the correction did, as the same partition the log names. `applied` empty with
    ///   `sessionOwned` filled is the third answer, and `rebuilt` is false exactly there.
    /// - Throws: `AetherEngineError.loadIdentityNotCorrectable` when the closure changed a field
    ///   that names the session, `AetherEngineError.sessionNotReloadable` when this session cannot
    ///   be rebuilt in place, or whatever the underlying load throws. The first two leave the
    ///   session untouched.
    @discardableResult
    public func reloadAtCurrentPosition(
        applying change: (inout LoadOptions) -> Void
    ) async throws -> SessionOptionCorrectionOutcome {
        // AE#560: a reload re-opens the source, which can come back with different codecs or a
        // different program, so the recording ends as a source reset rather than as a session end.
        // stopInternal's own call further down is then a no-op.
        endRecordingIfRunning(reason: .sourceReset)
        var proposed = loadedOptions
        change(&proposed)

        let refused = SessionOptionCorrection.refusedFields(from: loadedOptions, to: proposed)
        guard refused.isEmpty else {
            EngineLog.emit(
                "[AetherEngine] #460: correction refused, load identity is not correctable: "
                + refused.joined(separator: ", "),
                category: .engine
            )
            throw AetherEngineError.loadIdentityNotCorrectable(fields: refused)
        }

        if let refusal = sessionReloadRefusal {
            EngineLog.emit(
                "[AetherEngine] #460: correction refused, session cannot be rebuilt in place: \(refusal.rawValue)",
                category: .engine
            )
            throw AetherEngineError.sessionNotReloadable(refusal)
        }

        // AE#461: the decode-path escape is the one correction that can move the session to a host
        // that cannot serve this source. `load` catches both such sources, but only after the
        // routing decision, which on a correction is after the teardown; decide it here instead so
        // a refused correction still costs nothing (rule 2 above).
        if let refusal = SessionOptionCorrection.decodePathRefusal(
            routedSoftware: playbackBackend == .software,
            preferred: proposed.preferredDecodePath,
            codecID: lastDetectedVideoCodec,
            // AE#532: what the source is, not what its record claimed. A Profile 5 record the RPU
            // corrected is representable in software, so a flip to it is not refused.
            dvProfile: DolbyVisionRecordAudit.correctedProfile(
                record: sourceDVProfile, rpu: sourceDolbyVisionRPUProfile) ?? sourceDVProfile,
            dvBLCompatID: sourceDVBLCompatID,
            // The proposal's handling against the loaded source's base layer: a correction that turns
            // the base layer on and moves to software in one step is honoured, one that keeps the
            // Dolby Vision on a Profile 5 record is refused as before.
            presentsDolbyVisionBaseLayer: proposed.dolbyVisionHandling == .baseLayerOnly
                && sourceDolbyVisionBaseLayerPresentable,
            isLive: loadedOptions.isLive,
            hasCompanionAudioReader: (customReader as? LiveIngestSourceInfo)?.companionAudioReader != nil
        ) {
            EngineLog.emit(
                "[AetherEngine] #461: decode-path correction refused, the software path cannot serve "
                + "this session: \(refusal.rawValue)",
                category: .engine
            )
            throw AetherEngineError.sessionNotReloadable(refusal)
        }

        // Stating the no-op matters for the same reason #364's teletext switch states it: a host
        // that corrected an option and saw a plain reload cannot otherwise tell "the correction was
        // already in force" from "the correction did not arrive".
        let changed = SessionOptionCorrection.changedFields(from: loadedOptions, to: proposed)
        // Round 3: a field the rebuild decides for itself is not a field this reload applies, and
        // naming it in the applied line was the last way left for a correction to read as done when
        // it was not. The transport is the session's own unless a background teardown left it none
        // to read, which is the condition `reloadAtCurrentPosition` makes the same call on.
        let (applied, sessionOwned) = SessionOptionCorrection.partitionChanges(
            changed, sessionOwnsTransport: backgroundTeardownSelection == nil)
        if !applied.isEmpty || sessionOwned.isEmpty {
            EngineLog.emit(
                applied.isEmpty
                    ? "[AetherEngine] #460: reload applying no option change (session already on these options)"
                    : "[AetherEngine] #460: reload applying \(applied.joined(separator: ", "))",
                category: .engine
            )
        }
        if !sessionOwned.isEmpty {
            EngineLog.emit(
                "[AetherEngine] #460: \(sessionOwned.joined(separator: ", ")) not applied, the session "
                + "owns it: the rebuild comes back in the transport state the session is in, not the one "
                + "a mount was given (AE#464 round 2). Call play() / pause() to change it",
                category: .engine
            )
        }

        // Round 4: a correction the session decides for itself does not cost a teardown. Rule 2 says
        // a refusal costs nothing, and this third answer sat outside that rule: it paid a full
        // visible rebuild (measured by the reporter at 202 ms and a second native host) to arrive
        // where the session already was.
        //
        // Nothing is installed here on purpose, and that is the same answer the rebuild gives: the
        // reload writes the session's own transport over the mount flag before it replays the
        // options (`setLoadedAutoplay(sessionRebuildResumesPlaying)`), so a correction to `autoplay`
        // has never outlived the call. Writing the host's value on this path alone would make the
        // same field mean one thing when it travels by itself and another when a header rides along.
        // The one rebuild that DOES read the mount flag is the resume after a background teardown
        // (#357), and there the field is `applied` rather than session-owned, so it never arrives
        // here. `changed.isEmpty` is NOT this case and keeps rebuilding: a correction that changed
        // nothing is a documented way to ask for the rebuild itself.
        if applied.isEmpty, !sessionOwned.isEmpty {
            EngineLog.emit(
                "[AetherEngine] #460: correction complete without a rebuild, every field it changed "
                + "is the session's own (AE#464 round 4)",
                category: .engine
            )
            return SessionOptionCorrectionOutcome(
                applied: applied, sessionOwned: sessionOwned, rebuilt: false)
        }

        // Install BEFORE the rebuild, not through it: the URL branch carries these options into
        // `load`, but the custom-source branch reaches `reloadWithAudioOverride`, which reads
        // `loadedOptions` field by field at reload time and never takes a struct. One write covers
        // both, and the didSet's route recompute cannot move (`nativeRemoteHLS` is refused above).
        applySessionOptionCorrection(proposed)
        try await reloadAtCurrentPosition()
        return SessionOptionCorrectionOutcome(
            applied: applied, sessionOwned: sessionOwned, rebuilt: true)
    }

    /// Why `reloadAtCurrentPosition` would rebuild nothing for this session, or nil when it can
    /// rebuild it (#460).
    ///
    /// `reloadAtCurrentPosition()` returns silently in both of these cases. Read this to tell that
    /// silence apart from a rebuild that ran, without having to time one out.
    public var sessionReloadRefusal: SessionReloadRefusal? {
        guard loadedURL != nil else { return .noActiveSession }
        if isCustomSource, !customSourceIsSeekable { return .customSourceNotSeekable }
        return nil
    }
}

/// What a session-preserving correction did (#460, AE#464 round 4).
///
/// A correction has three answers, not two. Refused throws, applied rebuilds, and a field the
/// SESSION owns is neither: `reloadAtCurrentPosition(applying:)` neither refuses it nor carries it,
/// so the call returned normally and a host had no way to tell that answer from a correction that
/// landed. It read `Void` and reported its own optimism. This is that partition, handed back in the
/// same words the log uses, so a wrapper can say what happened instead of parsing a diagnostic.
public struct SessionOptionCorrectionOutcome: Sendable, Equatable {

    /// The fields the correction changed and the rebuild carried, in `LoadOptions` order. Empty
    /// alongside an empty `sessionOwned` means the session was already on these options, which is
    /// still a rebuild.
    public let applied: [String]

    /// The fields the correction named that the session decides for itself, today `autoplay`. They
    /// are not installed: the rebuild writes the session's own transport over the mount flag anyway,
    /// so this answer means the session kept its value, and `play()` / `pause()` is what moves the
    /// transport.
    public let sessionOwned: [String]

    /// Whether the session was torn down and rebuilt at the playhead. False only when every changed
    /// field was the session's own, where the rebuild would have carried nothing.
    public let rebuilt: Bool

    public init(applied: [String], sessionOwned: [String], rebuilt: Bool) {
        self.applied = applied
        self.sessionOwned = sessionOwned
        self.rebuilt = rebuilt
    }
}

/// Why a session cannot be rebuilt in place (#460).
public enum SessionReloadRefusal: String, Sendable, Equatable, CustomStringConvertible {
    /// No session: nothing has been loaded, or `stop()` cleared the source.
    case noActiveSession
    /// A custom `IOReader` source that reported itself non-seekable. The rebuild reopens the
    /// retained reader at the current position, which a forward-only origin cannot serve.
    case customSourceNotSeekable
    /// AE#461: the correction would move the session onto the software path, and this source's only
    /// signal is IPT-PQ-c2 (HEVC Profile 5, AV1 Profile 10.0), which has no compatible base layer.
    /// The software decoders hand that signal on as YCbCr, so the picture would render green/purple.
    /// Reached only from `reloadAtCurrentPosition(applying:)`, and only when the proposal moves a
    /// native session across; a session already on the software path is not moved by it.
    case softwarePathCannotRepresentSource
    /// AE#461: the correction would move a demuxed-audio live session onto the software path. The
    /// side-audio merge lives in the native path's segment producer, so the session would play
    /// silent. Same reachability as `softwarePathCannotRepresentSource`.
    case demuxedAudioLiveIsNativeOnly

    public var description: String {
        switch self {
        case .noActiveSession: return "no active session"
        case .customSourceNotSeekable: return "the custom source is not seekable"
        case .softwarePathCannotRepresentSource:
            return "the software path cannot represent this source's Dolby Vision signal"
        case .demuxedAudioLiveIsNativeOnly:
            return "this live source's audio is delivered separately and merged on the native path only"
        }
    }
}

/// The rules that decide which `LoadOptions` a running session can be corrected on (#460).
///
/// Split out of the engine so both halves are testable without one: the identity list is the
/// correctness-critical half and is compared field by field rather than by reflection, and
/// `LoadOptionsFieldInventoryTests` fails when a field is added to the struct without someone
/// deciding which half it belongs in.
enum SessionOptionCorrection {

    /// The fields that NAME the session rather than tune it. Each opens the source on a different
    /// pipeline, and the engine writes the last two itself, so a host write races its determination.
    static let loadIdentityFields: [String] = [
        "isLive",
        "audioOnly",
        "nativeRemoteHLS",
        "sequentialOrigin",
        "heldSourceConnection",
    ]

    /// The fields a running SESSION owns, which a correction may name and the rebuild then decides
    /// for itself. Neither refused nor applied, which is the one shape a log line could not say.
    ///
    /// `autoplay` describes the first MOUNT, and a rebuild is not a mount: it comes back in the
    /// transport state the session is in (AE#464 round 2), so a correction that sets it was
    /// accepted, named inside `#460: reload applying ...` and then overwritten. The reporter read
    /// that off the code and asked for a doc word; the docs already said it, and the log did not,
    /// which is the half that a host actually reads while its correction is happening.
    static let sessionOwnedFields: [String] = ["autoplay"]

    /// Split what the correction changed into what the reload applies and what the session decides.
    ///
    /// The transport is the session's own only where the rebuild has one to read. A resume after a
    /// background teardown (#357) has none, so there the mount flag still decides and the field is
    /// applied like any other, which is the same condition `reloadAtCurrentPosition` replays on.
    static func partitionChanges(
        _ changed: [String], sessionOwnsTransport: Bool
    ) -> (applied: [String], sessionOwned: [String]) {
        guard sessionOwnsTransport else { return (changed, []) }
        return (changed.filter { !sessionOwnedFields.contains($0) },
                changed.filter { sessionOwnedFields.contains($0) })
    }

    /// Identity fields the proposal changed, in `loadIdentityFields` order. Empty means the
    /// correction is honourable. Typed comparison on purpose: this decides whether a session is
    /// torn down, so it does not ride on reflection.
    static func refusedFields(from current: LoadOptions, to proposed: LoadOptions) -> [String] {
        var refused: [String] = []
        if proposed.isLive != current.isLive { refused.append("isLive") }
        if proposed.audioOnly != current.audioOnly { refused.append("audioOnly") }
        if proposed.nativeRemoteHLS != current.nativeRemoteHLS { refused.append("nativeRemoteHLS") }
        if proposed.sequentialOrigin != current.sequentialOrigin { refused.append("sequentialOrigin") }
        // #377: the transport is chosen when the source is opened, so a correction here would be
        // accepted and then not happen until something else reopened the source.
        if proposed.heldSourceConnection != current.heldSourceConnection {
            refused.append("heldSourceConnection")
        }
        return refused
    }

    /// AE#461: why a decode-path correction cannot be honoured for this session, or nil when it can.
    ///
    /// The escape moves a session onto `SoftwarePlaybackHost`, and two sources cannot be served
    /// there. `load` fails both of them, but it fails them AFTER the routing decision, which on a
    /// correction means after `stopInternal` has already taken the session down. #460's second rule
    /// is that a refusal costs nothing, so the same two facts are decided here, before any teardown,
    /// off state the session already carries (its codec and Dolby Vision configuration from the
    /// load-time probe, its live flag, its reader's companion audio reader).
    ///
    /// Only a FLIP is refusable. A session already on the software path is not moved by a software
    /// preference, so it is not asked to represent anything new, and an `.automatic` preference
    /// moves nothing at all: refusing on the source facts alone would start throwing on every
    /// ordinary audio-track switch of a Dolby Vision source.
    static func decodePathRefusal(
        routedSoftware: Bool,
        preferred: DecodePath,
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBLCompatID: Int?,
        presentsDolbyVisionBaseLayer: Bool = false,
        isLive: Bool,
        hasCompanionAudioReader: Bool
    ) -> SessionReloadRefusal? {
        let flipsToSoftware = !routedSoftware
            && VideoRoutingPolicy.usesSoftwarePath(routedSoftware: routedSoftware, preferred: preferred)
        guard flipsToSoftware else { return nil }

        if VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: codecID, dvProfile: dvProfile, dvBlCompatID: dvBLCompatID,
            presentsDolbyVisionBaseLayer: presentsDolbyVisionBaseLayer) {
            return .softwarePathCannotRepresentSource
        }
        // The companion reader exists only for a video-only live variant (the resolver spins one up
        // for exactly that shape), so this is the demuxed-audio population rather than a superset of
        // it. `load`'s own guard re-checks that the main container carries no audio; erring towards
        // the refusal here is the safe direction, because the session it leaves alone is playing.
        if isLive, hasCompanionAudioReader {
            return .demuxedAudioLiveIsNativeOnly
        }
        return nil
    }

    /// Every field the proposal changed, for the log line. Reflection is right here and wrong
    /// above: a diagnostic that names a new field the day it is added is worth more than one that
    /// cannot be wrong, and being wrong here costs a log line.
    static func changedFields(from current: LoadOptions, to proposed: LoadOptions) -> [String] {
        guard current != proposed else { return [] }
        var changed: [String] = []
        for (lhs, rhs) in zip(Mirror(reflecting: current).children,
                              Mirror(reflecting: proposed).children) {
            guard let label = lhs.label else { continue }
            if describe(lhs.value) != describe(rhs.value) { changed.append(label) }
        }
        return changed
    }

    /// `String(describing:)` on a Dictionary is order-unstable, so two equal `httpHeaders` can
    /// describe differently and report a change nobody made. Sort those; everything else in
    /// `LoadOptions` describes deterministically.
    private static func describe(_ value: Any) -> String {
        if let headers = value as? [String: String] {
            return headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        }
        return String(describing: value)
    }

    /// Every field `LoadOptions` carries, pinned so that adding one is a decision rather than an
    /// omission. A new field is correctable by default (it falls through `refusedFields`), which is
    /// right for a tuning lever and wrong for an identity one, so the choice has to be made
    /// deliberately. Update this list and, if the field names the session, `loadIdentityFields`.
    static let knownFields: [String] = [
        "omitCriteriaColorExtensions", "suppressDisplayCriteria", "httpHeaders",
        "keepDvh1TagWithoutDV", "forceDolbyVisionOnNonDVDisplay", "dolbyVisionHandling", "matchContentEnabled",
        "panelIsInHDRMode", "attemptsHDRMasterOnUnprovenPanel", "panelPresentsDolbyVision",
        "audioBridgeMode", "isLive", "audioOnly",
        "dvrWindowSeconds",
        "liveBlockingReload", "liveJoinProfile", "liveJoinStartsImmediately",
        "clampsLiveResumeToWindow", "nativeRemoteHLS", "nativeRemoteHLSIngestFallback",
        "preserveASSMarkup", "prepareNativeSubtitles", "eagerNativeSubtitleReaders", "confirmAtmos",
        "nativeSubtitlePreferredLanguages", "sequentialOrigin", "maxConcurrentSourceRequests", "heldSourceConnection",
        "declaredDurationSeconds", "probesize", "maxAnalyzeDuration", "preferredAudioLanguages",
        "preferredSubtitleLanguages", "externalSubtitles", "forwardBufferSegments", "autoplay",
        "audioDelaySeconds", "teletextPage", "deinterlaceMode", "deinterlaceFieldRate", "preferredDecodePath",
        "isLiveRejoin", "subtitleSessionCarryover",
    ]
}
