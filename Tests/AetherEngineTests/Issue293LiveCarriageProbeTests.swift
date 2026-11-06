import Foundation
import XCTest
@testable import AetherEngine

/// AE#293: a live `nativeRemoteHLS` session learns its carriage only after a full native mount plus the
/// #168 watchdog grace, so the first open of a HEVC-in-MPEG-TS channel burns 4 s of audio-only black in
/// every process. The playlist plus the first segment's PMT answer the same question while the mount is
/// still running (the #268 evidence chain, which is gated to finite VOD today). These tests pin the probe
/// gate, the watchdog's response to a positive verdict, and the playlist chain that produces it.
final class Issue293LiveCarriageProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Issue293URLProtocol.reset()
    }

    // MARK: - Probe gate

    func testH264MasterIsNeverProbed() {
        // AVPlayer carries H.264 in MPEG-TS itself, so its own free master evidence settles the case and
        // the probe must not spend an origin connect (per-token IPTV origins cap concurrent connections).
        XCTAssertFalse(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: [Self.avc1]
        ))
    }

    func testHEVCMasterIsProbed() {
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: [Self.hvc1]
        ))
    }

    func testDolbyVisionAndAV1MastersAreProbed() {
        // The HLS Authoring Spec sanctions all three in fMP4 only, so all three can reach readyToPlay
        // with no video track when the origin ships them in MPEG-TS.
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: [Self.dvh1]
        ))
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: [Self.av01]
        ))
    }

    func testMixedCodecMasterIsProbed() {
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: [Self.avc1, Self.hvc1]
        ))
    }

    func testMasterWithoutCodecEvidenceIsProbed() {
        // Video advertised but no CODECS attribute to judge it by: AVFoundation cannot settle this one.
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: true,
            advertisedVideoCodecs: []
        ))
    }

    func testDirectMediaPlaylistIsProbed() {
        // No master, so no variants: the watchdog can never fire here (it needs advertisement evidence),
        // which leaves HEVC-in-MPEG-TS behind a media playlist URL permanently black. The probe is the
        // only judge this case has.
        XCTAssertTrue(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: nil,
            advertisedVideoCodecs: []
        ))
    }

    func testAudioOnlyMasterIsNeverProbed() {
        XCTAssertFalse(RemoteHLSIngestFallback.shouldProbeCarriage(
            advertisesVideo: false,
            advertisedVideoCodecs: []
        ))
    }

    // MARK: - Watchdog response

    func testPositiveCarriageEvidenceFiresBeforeTheGrace() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(
            dog.tick(
                videoTrackCount: 0,
                variantsAdvertiseVideo: true,
                carriageEvidence: .transportStreamHEVC
            ),
            .fire,
            "a PMT that declares HEVC is the same verdict the grace was waiting to infer"
        )
    }

    func testPositiveCarriageEvidenceFiresWithoutMasterEvidence() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(
            dog.tick(
                videoTrackCount: 0,
                variantsAdvertiseVideo: nil,
                carriageEvidence: .transportStreamHEVC
            ),
            .fire,
            "the segment carries video, which is stronger evidence than the missing master parse"
        )
    }

    func testBuiltVideoTrackOutweighsCarriageEvidence() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(
            dog.tick(
                videoTrackCount: 1,
                variantsAdvertiseVideo: true,
                carriageEvidence: .transportStreamHEVC
            ),
            .disarm,
            "a session that is presenting video is never taken off the native path"
        )
    }

    func testAudioOnlyMasterIgnoresCarriageEvidence() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(
            dog.tick(
                videoTrackCount: 0,
                variantsAdvertiseVideo: false,
                carriageEvidence: .transportStreamHEVC
            ),
            .disarm,
            "the master states there is no video rendition to present"
        )
    }

    func testNativeCapableCarriageLeavesTheGraceUnchanged() {
        // The probe answering "AVPlayer's own carriage" is not a reason to disarm: a late video-track
        // build stays the healthy outcome and a track that never arrives still belongs on the ingest.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 3)
        for _ in 1...2 {
            XCTAssertEqual(
                dog.tick(
                    videoTrackCount: 0,
                    variantsAdvertiseVideo: true,
                    carriageEvidence: .nativeCapable
                ),
                .keepWaiting
            )
        }
        XCTAssertEqual(
            dog.tick(
                videoTrackCount: 0,
                variantsAdvertiseVideo: true,
                carriageEvidence: .nativeCapable
            ),
            .fire
        )
    }

    func testFiringOnProbeEvidenceReportsTheGraceItRemoved() {
        // AE#274: a latency fix that does not log the interval it removed leaves the reporter measuring
        // the sum, so the reroute line has to carry it.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(dog.remainingGraceSeconds(tickInterval: 0.5), 4, accuracy: 0.0001)
        _ = dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true)
        XCTAssertEqual(dog.remainingGraceSeconds(tickInterval: 0.5), 3.5, accuracy: 0.0001)
    }

    func testExhaustedGraceReportsNoRemainder() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 2)
        _ = dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true)
        _ = dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true)
        XCTAssertEqual(dog.remainingGraceSeconds(tickInterval: 0.5), 0, accuracy: 0.0001)
    }

    // MARK: - Playlist chain

    func testLiveMasterOverTransportStreamHEVCClassifies() async throws {
        let master = try XCTUnwrap(URL(string: "https://live.test/master.m3u8"))
        let low = try XCTUnwrap(URL(string: "https://live.test/low.m3u8"))
        let high = try XCTUnwrap(URL(string: "https://live.test/high.m3u8"))
        Issue293URLProtocol.bodyByURL[master.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="hvc1.2.4.L123.B0"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS="hvc1.2.4.L150.B0"
        high.m3u8
        """.utf8)
        Issue293URLProtocol.bodyByURL[low.absoluteString] = liveMediaPlaylist("low0.ts")
        Issue293URLProtocol.bodyByURL[high.absoluteString] = liveMediaPlaylist("high0.ts")
        Issue293URLProtocol.bodyByURL["https://live.test/high0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: master,
            httpHeaders: ["X-Fixture": "allowed"],
            session: session
        )

        XCTAssertEqual(verdict, .hevcInMPEGTS, "a live window without EXT-X-ENDLIST must still be judged")
        XCTAssertEqual(
            Issue293URLProtocol.headersByURL["https://live.test/high0.ts"]?["X-Fixture"],
            "allowed",
            "header-enforcing origins must see the session's headers on the probe fetches too"
        )
        XCTAssertNil(
            Issue293URLProtocol.headersByURL[low.absoluteString],
            "one variant answers the carriage question; the rest cost connects for nothing"
        )
    }

    func testDirectLiveMediaPlaylistClassifies() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/media.m3u8"))
        Issue293URLProtocol.bodyByURL[media.absoluteString] = liveMediaPlaylist("media0.ts")
        Issue293URLProtocol.bodyByURL["https://live.test/media0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .hevcInMPEGTS)
    }

    func testFragmentedMP4PlaylistNeedsNoSegmentFetch() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/fmp4.m3u8"))
        Issue293URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:120
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        fmp40.m4s
        """.utf8)
        Issue293URLProtocol.bodyByURL["https://live.test/fmp40.m4s"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .otherCarriage, "EXT-X-MAP is fMP4 carriage, which AVPlayer builds itself")
        XCTAssertNil(
            Issue293URLProtocol.headersByURL["https://live.test/fmp40.m4s"],
            "the playlist already settled it; no segment byte is worth fetching"
        )
    }

    func testH264TransportStreamKeepsTheNativeRoute() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/h264.m3u8"))
        Issue293URLProtocol.bodyByURL[media.absoluteString] = liveMediaPlaylist("h2640.ts")
        Issue293URLProtocol.bodyByURL["https://live.test/h2640.ts"] = transportStream(streamType: 0x1B)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .transportStreamWithoutHEVC)
    }

    func testEncryptedSegmentStaysInconclusive() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/aes.m3u8"))
        Issue293URLProtocol.bodyByURL[media.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        aes0.ts
        """.utf8)
        Issue293URLProtocol.bodyByURL["https://live.test/aes0.ts"] = transportStream(streamType: 0x24)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .inconclusive, "a PMT behind AES-128 cannot be read, and absence never fires")
        XCTAssertNil(Issue293URLProtocol.headersByURL["https://live.test/aes0.ts"])
    }

    func testUnreachablePlaylistStaysInconclusive() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/dead.m3u8"))

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .inconclusive)
    }

    func testUnreachableSegmentStaysInconclusive() async throws {
        let media = try XCTUnwrap(URL(string: "https://live.test/gap.m3u8"))
        Issue293URLProtocol.bodyByURL[media.absoluteString] = liveMediaPlaylist("gap0.ts")

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let verdict = await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: media,
            httpHeaders: [:],
            session: session
        )

        XCTAssertEqual(verdict, .inconclusive)
    }

    // MARK: - Fixtures

    private static let avc1: FourCharCode = 0x61766331
    private static let hvc1: FourCharCode = 0x68766331
    private static let dvh1: FourCharCode = 0x64766831
    private static let av01: FourCharCode = 0x61763031

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue293URLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A live window: no EXT-X-ENDLIST, a rolling media sequence. The VOD resolver rejects exactly this
    /// shape, which is why the live probe needs its own playlist chain.
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

final class Issue293URLProtocol: URLProtocol, @unchecked Sendable {
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
