import Foundation
import Testing
@testable import AetherEngine

/// A playlist can name any host and any scheme for a variant, a rendition, a segment or a key. The
/// host's credential headers were set on every one of those fetches, including an http:// URI inside
/// an https:// playlist. They now follow the redirect rule (audit NET-7): the token only to the origin
/// the host gave it for, with no downgrade, and every other header wherever the playlist points.
@Suite("Credential headers stay with the host's origin", .serialized)
struct PlaylistNamedHostCredentialTests {

    private let headers = [
        "Authorization": "MediaBrowser Token=\"t0k3n\"",
        "X-Emby-Token": "t0k3n",
        "Cookie": "connect.sid=s1",
        "Referer": "https://portal.example/",
        "User-Agent": "UA/1",
    ]
    private let credentialNames = ["Authorization", "X-Emby-Token", "Cookie"]
    private let origin = URL(string: "https://media.example/live/master.m3u8")!

    @Test("The live ingest keeps the token on its own origin and drops it elsewhere", arguments: [
        ("https://media.example/live/seg1.ts", true),
        ("https://media.example:443/keys/k1", true),
        ("https://cdn.other/seg1.ts", false),
        ("http://media.example/live/seg1.ts", false),
        ("https://media.example:8443/seg1.ts", false),
    ])
    func liveIngest(target: String, keepsCredentials: Bool) throws {
        let reader = HLSLiveIngestReader(playlistURL: origin, httpHeaders: headers)
        let request = reader.makeRequest(try #require(URL(string: target)))
        expect(request, keepsCredentials: keepsCredentials)
    }

    @Test("A companion reader judges by its parent's origin, not by the rendition URL it was handed")
    func companionInheritsTheHostOrigin() throws {
        let rendition = try #require(URL(string: "https://cdn.other/audio/index.m3u8"))
        let companion = HLSLiveIngestReader(
            playlistURL: rendition, httpHeaders: headers, role: .companionAudio, credentialOrigin: origin)
        expect(companion.makeRequest(try #require(URL(string: "https://cdn.other/audio/a1.aac"))),
               keepsCredentials: false)
        expect(companion.makeRequest(try #require(URL(string: "https://media.example/audio/a1.aac"))),
               keepsCredentials: true)
    }

    @Test("The VOD ingest applies the same rule")
    func vodIngest() throws {
        let reader = HLSVODIngestReader(playlistURL: origin, httpHeaders: headers)
        defer { reader.close() }
        expect(reader.makeRequest(try #require(URL(string: "https://media.example/v/seg0.ts"))),
               keepsCredentials: true)
        expect(reader.makeRequest(try #require(URL(string: "http://media.example/v/seg0.ts"))),
               keepsCredentials: false)
    }

    @Test("The relay sends credentials to the host's origins only, not to one a playlist revealed")
    func relayHeaders() throws {
        let scope = CredentialScope(headers: headers, anchors: [origin])
        let own = scope.headers(for: try #require(URL(string: "https://media.example/hls/seg.ts")))
        #expect(own == headers)
        let discovered = scope.headers(for: try #require(URL(string: "http://cdn.other/seg.ts")))
        for name in credentialNames { #expect(discovered[name] == nil, "\(name) reached a discovered origin") }
        #expect(discovered["Referer"] == "https://portal.example/")
        #expect(discovered["User-Agent"] == "UA/1")
    }

    /// Audit NET-109: allowing a fetch and granting the token were one call, so anything the relay
    /// was told it may fetch also received the credentials.
    @Test("An origin the relay is only allowed to fetch gets no credentials")
    func relayAllowIsNotGrant() throws {
        let relay = HLSOriginRelay()
        defer { relay.stop() }
        let edge = try #require(URL(string: "https://edge.cdn/v.m3u8"))
        relay.grantCredentials(to: origin, httpHeaders: headers)
        relay.allow(edge)

        #expect(relay.credentialAnchors == [origin])
        let onEdge = relay.upstreamHeaders(for: try #require(URL(string: "https://edge.cdn/seg.ts")))
        for name in credentialNames { #expect(onEdge[name] == nil, "\(name) reached an allowed origin") }
        #expect(onEdge["Referer"] == "https://portal.example/")
        let onOrigin = relay.upstreamHeaders(for: try #require(URL(string: "https://media.example/seg.ts")))
        #expect(onOrigin == headers)
    }

    @Test("Asking the server for a relay address grants nothing")
    func relayURLOnlyAllows() throws {
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        relay.grantCredentials(to: origin, httpHeaders: headers)
        let other = try #require(URL(string: "https://cdn.other/v/index.m3u8"))

        _ = try #require(server.relayURL(for: other))

        #expect(relay.credentialAnchors == [origin])
        let onOther = relay.upstreamHeaders(for: other)
        for name in credentialNames { #expect(onOther[name] == nil, "\(name) reached \(other)") }
    }

    /// Audit Vcred-101: the live rendition fetch set every host header on the rendition playlist and
    /// every WebVTT segment the master named.
    @Test("The live subtitle rendition fetch judges by the ingest's origin", arguments: [
        ("https://media.example/subs/en.m3u8", true),
        ("https://subs.other/en.m3u8", false),
        ("http://media.example/subs/en.m3u8", false),
    ])
    func liveSubtitleRendition(target: String, keepsCredentials: Bool) throws {
        let reader = HLSLiveIngestReader(playlistURL: origin, httpHeaders: headers)
        let scope = AetherEngine.liveSubtitleRenditionCredentials(headers: headers, source: reader)
        let sent = scope.headers(for: try #require(URL(string: target)))
        for name in credentialNames {
            #expect((sent[name] != nil) == keepsCredentials, "\(name) on \(target)")
        }
        #expect(sent["Referer"] == "https://portal.example/")
    }

    @Test("Without a live ingest reader the rendition fetch carries no credentials at all")
    func liveSubtitleRenditionWithoutAnIngest() throws {
        let scope = AetherEngine.liveSubtitleRenditionCredentials(headers: headers, source: nil)
        let sent = scope.headers(for: origin)
        for name in credentialNames { #expect(sent[name] == nil, "\(name) went out with no anchor") }
    }

    @Test("The carriage probe does not carry the token to a variant on another host")
    func carriageProbeVariant() async throws {
        CredentialCaptureProtocol.reset()
        let variant = "http://cdn.other/v/index.m3u8"
        CredentialCaptureProtocol.bodies[origin.absoluteString] = Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            \(variant)
            """.utf8)
        CredentialCaptureProtocol.bodies[variant] = Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.0,
            seg0.m4s
            """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: origin, httpHeaders: headers, advertisesFragmentedMP4OnlyVideo: false,
            session: session)
        #expect(evidence == .settled(.otherCarriage))

        let master = try #require(CredentialCaptureProtocol.seen[origin.absoluteString])
        let onVariant = try #require(CredentialCaptureProtocol.seen[variant])
        #expect(master["X-Emby-Token"] == "t0k3n")
        for name in credentialNames { #expect(onVariant[name] == nil, "\(name) reached \(variant)") }
        #expect(onVariant["Referer"] == "https://portal.example/")
    }

    /// Audit NAT-105 / NET-109: the #316 build fetched the master's first variant with every host
    /// header, whatever host the master named, and anchored the relay's grant on the redirect target.
    @Test("The subtitle proxy keeps the token off an edge the master redirected to",
          .timeLimit(.minutes(3)))
    func subtitleProxyAfterACrossOriginRedirect() async throws {
        let originMaybe = CannedHTTPOrigin()
        let edgeMaybe = CannedHTTPOrigin()
        let originServer = try #require(originMaybe)
        let edge = try #require(edgeMaybe)
        defer { originServer.stop(); edge.stop() }
        originServer.route("/master.m3u8", .redirect(to: "\(edge.baseURL)/master.m3u8"))
        edge.route("/master.m3u8", .body("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            v/index.m3u8
            """, contentType: "application/vnd.apple.mpegurl"))
        edge.route("/v/index.m3u8", .body("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6.0,
            seg0.ts
            #EXT-X-ENDLIST
            """, contentType: "application/vnd.apple.mpegurl"))
        let originURL = try #require(URL(string: "\(originServer.baseURL)/master.m3u8"))
        let sidecar = try #require(URL(string: "\(originServer.baseURL)/en.vtt"))

        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: originURL,
            tracks: [.init(externalID: 100_000, source: ExternalSubtitleTrack(url: sidecar, language: "en"))],
            httpHeaders: headers, needsRelay: true))
        defer { prepared.tearDown() }
        #expect(prepared.servesSubtitleRenditions)
        let relay = try #require(prepared.server.relay)
        #expect(relay.credentialAnchors == [originURL], "the grant moved to the redirect target")
        let backHome = try #require(URL(string: "\(originServer.baseURL)/seg0.ts"))
        #expect(relay.upstreamHeaders(for: backHome)["X-Emby-Token"] == "t0k3n",
                "a relayed request to the host's own origin lost its token")
        let atEdge = try #require(URL(string: "\(edge.baseURL)/v/seg0.ts"))
        #expect(relay.upstreamHeaders(for: atEdge)["X-Emby-Token"] == nil)

        let onOrigin = try #require(originServer.requests(to: "/master.m3u8").first)
        #expect(onOrigin.headers["x-emby-token"] == "t0k3n")
        for path in ["/master.m3u8", "/v/index.m3u8"] {
            let seen = try #require(edge.requests(to: path).first, "\(path) was never fetched")
            for name in credentialNames {
                #expect(seen.headers[name.lowercased()] == nil, "\(name) reached the edge on \(path)")
            }
            #expect(seen.headers["referer"] == "https://portal.example/")
        }
    }

    /// Audit DEC-103: the remote-HLS audio tap put every host header on every playlist, segment and
    /// key a playlist named.
    @Test("The audio tap keeps the token on the loaded origin", arguments: [
        ("https://media.example/live/seg1.ts", true),
        ("https://cdn.other/seg1.ts", false),
        ("http://media.example/live/seg1.ts", false),
    ])
    func audioTapSegment(target: String, keepsCredentials: Bool) async throws {
        CredentialCaptureProtocol.reset()
        CredentialCaptureProtocol.bodies[target] = Data([0x47, 0x40, 0x11, 0x10])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetcher = AudioTapHLSFetcher(session: session, httpHeaders: headers, credentialOrigin: origin)
        let url = try #require(URL(string: target))

        _ = try await fetcher.fetchSegment(url, crypt: nil, base: origin)

        let seen = try #require(CredentialCaptureProtocol.seen[target])
        for name in credentialNames {
            #expect((seen[name] != nil) == keepsCredentials, "\(name) on \(target)")
        }
        #expect(seen["Referer"] == "https://portal.example/")
    }

    private func expect(_ request: URLRequest, keepsCredentials: Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        for name in credentialNames {
            let value = request.value(forHTTPHeaderField: name)
            #expect((value != nil) == keepsCredentials, "\(name) on \(request.url!)",
                    sourceLocation: sourceLocation)
        }
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://portal.example/",
                sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UA/1", sourceLocation: sourceLocation)
    }
}

/// Answers from canned bodies and records the headers each URL was asked with. Its own class rather
/// than the #119 suite's, whose statics a parallel suite would reset under this one.
private final class CredentialCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var _seen: [String: [String: String]] = [:]

    static var bodies: [String: Data] {
        get { lock.withLock { _bodies } }
        set { lock.withLock { _bodies = newValue } }
    }

    static var seen: [String: [String: String]] { lock.withLock { _seen } }

    static func reset() {
        lock.withLock { _bodies = [:]; _seen = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fields = request.allHTTPHeaderFields ?? [:]
        Self.lock.withLock { Self._seen[url.absoluteString] = fields }
        guard let data = Self.bodies[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
