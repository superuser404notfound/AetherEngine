import Foundation

/// #316: serves the sidecar renditions the remote-HLS subtitle proxy injects into the origin master.
///
/// It is an `HLSSegmentProvider` that owns no media at all. Every segment, init and key URI points
/// straight at the origin, so AVPlayer never asks this server for media. It fetches `/master.m3u8`
/// (verbatim, via `staticMasterPlaylistBody`), `/subs_{n}.m3u8` and `/subs_{n}_0.vtt`, and with
/// AE#1122 also the origin's variant at `/origin_variant.m3u8` (`servedVariantPlaylist`), whose answer
/// can wait up to `RemoteHLSResumeWarm.waitSeconds` for the resume segment.
/// The single reported segment exists so `buildSubtitleMediaPlaylistText`'s whole-program shape can read
/// the program duration off the usual `segmentDuration(at:)` path (Sodalite#32) without a special case.
final class RemoteHLSSubtitleProvider: HLSSegmentProvider, @unchecked Sendable {

    /// One declared sidecar, tied back to the engine-side external track id it was registered under.
    struct Track: Sendable {
        let externalID: Int
        let source: ExternalSubtitleTrack
    }

    let tracks: [Track]

    /// Settable because the relay can only rewrite this once the server it is mounted on has a
    /// port and a token, which is after the provider exists. Written once during build, before
    /// the server has answered anything.
    private(set) var staticMasterPlaylistBody: String?

    /// AE#1122: the origin variant the proxy already fetched, served at
    /// `RemoteHLSMasterRewrite.servedVariantURI` so AVPlayer does not fetch it again. Nil when the
    /// master still points at the origin's own copy. Written once during build, like the master.
    private(set) var staticVariantPlaylistBody: String?

    /// Total program seconds, summed from the origin's own variant playlist. TARGETDURATION and the
    /// single EXTINF of every subtitle rendition are built from it.
    private let programDuration: Double
    private let stores: [NativeSubtitleCueStore]
    private let defaultHeaders: [String: String]
    private let mediaURL: URL?
    /// AE#984: the sidecar decodes, one at a time, the picked track first.
    private let fillQueue = ExternalSubtitleFillQueue()

    init(tracks: [Track], masterBody: String, programDuration: Double,
         defaultHeaders: [String: String], mediaURL: URL?) {
        self.tracks = tracks
        self.staticMasterPlaylistBody = masterBody
        // `RemoteHLSSubtitleProxy.sumSegmentDurations` already refuses a non-finite, negative or
        // absurd EXTINF sum before it reaches here; this is the last stop before the value leaves
        // the provider (`segmentDuration(at:)`) for `wholeSecondsCovering`'s `Int(Double)`, which
        // traps on `+inf` (audit NAT-1). Bounded again here so a caller that builds this provider
        // directly, bypassing the proxy, cannot reintroduce the trap.
        let finiteDuration = programDuration.isFinite ? programDuration : 1
        self.programDuration = min(max(1, finiteDuration), RemoteHLSSubtitleProxy.maxProgramDurationSeconds)
        self.defaultHeaders = defaultHeaders
        self.mediaURL = mediaURL
        self.stores = tracks.map { _ in NativeSubtitleCueStore() }
    }

    /// Replaces the served master. Only the relay calls this, to send the origin's variants back
    /// through the engine once the server's address is known.
    func setMasterPlaylistBody(_ body: String) {
        staticMasterPlaylistBody = body
    }

    /// AE#1122: held by the first variant answer on a resume. Written once during build.
    private var resumeWarm: RemoteHLSResumeWarm.Gate?

    func setVariantPlaylistBody(_ body: String) {
        staticVariantPlaylistBody = body
    }

    func setResumeWarm(_ gate: RemoteHLSResumeWarm.Gate) {
        resumeWarm = gate
    }

