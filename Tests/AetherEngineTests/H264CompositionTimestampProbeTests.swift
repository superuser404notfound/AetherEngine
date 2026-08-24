import Foundation
import Libavcodec
import Testing
@testable import AetherEngine

@Suite("H.264 missing composition timestamp recovery (#409)")
struct H264CompositionTimestampProbeTests {

    private func completeEvidence() -> H264CompositionTimestampProbe.Evidence {
        H264CompositionTimestampProbe.Evidence(
            videoPackets: 64,
            validTimestampPairs: 64,
            nonKeyPackets: 63,
            sawCompositionOffset: false,
            decodedFrames: 48,
            validBestEffortFrames: 48,
            bestEffortAdvances: 47,
            bestEffortRegressions: 0,
            rawPTSRegressions: 1,
            rawPTSDiffersFromBestEffort: 12
        )
    }

    @Test("missing CTS plus decoded raw-PTS regression selects repair")
    func confirmedSignatureRepairs() {
        #expect(H264CompositionTimestampProbe.classify(completeEvidence())
            == .repairWithBestEffortPTS)
    }

    @Test("routing bridge forces only a confirmed repair and keeps its timestamp policy paired")
    func routingBridge() {
        let repair = H264CompositionTimestampProbe.routingDecision(
            for: .repairWithBestEffortPTS,
            preservingSoftwarePath: false
        )
        #expect(repair.useSoftwarePath)
        #expect(repair.frameTimestampPolicy == .bestEffort)
        #expect(repair.appliesTimestampRepair)

        let healthy = H264CompositionTimestampProbe.routingDecision(
            for: .healthy,
            preservingSoftwarePath: true
        )
        #expect(healthy.useSoftwarePath)
        #expect(healthy.frameTimestampPolicy == .decodedPTS)
        #expect(!healthy.appliesTimestampRepair)

        let inconclusive = H264CompositionTimestampProbe.routingDecision(
            for: .inconclusive,
            preservingSoftwarePath: false
        )
        #expect(!inconclusive.useSoftwarePath)
        #expect(inconclusive.frameTimestampPolicy == .decodedPTS)
        #expect(!inconclusive.appliesTimestampRepair)
    }

    @Test("one real composition offset proves the container carries CTS")
    func compositionOffsetStaysNative() {
        var evidence = completeEvidence()
        evidence.sawCompositionOffset = true
        #expect(H264CompositionTimestampProbe.classify(evidence) == .healthy)
    }

    @Test("every evidence floor fails closed")
    func evidenceFloorsFailClosed() {
        var pairs = completeEvidence()
        pairs.validTimestampPairs = 31
        #expect(H264CompositionTimestampProbe.classify(pairs) == .inconclusive)

        var nonKey = completeEvidence()
        nonKey.nonKeyPackets = 15
        #expect(H264CompositionTimestampProbe.classify(nonKey) == .inconclusive)

        var decoded = completeEvidence()
        decoded.decodedFrames = 15
        #expect(H264CompositionTimestampProbe.classify(decoded) == .inconclusive)

        var bestFrames = completeEvidence()
        bestFrames.validBestEffortFrames = 15
        #expect(H264CompositionTimestampProbe.classify(bestFrames) == .inconclusive)

        var advances = completeEvidence()
        advances.bestEffortAdvances = 7
        #expect(H264CompositionTimestampProbe.classify(advances) == .inconclusive)

        var bestRegressed = completeEvidence()
        bestRegressed.bestEffortRegressions = 1
        #expect(H264CompositionTimestampProbe.classify(bestRegressed) == .inconclusive)
    }

    @Test("raw/best differences without a backward step stay native")
    func bestEffortDifferenceAloneStaysNative() {
        var evidence = completeEvidence()
        evidence.rawPTSRegressions = 0
        evidence.rawPTSDiffersFromBestEffort = 12
        #expect(H264CompositionTimestampProbe.classify(evidence) == .healthy)
    }

    @Test("raw PTS regression threshold is half a nominal frame")
    func halfFrameRegressionBoundary() {
        #expect(H264CompositionTimestampProbe.isMeaningfulRawPTSRegression(
            previous: 12_012, current: 3_003, nominalFrameTicks: 3_003))
        #expect(H264CompositionTimestampProbe.isMeaningfulRawPTSRegression(
            previous: 10_000, current: 8_500, nominalFrameTicks: 3_000))
        #expect(!H264CompositionTimestampProbe.isMeaningfulRawPTSRegression(
            previous: 10_000, current: 8_501, nominalFrameTicks: 3_000))
        #expect(!H264CompositionTimestampProbe.isMeaningfulRawPTSRegression(
            previous: 10_000, current: 10_001, nominalFrameTicks: 3_000))
        #expect(H264CompositionTimestampProbe.isMeaningfulRawPTSRegression(
            previous: Int64.max, current: Int64.min + 1, nominalFrameTicks: 3_000))
    }

    @Test("zero packet and wall-clock budgets fail closed without moving the demuxer")
    func exhaustedBudgetsFailClosed() throws {
        let packetLimited = try Self.makeDemuxer(base64: Self.missingCTTSFixtureBase64)
        defer { packetLimited.close() }
        let packetResult = H264CompositionTimestampProbe.run(
            demuxer: packetLimited,
            streamIndex: packetLimited.videoStreamIndex,
            packetBudget: 0
        )
        #expect(packetResult.verdict == .inconclusive)
        #expect(!packetResult.requiresRewind)
        #expect(packetResult.evidence.videoPackets == 0)

        let timeLimited = try Self.makeDemuxer(base64: Self.missingCTTSFixtureBase64)
        defer { timeLimited.close() }
        let timeResult = H264CompositionTimestampProbe.run(
            demuxer: timeLimited,
            streamIndex: timeLimited.videoStreamIndex,
            wallClockBudget: 0
        )
        #expect(timeResult.verdict == .inconclusive)
        #expect(!timeResult.requiresRewind)
        #expect(timeResult.evidence.videoPackets == 0)
    }

    @Test("a read attempt dirties the input position before any packet or error is returned")
    func readAttemptRequiresRewind() {
        var position = H264CompositionTimestampProbe.InputPositionState()
        #expect(!position.requiresRewind)
        position.beginReadAttempt()
        #expect(position.requiresRewind)
    }

    @Test("probe-selected timestamp policy preserves the NOPTS fallback")
    func decodedFrameTimestampPolicy() {
        let nopts = Int64.min
        #expect(SoftwareVideoDecoder.resolvedFramePTS(
            decodedPTS: 3_003, bestEffortPTS: 12_012, policy: .decodedPTS) == 3_003)
        #expect(SoftwareVideoDecoder.resolvedFramePTS(
            decodedPTS: 3_003, bestEffortPTS: 12_012, policy: .bestEffort) == 12_012)
        #expect(SoftwareVideoDecoder.resolvedFramePTS(
            decodedPTS: 3_003, bestEffortPTS: nopts, policy: .bestEffort) == 3_003)
        // Preserve #407: the default policy still repairs a genuinely missing raw PTS.
        #expect(SoftwareVideoDecoder.resolvedFramePTS(
            decodedPTS: nopts, bestEffortPTS: 12_012, policy: .decodedPTS) == 12_012)
        #expect(SoftwareVideoDecoder.resolvedFramePTS(
            decodedPTS: nopts, bestEffortPTS: nopts, policy: .decodedPTS) == nopts)
    }

    @Test("real MP4 missing CTTS selects repair and rewinds to the identical first packet")
    func malformedMP4Integration() throws {
        let sampled = try Self.makeDemuxer(base64: Self.missingCTTSFixtureBase64)
        defer { sampled.close() }
        let videoIndex = sampled.videoStreamIndex

        let result = H264CompositionTimestampProbe.run(
            demuxer: sampled,
            streamIndex: videoIndex
        )
        #expect(result.verdict == .repairWithBestEffortPTS)
        #expect(result.evidence.validTimestampPairs >= 32)
        #expect(result.evidence.rawPTSRegressions > 0)
        #expect(result.evidence.bestEffortRegressions == 0)
        #expect(result.requiresRewind)
        #expect(sampled.seek(to: 0))

        let rewoundFirstPacket = try #require(Self.firstVideoPacket(in: sampled))
        let fresh = try Self.makeDemuxer(base64: Self.missingCTTSFixtureBase64)
        defer { fresh.close() }
        let freshFirstPacket = try #require(Self.firstVideoPacket(in: fresh))
        #expect(rewoundFirstPacket == freshFirstPacket)
    }

    @Test("real MP4 carrying CTTS exits healthy without selecting software repair")
    func healthyMP4Integration() throws {
        let demuxer = try Self.makeDemuxer(base64: Self.healthyCTTSFixtureBase64)
        defer { demuxer.close() }

        let result = H264CompositionTimestampProbe.run(
            demuxer: demuxer,
            streamIndex: demuxer.videoStreamIndex
        )
        #expect(result.verdict == .healthy)
        #expect(result.evidence.sawCompositionOffset)
        #expect(result.evidence.videoPackets <= 2)
        #expect(result.requiresRewind)
        #expect(demuxer.seek(to: 0))

        let rewoundFirstPacket = try #require(Self.firstVideoPacket(in: demuxer))
        let fresh = try Self.makeDemuxer(base64: Self.healthyCTTSFixtureBase64)
        defer { fresh.close() }
        let freshFirstPacket = try #require(Self.firstVideoPacket(in: fresh))
        #expect(rewoundFirstPacket == freshFirstPacket)
    }

    private struct PacketSnapshot: Equatable {
        let pts: Int64
        let dts: Int64
        let flags: Int32
    }

    private static func makeDemuxer(base64: String) throws -> Demuxer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    private static func firstVideoPacket(in demuxer: Demuxer) -> PacketSnapshot? {
        let videoIndex = demuxer.videoStreamIndex
        while let packet = try? demuxer.readPacket() {
            let isVideo = packet.pointee.stream_index == videoIndex
            let snapshot = PacketSnapshot(
                pts: packet.pointee.pts,
                dts: packet.pointee.dts,
                flags: packet.pointee.flags
            )
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&ownedPacket)
            if isVideo { return snapshot }
        }
        return nil
    }

    /// 96x64 H.264 Main, 30000/1001 fps, 66 frames, three B-frames per group. Both stay tiny because
    /// every frame is the same color. Reproduce with FFmpeg 8.1.2:
    ///
    ///     ffmpeg -f lavfi -i 'color=c=red:s=96x64:r=30000/1001:d=2.2' -frames:v 66 \
    ///       -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 -g 66 \
    ///       -sc_threshold 0 -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4
    ///
    /// The first file contains a `ctts` table. The stream-copy keeps the identical reordered H.264
    /// bitstream while deleting composition offsets from the second file.
    private static let healthyCTTSFixtureBase64 = """
        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
        b25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEu
        MDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpv
        bmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGlj
        ZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJh
        PTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3
        ZWlnaHRwPTAga2V5aW50PTY2IGtleWludF9taW49NiBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAg
        Y3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBh
        cT0wAIAAAAAmZYiEAOhGKAAIY8cAAQPY4AAh5ScnJycnXXXXXXXXXXXXXXXXXXgAAAAHQZokAOoMwAAAAAdBnkJANoMwAAAABwGe
        YUBdBmAAAAAHAZ5jQF0GYAAAAAhBmmg0QHUGYAAAAAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAAAAcBnqdAZQZgAAAACEGarDRAfQZg
        AAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe60BlBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBlBmAAAAAH
        AZ8vQG0GYAAAAAhBmzQ0QH0GYAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUV
        KHUGYAAAAAcBn7VAbQZgAAAABwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAA
        AAhBm+A0QH0GYAAAAAlBnh5FFSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaJDRAfQZgAAAACUGeQkUVKHUGYAAAAAcB
        nmFAbQZgAAAABwGeY0BtBmAAAAAIQZpoNEB9BmAAAAAJQZ6GRRUodQZgAAAABwGepUBtBmAAAAAHAZ6nQG0GYAAAAAhBmqw0QH0G
        YAAAAAlBnspFFSh1BmAAAAAHAZ7pQG0GYAAAAAcBnutAbQZgAAAACEGa8DRAfQZgAAAACUGfDkUVKHUGYAAAAAcBny1AbQZgAAAA
        BwGfL0BtBmAAAAAIQZs0NEB9BmAAAAAJQZ9SRRUodQZgAAAABwGfcUBtBmAAAAAHAZ9zQG0GYAAAAAhBm3g0QH0GYAAAAAlBn5ZF
        FSh1BmAAAAAHAZ+1QG0GYAAAAAcBn7dAbQZgAAAACEGbvDRAfQZgAAAACUGf2kUVKHUGYAAAAAcBn/lAbQZgAAAABwGf+0BtBmAA
        AAAIQZvgNEB9BmAAAAAJQZ4eRRUodQZgAAAABwGePUBtBmAAAAAHAZ4/QG0GYAAAAAhBmiE0QH0GYA==
        """

    private static let missingCTTSFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQpbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAACFgAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        A1N0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAACFgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAGAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAhYAAAH0gABAAAAAALLbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAB1MAABAhJVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACdm1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjZzdGJsAAAAtnN0c2QA
        AAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAGAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGli
        eDI2NAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBTUAK/+EAFWdNQArsoxNgIgAAB9IAAdTAHiRLLAEABGjOD8gAAAAQcGFzcAAAAAEA
        AAABAAAAFGJ0cnQAAAAAAAAU8QAAFPEAAAAYc3R0cwAAAAAAAAABAAAAQgAAA+kAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNj
        AAAAAAAAAAEAAAABAAAAQgAAAAEAAAEcc3RzegAAAAAAAAAAAAAAQgAAAssAAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAA
        CwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAA
        AAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwA
        AAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAAL
        AAAADAAAABRzdGNvAAAAAAAAAAEAAARZAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAA
        AAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAABcxtZGF0AAACnQYF//+Z3EXp
        vebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHls
        ZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEg
        ZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
        IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lw
        PTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBk
        ZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJh
        bWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9NjYg
        a2V5aW50X21pbj02IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYw
        IHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAACZliIQA6EYoAAhj
        xwABA9jgACHlJycnJyddddddddddddddddddeAAAAAdBmiQA6gzAAAAAB0GeQkA2gzAAAAAHAZ5hQF0GYAAAAAcBnmNAXQZgAAAA
        CEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0BlBmAAAAAIQZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe
        6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmvA0QH0GYAAAAAlBnw5FFSh1BmAAAAAHAZ8tQGUGYAAAAAcBny9AbQZgAAAACEGbNDRAfQZg
        AAAACUGfUkUVKHUGYAAAAAcBn3FAbQZgAAAABwGfc0BtBmAAAAAIQZt4NEB9BmAAAAAJQZ+WRRUodQZgAAAABwGftUBtBmAAAAAH
        AZ+3QG0GYAAAAAhBm7w0QH0GYAAAAAlBn9pFFSh1BmAAAAAHAZ/5QG0GYAAAAAcBn/tAbQZgAAAACEGb4DRAfQZgAAAACUGeHkUV
        KHUGYAAAAAcBnj1AbQZgAAAABwGeP0BtBmAAAAAIQZokNEB9BmAAAAAJQZ5CRRUodQZgAAAABwGeYUBtBmAAAAAHAZ5jQG0GYAAA
        AAhBmmg0QH0GYAAAAAlBnoZFFSh1BmAAAAAHAZ6lQG0GYAAAAAcBnqdAbQZgAAAACEGarDRAfQZgAAAACUGeykUVKHUGYAAAAAcB
        nulAbQZgAAAABwGe60BtBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBtBmAAAAAHAZ8vQG0GYAAAAAhBmzQ0QH0G
        YAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUVKHUGYAAAAAcBn7VAbQZgAAAA
        BwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAAAAhBm+A0QH0GYAAAAAlBnh5F
        FSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaITRAfQZg
        """
}
