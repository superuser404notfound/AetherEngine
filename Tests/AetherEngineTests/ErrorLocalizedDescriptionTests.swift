import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// AE#283: the load path publishes its terminal state as `state = .error("Failed to load: \(error.localizedDescription)")`
/// (and the reload / track-switch / playback boundaries do the same). For a Swift error that is only
/// `CustomStringConvertible`, `localizedDescription` does not reach `description`; Foundation's bridge
/// answers "The operation couldn't be completed. (HLSIngestError error 0.)" instead, so an origin refusing
/// a transcode with HTTP 500 became indistinguishable from a corrupt file.
///
/// The fix is `LocalizedError` conformance on the error types, not `\(error)` at the call sites: that keeps
/// `localizedDescription` genuinely correct for Foundation errors (URLError etc.) while making the engine's
/// own enums render what they already compute. These tests pin the invariant for every engine error type,
/// so a new one added without conformance fails here rather than in a user's error banner.
struct ErrorLocalizedDescriptionTests {

    /// The reported case, verbatim: the status the reader resolved must survive to the state string.
    @Test("Ingest playlist status survives localizedDescription")
    func ingestStatusSurvives() {
        let error = HLSIngestError.playlistUnreachable(status: 500)
        #expect(error.localizedDescription == "playlistUnreachable(500)")
        #expect((error as Error).localizedDescription == "playlistUnreachable(500)")
        #expect("Failed to load: \(error.localizedDescription)" == "Failed to load: playlistUnreachable(500)")
    }

    /// The pre-fix rendering, spelled out so the regression is unmistakable if conformance is ever dropped.
    @Test("No engine error renders Foundation's generic bridge text")
    func noGenericBridgeText() {
        for error in Self.allEngineErrors {
            let localized = (error as Error).localizedDescription
            #expect(
                !localized.contains("The operation couldn"),
                "\(type(of: error)) fell through to Foundation's generic bridge: \(localized)"
            )
        }
    }

    /// `description` is what the engine's log lines and `EngineLog.emit("\(error)")` already show. The
    /// state string must not be a second, poorer rendering of the same error.
    @Test("localizedDescription matches description for every engine error")
    func localizedMatchesDescription() {
        for error in Self.allEngineErrors {
            let described = String(describing: error)
            #expect(
                (error as Error).localizedDescription == described,
                "\(type(of: error)): localizedDescription '\((error as Error).localizedDescription)' != description '\(described)'"
            )
        }
    }

    /// The payloads that carry the diagnosis (status, errno, AVERROR code, stream index) must appear in
    /// the rendered text. A conformance that returned a case name alone would pass the two tests above.
    @Test("Diagnostic payloads reach the rendered text")
    func payloadsReachText() {
        #expect((HLSIngestError.segmentDecryptFailed(reason: "key length 8 != 16") as Error)
            .localizedDescription.contains("key length 8 != 16"))
        #expect((HLSLocalServerError.bind(errno: 48) as Error)
            .localizedDescription.contains("48"))
        #expect((SubtitleDecoderError.streamIndexNotSubtitle(index: 7) as Error)
            .localizedDescription.contains("7"))
        #expect((AudioTapHLSFetcher.FetchError.http(403) as Error)
            .localizedDescription.contains("403"))
        #expect((DiscError.directoryNotFound("VIDEO_TS") as Error)
            .localizedDescription.contains("VIDEO_TS"))
    }

    /// DemuxerError is the most common failure at the load boundary and carried no description at all.
    /// The AVERROR code is the whole diagnosis, so it must survive; libavutil's own text rides along.
    @Test("Demuxer AVERROR codes render with FFmpeg's text")
    func demuxerAVERRORText() {
        let invalidData = (DemuxerError.openFailed(code: FFmpegErr.invalidData) as Error).localizedDescription
        #expect(invalidData.contains("\(FFmpegErr.invalidData)"))
        #expect(invalidData.contains("Invalid data"))

        let eof = (DemuxerError.readFailed(code: FFmpegErr.eof) as Error).localizedDescription
        #expect(eof.contains("\(FFmpegErr.eof)"))
        #expect(eof.contains("End of file"))
    }

    /// A code libavutil has no string for still keeps the number rather than collapsing to empty.
    @Test("Unknown AVERROR codes keep the raw number")
    func unknownAVERRORKeepsNumber() {
        #expect(FFmpegErr.text(for: -1_234_567).contains("-1234567"))
    }

    // MARK: - Fixtures

    /// One representative case per engine error type. Every type reachable from a `throws` entry point
    /// belongs here; the payload cases are preferred because they are the ones that lose information.
    private static let allEngineErrors: [any Error] = [
        HLSIngestError.playlistUnreachable(status: 500),
        HLSIngestError.playlistInvalid(reason: "missing #EXTM3U"),
        HLSIngestError.demuxedAudioNotSupported,
        AVIOReaderError.hlsPlaylistOnVODPath,
        AVIOReaderError.requestTimeout,
        HLSLocalServerError.bind(errno: 48),
        MP4SegmentMuxer.MuxerError.openStagingFileFailed(errno: 2),
        AudioBridge.AudioBridgeError.encoderNotFound(codecID: AV_CODEC_ID_EAC3),
        DemuxerError.openFailed(code: FFmpegErr.invalidData),
        DemuxerError.streamInfoFailed(code: FFmpegErr.eof),
        DiscError.directoryNotFound("VIDEO_TS"),
        DiscError.malformed("PVD too short"),
        SubtitleDecoderError.streamIndexNotSubtitle(index: 7),
        SubtitleDecoderError.noSubtitleStream,
        FrameDecodeError.unsupportedCodec,
        AudioDecoderError.formatDescriptionFailed,
        AudioTapDecoder.TapDecoderError.openFailed,
        AudioTapHLSFetcher.FetchError.http(403),
        AudioTapHLSFetcher.FetchError.invalidPlaylist("no variants"),
        HLSVideoEngine.HLSVideoEngineError.unsupportedCodec(rawCodecID: 226),
        PacketTimingProbe.ProbeError.unknownProfile("bogus"),
        AudioTapProbe.ProbeError.wavWriteFailed("/tmp/out.wav"),
    ]
}
