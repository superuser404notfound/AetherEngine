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

    /// Audit LOAD-208: the engine's own ingest reads the session store, so a rotated token reaches it.
    func testEngineIngestFollowsTheSessionHeaderStore() throws {
        let reader = HLSLiveIngestReader.engineIngest(
            playlistURL: URL(string: "https://origin.example/live/master.m3u8")!,
            httpHeaders: ["Authorization": "Bearer old"], diagnosticContext: nil)
        defer { reader.close() }
        let store = RequestHeaderStore(["Authorization": "Bearer old"])
        reader.adoptSessionHeaderStore(store)
        store.replace(["Authorization": "Bearer new"])
        let request = reader.makeRequest(URL(string: "https://origin.example/live/seg1.ts")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
        let fresh = try XCTUnwrap(reader.makeFreshMainReader())
        defer { fresh.close() }
        XCTAssertEqual(fresh.makeRequest(URL(string: "https://origin.example/live/seg2.ts")!)
            .value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testHostBuiltReaderKeepsItsOwnHeaders() throws {
        let reader = HLSLiveIngestReader(
            playlistURL: URL(string: "https://origin.example/live/master.m3u8")!,
            httpHeaders: ["Authorization": "Bearer mine"])
        defer { reader.close() }
        reader.adoptSessionHeaderStore(RequestHeaderStore([:]))
        let request = reader.makeRequest(URL(string: "https://origin.example/live/seg1.ts")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mine")
    }

    /// Audit NET-208: a provider that rotates key URIs must not grow the cache for the whole session.
    func testKeyCacheStaysBounded() {
        let reader = HLSLiveIngestReader(playlistURL: URL(string: "https://origin.example/live/master.m3u8")!)
        defer { reader.close() }
        for index in 0..<1000 { reader.storeKey(Data(count: 16), for: "https://k.example/key?n=\(index)") }
        XCTAssertEqual(reader.cachedKeyCount, HLSLiveIngestReader.maximumCachedKeys)
    }
}
