import Foundation
import XCTest
@testable import AetherEngine

/// AE#296: the #293 carriage probe reads a segment head to classify the PMT, and it reads it while the
/// native mount is establishing its own connection to the same origin. On a per-token connection cap
/// (the IPTV norm) that is a second media connection competing with the mount, on exactly the channels
/// the probe's gate admits. Two defects, neither of which is "the probe reads a segment": it reads one
/// where the playlists already answer, and it reads it at the one moment where losing the race costs the
/// mount rather than the verdict. These tests pin the playlist stage's evidence rules and the point at
/// which a media byte is spent at all.
final class Issue296CarriageProbeConnectionBudgetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Issue296URLProtocol.reset()
    }

    // MARK: - Advertisement classification

    func testFragmentedMP4OnlyCodecsAreRecognized() {
        // The HLS Authoring Spec sanctions these in fMP4 carriage alone, so MPEG-TS segments behind such
        // an advertisement are the #168 case without a PMT read.
        for codec in [Self.hvc1, Self.hev1, Self.dvh1, Self.dvhe, Self.av01] {
            XCTAssertTrue(RemoteHLSIngestFallback.advertisesFragmentedMP4OnlyVideo([codec]))
        }
        XCTAssertTrue(RemoteHLSIngestFallback.advertisesFragmentedMP4OnlyVideo([Self.avc1, Self.hvc1]))
    }

    func testH264AndAbsentAdvertisementAreNotFragmentedMP4Only() {
        XCTAssertFalse(RemoteHLSIngestFallback.advertisesFragmentedMP4OnlyVideo([Self.avc1]))
        XCTAssertFalse(
            RemoteHLSIngestFallback.advertisesFragmentedMP4OnlyVideo([]),
            "no CODECS attribute is an absence of evidence, and only the PMT can settle that source"
        )
    }

    // MARK: - Playlist stage: settled without a media byte

    func testAdvertisedHEVCWithoutMapSettlesWithoutFetchingASegment() async throws {
        let master = try XCTUnwrap(URL(string: "https://cap.test/master.m3u8"))
        let high = try XCTUnwrap(URL(string: "https://cap.test/high.m3u8"))
        Issue296URLProtocol.bodyByURL[master.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS="hvc1.2.4.L150.B0"
        high.m3u8
        """.utf8)
        Issue296URLProtocol.bodyByURL[high.absoluteString] = liveMediaPlaylist("high0.ts")
        Issue296URLProtocol.bodyByURL["https://cap.test/high0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: master,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(
            evidence,
            .settled(.hevcInMPEGTS),
            "an fMP4 media segment requires an EXT-X-MAP, so an fMP4-only codec without one is MPEG-TS"
        )
        XCTAssertNil(
            Issue296URLProtocol.headersByURL["https://cap.test/high0.ts"],
            "the playlists answered; a capped origin must not see a second media connection for this"
        )
    }

    func testAdvertisedHEVCWithMapStaysOtherCarriage() async throws {
        let media = try XCTUnwrap(URL(string: "https://cap.test/fmp4.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        fmp40.m4s
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(evidence, .settled(.otherCarriage), "fMP4 is the carriage AVPlayer builds itself")
    }

    func testAES128DoesNotBlockPlaylistEvidence() async throws {
        // The PMT behind AES-128 is unreadable, which is why the segment stage gives up on it. Playlist
        // evidence does not read the PMT, and the ingest decrypts this carriage, so the verdict lands
        // early instead of costing the full grace before the watchdog concludes the same thing.
        let media = try XCTUnwrap(URL(string: "https://cap.test/aes.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:99
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        aes0.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(evidence, .settled(.hevcInMPEGTS))
        XCTAssertNil(Issue296URLProtocol.headersByURL["https://cap.test/aes0.ts"])
        XCTAssertNil(
            Issue296URLProtocol.headersByURL["https://cap.test/key.bin"],
            "the key is the ingest's business, not the probe's"
        )
    }

    func testSampleAESStaysInconclusiveOnPlaylistEvidence() async throws {
        // SAMPLE-AES is not carriage the ingest can serve, so positive evidence must not be claimed for it.
        let media = try XCTUnwrap(URL(string: "https://cap.test/sample-aes.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
        #EXTINF:6,
        sae0.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(evidence, .settled(.inconclusive))
    }

    func testEmptyPlaylistStaysInconclusive() async throws {
        // A window with no segments states nothing about its carriage, and an absence never reroutes.
        let media = try XCTUnwrap(URL(string: "https://cap.test/empty.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:4
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(evidence, .settled(.inconclusive))
    }

    // MARK: - Playlist stage: what still needs the PMT

    func testDirectMediaPlaylistDefersTheSegmentHead() async throws {
        // No master, so no CODECS: only the PMT separates HEVC in MPEG-TS from H.264 in MPEG-TS here, and
        // dropping that distinction would pull working H.264 channels off the native path. The playlist
        // stage must hand the segment back rather than fetch it, so the host can spend it after
        // readyToPlay instead of against the mount.
        let media = try XCTUnwrap(URL(string: "https://cap.test/direct.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = liveMediaPlaylist("direct0.ts")
        Issue296URLProtocol.bodyByURL["https://cap.test/direct0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: false,
            session: session
        )

        XCTAssertEqual(
            evidence,
            .needsSegmentHead(try XCTUnwrap(URL(string: "https://cap.test/direct0.ts")), key: nil)
        )
        XCTAssertNil(
            Issue296URLProtocol.headersByURL["https://cap.test/direct0.ts"],
            "the playlist stage runs against the mount, so it spends playlists only"
        )
    }

    func testMasterWithoutCodecEvidenceDefersTheSegmentHead() async throws {
        let master = try XCTUnwrap(URL(string: "https://cap.test/nocodecs.m3u8"))
        let variant = try XCTUnwrap(URL(string: "https://cap.test/v1.m3u8"))
        Issue296URLProtocol.bodyByURL[master.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
        v1.m3u8
        """.utf8)
        Issue296URLProtocol.bodyByURL[variant.absoluteString] = liveMediaPlaylist("v10.ts")

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: master,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: false,
            session: session
        )

        XCTAssertEqual(
            evidence,
            .needsSegmentHead(try XCTUnwrap(URL(string: "https://cap.test/v10.ts")), key: nil)
        )
    }

    func testEncryptedSegmentWithoutCodecEvidenceDefersWithItsKey() async throws {
        // AE#1089: the PMT behind AES-128 is read once decrypted, so the segment stage gets the key
        // context instead of the source being settled as unjudged.
        let media = try XCTUnwrap(URL(string: "https://cap.test/aes-nocodecs.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        aes0.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: false,
            session: session
        )

        XCTAssertEqual(
            evidence,
            .needsSegmentHead(
                try XCTUnwrap(URL(string: "https://cap.test/aes0.ts")),
                key: HLSCarriageProbe.SegmentKey(
                    url: try XCTUnwrap(URL(string: "https://cap.test/key.bin")), iv: Data(count: 16))
            )
        )
    }

    func testUnreachablePlaylistSettlesInconclusive() async throws {
        let media = try XCTUnwrap(URL(string: "https://cap.test/dead.m3u8"))

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: media,
            httpHeaders: [:],
            advertisesFragmentedMP4OnlyVideo: true,
            session: session
        )

        XCTAssertEqual(evidence, .settled(.inconclusive))
    }

    // MARK: - Deferred segment stage

    func testDeferredSegmentHeadClassifiesTheCarriage() async throws {
        Issue296URLProtocol.bodyByURL["https://cap.test/direct0.ts"] = transportStream(streamType: 0x24)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let verdict = await HLSCarriageProbe.classifyDeferredSegmentHead(
            url: try XCTUnwrap(URL(string: "https://cap.test/direct0.ts")),
            httpHeaders: ["X-Fixture": "allowed"],
            credentialOrigin: try XCTUnwrap(URL(string: "https://cap.test/live.m3u8")),
            session: session
        )

        XCTAssertEqual(verdict, .hevcInMPEGTS)
        XCTAssertEqual(
            Issue296URLProtocol.headersByURL["https://cap.test/direct0.ts"]?["X-Fixture"],
            "allowed",
            "header-enforcing origins must see the session's headers on the deferred fetch too"
        )
    }

    func testDeferredSegmentHeadCollapsesFailureToInconclusive() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let verdict = await HLSCarriageProbe.classifyDeferredSegmentHead(
            url: try XCTUnwrap(URL(string: "https://cap.test/gone.ts")),
            httpHeaders: [:],
            credentialOrigin: try XCTUnwrap(URL(string: "https://cap.test/live.m3u8")),
            session: session
        )

        XCTAssertEqual(verdict, .inconclusive, "a refused connection is not a reason to reroute")
    }

    // MARK: - Composed chain (the #293 behaviour that must not regress)

    func testComposedChainStillClassifiesADirectMediaPlaylist() async throws {
        let media = try XCTUnwrap(URL(string: "https://cap.test/direct.m3u8"))
        Issue296URLProtocol.bodyByURL[media.absoluteString] = liveMediaPlaylist("direct0.ts")
        Issue296URLProtocol.bodyByURL["https://cap.test/direct0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .hevcInMPEGTS)
    }

    // MARK: - Fixtures

    private static let avc1: FourCharCode = 0x61766331
    private static let hvc1: FourCharCode = 0x68766331
    private static let hev1: FourCharCode = 0x68657631
    private static let dvh1: FourCharCode = 0x64766831
    private static let dvhe: FourCharCode = 0x64766865
    private static let av01: FourCharCode = 0x61763031

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue296URLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func liveMediaPlaylist(_ segment: String) -> Data {
        Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:812
        #EXTINF:6,
        \(segment)
        """.utf8)
    }

    private func transportStream(streamType: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
        for packet in 0..<3 {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        bytes[1] = 0x40
        bytes[2] = 0x64
        bytes[4] = 0
        bytes[5] = 0x02
        bytes[6] = 0xB0
        bytes[7] = 18
        bytes[8] = 0
        bytes[9] = 1
        bytes[10] = 0xC1
        bytes[11] = 0
        bytes[12] = 0
        bytes[13] = 0xE1
        bytes[14] = 0
        bytes[15] = 0xF0
        bytes[16] = 0
        bytes[17] = streamType
        bytes[18] = 0xE1
        bytes[19] = 1
        bytes[20] = 0xF0
        bytes[21] = 0
        return Data(bytes)
    }
}

final class Issue296URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodyByURL: [String: Data] = [:]
    nonisolated(unsafe) static var headersByURL: [String: [String: String]] = [:]

    static func reset() {
        bodyByURL = [:]
        headersByURL = [:]
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
        let response = HTTPURLResponse(
            url: url,
            statusCode: request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
