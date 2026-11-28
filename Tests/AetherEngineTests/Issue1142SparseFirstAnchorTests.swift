import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// AE#1142 (axeslasher): on an MKV whose FIRST subtitle track is sparse, both side readers jumped to
/// that track's first cue instead of the playhead and parked there.
///
/// Since #234 the readers anchor their positioning seek on the lowest routed subtitle stream.
/// `matroska_read_seek` clamps the target up to the anchor's first index entry
/// (`timestamp = FFMAX(timestamp, index_entries[0].timestamp)`), so a forced track whose first cue
/// sits at 900 s turned a seek to 6 s into a seek to 900 s, and nothing in between was read. The
/// anchor now comes only from a routed stream whose index brackets the target.
struct Issue1142SparseFirstAnchorTests {

    /// Fixture: 15 s Matroska, gray 128x72 at 5 fps with a keyframe every second, a cluster per
    /// second, and two SubRip tracks. Stream 1 is the sparse "forced" track with cues at 10 s and
    /// 13 s, stream 2 the full track with a cue every second from 1 s to 14 s. Made with
    /// `ffmpeg -f lavfi -i color=c=gray:size=128x72:rate=5:duration=15 -i a.srt -i b.srt -map 0:v
    /// -map 1:s -map 2:s -c:v libx264 -preset ultrafast -g 5 -c:s srt -disposition:s:0 forced
    /// -cluster_time_limit 1000`.
    private static let sparse: Int32 = 1
    private static let full: Int32 = 2

    private static func makeDemuxer(prewarm: Bool = true) throws -> Demuxer {
        let data = try #require(Data(base64Encoded: fixtureBase64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        // The readers' cue-index prewarm: Matroska parses its Cues on the first seek.
        if prewarm { demuxer.seekBounded(to: demuxer.duration * 0.5, timeout: 5) }
        return demuxer
    }

    private static func firstDeliveredPTS(_ demuxer: Demuxer, streamIndex: Int32) -> Double? {
        guard let tb = demuxer.stream(at: streamIndex)?.pointee.time_base,
              tb.num > 0, tb.den > 0 else { return nil }
        while let pkt = try? demuxer.readPacket() {
            let idx = pkt.pointee.stream_index
            let pts = pkt.pointee.pts
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            guard idx == streamIndex, pts != Int64.min else { continue }
            return Double(pts) * Double(tb.num) / Double(tb.den)
        }
        return nil
    }

