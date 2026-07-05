import XCTest
import Libavcodec
import Libavutil
@testable import AetherEngine

/// #104: the subtitle side demuxer must set `AVDISCARD_ALL` on video/audio so it does not pull the whole
/// program byte-for-byte through a second connection just to reach the sparse mov_text samples (OOM on a
/// file with many subtitle tracks, RSS growing with playback position). Both `runNativeSubtitleReaders`
/// (native rendition) and `runEmbeddedSubtitleReader` (host overlay) rely on `discardAllStreamsExcept`.
///
/// This exercises the mechanism through the real FFmpeg mov demuxer: with the discard applied, mov skips
/// `avio_seek`/`av_get_packet` for the discarded samples and never returns them (`mov_read_packet` line
/// `if (st->discard != AVDISCARD_ALL ...)` guards the read; `if (st->discard == AVDISCARD_ALL) goto retry`
/// drops the return). So "no video packet is returned" is the same code branch that skips the byte read.
///
/// Fixture: a 4.5 KB MP4, h264 video (150 samples) + sparse mov_text subtitles (3 cues + 3 clear samples).
/// Regenerate:
///   ffmpeg -f lavfi -i "color=c=red:s=128x96:r=10:d=15" -c:v libx264 -preset ultrafast \
///     -tune zerolatency -pix_fmt yuv420p -x264-params keyint=30 vonly.mp4
///   printf '1\n00:00:01,000 --> 00:00:03,000\nAAA\n\n2\n00:00:08,000 --> 00:00:10,000\nBBB\n\n3\n00:00:13,000 --> 00:00:14,500\nCCC\n' > subs.srt
///   ffmpeg -i vonly.mp4 -i subs.srt -map 0:v -map 1 -c:v copy -c:s mov_text -movflags +faststart vsub.mp4
///   base64 -i vsub.mp4
final class Issue104SubtitleDiscardTests: XCTestCase {