    /// The served variant, once the resume segment has been asked for with the player's own agent.
    func servedVariantPlaylist(userAgent: String?) -> String? {
        guard let body = staticVariantPlaylistBody else { return nil }
        resumeWarm?.passThrough(userAgent: userAgent)
        return body
    }

    /// The renditions as the rewriter needs to declare them, in `subs_{ordinal}` order.
    static func renditions(for tracks: [Track]) -> [RemoteHLSMasterRewrite.Rendition] {
        tracks.enumerated().map { ordinal, track in
            RemoteHLSMasterRewrite.Rendition(
                ordinal: ordinal,
                name: track.source.makeTrackInfo(id: track.externalID, fallbackNumber: ordinal + 1).name,
                language: track.source.language,
                isForced: track.source.isForced,
                isSDH: track.source.isHearingImpaired)
        }
    }

    /// Decode every sidecar into its store, off the main actor. Same one-pass-per-container machinery
    /// the loopback path uses (#266), so a container holding several subtitle streams is read once and
    /// a single bad stream index cannot blank its siblings.
    ///
    /// AE#984: with `holdingUnpicked` only a picked rendition fills (`prioritizeFill`) until the engine
    /// lifts the hold (`releaseHeldFills`) at `readyToPlay`, so the other extractions do not compete
    /// with the origin's start.
    func startFill(holdingUnpicked: Bool = false) {
        fillQueue.start(
            Self.fillJobs(tracks: tracks, stores: stores, defaultHeaders: defaultHeaders, mediaURL: mediaURL),
            holdingUnpicked: holdingUnpicked)
    }

    func cancelFill() {
        fillQueue.cancel()
        resumeWarm?.cancel()
    }

    /// AE#984: the host picked `ordinal`; its sidecar fills next (see `ExternalSubtitleFillQueue.prioritize`).
    func prioritizeFill(ordinal: Int) {
        guard ordinal >= 0, ordinal < stores.count else { return }
        fillQueue.prioritize(stores[ordinal])
    }

    /// AE#984: the item is ready to play; the renditions nobody picked may fill now.
    func releaseHeldFills() { fillQueue.releaseHeld() }

    /// AE#984: the ordinal of the rendition registered under the host's external track id.
    func ordinal(forExternalID id: Int) -> Int? {
        tracks.firstIndex { $0.externalID == id }
    }

    /// AE#984: whether AVPlayer's last request for this rendition was answered "not yet".
    func renditionWasRefused(ordinal: Int) -> Bool {
        guard ordinal >= 0, ordinal < stores.count else { return false }
        return stores[ordinal].wasRefusedWhilePending
    }

    /// AE#984: what a `.vtt` request for this rendition would get right now.
    func renditionServe(ordinal: Int) -> NativeSubtitleCueStore.WholeProgramServe? {
        guard ordinal >= 0, ordinal < stores.count else { return nil }
        return stores[ordinal].wholeProgramServe
    }

    /// Wait for every fill that can run to finish. Nothing in the session waits for it, the `.vtt`
    /// handler reads the store's state instead; this exists so a test can assert on a finished store
    /// without racing the wall clock. Fills held for a pick are not waited for.
    func awaitFill() async { await fillQueue.awaitIdle() }

    /// AE#616: every sidecar's decode has finished, so `allCueStarts()` is the whole program.
    var isFillFinished: Bool { stores.allSatisfy(\.isFinished) }

    /// AE#616: cue starts and texts across every injected rendition, on the axis the `.vtt` serves.
    func allCueStarts() -> [(start: Double, text: String)] {
        stores.flatMap { $0.allCues().map { (start: $0.start, text: $0.text) } }
    }

