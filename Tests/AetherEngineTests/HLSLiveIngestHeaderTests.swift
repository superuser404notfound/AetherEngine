import XCTest
@testable import AetherEngine

/// AetherEngine#168 follow-up: the engine-side reroute from `nativeRemoteHLS` onto the live-ingest path
/// must not drop `LoadOptions.httpHeaders`. Header-enforcing IPTV origins (Referer / User-Agent /
/// Authorization, see #119) would otherwise 403 the ingest that the AVPlayer bypass reached fine.
/// Pins the request builder every ingest fetch (playlist, segment, AES key) goes through.
final class HLSLiveIngestHeaderTests: XCTestCase {

    func testMakeRequestAppliesConfiguredHeaders() throws {
        let reader = HLSLiveIngestReader(
            playlistURL: URL(string: "https://origin.example/live/master.m3u8")!,
            httpHeaders: [
                "Referer": "https://portal.example/",
                "User-Agent": "SodaliteTV/1.0",
                "Authorization": "Bearer token123",
            ]
        )
        defer { reader.close() }
        let request = reader.makeRequest(URL(string: "https://origin.example/live/seg42.ts")!)
        XCTAssertEqual(request.url?.absoluteString, "https://origin.example/live/seg42.ts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://portal.example/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SodaliteTV/1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token123")
    }

    func testMakeRequestWithoutHeadersAddsNoFields() throws {
        let reader = HLSLiveIngestReader(playlistURL: URL(string: "https://origin.example/live/master.m3u8")!)
        defer { reader.close() }
        let request = reader.makeRequest(URL(string: "https://origin.example/live/media.m3u8")!)
        XCTAssertTrue(request.allHTTPHeaderFields?.isEmpty ?? true)
    }
}
