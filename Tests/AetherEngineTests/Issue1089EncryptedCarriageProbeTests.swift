import CommonCrypto
import Foundation
import Testing
@testable import AetherEngine

/// AE#1089: an AES-128 live channel without CODECS (Xtream/XUI panels) stayed `inconclusive` because the
/// probe would not read a PMT behind encryption, so HEVC-in-TS sat on AVPlayer with sound and no
/// picture. The probe now fetches the key and decrypts the segment head, as the ingest does with the
/// whole segment.
@Suite("AE#1089 carriage probe reads the PMT of an AES-128 segment", .serialized, .timeLimit(.minutes(3)))
struct Issue1089EncryptedCarriageProbeTests {
    private static let key = Data((0..<16).map { UInt8($0 &* 7 &+ 3) })
    private static let explicitIV = Data((0..<16).map { UInt8(0xA0 &+ $0) })

    init() { Issue1089URLProtocol.reset() }

    @Test("a decrypted head is the prefix of the full plaintext")
    func headMatchesFullDecrypt() throws {
        let plaintext = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let ciphertext = try #require(Self.encrypt(plaintext, iv: Self.explicitIV))
        let full = try #require(HLSSegmentDecryptor.decryptAES128CBC(ciphertext, key: Self.key, iv: Self.explicitIV))
        #expect(full == plaintext)
        for length in [16, 1000, 1024, 4096] {
            let head = try #require(HLSSegmentDecryptor.decryptAES128CBCHead(
                ciphertext.prefix(length), key: Self.key, iv: Self.explicitIV))
            #expect(head == plaintext.prefix(length - length % 16))
        }
        #expect(HLSSegmentDecryptor.decryptAES128CBCHead(ciphertext.prefix(15), key: Self.key, iv: Self.explicitIV) == nil)
    }

    @Test("HEVC behind AES-128 with a sequence-number IV is found in the decrypted head")
    func sequenceIVFindsHEVC() async throws {
        // Large enough that the verdict lands on a chunk boundary, mid-segment, not at its end.
        let segment = Self.transportStream(streamType: 0x24, packets: 400)
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 4711, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="/key/abc""#)
        Issue1089URLProtocol.bodyByURL["https://panel.test/key/abc"] = Self.key
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg4711.ts"] = try #require(
            Self.encrypt(segment, iv: Self.sequenceIV(4711)))

        let verdict = await classify("https://panel.test/live/ch.m3u8")

        #expect(verdict == .hevcInMPEGTS)
    }

    @Test("an explicit IV is the one used, and H.264 behind it stays native")
    func explicitIVReadsH264() async throws {
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 9, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="/key/abc",IV=0xA0A1A2A3A4A5A6A7A8A9AAABACADAEAF"#)
        Issue1089URLProtocol.bodyByURL["https://panel.test/key/abc"] = Self.key
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg9.ts"] = try #require(
            Self.encrypt(Self.transportStream(streamType: 0x1B, packets: 3), iv: Self.explicitIV))

        let verdict = await classify("https://panel.test/live/ch.m3u8")

        #expect(verdict == .transportStreamWithoutHEVC)
    }

    @Test("a wrong key reads as foreign carriage and never as HEVC")
    func wrongKeyNeverReroutes() async throws {
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 1, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="/key/abc""#)
        Issue1089URLProtocol.bodyByURL["https://panel.test/key/abc"] = Data(repeating: 0x55, count: 16)
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg1.ts"] = try #require(
            Self.encrypt(Self.transportStream(streamType: 0x24, packets: 400), iv: Self.sequenceIV(1)))

        let verdict = await classify("https://panel.test/live/ch.m3u8")

        #expect(verdict != .hevcInMPEGTS)
    }

    @Test("an unreachable key leaves the source unjudged and costs no media byte")
    func missingKeyStaysInconclusive() async throws {
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 1, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="/key/abc""#)
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg1.ts"] = try #require(
            Self.encrypt(Self.transportStream(streamType: 0x24, packets: 3), iv: Self.sequenceIV(1)))

        let verdict = await classify("https://panel.test/live/ch.m3u8")

        #expect(verdict == .inconclusive)
        #expect(Issue1089URLProtocol.headersByURL["https://panel.test/hls/seg1.ts"] == nil)
    }

    @Test("a key that is not 16 bytes is refused")
    func oversizedKeyStaysInconclusive() async throws {
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 1, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="/key/abc""#)
        Issue1089URLProtocol.bodyByURL["https://panel.test/key/abc"] = Data(repeating: 1, count: 32)
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg1.ts"] = try #require(
            Self.encrypt(Self.transportStream(streamType: 0x24, packets: 3), iv: Self.sequenceIV(1)))

        #expect(await classify("https://panel.test/live/ch.m3u8") == .inconclusive)
    }

    @Test("an encrypted sub-range segment stays unjudged, since its cipher starts at its own offset")
    func encryptedByteRangeStaysInconclusive() async throws {
        let url = try #require(URL(string: "https://panel.test/live/ch.m3u8"))
        Issue1089URLProtocol.bodyByURL[url.absoluteString] = Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-KEY:METHOD=AES-128,URI="/key/abc"
        #EXT-X-BYTERANGE:1000@5000
        #EXTINF:10.0,
        /hls/all.ts
        """.utf8)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: url, httpHeaders: [:], advertisesFragmentedMP4OnlyVideo: false, session: session)

        #expect(evidence == .settled(.inconclusive))
    }

    @Test("the key request carries the host's headers on the playlist's origin only")
    func keyHeadersAreScoped() async throws {
        Issue1089URLProtocol.bodyByURL["https://panel.test/live/ch.m3u8"] = Self.playlist(
            sequence: 1, keyTag: #"#EXT-X-KEY:METHOD=AES-128,URI="https://keys.other.test/k""#)
        Issue1089URLProtocol.bodyByURL["https://keys.other.test/k"] = Self.key
        Issue1089URLProtocol.bodyByURL["https://panel.test/hls/seg1.ts"] = try #require(
            Self.encrypt(Self.transportStream(streamType: 0x24, packets: 3), iv: Self.sequenceIV(1)))

        let verdict = await classify("https://panel.test/live/ch.m3u8", headers: ["Authorization": "Bearer t"])

        #expect(verdict == .hevcInMPEGTS)
        #expect(Issue1089URLProtocol.headersByURL["https://panel.test/live/ch.m3u8"]?["Authorization"] == "Bearer t")
        #expect(Issue1089URLProtocol.headersByURL["https://keys.other.test/k"]?["Authorization"] == nil)
    }

    // MARK: - Fixtures

    private func classify(
        _ playlist: String, headers: [String: String] = [:]
    ) async -> MPEGTransportStreamCodecProbe.Verdict {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        return await HLSCarriageProbe.classifyLiveCarriage(
            playlistURL: URL(string: playlist)!, httpHeaders: headers, session: session)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue1089URLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The reporter's shape: a media playlist straight from the panel, no master, no CODECS.
    private static func playlist(sequence: Int, keyTag: String) -> Data {
        Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:\(sequence)
        \(keyTag)
        #EXTINF:10.0,
        /hls/seg\(sequence).ts
        """.utf8)
    }

    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        withUnsafeBytes(of: UInt64(sequence).bigEndian) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    /// PAT plus a PMT declaring one video stream, then null packets to `packets`.
    private static func transportStream(streamType: UInt8, packets: Int) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * max(3, packets))
        for packet in 0..<max(3, packets) {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
            if packet >= 3 {
                bytes[packet * 188 + 1] = 0x1F
                bytes[packet * 188 + 2] = 0xFF
            }
        }
        let pmt: [UInt8] = [0x40, 0x64, 0x10, 0, 0x02, 0xB0, 18, 0, 1, 0xC1, 0, 0, 0xE1, 0, 0xF0, 0,
                            streamType, 0xE1, 1, 0xF0, 0]
        bytes.replaceSubrange(1..<(1 + pmt.count), with: pmt)
        return Data(bytes)
    }

    private static func encrypt(_ plaintext: Data, iv: Data) -> Data? {
        let capacity = plaintext.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var written = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, kCCKeySizeAES128, ivBuf.baseAddress,
                                inBuf.baseAddress, plaintext.count, outBuf.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return out.prefix(written)
    }
}

final class Issue1089URLProtocol: URLProtocol, @unchecked Sendable {
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
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
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
