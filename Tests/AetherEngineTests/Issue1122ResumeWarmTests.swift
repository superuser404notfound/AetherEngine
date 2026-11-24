import Testing
import Foundation
@testable import AetherEngine

/// AE#1122: a resumed transcode on the `nativeRemoteHLS` stand-in. AVPlayer asks for the fMP4 init
/// before the resume segment, and a Jellyfin transcode then starts ffmpeg twice: once at 0 for the init,
/// once more at the resume point for the segment. The stand-in serves AVPlayer the variant it already
/// fetched, and on a resume the first answer for it waits until the resume segment has been asked for,
/// with the requester's own User-Agent (Jellyfin keys the job on it).
@Suite("Remote-HLS resume warm and served variant (AE#1122)", .timeLimit(.minutes(3)))
struct Issue1122ResumeWarmTests {

    // MARK: - Which segment

    private static func playlist(durations: [Double], hasMap: Bool = true, hasEndList: Bool = true,
                                 byteRanged: Bool = false) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: 6, mediaSequence: 0,
            segments: durations.enumerated().map { index, duration in
                HLSMediaSegment(uri: "hls1/main/\(index).mp4?api_key=k", duration: duration,
                                discontinuityBefore: false,
                                byteRange: byteRanged ? HLSByteRange(offset: index * 100, length: 100) : nil)
            },
            hasEndList: hasEndList, isEncrypted: false, hasUnsupportedEncryption: false, hasMap: hasMap)
    }

    private static let variantURL = URL(string: "https://jf.test/videos/42/main.m3u8?api_key=k")!

    @Test("The segment whose span holds the start position, start inclusive")
    func picksTheSegmentHoldingThePosition() throws {
        let media = Self.playlist(durations: [6, 6, 6, 6])
        let mid = try #require(RemoteHLSResumeWarm.target(
            startPosition: 13, playlist: media, playlistURL: Self.variantURL, variantCount: 1))
        #expect(mid.index == 2)
        #expect(mid.url.absoluteString == "https://jf.test/videos/42/hls1/main/2.mp4?api_key=k")
        let boundary = try #require(RemoteHLSResumeWarm.target(
            startPosition: 12, playlist: media, playlistURL: Self.variantURL, variantCount: 1))
        #expect(boundary.index == 2, "a position on a boundary belongs to the segment that starts there")
    }

    @Test("Nothing to warm where the init request already lands right, or nothing is transcoded")
    func skipsWhereWarmingGainsNothing() {
        let media = Self.playlist(durations: [6, 6, 6, 6])
        func target(_ position: Double?, _ playlist: HLSMediaPlaylist = media, variants: Int = 1) -> Int? {
            RemoteHLSResumeWarm.target(startPosition: position, playlist: playlist,
                                       playlistURL: Self.variantURL, variantCount: variants)?.index
        }
        #expect(target(nil) == nil)
        #expect(target(0) == nil)
        #expect(target(3) == nil, "segment 0 is where the init request starts the job anyway")
        #expect(target(.infinity) == nil)
        #expect(target(30) == nil, "past the last segment")
        #expect(target(13, Self.playlist(durations: [6, 6, 6, 6], hasMap: false)) == nil)
        #expect(target(13, Self.playlist(durations: [6, 6, 6, 6], hasEndList: false)) == nil)
        #expect(target(13, Self.playlist(durations: [6, 6, 6, 6], byteRanged: true)) == nil)
        #expect(target(13, variants: 2) == nil, "AVPlayer picks the variant, so a warm could start a job it skips")
    }

    // MARK: - The served variant

    @Test("A served variant keeps every URI pointing at the origin")
    func servedVariantIsAbsolute() {
        let body = "#EXTM3U\r\n#EXT-X-TARGETDURATION:6\r\n#EXT-X-MAP:URI=\"hls1/main/-1.mp4?api_key=k\"\r\n"
            + "#EXTINF:6.0,\r\nhls1/main/0.mp4?api_key=k\r\n"
            + "#EXTINF:6.0,\r\nhttps://cdn.test/1.mp4\r\n#EXT-X-ENDLIST\r\n"
        let out = RemoteHLSMasterRewrite.absolutizedMediaPlaylist(body, against: Self.variantURL)
        #expect(out.contains("#EXT-X-MAP:URI=\"https://jf.test/videos/42/hls1/main/-1.mp4?api_key=k\""))
        #expect(out.contains("\nhttps://jf.test/videos/42/hls1/main/0.mp4?api_key=k\n"))
        #expect(out.contains("\nhttps://cdn.test/1.mp4\n"))
        #expect(!out.contains("\r"))
        #expect(out.contains("#EXT-X-TARGETDURATION:6\n"))
    }

    @Test("Only the fetched variant moves to the loopback origin, and its URI stays relative")
    func masterNamesTheServedVariant() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000
        main.m3u8?api_key=k
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        low.m3u8?api_key=k
        """
        let base = try #require(URL(string: "https://jf.test/videos/42/master.m3u8?api_key=k"))
        let rewritten = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: master, originURL: base,
            renditions: [.init(ordinal: 0, name: "English")],
            servedVariant: .init(originURL: Self.variantURL, localURI: RemoteHLSMasterRewrite.servedVariantURI))
        let lines = rewritten.components(separatedBy: "\n")
        #expect(lines.contains(RemoteHLSMasterRewrite.servedVariantURI))
        #expect(lines.contains("https://jf.test/videos/42/low.m3u8?api_key=k"))
        #expect(!lines.contains("https://jf.test/videos/42/main.m3u8?api_key=k"))
    }

    @Test("A served variant that matches no variant line is reported as not served")
    func unmatchedServedVariantIsNotServed() throws {
        let rewritten = try RemoteHLSMasterRewrite.rewriteDeclaringNames(
            originPlaylist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://origin.test/a/main.m3u8\n",
            originURL: try #require(URL(string: "http://origin.test/master.m3u8")),
            renditions: [.init(ordinal: 0, name: "English")],
            servedVariant: .init(originURL: try #require(URL(string: "http://origin.test/b/main.m3u8")),
                                 localURI: RemoteHLSMasterRewrite.servedVariantURI))
        #expect(!rewritten.servesVariant)
        #expect(rewritten.master.contains("http://origin.test/a/main.m3u8"))
    }

    @Test("A media-playlist origin is wrapped around the served copy")
    func wrapNamesTheServedVariant() throws {
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\n0.ts\n#EXT-X-ENDLIST\n"
        let rewritten = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: media, originURL: Self.variantURL,
            renditions: [.init(ordinal: 0, name: "English")],
            servedVariant: .init(originURL: Self.variantURL, localURI: RemoteHLSMasterRewrite.servedVariantURI))
        #expect(rewritten.components(separatedBy: "\n").contains(RemoteHLSMasterRewrite.servedVariantURI))
        #expect(!rewritten.contains(Self.variantURL.absoluteString))
    }

    // MARK: - Against an origin

    private static let originMaster = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=8000000
    videos/42/main.m3u8
    """

    private static let originVariant = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-MAP:URI="hls1/main/-1.mp4"
    #EXTINF:6.0,
    hls1/main/0.mp4
    #EXTINF:6.0,
    hls1/main/1.mp4
    #EXTINF:6.0,
    hls1/main/2.mp4
    #EXT-X-ENDLIST
    """

    private static func origin() throws -> CannedHTTPOrigin {
        let server = try #require(CannedHTTPOrigin())
        server.route("/master.m3u8", .body(originMaster, contentType: "application/vnd.apple.mpegurl"))
        server.route("/videos/42/main.m3u8", .body(originVariant, contentType: "application/vnd.apple.mpegurl"))
        server.route("/en.vtt", .body("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n", contentType: "text/vtt"))
        return server
    }

    private static func prepare(_ server: CannedHTTPOrigin, resumeAt: Double?,
                                waitSeconds: TimeInterval = RemoteHLSResumeWarm.waitSeconds,
                                headers: [String: String] = ["X-Emby-Token": "t0k3n"])
        async throws -> RemoteHLSSubtitleProxy.Prepared {
        let sidecar = try #require(URL(string: "\(server.baseURL)/en.vtt"))
        let master = try #require(URL(string: "\(server.baseURL)/master.m3u8"))
        return try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: master,
            tracks: [.init(externalID: 100_000, source: ExternalSubtitleTrack(url: sidecar, language: "en"))],
            httpHeaders: headers, needsRelay: false, resumeAt: resumeAt,
            resumeWarmWaitSeconds: waitSeconds))
    }

    private static func variantURL(_ prepared: RemoteHLSSubtitleProxy.Prepared) throws -> URL {
        try #require(URL(string: RemoteHLSMasterRewrite.servedVariantURI, relativeTo: prepared.masterURL))
    }

    private static func get(_ url: URL, userAgent: String? = nil) async throws -> (status: Int, body: String) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("A resume asks for the resume segment, with the player's agent, before the variant goes out")
    func resumeSegmentIsRequestedBeforeTheVariant() async throws {
        let server = try Self.origin()
        defer { server.stop() }
        server.route("/videos/42/hls1/main/2.mp4", .body("seg2", contentType: "video/mp4"))

        let prepared = try await Self.prepare(server, resumeAt: 13)
        defer { prepared.tearDown() }
        #expect(server.requests(to: "/videos/42/hls1/main/2.mp4").isEmpty,
                "the warm waits for the player's own request, which carries the agent the job is keyed on")

        let variant = try await Self.get(Self.variantURL(prepared), userAgent: "AppleCoreMedia/1.0.0.test")
        #expect(variant.status == 200)
        let warm = server.requests(to: "/videos/42/hls1/main/2.mp4")
        #expect(warm.count == 1)
        #expect(warm.first?.headers["user-agent"] == "AppleCoreMedia/1.0.0.test")
        #expect(warm.first?.headers["x-emby-token"] == "t0k3n")
        #expect(server.requests(to: "/videos/42/hls1/main/-1.mp4").isEmpty,
                "the init is the player's to ask for, after the job runs at the resume point")

        _ = try await Self.get(Self.variantURL(prepared), userAgent: "AppleCoreMedia/1.0.0.test")
        #expect(server.requests(to: "/videos/42/hls1/main/2.mp4").count == 1, "the warm runs once")
    }

    @Test("Without a start position no segment is asked for")
    func noWarmAtTheHead() async throws {
        let server = try Self.origin()
        defer { server.stop() }

        let prepared = try await Self.prepare(server, resumeAt: nil)
        defer { prepared.tearDown() }
        #expect(try await Self.get(Self.variantURL(prepared)).status == 200)

        #expect(server.requests.allSatisfy { !$0.path.hasSuffix(".mp4") })
    }

    /// The segment answers after 60 s and the cap is 0.5 s, so a variant that went out before the
    /// segment proves the cap without a tight wall-clock bound: a fixed 2.5 s bound over a 4 s segment
    /// failed on a loaded runner (the one-thread pool CI job, 2026-11-24) while the cap was honoured.
    @Test("A resume segment that does not answer in time still lets the variant go out")
    func slowResumeSegmentDoesNotHoldTheVariant() async throws {
        let server = try Self.origin()
        defer { server.stop() }
        server.route("/videos/42/hls1/main/2.mp4", .delayed(60, .body("seg2", contentType: "video/mp4")))

        let prepared = try await Self.prepare(server, resumeAt: 13, waitSeconds: 0.5)
        defer { prepared.tearDown() }

        let started = Date()
        #expect(try await Self.get(Self.variantURL(prepared)).status == 200)
        #expect(Date().timeIntervalSince(started) < 30, "the variant waited for the segment past its cap")
    }

    @Test("A host's own User-Agent, in any spelling, gives way to the player's")
    func playerAgentReplacesTheHostsInAnySpelling() async throws {
        let server = try Self.origin()
        defer { server.stop() }
        server.route("/videos/42/hls1/main/2.mp4", .body("seg2", contentType: "video/mp4"))

        let prepared = try await Self.prepare(
            server, resumeAt: 13, headers: ["X-Emby-Token": "t0k3n", "user-agent": "Host/1.0"])
        defer { prepared.tearDown() }
        _ = try await Self.get(Self.variantURL(prepared), userAgent: "AppleCoreMedia/1.0.0.test")

        let warm = server.requests(to: "/videos/42/hls1/main/2.mp4")
        #expect(warm.count == 1)
        #expect(warm.first?.headers["user-agent"] == "AppleCoreMedia/1.0.0.test")
    }

    @Test("A variant that set a cookie is left to AVPlayer, and nothing is warmed")
    func cookieVariantStaysAtTheOrigin() async throws {
        let server = try Self.origin()
        defer { server.stop() }
        server.route("/videos/42/main.m3u8", .header(
            "Set-Cookie", "edge=abc; Path=/",
            .body(Self.originVariant, contentType: "application/vnd.apple.mpegurl")))

        let prepared = try await Self.prepare(server, resumeAt: 13)
        defer { prepared.tearDown() }

        let master = try await Self.get(prepared.masterURL)
        #expect(master.body.contains("\(server.baseURL)/videos/42/main.m3u8"))
        #expect(!master.body.contains(RemoteHLSMasterRewrite.servedVariantURI))
        #expect(try await Self.get(Self.variantURL(prepared)).status == 404)
        #expect(server.requests.allSatisfy { !$0.path.hasSuffix(".mp4") })
    }

    @Test("AVPlayer is served the variant the stand-in fetched, and the origin sees it once")
    func variantIsServedFromTheStandIn() async throws {
        let server = try Self.origin()
        defer { server.stop() }

        let prepared = try await Self.prepare(server, resumeAt: nil)
        defer { prepared.tearDown() }

        let master = try await Self.get(prepared.masterURL)
        #expect(master.body.components(separatedBy: "\n").contains(RemoteHLSMasterRewrite.servedVariantURI))
        let variant = try await Self.get(Self.variantURL(prepared))
        #expect(variant.status == 200)
        #expect(variant.body.contains("#EXT-X-MAP:URI=\"\(server.baseURL)/videos/42/hls1/main/-1.mp4\""))
        #expect(variant.body.contains("\n\(server.baseURL)/videos/42/hls1/main/2.mp4\n"))
        #expect(server.requests(to: "/videos/42/main.m3u8").count == 1)
    }
}