    /// One job per (url, headers) pair, in first-appearance order. Mirrors
    /// `AetherEngine.externalSubtitleFillJobs`, which keys off the loopback's rendition table.
    static func fillJobs(tracks: [Track],
                         stores: [NativeSubtitleCueStore],
                         defaultHeaders: [String: String], mediaURL: URL?) -> [AetherEngine.ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
        }
        var order: [Key] = []
        var targetsByKey: [Key: [AetherEngine.ExternalSubtitleFillJob.Target]] = [:]
        var hintByKey: [Key: String] = [:]
        for (ordinal, track) in tracks.enumerated() where ordinal < stores.count {
            let key = Key(url: track.source.url, headers: AetherEngine.resolvedSubtitleHeaders(
                for: track.source.url, explicit: track.source.httpHeaders, mediaURL: mediaURL,
                mediaHeaders: defaultHeaders))
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.source.sourceStreamIndex, store: stores[ordinal]))
            if hintByKey[key] == nil, let hint = track.source.formatHint { hintByKey[key] = hint }
        }
        return order.map {
            AetherEngine.ExternalSubtitleFillJob(url: $0.url, headers: $0.headers,
                                                 targets: targetsByKey[$0] ?? [],
                                                 formatHint: hintByKey[$0])
        }
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }

    /// This provider owns no media, and says so: a `/seg{N}.mp4` that reaches this origin is answered 404
    /// rather than "not yet, retry", because it never will exist. The served master's only variants are
    /// the origin's own.
    var segmentCount: Int { 0 }

    /// The subtitle playlist builder derives the whole-program TARGETDURATION and EXTINF from one visible
    /// segment (Sodalite#32). Reporting it here, instead of through `segmentCount`, keeps the duration
    /// math working without also claiming a media segment exists.
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (visibleCount: 1, firstVisible: 0, refreshCounter: 0, endlistAdded: true, discontinuitySequence: 0)
    }

    func segmentDuration(at index: Int) -> Double { programDuration }
    var playlistType: HLSPlaylistType { .vod }
    var nativeSubtitleWholeProgram: Bool { true }

    /// Empty on purpose: `nativeSubtitleRenditions` only feeds the master BUILDER, and this provider
    /// serves a finished master instead. The EXT-X-MEDIA tags were written by `RemoteHLSMasterRewrite`.
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { [] }

    /// Whole-program WebVTT for one sidecar. Cue times are used verbatim: this bypass has no loopback
    /// producer and therefore no playlist shift, and AVPlayer places the cues by media timestamp, so
    /// the sidecar's own absolute seconds line up with the frames. They do NOT line up with item time
    /// where an origin's segments start before their playlist slot; AE#616 measures that gap off them.
    ///
    /// AE#984: never held. A request held for the fill also held AVPlayer's media loading, so a slow
    /// sidecar froze the picture of a healthy stream. While the fill runs the answer is a 404, which
    /// AVPlayer retries every few seconds while A/V keeps loading; a failed fill is served empty at once.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal >= 0, ordinal < stores.count else { return nil }
        let store = stores[ordinal]
        let serve = store.wholeProgramServe
        if serve == .retryLater {
            // The engine selects a rendition only once its sidecar is in, so a request for a pending one
            // means something else selected it (AVKit's own menu). Its sidecar goes next.
            store.noteRefusedWhilePending()
            EngineLog.emit(
                "[AetherEngine] AE#984: subtitle rendition ord=\(ordinal) requested before its sidecar is "
                + "decoded; answering 404 so AVPlayer asks again, and fetching it next", category: .hlsServer)
            return nil
        }
        let cues = store.allCues()
        store.noteServed()
        if serve != .complete {
            let why = serve == .failedFill ? "could not be read" : "has no decode running"
            EngineLog.emit(
                "[AetherEngine] AE#984: the sidecar for subtitle rendition ord=\(ordinal) \(why); "
                + "serving it as it stands so the A/V session is not held for it", category: .hlsServer)
        } else {
            EngineLog.emit(
                "[AetherEngine] #316: whole-program rendition ord=\(ordinal) cues=\(cues.count)",
                category: .hlsServer, level: .verbose)
        }
        return WebVTTBuilder.body(cues: cues)
    }
}
