import Testing
import Foundation
@testable import AetherEngine

/// #316: the loopback origin that carries host-declared sidecars as legible renditions in front of a
/// remote HLS master. These drive the real server over a real socket, because the contract that matters
/// is what AVPlayer would actually fetch: a verbatim master, a whole-program WebVTT playlist, and
/// nothing else. A media request reaching this server at all would mean the rewrite moved the media.
@Suite("Remote-HLS subtitle proxy origin (#316)")
struct RemoteHLSSubtitleProxyTests {

    private static let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"
    https://jf.test/videos/42/main.m3u8
    """

    private static func track(_ id: Int, url: URL, headers: [String: String]? = nil,
                              streamIndex: Int32? = nil) -> RemoteHLSSubtitleProvider.Track {
        RemoteHLSSubtitleProvider.Track(
            externalID: id,
            source: ExternalSubtitleTrack(url: url, name: "English", language: "en",
                                          httpHeaders: headers, sourceStreamIndex: streamIndex))
    }

    /// Async on purpose: the callback form parked a cooperative thread on a semaphore for the whole
    /// round trip, and every one of these tests runs inside a several-hundred-test parallel run. A
    /// transport error is thrown rather than folded into status 0, so a failure names itself instead
    /// of arriving as "expected 200, got 0".
    private static func get(_ path: String, port: UInt16) async throws -> (status: Int, body: String) {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Fill jobs

    @Test("Sidecars sharing a container are decoded in one pass")
    func fillJobsGroupByContainer() {
        let container = URL(string: "https://origin.test/movie.mkv")!
        let tracks = [Self.track(100_000, url: container, streamIndex: 2),
                      Self.track(100_001, url: container, streamIndex: 3)]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }

        let jobs = RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                      defaultHeaders: [:], mediaURL: nil)
        #expect(jobs.count == 1)
        #expect(jobs[0].targets.map(\.streamIndex) == [2, 3])
    }

    @Test("Differing auth means differing requests, so it splits the jobs")
    func fillJobsSplitOnHeaders() {
        let container = URL(string: "https://origin.test/movie.mkv")!
        let tracks = [Self.track(100_000, url: container, headers: ["X-Token": "a"]),
                      Self.track(100_001, url: container, headers: ["X-Token": "b"])]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }
        #expect(RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                   defaultHeaders: [:], mediaURL: nil).count == 2)
    }

    @Test("A track without its own headers inherits the load's")
    func fillJobsInheritDefaultHeaders() {
        let tracks = [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)]
        let stores = tracks.map { _ in NativeSubtitleCueStore() }
        let jobs = RemoteHLSSubtitleProvider.fillJobs(tracks: tracks, stores: stores,
                                                      defaultHeaders: ["Authorization": "Bearer x"],
                                                      mediaURL: URL(string: "https://origin.test/movie.m3u8"))
        #expect(jobs.first?.headers == ["Authorization": "Bearer x"])
    }

    // MARK: - Served endpoints

    @Test("The rewritten master is served verbatim, not rebuilt from provider metadata")
    func masterIsServedVerbatim() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:], mediaURL: nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (status, body) = try await Self.get("/\(server.pathToken)/master.m3u8", port: server.port)
        #expect(status == 200)
        #expect(body == Self.master)
    }

    @Test("AVPlayer is pointed at the master even though the provider has no master codecs")
    func playlistURLPrefersTheStaticMaster() throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:], mediaURL: nil)
        #expect(provider.masterCodecs == nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        #expect(server.playlistURL?.lastPathComponent == "master.m3u8")
    }

    @Test("The rendition playlist is a finished whole-program VOD playlist")
    func subtitlePlaylistIsWholeProgram() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1234.5, defaultHeaders: [:], mediaURL: nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (status, body) = try await Self.get("/\(server.pathToken)/subs_0.m3u8", port: server.port)
        #expect(status == 200)
        #expect(body.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(body.contains("#EXT-X-TARGETDURATION:1235"))
        #expect(body.contains("#EXTINF:1234.500"))
        #expect(body.contains("subs_0_0.vtt"))
        #expect(body.contains("#EXT-X-ENDLIST"))
    }

    @Test("The proxy origin serves no media: a segment request is a 404, not a redirect to the origin")
    func mediaIsNotServed() async throws {
        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: URL(string: "https://origin.test/en.srt")!)],
            masterBody: Self.master, programDuration: 1200, defaultHeaders: [:], mediaURL: nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        #expect(try await Self.get("/\(server.pathToken)/seg0.mp4", port: server.port).status == 404)
        #expect(try await Self.get("/\(server.pathToken)/init.mp4", port: server.port).status == 404)
    }

    @Test("A decoded sidecar is served as whole-program WebVTT", .timeLimit(.minutes(2)))
    func sidecarBecomesWebVTT() async throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Erste Zeile

        2
        00:00:04,500 --> 00:00:06,000
        Zweite Zeile

        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae316-\(UUID().uuidString).srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let provider = RemoteHLSSubtitleProvider(
            tracks: [Self.track(100_000, url: file)],
            masterBody: Self.master, programDuration: 60, defaultHeaders: [:], mediaURL: nil)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop(); provider.cancelFill() }
        // Await the fill: the handler answers a request that beats it with a 404 (AE#984), and the
        // decode is a detached Task that a saturated cooperative pool can leave without a thread.
        provider.startFill()
        await provider.awaitFill()

        let (status, body) = try await Self.get("/\(server.pathToken)/subs_0_0.vtt", port: server.port)
        #expect(status == 200)
        #expect(body.hasPrefix("WEBVTT"))
        #expect(body.contains("Erste Zeile"))
        #expect(body.contains("Zweite Zeile"))
        // Cue times are used verbatim: no loopback producer means no playlist shift.
        #expect(body.contains("00:00:01.000 --> 00:00:03.000"))
    }

    // MARK: - Rendition metadata

    @Test("Renditions are numbered in subs_{ordinal} order and carry the host's own labels")
    func renditionsMirrorTheDeclaration() {
        let tracks = [
            RemoteHLSSubtitleProvider.Track(
                externalID: 100_000,
                source: ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!,
                                              name: "English", language: "en")),
            RemoteHLSSubtitleProvider.Track(
                externalID: 100_001,
                source: ExternalSubtitleTrack(url: URL(string: "https://o/de.srt")!,
                                              name: "Deutsch SDH", language: "de",
                                              isHearingImpaired: true))
        ]
        let renditions = RemoteHLSSubtitleProvider.renditions(for: tracks)
        #expect(renditions.map(\.ordinal) == [0, 1])
        #expect(renditions.map(\.name) == ["English", "Deutsch SDH"])
        #expect(renditions.map(\.isSDH) == [false, true])
    }

    @Test("A bitmap sidecar is not rendition material")
    func bitmapSidecarIsExcluded() {
        let pgs = ExternalSubtitleTrack(url: URL(string: "https://o/en.sup")!)
        let srt = ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!)
        let hinted = ExternalSubtitleTrack(url: URL(string: "https://o/stream?id=3")!, formatHint: "ass")
        #expect(!pgs.isTextFormat)
        #expect(srt.isTextFormat)
        #expect(hinted.isTextFormat)
    }

    // MARK: - Dedupe against the surfaced legible group

    @MainActor
    @Test("An injected rendition is not published a second time under a legible id")
    func injectedRenditionsAreNotDoubleListed() {
        let declared = [ExternalSubtitleTrack(url: URL(string: "https://o/en.srt")!, name: "English",
                                              language: "en")
            .makeTrackInfo(id: AetherEngine.externalSubtitleTrackIDBase, fallbackNumber: 1)]
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false),
            RemoteHLSMediaSelection.LegibleOption(displayName: "English", extendedLanguageTag: "en",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(
            existing: declared, legible: legible, injectedNames: ["English"])

        #expect(merged.map(\.name) == ["English", "Français"])
        // The surviving rendition keeps its index in the FULL group, which is what selection indexes back.
        #expect(merged.map(\.id) == [AetherEngine.externalSubtitleTrackIDBase,
                                     RemoteHLSMediaSelection.subtitleTrackIDBase + 0])
    }

    /// Measured against Apple's own CMAF master: `displayName` is a LOCALIZED language name, not the
    /// rendition's NAME (an injected `NAME="DE"` reads back as "German", the origin's "简体中文" as
    /// "Chinese"). Keying the dedupe on the display name therefore matched nothing and the sidecar was
    /// published twice, once as its external track and once as a legible one.
    @MainActor
    @Test("Dedupe keys on the playlist NAME, not on AVFoundation's localized display name")
    func dedupeSurvivesTheLocalizedDisplayName() {
        let localized = RemoteHLSMediaSelection.LegibleOption(
            displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false, playlistName: "DE")

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(
            existing: [], legible: [localized], injectedNames: ["DE"])

        #expect(merged.isEmpty)
    }

    // MARK: - NAT-1: a hostile EXTINF never reaches Int(Double)

    private static func seg(_ duration: Double) -> HLSMediaSegment {
        HLSMediaSegment(uri: "s.ts", duration: duration, discontinuityBefore: false)
    }

    @Test("An infinite, negative or absurd EXTINF is refused before it becomes a program duration")
    func rejectsHostileSegmentDurations() {
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(.infinity)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(.nan)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(-1)])
        }
        #expect(throws: RemoteHLSSubtitleProxy.Refusal.self) {
            // Finite, but a sum this large is still out of range (audit NAT-1's "finite but huge" case).
            _ = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(5e18), Self.seg(5e18)])
        }
    }

    @Test("An ordinary EXTINF sum is unaffected")
    func sumsOrdinaryDurations() throws {
        let total = try RemoteHLSSubtitleProxy.sumSegmentDurations([Self.seg(5), Self.seg(6.5)])
        #expect(total == 11.5)
    }

    @Test("A non-finite or absurd program duration is clamped before it reaches the provider's segment")
    func providerClampsAHostileProgramDuration() {
        let providerInf = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: .infinity, defaultHeaders: [:], mediaURL: nil)
        #expect(providerInf.segmentDuration(at: 0).isFinite)

        let providerHuge = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: 5e18, defaultHeaders: [:], mediaURL: nil)
        #expect(providerHuge.segmentDuration(at: 0) <= RemoteHLSSubtitleProxy.maxProgramDurationSeconds)

        let providerNaN = RemoteHLSSubtitleProvider(
            tracks: [], masterBody: Self.master, programDuration: .nan, defaultHeaders: [:], mediaURL: nil)
        #expect(providerNaN.segmentDuration(at: 0) == 1)
    }

    @Test("Without an m3u8/NAME the display name is still the key")
    func injectionKeyFallsBackToDisplayName() {
        let bare = RemoteHLSMediaSelection.LegibleOption(
            displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false)
        #expect(RemoteHLSMediaSelection.injectionKey(bare) == "German")
    }
}