    @Test("a sparse anchor clamps the seek to its first cue", .timeLimit(.minutes(3)))
    func sparseAnchorClampsTheSeek() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        #expect(demuxer.seekBounded(to: 6.5, anchorStreamIndex: Self.sparse, timeout: 5))
        let clamped = Self.firstDeliveredPTS(demuxer, streamIndex: Self.full)
        #expect(clamped == 10, "the 5 s to 9 s cues of the full track are skipped, got \(String(describing: clamped))")
    }

    @Test("the anchor is a routed stream whose index brackets the target",
          .timeLimit(.minutes(3)))
    func anchorBracketsTheTarget() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let routed = [Self.sparse, Self.full]
        #expect(demuxer.sideReaderSeekAnchor(among: routed, forSeconds: 6.5) == Self.full,
                "before the sparse track's first cue")
        #expect(demuxer.sideReaderSeekAnchor(among: routed, forSeconds: 11.5) == Self.sparse,
                "both land inside the window, the sparse track's 10 s cue is the earlier landing")
        #expect(demuxer.sideReaderSeekAnchor(among: routed, forSeconds: 11.5,
                                             landingWindowSeconds: 1) == Self.full,
                "outside the window the nearest landing wins")
        #expect(demuxer.sideReaderSeekAnchor(among: routed, forSeconds: 13.5) == Self.full,
                "past the sparse track's last cue Matroska would parse clusters to EOF")
        #expect(demuxer.sideReaderSeekAnchor(among: routed, forSeconds: 0.5) == -1,
                "no routed index reaches the target, so libavformat picks")
        #expect(demuxer.sideReaderSeekAnchor(among: [Int32](), forSeconds: 6.5) == -1)
    }

    @Test("a stream without index entries keeps anchoring", .timeLimit(.minutes(3)))
    func unindexedCandidateKeepsTheOldRule() throws {
        let demuxer = try Self.makeDemuxer(prewarm: false)
        defer { demuxer.close() }
        // Before the Cues are parsed the sparse track has no entries; the open's probe read
        // has already indexed the full track's first blocks, so it is left out here.
        let stream = try #require(demuxer.stream(at: Self.sparse))
        try #require(avformat_index_get_entries_count(stream) == 0)
        #expect(demuxer.sideReaderSeekAnchor(among: [Self.sparse], forSeconds: 6.5) == Self.sparse)
    }

    @Test("the native readers' seek lands at the target", .timeLimit(.minutes(3)))
    func nativeReaderSeekLandsAtTheTarget() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let anchor = demuxer.sideReaderSeekAnchor(among: [Self.sparse, Self.full], forSeconds: 6.5)
        #expect(demuxer.seekBounded(to: 6.5, anchorStreamIndex: anchor, timeout: 5))
        let first = try #require(Self.firstDeliveredPTS(demuxer, streamIndex: Self.full))
        #expect(first <= 6.5, "landed at \(first)")
    }

    @Test("the prefetcher's reposition lands at the target", .timeLimit(.minutes(3)))
    func prefetcherRepositionLandsAtTheTarget() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        demuxer.discardAllStreamsExcept([Self.sparse, Self.full], pacing: demuxer.videoStreamIndex)
        let landed = SubtitleForwardPrefetcher.reposition(
            demuxer: demuxer, to: 8.5, anchorCandidates: [Self.sparse, Self.full],
            fallbackDuration: 15, timeout: 5)
        #expect(landed == .seek)
        let first = try #require(Self.firstDeliveredPTS(demuxer, streamIndex: Self.full))
        #expect(first <= 6.5, "landed at \(first)")
    }

    static let fixtureBase64 = """
    GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAQHRFNm3TAv4Tt7dubTbuLU6uEFUmpZlOs
    gaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIB/E27jFOrhBxTu2tTrIIOAuwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hH9Ni7sq
    17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJAl8AR1FosS7hNNqatO7Y1KRImIQM1MAAAAAAAWVK5rQQW/
    hMmDOEGuAQAAAAAAAILXgQFzxYg0r7sKZXIoeZyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OBASPjg4QL68IA4JCwgYC6
    gUiagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KnAULACv/hABhnQsAK2ggv5cBEAAADAAQAAAMAKDxImoABAARozg/IrgEAAAAA
    AAAz14ECc8WI+UQsEiPv0O+cgQAitZyDdW5kiIEAVaqBAYaLU19URVhUL1VURjiDgRFV7oEArgEAAAAAAAAv14EDc8WIFsecNwR5
    iHScgQAitZyDdW5kiIEAhotTX1RFWFQvVVRGOIOBEVXugQASVMNnQS+/hHzTHSZzc6BjwIBnyJpFo4dFTkNPREVSRIeNTGF2ZjYy
    LjEyLjEwMXNz12PAi2PFiDSvuwplcih5Z8iiRaOHRU5DT0RFUkSHlUxhdmM2Mi4yOC4xMDEgbGlieDI2NGfIoUWjiERVUkFUSU9O
    RIeTMDA6MDA6MTUuMDAwMDAwMDAwAHNz02PAi2PFiPlELBIj79DvZ8ieRaOHRU5DT0RFUkSHkUxhdmM2Mi4yOC4xMDEgc3J0Z8ih
    RaOIRFVSQVRJT05Eh5MwMDowMDoxMy41MDAwMDAwMDAAc3PTY8CLY8WIFsecNwR5iHRnyJ5Fo4dFTkNPREVSRIeRTGF2YzYyLjI4
    LjEwMSBzcnRnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjE0LjUwMDAwMDAwMAAfQ7Z1QxG/hOZE8VjngQCjQoOBAACAAAACUQYF//9N
    3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENv
    cHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVm
    PTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3Jl
    Zj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bz
    a2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9
    MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2Vp
    Z2h0cD0wIGtleWludD01IGtleWludF9taW49MSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3Jm
    PTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAJmWIhDomKAyc
    nJycnJyddddddddddddddddddddddddddddddddeo46BAMgAAAAABkGaIBKgU6OOgQGQAAAAAAZBmkASoFOjjoECWAAAAAAGQZpg
    EqBTo46BAyAAAAAABkGagBOgU6OygQPogAAAACpliIIBKiYoAAgLycnJycnJyddddddddddddddddddddddddddddddddeCgjKGG
    gwPoAEIxm4IB9B9DtnVAnL+EIu+U7OeCBLCjjoEAAAAAAAAGQZogEqBTo46BAMgAAAAABkGaQBKgU6OOgQGQAAAAAAZBmmASoFOj
    joECWAAAAAAGQZqAE6BTo7KBAyCAAAAAKmWIhATomKAAID8nJycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgKCMoYaDAyAA
    QjKbggH0o46BA+gAAAAABkGaIBKgUx9DtnVAnL+E7mCMceeCCWCjjoEAAAAAAAAGQZpAEqBTo46BAMgAAAAABkGaYBKgU6OOgQGQ
    AAAAAAZBmoAToFOjsoECWIAAAAAqZYiCAUomKAAIE8nJycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgoIyhhoMCWABCM5uC
    AfSjjoEDIAAAAAAGQZogEqBTo46BA+gAAAAABkGaQBKgUx9DtnVAnL+Es9n6HeeCDhCjjoEAAAAAAAAGQZpgEqBTo46BAMgAAAAA
    BkGagBOgU6OygQGQgAAAACpliIQFKJigACBPJycnJycnJ111111111111111111111111111111114CgjKGGgwGQAEI0m4IB9KOO
    gQJYAAAAAAZBmiASoFOjjoEDIAAAAAAGQZpAEqBTo46BA+gAAAAABkGaYBKgUx9DtnVAnL+EOA/ROueCEsCjjoEAAAAAAAAGQZqA
    E6BTo7KBAMiAAAAAKmWIggFaJigACBbJycnJycnJ111111111111111111111111111111114KCMoYaDAMgAQjWbggH0o46BAZAA
    AAAABkGaIBKgU6OOgQJYAAAAAAZBmkASoFOjjoEDIAAAAAAGQZpgEqBTo46BA+gAAAAABkGagBOgUx9DtnVAzr+E5AZSGueCF3Cj
    soEAAIAAAAAqZYiEBWiYoAAgWycnJycnJyddddddddddddddddddddddddddddddddeAoIyhhoMAAABCNpuCAfSjjoEAyAAAAAAG
    QZogEqBTo46BAZAAAAAABkGaQBKgU6OOgQJYAAAAAAZBmmASoFOjjoEDIAAAAAAGQZqAE6BTo7KBA+iAAAAAKmWIggFaJigACBbJ
    ycnJycnJ111111111111111111111111111111114KCMoYaDA+gAQjebggH0H0O2dUCcv4RX65lw54IcIKOOgQAAAAAAAAZBmiAS
    oFOjjoEAyAAAAAAGQZpAEqBTo46BAZAAAAAABkGaYBKgU6OOgQJYAAAAAAZBmoAToFOjsoEDIIAAAAAqZYiEBWiYoAAgWycnJycn
    JyddddddddddddddddddddddddddddddddeAoIyhhoMDIABCOJuCAfSjjoED6AAAAAAGQZogEqBTH0O2dUCcv4Qj7Z/N54Ig0KOO
    gQAAAAAAAAZBmkASoFOjjoEAyAAAAAAGQZpgEqBTo46BAZAAAAAABkGagBOgU6OygQJYgAAAACpliIIBWiYoAAgWycnJycnJyddd
    dddddddddddddddddddddddddddddeCgjKGGgwJYAEI5m4IB9KOOgQMgAAAAAAZBmiASoFOjjoED6AAAAAAGQZpAEqBTH0O2dUCr
    v4S5FC4p54IlgKOOgQAAAAAAAAZBmmASoFOjjoEAyAAAAAAGQZqAE6BTo7KBAZCAAAAAKmWIhAVomKAAIFsnJycnJycnXXXXXXXX
    XXXXXXXXXXXXXXXXXXXXXXXXgKCMoYaCAZAAQTGbggH0oI2hh4MBkABCMTCbggH0o46BAlgAAAAABkGaIBKgU6OOgQMgAAAAAAZB
    mkASoFOjjoED6AAAAAAGQZpgEqBTH0O2dUCdv4QlnEfb54IqMKOOgQAAAAAAAAZBmoAToFOjsoEAyIAAAAAqZYiCAVomKAAIFsnJ
    ycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgoI2hh4MAyABCMTGbggH0o46BAZAAAAAABkGaIBKgU6OOgQJYAAAAAAZBmkAS
    oFOjjoEDIAAAAAAGQZpgEqBTo46BA+gAAAAABkGagBOgUx9DtnVA3r+EpS++BueCLuCjsoEAAIAAAAAqZYiEBWiYoAAgWycnJycn
    JyddddddddddddddddddddddddddddddddeAoI2hh4MAAABCMTKbggH0o46BAMgAAAAABkGaIBKgU6OOgQGQAAAAAAZBmkASoFOj
    joECWAAAAAAGQZpgEqBTo46BAyAAAAAABkGagBOgU6OygQPogAAAACpliIIBWiYoAAgWycnJycnJyddddddddddddddddddddddd
    dddddddddeCgjKGGggPoAEEym4IB9KCNoYeDA+gAQjEzm4IB9B9DtnVAnb+EdMq8q+eCM5CjjoEAAAAAAAAGQZogEqBTo46BAMgA
    AAAABkGaQBKgU6OOgQGQAAAAAAZBmmASoFOjjoECWAAAAAAGQZqAE6BTo7KBAyCAAAAAKmWIhAVomKAAIFsnJycnJycnXXXXXXXX
    XXXXXXXXXXXXXXXXXXXXXXXXgKCNoYeDAyAAQjE0m4IB9KOOgQPoAAAAAAZBmiASoFMfQ7Z1ur+EgMRPmOeCOECjjoEAAAAAAAAG
    QZpAEqBTo46BAMgAAAAABkGaYBKgU6OOgQGQAAAAAAZBmoAToFMcU7trQhW/hCrRojW7j7OBALeK94EB8YIDMfCBCbuis4ID6LeL
    94EB8YIDMfCCAs+3j/eBA/GCAzHwggMDsoIB9Lugs4IH0LeK94EB8YIGSPCBSreO94ED8YIGSPCBfrKCAfS7oLOCC7i3iveBAfGC
    BurwgTq3jveBA/GCBurwgW6yggH0u6Czgg+gt4r3gQHxggeM8IEqt473gQPxggeM8IFesoIB9Lugs4ITiLeK94EB8YIILvCBGreO
    94ED8YIILvCBTrKCAfS7oLOCF3C3iveBAfGCCNDwgQq3jveBA/GCCNDwgT6yggH0u6CzghtYt4r3gQHxggjQ8IGMt473gQPxggjQ
    8IHAsoIB9Lugs4IfQLeK94EB8YIJpPCBSreO94ED8YIJpPCBfrKCAfS7oLOCIyi3iveBAfGCCkbwgTq3jveBA/GCCkbwgW6yggH0
    u7CzgicQt4r3gQHxggro8IEqt473gQLxggro8IFesoIB9LeO94ED8YIK6PCBbLKCAfS7oLOCKvi3iveBAfGCC5nwgRq3jveBA/GC
    C5nwgU6yggH0u6Czgi7gt4r3gQHxggw88IEKt473gQPxggw88IE+soIB9Luws4IyyLeK94EB8YIMPPCBjbeO94EC8YIMPPCBwbKC
    AfS3jveBA/GCDDzwgc+yggH0u6Czgjawt4r3gQHxgg0g8IFKt473gQPxgg0g8IF+soIB9A==
    """
}
