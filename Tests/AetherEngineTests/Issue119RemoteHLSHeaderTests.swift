import Testing
import Foundation
@testable import AetherEngine

/// #119: the `nativeRemoteHLS` bypass silently dropped `LoadOptions.httpHeaders`. Jellyfin carries
/// auth in query params, but generic live HLS origins (IPTV / Stremio add-on channels) enforce
/// per-stream Referer / User-Agent / Authorization headers and answered 403 on this path.
///
/// Two seams carry the headers and are locked here:
/// - `NativeAVPlayerHost.assetCreationOptions(httpHeaders:)` builds the AVURLAsset options
///   (`AVURLAssetHTTPHeaderFieldsKey`) AVFoundation applies to playlist + segment requests.
///   The loadRemoteHLS -> host.load wiring itself is AVPlayer-bound and reporter-verified.
/// - `AudioTapHLSFetcher` fetches playlists / segments / AES keys on its own URLSession for the
///   remote-HLS audio tap (#95); without the same headers the tap 403s on the same origins.
@Suite("Remote-HLS HTTP headers (#119)", .serialized)
struct Issue119RemoteHLSHeaderTests {

    // MARK: - AVURLAsset options seam

    @Test("Empty headers keep the default asset options (nil)")
    func emptyHeadersMeanNilOptions() {
        #expect(NativeAVPlayerHost.assetCreationOptions(httpHeaders: [:]) == nil)
    }

    @Test("Non-empty headers map to AVURLAssetHTTPHeaderFieldsKey")
    func headersLandInAssetOptions() throws {
        let headers = ["Referer": "https://example.org/", "User-Agent": "SodaliteTV"]
        let options = try #require(NativeAVPlayerHost.assetCreationOptions(httpHeaders: headers))
        let field = try #require(options["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String])
        #expect(field == headers)
        #expect(options.count == 1)
    }

    // MARK: - Audio tap fetcher

    private static func makeFetcher(httpHeaders: [String: String]) -> AudioTapHLSFetcher {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HeaderCaptureURLProtocol.self]
        return AudioTapHLSFetcher(session: URLSession(configuration: cfg),
                                  httpHeaders: httpHeaders)
    }

    @Test("fetchPlaylist sends the configured headers")
    func playlistFetchCarriesHeaders() async throws {
        HeaderCaptureURLProtocol.reset()
        let url = URL(string: "https://origin.test/live/channel.m3u8")!
        HeaderCaptureURLProtocol.bodyByURL[url.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        """.utf8)

        let fetcher = Self.makeFetcher(httpHeaders: ["Referer": "https://example.org/"])
        _ = try await fetcher.fetchPlaylist(url)

        let seen = try #require(HeaderCaptureURLProtocol.headersByURL[url.absoluteString])
        #expect(seen["Referer"] == "https://example.org/")
    }

    @Test("fetchSegment sends the configured headers")
    func segmentFetchCarriesHeaders() async throws {
        HeaderCaptureURLProtocol.reset()
        let base = URL(string: "https://origin.test/live/channel.m3u8")!
        let url = URL(string: "https://origin.test/live/seg0.ts")!
        HeaderCaptureURLProtocol.bodyByURL[url.absoluteString] = Data([0x47, 0x40, 0x11, 0x10])

        let fetcher = Self.makeFetcher(httpHeaders: ["Authorization": "Bearer token123"])
        _ = try await fetcher.fetchSegment(url, crypt: nil, base: base)

        let seen = try #require(HeaderCaptureURLProtocol.headersByURL[url.absoluteString])
        #expect(seen["Authorization"] == "Bearer token123")
    }

    @Test("No configured headers means no injected header fields")
    func noHeadersMeansCleanRequest() async throws {
        HeaderCaptureURLProtocol.reset()
        let base = URL(string: "https://origin.test/live/channel.m3u8")!
        let url = URL(string: "https://origin.test/live/seg1.ts")!
        HeaderCaptureURLProtocol.bodyByURL[url.absoluteString] = Data([0x47])

        let fetcher = Self.makeFetcher(httpHeaders: [:])
        _ = try await fetcher.fetchSegment(url, crypt: nil, base: base)

        let seen = HeaderCaptureURLProtocol.headersByURL[url.absoluteString] ?? [:]
        #expect(seen["Referer"] == nil)
        #expect(seen["Authorization"] == nil)
    }
}

/// In-process URLProtocol that records each request's headers and answers 200 with canned bytes,
/// so header application can be asserted without a real server (pattern: MockRangeURLProtocol).
final class HeaderCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodyByURL: [String: Data] = [:]
    nonisolated(unsafe) static var headersByURL: [String: [String: String]] = [:]

    static func reset() {
        bodyByURL = [:]; headersByURL = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.headersByURL[url.absoluteString] = request.allHTTPHeaderFields ?? [:]
        guard let data = Self.bodyByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
