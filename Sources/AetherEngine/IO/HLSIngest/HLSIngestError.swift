import Foundation

/// Finite diagnostics only; payload strings and playlist contents never become telemetry.
public enum HLSIngestDiagnosticReason: String, Sendable, CaseIterable {
    case missingEXTM3U = "missing_extm3u"
    case missingTargetDuration = "missing_target_duration"
    case noSegments = "no_segments"
    case noVariants = "no_variants"
    case noUsableVariant = "no_usable_variant"
    case expectedMediaPlaylist = "expected_media_playlist"
    case missingEndList = "missing_endlist"
    case invalidSegmentURI = "invalid_segment_uri"
    case invalidMediaSequence = "invalid_media_sequence"
    case invalidTargetDuration = "invalid_target_duration"
    case invalidSegmentDuration = "invalid_segment_duration"
    case durationLimitExceeded = "duration_limit_exceeded"
    case playlistSizeLimitExceeded = "playlist_size_limit_exceeded"
    case playlistLineLimitExceeded = "playlist_line_limit_exceeded"
    case bodySizeLimitExceeded = "body_size_limit_exceeded"
    case invalidPlaylistEncoding = "invalid_playlist_encoding"
    case invalidResponse = "invalid_response"
    case httpResponseRefused = "http_response_refused"
    case playlistInvalid = "playlist_invalid_other"
    case encryptionUnsupported = "encryption_unsupported"
    case invalidKeyURI = "invalid_key_uri"
    case invalidKeyLength = "invalid_key_length"
    case keySizeLimitExceeded = "key_size_limit_exceeded"
    case decryptionFailed = "decryption_failed"
    case segmentFormatUnsupported = "segment_format_unsupported"
    case ingestStalled = "ingest_stalled"
    case demuxedAudioUnsupported = "demuxed_audio_unsupported"

    static let userInfoKey = "AetherHLSDiagnosticReason"

    /// Inspect only this SDK's domain/key and accept only known values, even through NSError wrappers.
    static func preserved(in error: Error?) -> Self? {
        var next = error as NSError?
        for _ in 0..<6 {
            guard let current = next else { break }
            if current.domain == HLSIngestError.errorDomain,
               let code = current.userInfo[userInfoKey] as? String,
               let reason = Self(rawValue: code) { return reason }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

/// Terminal errors from the HLS ingest. Hosts choose recovery or fallback from the failure kind;
/// a malformed playlist or a transport failure does not establish a format incompatibility.
public enum HLSIngestError: Error, Equatable, CustomStringConvertible, LocalizedError, CustomNSError {
    /// An HLS request was refused: the status may belong to a playlist, segment or AES key.
    /// The historical case name and NSError code are retained for source compatibility.
    case playlistUnreachable(status: Int)
    case playlistInvalid(reason: String)
    /// SAMPLE-AES / SAMPLE-AES-CTR, or AES-128 tag with no URI. Plain AES-128 clear-key is handled by `HLSSegmentDecryptor`.
    case encryptedNotSupported
    /// AES-128 key fetch failed or CommonCrypto rejected key/IV/ciphertext. Falls back rather than feeding ciphertext to the demuxer.
    case segmentDecryptFailed(reason: String)
    /// EXT-X-MAP present, or first segment is not TS (main) or TS/packed-audio (companion). fMP4-segment HLS is a later phase.
    case unsupportedSegmentFormat
    case ingestStalled
    /// Demuxed-audio rendition in a shape the ingest cannot handle: unresolvable URI, packed audio without a parsable PRIV timestamp (ARD-style, device repro: Das Erste HD), or no program-clock anchor to align audio without risking silent A/V desync.
    case demuxedAudioNotSupported

    public var description: String {
        switch self {
        case .playlistUnreachable(let status): "playlistUnreachable(\(status))"
        case .playlistInvalid(let reason): "playlistInvalid(\(reason))"
        case .encryptedNotSupported: "encryptedNotSupported"
        case .segmentDecryptFailed(let reason): "segmentDecryptFailed(\(reason))"
        case .unsupportedSegmentFormat: "unsupportedSegmentFormat"
        case .ingestStalled: "ingestStalled"
        case .demuxedAudioNotSupported: "demuxedAudioNotSupported"
        }
    }

    /// AE#283: without this, `localizedDescription` at the load boundary collapses every case to
    /// "The operation couldn't be completed. (HLSIngestError error 0.)" and the HTTP status the
    /// reader already resolved is lost.
    public var errorDescription: String? { description }

    public static var errorDomain: String { "AetherEngine.HLSIngestError" }
    // Preserve Swift's implicit NSError codes from before CustomNSError conformance.
    public var errorCode: Int {
        switch self {
        case .playlistUnreachable: 0
        case .playlistInvalid: 1
        case .segmentDecryptFailed: 2
        case .encryptedNotSupported: 3
        case .unsupportedSegmentFormat: 4
        case .ingestStalled: 5
        case .demuxedAudioNotSupported: 6
        }
    }
    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: description,
         HLSIngestDiagnosticReason.userInfoKey: diagnosticReason.rawValue]
    }

    /// Keep the existing error codes and messages intact: this field never selects playback policy.
    public var diagnosticReason: HLSIngestDiagnosticReason {
        switch self {
        case .playlistUnreachable(let status):
            return (100...599).contains(status) ? .httpResponseRefused : .invalidResponse
        case .playlistInvalid(let reason):
            switch reason {
            case "missing #EXTM3U": return .missingEXTM3U
            case "missing TARGETDURATION": return .missingTargetDuration
            case "no segments": return .noSegments
            case "master playlist without variants": return .noVariants
            case "no usable variant": return .noUsableVariant
            case "selected variant is not a media playlist", "expected media playlist on refresh":
                return .expectedMediaPlaylist
            case "finite VOD requires EXT-X-ENDLIST": return .missingEndList
            case "unresolvable segment URI": return .invalidSegmentURI
            case "media sequence out of range": return .invalidMediaSequence
            case "TARGETDURATION out of range": return .invalidTargetDuration
            case "EXTINF out of range", "segment duration must be positive": return .invalidSegmentDuration
            case "non-UTF8 playlist", "playlist is not bounded UTF-8", "rendition payload is not UTF-8": return .invalidPlaylistEncoding
            default:
                if reason.hasPrefix("playlist line exceeds ") { return .playlistLineLimitExceeded }
                if reason.hasPrefix("playlist exceeds ") { return .playlistSizeLimitExceeded }
                if reason == "segment body over its limit" || reason.hasPrefix("segment exceeds ") || reason.hasPrefix("body exceeds ") {
                    return .bodySizeLimitExceeded
                }
                if reason.hasPrefix("program duration exceeds ") { return .durationLimitExceeded }
                return .playlistInvalid
            }
        case .encryptedNotSupported: return .encryptionUnsupported
        case .segmentDecryptFailed(let reason):
            if reason == "unresolvable key URI" { return .invalidKeyURI }
            if reason.hasPrefix("key length ") { return .invalidKeyLength }
            if reason.hasPrefix("key exceeds ") { return .keySizeLimitExceeded }
            return .decryptionFailed
        case .unsupportedSegmentFormat: return .segmentFormatUnsupported
        case .ingestStalled: return .ingestStalled
        case .demuxedAudioNotSupported: return .demuxedAudioUnsupported
        }
    }
}