    private func makeDemuxer() throws -> Demuxer {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    /// Drain the demuxer to EOF, returning the stream index of every packet av_read_frame handed back.
    private func drainStreamIndices(_ demuxer: Demuxer) -> [Int32] {
        var indices: [Int32] = []
        while let pkt = try? demuxer.readPacket() {
            indices.append(pkt.pointee.stream_index)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return indices
    }

    func test_discardAllStreamsExcept_skipsVideoOnTheSubtitleSideDemuxer() throws {
        // Control: without the discard, the side demuxer walks and returns the whole video track (this is
        // the #104 leak, every one of those samples was a byte-for-byte read through a second connection).
        // Seek before draining exactly like the real readers do (native line 1062 / overlay line 357): the
        // seek flushes libavformat's find_stream_info read-ahead buffer so the drain reflects the read loop.
        let control = try makeDemuxer()
        defer { control.close() }
        let subtitleIndex = try XCTUnwrap(control.subtitleTrackInfos().first).id
        let videoIndex = control.videoStreamIndex
        control.seek(to: 0)
        let controlIndices = drainStreamIndices(control)
        let controlVideo = controlIndices.filter { $0 == videoIndex }.count
        let controlSubtitles = controlIndices.filter { $0 == Int32(subtitleIndex) }.count
        XCTAssertGreaterThan(controlVideo, 0, "fixture must carry video samples for the discard to skip")
        XCTAssertGreaterThan(controlSubtitles, 0, "fixture must carry subtitle cues to keep")

        // With the discard: mov must return only subtitle packets. No video packet returned means no
        // avio_seek/av_get_packet ran for the video samples, so the whole program is never streamed. The
        // seek must come before discard is applied (matches the readers) so the pre-discard find_stream_info
        // read-ahead is flushed; otherwise one already-buffered video packet leaks through.
        let discarded = try makeDemuxer()
        defer { discarded.close() }
        discarded.seek(to: 0)
        discarded.discardAllStreamsExcept([Int32(subtitleIndex)])
        let discardIndices = drainStreamIndices(discarded)

        XCTAssertTrue(discardIndices.allSatisfy { $0 == Int32(subtitleIndex) },
                      "side demuxer returned a non-subtitle packet: \(discardIndices)")
        XCTAssertTrue(discardIndices.filter { $0 == videoIndex }.isEmpty,
                      "video samples were still pulled through the side demuxer")
        XCTAssertEqual(discardIndices.count, controlSubtitles,
                       "every subtitle cue must still be delivered after the discard")
    }

    private static let fixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAgfbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAOpgAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAA
        BPV0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAOpgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAIAAAABgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAADqYAAAAAAABAAAAAARtbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAAoAAACWABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAEGG1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAA9hzdGJsAAAAuHN0c2QA
        AAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAIAAYABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDEgbGli
        eDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAF2dCwAraCDbARAAAAwAEAAADAFI8SJqAAQAEaM4PyAAAABBwYXNwAAAA
        AQAAAAEAAAAUYnRydAAAAAAAAATmAAAE5gAAABhzdHRzAAAAAAAAAAEAAACWAAAEAAAAACRzdHNzAAAAAAAAAAUAAAABAAAAHwAA
        AD0AAABbAAAAeQAAAExzdHNjAAAAAAAAAAUAAAABAAAAAQAAAAEAAAACAAAACgAAAAEAAAADAAAARgAAAAEAAAAEAAAAMgAAAAEA
        AAAFAAAAEwAAAAEAAAJsc3RzegAAAAAAAAAAAAAAlgAAApIAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAK
        AAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAA
        CgAAAD0AAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAA
        AAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAD0AAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA
        AAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAK
        AAAACgAAAAoAAAAKAAAACgAAAD0AAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAA
        CgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAD0AAAAKAAAACgAA
        AAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA
        AAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAACRzdGNvAAAAAAAAAAUAAAhPAAAK4wAAC0wAAA51AAAQ1gAAAlR0cmFr
        AAAAXHRraGQAAAADAAAAAAAAAAAAAAACAAAAAAAAOKQAAAAAAAAAAAAAAAMAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAA
        AAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAADikAAAAAAABAAAAAAHMbWRpYQAAACBtZGhkAAAAAAAA
        AAAAAAAAAA9CQADdQKBVxAAAAAAAMGhkbHIAAAAAAAAAAHNidGwAAAAAAAAAAAAAAABTdWJ0aXRsZUhhbmRsZXIAAAABdG1pbmYA
        AAAMbm1oZAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAE8c3RibAAAAGRzdHNkAAAAAAAAAAEAAABU
        dHgzZwAAAAAAAAABAAAAAAH/AAAA/wAAAAAAAAAAAAAAAAABABD/////AAAAEmZ0YWIAAQABBUFyaWFsAAAAFGJ0cnQAAAAAAAAA
        DAAAAAwAAABIc3R0cwAAAAAAAAAHAAAAAQAPQkAAAAABAB6EgAAAAAEATEtAAAAAAQAehIAAAAABAC3GwAAAAAEAFuNgAAAAAQAA
        AAAAAAA0c3RzYwAAAAAAAAADAAAAAQAAAAEAAAABAAAAAwAAAAIAAAABAAAABQAAAAEAAAABAAAAMHN0c3oAAAAAAAAAAAAAAAcA
        AAACAAAABQAAAAIAAAAFAAAAAgAAAAUAAAACAAAAJHN0Y28AAAAAAAAABQAACuEAAAtHAAAObgAAEM8AABGUAAAAYnVkdGEAAABa
        bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExh
        dmY2Mi4xMi4xMDEAAAAIZnJlZQAACU9tZGF0AAACUgYF//9O3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBi
        MzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
        b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3Vi
        bWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4
        eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29r
        YWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0
        PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0zMCBrZXlpbnRfbWluPTMgc2NlbmVjdXQ9
        MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0
        ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAADhliIQ6EYoAAhjxwABA9jgACHlJycnJycnJ1111111111111111111111111111
        1111111111114AAAAAAABkGaID6BjAAAAAZBmkA+gYwAAAAGQZpgEKBjAAAABkGagBCgYwAAAAZBmqAQoGMAAAAGQZrAEKBjAAAA
        BkGa4BCgYwAAAAZBmwAQoGMAAAAGQZsgEKBjAAAABkGbQBCgYwADQUFBAAAABkGbYBCgYwAAAAZBm4AQoGMAAAAGQZugEKBjAAAA
        BkGbwBCgYwAAAAZBm+AQoGMAAAAGQZoAEKBjAAAABkGaIBCgYwAAAAZBmkAQoGMAAAAGQZpgEKBjAAAABkGagBCgYwAAAAZBmqAQ
        oGMAAAAGQZrAEKBjAAAABkGa4BCgYwAAAAZBmwAQoGMAAAAGQZsgEKBjAAAABkGbQBCgYwAAAAZBm2AQoGMAAAAGQZuAEKBjAAAA
        BkGboBCgYwAAADlliIIBOhGKAAK38cAASOY4AAtrScnJycnJyddddddddddddddddddddddddddddddddddddddddeAAAAAGQZog
        PoGMAAAABkGaQD6BjAAAAAZBmmAQoGMAAAAGQZqAEKBjAAAABkGaoBCgYwAAAAZBmsAQoGMAAAAGQZrgEKBjAAAABkGbABCgYwAA
        AAZBmyAQoGMAAAAGQZtAEKBjAAAABkGbYBCgYwAAAAZBm4AQoGMAAAAGQZugEKBjAAAABkGbwBCgYwAAAAZBm+AQoGMAAAAGQZoA
        EKBjAAAABkGaIBCgYwAAAAZBmkAQoGMAAAAGQZpgEKBjAAAABkGagBCgYwAAAAZBmqAQoGMAAAAGQZrAEKBjAAAABkGa4BCgYwAA
        AAZBmwAQoGMAAAAGQZsgEKBjAAAABkGbQBCgYwAAAAZBm2AQoGMAAAAGQZuAEKBjAAAABkGboBCgYwAAADlliIQE6EYoAArfxwAB
        I5jgAC2tJycnJycnJ11111111111111111111111111111111111111114AAAAAGQZogPoGMAAAABkGaQD6BjAAAAAZBmmAQoGMA
        AAAGQZqAEKBjAAAABkGaoBCgYwAAAAZBmsAQoGMAAAAGQZrgEKBjAAAABkGbABCgYwAAAAZBmyAQoGMAAAAGQZtAEKBjAAAABkGb
        YBCgYwAAAAZBm4AQoGMAAAAGQZugEKBjAAAABkGbwBCgYwAAAAZBm+AQoGMAAAAGQZoAEKBjAAAABkGaIBCgYwAAAAZBmkAQoGMA
        AAAGQZpgEKBjAAAABkGagBCgYwAAAANCQkIAAAAGQZqgEKBjAAAABkGawBCgYwAAAAZBmuAQoGMAAAAGQZsAEKBjAAAABkGbIBCg
        YwAAAAZBm0AQoGMAAAAGQZtgEKBjAAAABkGbgBCgYwAAAAZBm6AQoGMAAAA5ZYiCAToRigACt/HAAEjmOAALa0nJycnJycnXXXXX
        XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgAAAABkGaID6BjAAAAAZBmkA+gYwAAAAGQZpgEKBjAAAABkGagBCgYwAAAAZBmqAQ
        oGMAAAAGQZrAEKBjAAAABkGa4BCgYwAAAAZBmwAQoGMAAAAGQZsgEKBjAAAABkGbQBCgYwAAAAZBm2AQoGMAAAAGQZuAEKBjAAAA
        BkGboBCgYwAAAAZBm8AQoGMAAAAGQZvgEKBjAAAABkGaABCgYwAAAAZBmiAQoGMAAAAGQZpAEKBjAAAABkGaYBCgYwAAAAZBmoAQ
        oGMAAAAGQZqgEKBjAAAABkGawBCgYwAAAAZBmuAQoGMAAAAGQZsAEKBjAAAABkGbIBCgYwAAAAZBm0AQoGMAAAAGQZtgEKBjAAAA
        BkGbgBCgYwAAAAZBm6AQoGMAAAA5ZYiEBOhGKAAK38cAASOY4AAtrScnJycnJydddddddddddddddddddddddddddddddddddddd
        ddeAAAAABkGaID6BjAAAAAZBmkA+gYwAAAAGQZpgEKBjAAAABkGagBCgYwAAAAZBmqAQoGMAAAAGQZrAEKBjAAAABkGa4BCgYwAA
        AAZBmwAQoGMAAAAGQZsgEKBjAAAABkGbQBCgYwAAAANDQ0MAAAAGQZtgEKBjAAAABkGbgBCgYwAAAAZBm6AQoGMAAAAGQZvAEKBj
        AAAABkGb4BCgYwAAAAZBmgAQoGMAAAAGQZogEKBjAAAABkGaQBCgYwAAAAZBmmAQoGMAAAAGQZqAEKBjAAAABkGaoBCgYwAAAAZB
        msAQoGMAAAAGQZrgEKBjAAAABkGbABCgYwAAAAZBmyAQoGMAAAAGQZtAEKBjAAAABkGbYBCgYwAAAAZBm4AQoGMAAAAGQZugEKBj
        AAA=
        """
}
