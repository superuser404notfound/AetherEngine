import Foundation
import XCTest
@testable import AetherEngine

final class HLSIngestDiagnosticsTests: XCTestCase {
    func testAllCasesPreserveHistoricalNSErrorCodesAndPlaybackErrorInfo() {
        // Codes produced by Swift's implicit bridging at upstream 834f5fd4, before CustomNSError.
        let cases: [(HLSIngestError, Int, HLSIngestDiagnosticReason)] = [
            (.playlistUnreachable(status: 403), 0, .httpResponseRefused),
            (.playlistInvalid(reason: "no segments"), 1, .noSegments),
            (.segmentDecryptFailed(reason: "AES-128-CBC failed"), 2, .decryptionFailed),
            (.encryptedNotSupported, 3, .encryptionUnsupported),
            (.unsupportedSegmentFormat, 4, .segmentFormatUnsupported),
            (.ingestStalled, 5, .ingestStalled),
            (.demuxedAudioNotSupported, 6, .demuxedAudioUnsupported)
        ]
        for (error, code, reason) in cases {
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, "AetherEngine.HLSIngestError")
            XCTAssertEqual(bridged.code, code, "Historical code changed for \(error)")
            XCTAssertEqual(bridged.localizedDescription, error.description)
            XCTAssertEqual(bridged.userInfo[HLSIngestDiagnosticReason.userInfoKey] as? String, reason.rawValue)

            let info = PlaybackErrorInfo(kind: .hlsIngestFailed, message: "HLS ingest failed", underlying: bridged)
            XCTAssertEqual(info.underlyingDomain, "AetherEngine.HLSIngestError")
            XCTAssertEqual(info.underlyingCode, code)
            XCTAssertEqual(info.hlsDiagnosticReason, reason)
        }
    }

    func testPlaylistSubreasonsSurviveNSErrorWithoutChangingTheExistingCode() {
        let cases: [(String, HLSIngestDiagnosticReason)] = [
            ("missing #EXTM3U", .missingEXTM3U),
            ("missing TARGETDURATION", .missingTargetDuration),
            ("no segments", .noSegments),
            ("master playlist without variants", .noVariants),
            ("no usable variant", .noUsableVariant),
            ("selected variant is not a media playlist", .expectedMediaPlaylist),
            ("expected media playlist on refresh", .expectedMediaPlaylist),
            ("finite VOD requires EXT-X-ENDLIST", .missingEndList),
            ("unresolvable segment URI", .invalidSegmentURI),
            ("media sequence out of range", .invalidMediaSequence),
            ("TARGETDURATION out of range", .invalidTargetDuration),
            ("EXTINF out of range", .invalidSegmentDuration),
            ("segment duration must be positive", .invalidSegmentDuration),
            ("program duration exceeds 1.0s", .durationLimitExceeded),
            ("playlist exceeds 10 bytes", .playlistSizeLimitExceeded),
            ("playlist line exceeds 10 bytes", .playlistLineLimitExceeded),
            ("segment exceeds 10 bytes", .bodySizeLimitExceeded),
            ("segment body over its limit", .bodySizeLimitExceeded),
            ("body exceeds 10 bytes", .bodySizeLimitExceeded),
            ("non-UTF8 playlist", .invalidPlaylistEncoding),
            ("playlist is not bounded UTF-8", .invalidPlaylistEncoding),
            ("https://private.invalid/password?token=secret", .playlistInvalid)
        ]
        for (text, reason) in cases {
            let error = HLSIngestError.playlistInvalid(reason: text)
            let bridged = error as NSError
            XCTAssertEqual(bridged.code, 1)
            XCTAssertEqual(bridged.domain, HLSIngestError.errorDomain)
            XCTAssertEqual(error.diagnosticReason, reason)
            XCTAssertEqual(bridged.userInfo[HLSIngestDiagnosticReason.userInfoKey] as? String, reason.rawValue)
            let wrapper = NSError(domain: "AetherEngine.DemuxerError", code: 1,
                                  userInfo: [NSUnderlyingErrorKey: bridged])
            let info = PlaybackErrorInfo(kind: .customSourceProbeFailed, message: "private", underlying: wrapper)
            XCTAssertEqual(info.hlsDiagnosticReason, reason)
            XCTAssertEqual(info.underlyingDomain, wrapper.domain)
            XCTAssertEqual(info.underlyingCode, wrapper.code)
        }
    }

    func testParserRetainsTheSpecificMalformedPlaylistCause() {
        let cases: [(String, HLSIngestDiagnosticReason)] = [
            ("<html>private credentials</html>", .missingEXTM3U),
            ("#EXTM3U\n#EXTINF:4,\nsegment.ts", .missingTargetDuration),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:4", .noSegments),
            ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1", .noVariants),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:inf\n#EXTINF:4,\nsegment.ts", .invalidTargetDuration),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:nan,\nsegment.ts", .invalidSegmentDuration)
        ]
        for (body, reason) in cases {
            XCTAssertThrowsError(try HLSPlaylistParser.parse(body)) { error in
                XCTAssertEqual(HLSIngestDiagnosticReason.preserved(in: error), reason)
            }
        }
    }

    func testResponseEncryptionAndSegmentReasonsAreFinite() {
        let cases: [(HLSIngestError, HLSIngestDiagnosticReason, Int)] = [
            (.playlistUnreachable(status: -1), .invalidResponse, 0),
            (.playlistUnreachable(status: 403), .httpResponseRefused, 0),
            (.encryptedNotSupported, .encryptionUnsupported, 3),
            (.segmentDecryptFailed(reason: "unresolvable key URI"), .invalidKeyURI, 2),
            (.segmentDecryptFailed(reason: "key length 8 != 16"), .invalidKeyLength, 2),
            (.segmentDecryptFailed(reason: "key length is not 16 bytes"), .invalidKeyLength, 2),
            (.segmentDecryptFailed(reason: "key exceeds 64 bytes"), .keySizeLimitExceeded, 2),
            (.segmentDecryptFailed(reason: "https://private.invalid/token"), .decryptionFailed, 2),
            (.unsupportedSegmentFormat, .segmentFormatUnsupported, 4),
            (.ingestStalled, .ingestStalled, 5),
            (.demuxedAudioNotSupported, .demuxedAudioUnsupported, 6)
        ]
        for (error, reason, code) in cases {
            XCTAssertEqual(error.diagnosticReason, reason)
            XCTAssertEqual((error as NSError).code, code)
        }
    }

    func testUntrustedReasonMetadataIsRejectedAndTraversalIsBounded() {
        let privateMetadata = [HLSIngestDiagnosticReason.userInfoKey: "https://private.invalid/password"]
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: NSError(
            domain: HLSIngestError.errorDomain, code: 1, userInfo: privateMetadata)))
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: NSError(
            domain: "unrelated.domain", code: 2,
            userInfo: [HLSIngestDiagnosticReason.userInfoKey: "no_segments"])))
        var wrapped: NSError = HLSIngestError.playlistInvalid(reason: "no segments") as NSError
        for _ in 0..<6 {
            wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: wrapped])
        }
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: wrapped), "Traversal must have a fixed bound")
    }
    func testEverySourceReasonLiteralHasASpecificDiagnosticMapping() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"HLSIngestError\.(playlistInvalid|segmentDecryptFailed)\(reason:\s*"((?:\\.|[^"\\])*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var count = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let ns = source as NSString
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                count += 1
                let kind = ns.substring(with: match.range(at: 1))
                let literal = ns.substring(with: match.range(at: 2))
                let reasons: [String]
                if literal == #"\(tag) out of range"# {
                    // Expand the parser's dynamic tag from its actual call sites, not a duplicate list.
                    let tags = try NSRegularExpression(pattern: #"tag:\s*"([^"]+)""#)
                    reasons = tags.matches(in: source, range: NSRange(location: 0, length: ns.length))
                        .map { ns.substring(with: $0.range(at: 1)) + " out of range" }
                    XCTAssertFalse(reasons.isEmpty)
                } else {
                    reasons = [interpolation.stringByReplacingMatches(in: literal,
                        range: NSRange(location: 0, length: (literal as NSString).length), withTemplate: "1")]
                }
                for reason in reasons {
                    let error: HLSIngestError = kind == "playlistInvalid"
                        ? .playlistInvalid(reason: reason) : .segmentDecryptFailed(reason: reason)
                    XCTAssertNotEqual(error.diagnosticReason, .playlistInvalid, "Unmapped reason at \(file.lastPathComponent): \(literal)")
                    if error.diagnosticReason == .decryptionFailed {
                        // This is a real decrypt failure, whereas an unknown key error would hit the same fallback.
                        XCTAssertEqual(reason, "AES-128-CBC failed", "Unmapped decrypt reason at \(file.lastPathComponent): \(literal)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(count, 0, "Source scan must exercise real throw sites")
    }

}
