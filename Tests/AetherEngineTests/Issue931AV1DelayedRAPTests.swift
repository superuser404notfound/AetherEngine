import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#931: an AV1 Matroska file built on forward key frames opens every GOP with a Temporal Unit
/// holding a Sequence Header and a HIDDEN Key Frame that refreshes all eight reference slots.
/// Decoding can start there, but stock FFmpeg flagged none of them (av1_parser only reports a shown
/// Key Frame and replaces the block flag with that verdict, and muxers leave the flag off), so the
/// loopback producer waited for a keyframe that never came and wrote zero packets, and the first
/// seek on the software path failed with "could not reposition". FFmpegBuild carries the fix
/// (`patch_ffmpeg_av1_delayed_rap`, FFmpeg PR 25607); this pins it through the engine's Demuxer.
///
/// The fixture is one Temporal Unit from a libaom encode of `testsrc2` (`--enable-fwd-kf`) with its
/// `refresh_frame_flags` set to 0xFF, muxed by lavf without a keyframe flag: the reporting file's
/// layout, with nothing of its content.
@Suite("AE#931 AV1 delayed random access points")
struct Issue931AV1DelayedRAPTests {

    private static let fixture = """
        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
        """

    @Test("the hidden full-refresh key frame arrives flagged, and the source repositions")
    func delayedRandomAccessPointIsKeyframe() throws {
        let data = try #require(Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae931-\(UUID().uuidString).mkv")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        #expect(videoIndex >= 0)

        let first = try #require(try demuxer.readPacket())
        defer { var p: UnsafeMutablePointer<AVPacket>? = first; trackedPacketFree(&p) }
        #expect(first.pointee.stream_index == videoIndex)
        #expect(first.pointee.flags & AV_PKT_FLAG_KEY != 0, "the producer gate opens on this packet")
        #expect(demuxer.seek(to: 0), "matroskadec indexed the block")
    }
}
