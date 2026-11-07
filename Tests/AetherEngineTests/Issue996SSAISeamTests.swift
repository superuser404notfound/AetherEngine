import Foundation
import Testing
@testable import AetherEngine

/// AE#996: an ad-stitched HLS channel restarts its clock at an announced discontinuity and, on
/// some ad servers, carries the ad's audio on a PID of its own. The fixtures are what the ingest
/// FIFO hands the demuxer at such a seam: a programme segment followed by an ad segment.
///
/// - `programme`: H.264 on 0x100, AAC on 0x101, clock from 1.4 s.
/// - `programmeLate`: the same at `-output_ts_offset 20000`, so a clock restart behind it reaches
///   the producer the way the field trace showed it, wrap-corrected to 2^33 + a few seconds.
/// - `ad`: H.264 on 0x100, AAC on 0x102, clock from 1.4 s again.
/// - `adOnProgrammeAudioPID`: the same with its AAC on 0x101.
///
/// Regenerate with (`P`=0x101 or 0x102, `D` in seconds, `OFFSET` only for `programmeLate`):
///
///     ffmpeg -f lavfi -i "color=c=black:s=16x16:r=2:d=D" -f lavfi -i "anullsrc=r=48000:cl=stereo" \
///       -t D -c:v libx264 -preset ultrafast -profile:v baseline -crf 51 -g 2 -keyint_min 2 \
///       -sc_threshold 0 -x264-params "bframes=0:repeat-headers=1" -pix_fmt yuv420p -c:a aac -b:a 24k \
///       -streamid 0:0x100 -streamid 1:P [-output_ts_offset OFFSET] -f mpegts \
///       -mpegts_service_type digital_tv -pat_period 0.5 out.ts
///
/// and store raw DEFLATE (`zlib.compressobj(9, zlib.DEFLATED, -15)`) as base64.
@Suite("AE#996 SSAI seam: clock restart and audio PID change", .serialized, .timeLimit(.minutes(2)))
struct Issue996SSAISeamTests {

    // MARK: - A clock restart on a segmented source is a seam

    private static let tb90k = 1.0 / 90_000.0

    /// Field numbers from the Dragons' Den trace: the ad seam restarted the clock at 2 s, FFmpeg's
    /// wrap correction lifted it to 2^33 + 180000, and the pump exited as a source replay.
    @Test("the field trace's video jump is a seam on HLS ingest and an axis reset on raw TS")
    func fieldTraceVideo() {
        #expect(HLSSegmentProducer.sourceRestartShape(
            newDts: 8_590_114_592, jumpTicks: 6_848_013_978, firstSeenDts: 1_741_926_440,
            tbSeconds: Self.tb90k, isLive: true, sourceAnnouncesDiscontinuities: true) == nil)
        #expect(HLSSegmentProducer.sourceRestartShape(
            newDts: 8_590_114_592, jumpTicks: 6_848_013_978, firstSeenDts: 1_741_926_440,
            tbSeconds: Self.tb90k, isLive: true, sourceAnnouncesDiscontinuities: false) == .axisReset,
            "#405: a continuous transport stream keeps the restart reading")
    }

    /// Kim's Convenience: the same shape on the audio stream, six reopens in nine seconds.
    @Test("the field trace's audio jump is a seam on HLS ingest")
    func fieldTraceAudio() {
        #expect(HLSSegmentProducer.sourceRestartShape(
            newDts: 8_590_114_592, jumpTicks: 1_461_531_392, firstSeenDts: 68_708_190,
            tbSeconds: Self.tb90k, isLive: true, sourceAnnouncesDiscontinuities: true) == nil)
    }

    /// The rewind shape needs a recent unplanned reconnect and is evidence of its own; a segmented
    /// source keeps it.
    @Test("a rewind to the join point still classifies on HLS ingest")
    func rewindStillClassifies() {
        #expect(HLSSegmentProducer.sourceRestartShape(
            newDts: 90_000, jumpTicks: -1_800_000, firstSeenDts: 0,
            tbSeconds: Self.tb90k, isLive: true, sourceAnnouncesDiscontinuities: true) == .rewind)
    }

    // MARK: - Audio follow decision

    @Test("a stream that was bound before is taken back on its first packet after a seam")
    func returningStreamAtSeam() {
        #expect(HLSSegmentProducer.audioFollowDecision(
            candidatePackets: 1, candidateWasBoundBefore: true,
            seamSinceBoundAudio: true, boundSilentSeconds: 0))
    }

    @Test("a new stream after a seam needs a short run before it takes over")
    func newStreamAtSeam() {
        let run = HLSSegmentProducer.audioFollowSeamPackets
        #expect(!HLSSegmentProducer.audioFollowDecision(
            candidatePackets: run - 1, candidateWasBoundBefore: false,
            seamSinceBoundAudio: true, boundSilentSeconds: 0.1))
        #expect(HLSSegmentProducer.audioFollowDecision(
            candidatePackets: run, candidateWasBoundBefore: false,
            seamSinceBoundAudio: true, boundSilentSeconds: 0.1))
    }

    /// A second audio stream next to a live bound one (an audio description PID, a bursty
    /// interleave) must never take the track while the bound stream keeps delivering.
    @Test("without a seam only a long silence of the bound stream hands over")
    func noSeamNeedsSilence() {
        #expect(!HLSSegmentProducer.audioFollowDecision(
            candidatePackets: 500, candidateWasBoundBefore: true,
            seamSinceBoundAudio: false, boundSilentSeconds: 0.9))
        #expect(HLSSegmentProducer.audioFollowDecision(
            candidatePackets: 1, candidateWasBoundBefore: false,
            seamSinceBoundAudio: false,
            boundSilentSeconds: HLSSegmentProducer.audioFollowSilenceSeconds))
    }

    // MARK: - Format match

    /// ASC 0x11 0x90: AAC-LC (object type 2), 48 kHz (index 3), two channels.
    private static let ascLC48Stereo: [UInt8] = [0x11, 0x90]

    private static func adts(profile: UInt8, samplingIndex: UInt8, channels: UInt8) -> [UInt8] {
        [0xFF, 0xF1,
         (profile << 6) | (samplingIndex << 2) | (channels >> 2),
         ((channels & 0x03) << 6) | 0x00, 0x00, 0x1F, 0xFC]
    }

    @Test("an ADTS frame matches the ASC only with the same object type, rate and channels")
    func adtsMatch() {
        func matches(_ frame: [UInt8]) -> Bool {
            frame.withUnsafeBytes { f in
                Self.ascLC48Stereo.withUnsafeBytes { HLSSegmentProducer.adtsFrameMatchesASC(f, asc: $0) }
            }
        }
        #expect(matches(Self.adts(profile: 1, samplingIndex: 3, channels: 2)))
        #expect(!matches(Self.adts(profile: 1, samplingIndex: 4, channels: 2)), "44.1 kHz")
        #expect(!matches(Self.adts(profile: 1, samplingIndex: 3, channels: 6)), "5.1")
        #expect(!matches(Self.adts(profile: 0, samplingIndex: 3, channels: 2)), "AAC Main")
        #expect(!matches([0x00, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC]), "no sync word")
    }

    // MARK: - Through the producer

    private final class Reader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let lock = NSLock()
        private var position = 0
        private let holdsOpen: Bool
        private var released = false
        private var gaveUp = false
        /// True once the open source ran into its idle bound and ended after all.
        var endedOnItsOwn: Bool { lock.withLock { gaveUp } }
        /// `holdsOpen`: after the bytes, the read waits like a live source between segments
        /// instead of ending, so nothing the end of input releases can hide a stuck pump.
        init(_ bytes: Data, holdsOpen: Bool = false) {
            self.bytes = bytes
            self.holdsOpen = holdsOpen
        }
        func release() { lock.withLock { released = true } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            var idleMicros = 0
            while true {
                let result: Int32? = lock.withLock {
                    let count = min(Int(size), bytes.count - position)
                    guard count > 0 else { return holdsOpen && !released ? nil : 0 }
                    bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, count) }
                    position += count
                    return Int32(count)
                }
                if let result { return result }
                // Bounded past the 10 s no-cut watchdog, whose abort cannot reach this loop.
                idleMicros += 20_000
                if idleMicros > 15_000_000 {
                    lock.withLock { gaveUp = true }
                    return 0
                }
                usleep(20_000)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        private var sounds: [(index: Int, first: Double, last: Double)] = []
        private var finalized: [Int] = []
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        func sound(_ index: Int, _ first: Double, _ last: Double) { lock.withLock { sounds.append((index, first, last)) } }
        func segment(_ index: Int) { lock.withLock { finalized.append(index) } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
        var soundSpans: [(index: Int, first: Double, last: Double)] { lock.withLock { sounds } }
        var segments: [Int] { lock.withLock { finalized } }
    }

    private struct Run {
        let exit: String?
        /// Item-axis seconds of the last audio sample the producer muxed.
        let lastSoundSeconds: Double
        let segments: Int
        /// The source had to end before the run got its segments.
        let neededEndOfInput: Bool
    }

    private func run(_ bytes: Data, segmented: Bool,
                     untilSegments: Int? = nil) async throws -> Run {
        let reader = Reader(bytes, holdsOpen: untilSegments != nil)
        let demuxer = Demuxer()
        // An open source has no end for the stream probe to stop at, so it gets a small budget.
        try demuxer.open(reader: reader, formatHint: "mpegts",
                         profile: untilSegments == nil ? .playback
                             : DemuxerOpenProfile.playback.withProbeBudget(probesize: 32 * 1024,
                                                                           maxAnalyzeDuration: 1_000_000))
        let videoIndex = demuxer.videoStreamIndex
        let audioIndex = demuxer.audioStreamIndex
        let video = try #require(demuxer.stream(at: videoIndex))
        let audioStream = try #require(demuxer.stream(at: audioIndex))
        #expect(audioStream.pointee.id == 0x101, "the session binds the programme's audio PID")
        _ = HLSVideoEngine.prepareAACForFMP4(audioStream.pointee.codecpar)
        let audio = HLSSegmentProducer.AudioConfig(
            codecpar: UnsafePointer(audioStream.pointee.codecpar),
            timeBase: audioStream.pointee.time_base, sourceStreamIndex: audioIndex,
            inputTimeBase: audioStream.pointee.time_base, sourceTimeBase: audioStream.pointee.time_base,
            bridge: nil, stripAacAdts: true)
        let cache = SegmentCache(forwardWindow: 64, backwardWindow: 64)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(video.pointee.codecpar),
                         timeBase: video.pointee.time_base, codecTagOverride: "avc1"),
            audio: audio, cache: cache, baseIndex: 0, targetSegmentDurationSeconds: 1,
            videoFallbackDurationPts: 45_000, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [], isLive: true, bufferAheadSegments: 64)
        producer.sourceAnnouncesDiscontinuities = segmented
        let outcome = Outcome()
        producer.onPumpFinished = { outcome.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in }
        producer.onLiveSegmentSound = { outcome.sound($0, $1, $2) }
        producer.onLiveSegmentFinalized = { index, _, _, _ in outcome.segment(index) }
        producer.start()
        defer {
            reader.release()
            producer.stop()
            if outcome.reason != nil { cache.close() }
        }
        if let untilSegments {
            // A wedged pump ends on its own: the no-cut watchdog exits it as a segment stall.
            try await waitFor { outcome.reason != nil || outcome.segments.count >= untilSegments }
        } else {
            try await waitFor { outcome.reason != nil }
        }
        return Run(exit: outcome.reason?.description,
                   lastSoundSeconds: outcome.soundSpans.map(\.last).max() ?? 0,
                   segments: outcome.segments.count,
                   neededEndOfInput: reader.endedOnItsOwn)
    }

    /// 6 s of programme, then 4 s of ad whose audio is on 0x102. Before AE#996 the producer kept
    /// 0x101 and cut the ad's segments without sound.
    @Test("the audio track follows the ad onto its own PID")
    func audioFollowsTheAdPID() async throws {
        let programmeOnly = try await run(Self.programme, segmented: true)
        let withAd = try await run(Self.programme + Self.ad, segmented: true)
        #expect(withAd.exit == "eof")
        #expect(withAd.segments > programmeOnly.segments)
        #expect(withAd.lastSoundSeconds > programmeOnly.lastSoundSeconds + 3,
                "sound continues through the ad (programme \(programmeOnly.lastSoundSeconds)s, with ad \(withAd.lastSoundSeconds)s)")
    }

    /// The field shape end to end: a programme deep into its clock, then the ad's clock restarting
    /// near zero, wrap-corrected by FFmpeg to 2^33 + 1.4 s.
    @Test("a wrap-corrected clock restart at an HLS seam is cut through, a raw TS still exits")
    func wrapCorrectedRestart() async throws {
        let rawTS = try await run(Self.programmeLate + Self.ad, segmented: false)
        #expect(rawTS.exit == "sourceReplay", "#405 stays as it was for a continuous transport stream")
        let ingest = try await run(Self.programmeLate + Self.ad, segmented: true)
        #expect(ingest.exit == "eof")
        #expect(ingest.lastSoundSeconds > 8, "sound through the ad, got \(ingest.lastSoundSeconds)s")
    }

    /// Round 3, Kim's Convenience: the outgoing segment's last video PES reaches the demuxer
    /// truncated, so the replay guard holds it as a damaged boundary, and the clock restart behind
    /// it rebases first. The rebase reset the guard while the producer still held that packet, and
    /// from then on the producer buffered every packet as part of an overlap that no longer
    /// existed: no segment was cut until the 10 s watchdog retuned, at the same seam every time.
    /// The source stays open here, as a live one does, because the end of input released the
    /// buffer and let the tests above pass over the same fault.
    @Test("a seam behind a truncated outgoing PES keeps cutting while the source stays open")
    func damagedBoundaryAtSeamDoesNotWedge() async throws {
        let programmeOnly = try await run(Self.programmeLate, segmented: true)
        // The open segment of each run is finalized only by the keyframe after it, so two
        // finalized ad segments are the most an open source can show.
        let target = programmeOnly.segments + 2
        let live = try await run(Self.programmeLate + Self.adOnProgrammeAudioPID, segmented: true,
                                 untilSegments: target)
        #expect(!live.neededEndOfInput, "the segments only came once the source ended")
        #expect(live.exit == nil, "the pump stays on the open source, got \(live.exit ?? "nil")")
        #expect(live.segments >= target,
                "segments past the seam are cut before the source ends (programme \(programmeOnly.segments), got \(live.segments))")
    }

    // MARK: - Fixtures

    private static func inflate(_ lines: [String]) -> Data {
        let compressed = Data(base64Encoded: lines.joined())!
        return try! (compressed as NSData).decompressed(using: .zlib) as Data
    }

    private static let programme = inflate([
            "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",
            "fVpu4P8H",
    ])

    private static let programmeLate = inflate([
            "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",
            "Pw==",
    ])

    private static let ad = inflate([
            "7ZlNbBtFFIBnnTZNWoXGdhxTBaRpKVWEamd3/VPHsNRO1DiHVDJC4oRkxuuxvWTXu97dxDagyK0i1AMqFwSoJ0CCc+DCCZEc",
            "uCAo/6VFqLQHiriAc+EUybxxIyVWpaIAcjxS19LsvJk3u2/fm/3meSeT8o6imdbjSNhAqC20kbDVHJv3CYNzc4ZFS8PPUntZ",
            "U6ko1V6Z/bzdX0cmhUYRWhvp2I6EFnriwwMftfk4Mlmw3bMW7Nh+G7XQBCuO3va0UCi04Otv29NIPJRFaOWLFeb3Wwg1mweP",
            "o0O/ESYOt1hZmlk//NPLAsRnAHWK1OaJF1lH+arwFobz4MF2+/zP537/5M6N+Y/fPH0d33jsjz/rcjyKQ1g1bYqleAzbEVmW",
            "cT4Si4sxAh3zYVCYOp89lwlFcfq5WdAsUBU6Zk2rodOii2VRjIRkUY5BY9l1reTUVK1WCy9rBWrqpBLOCMhr2qUpdqdw2TV0",
            "0DMtVzMrThKrJE9URcQ2LSoSLtC8bqqLipiEHyYVojccyiRsUKWgEews5aEmYstpgDqUObugSGERVKDAhlanhRy7FhuRs0ml",
            "RBUpjtWybRokB0Ml7NpU1zUHNBL1REF1oaJWDSgLlBReMitUkaXTkoSLxHFzYLvPchY1CwZuX6Rq5cxi0aFsoFu2YZADnbpp",
            "LpIyCLmdNkeH13inQcQVu3MbVTOIy0zRKi61dQJK0J7Xl2zSyKmmYZGOUeAf1yZaBS4BijZhOkWbGJRdqka1Utm1oLZIG9Ct",
            "yNuVnKFVQHBUCrZH0ui/zrwKVZeYOR0TmGtt6pRZwFRFtYvYyIM/WURAUGIQCVxlT6CI4ThULWZM50zqSnwaKo5LLSWKNQuC",
            "A1MAYheFQFcVETVhhtJLq8lTkyiwnkl7RCEFLevor7sz/Tppby40B37ZuulBC2RZjcthORGWRAnN4KGNhxOsV/h06/jogRde",
            "e2RfhYzgkaqo14T4f54hk/J6OV6bvByvTV6O16boFVhwrq2toD40b9dyeWRuc2e5TF/BvveBM/I2Z37tqAz/SPqHJPcXgDOR",
            "i/vv8X/LGR/HnPFxzBkfx5yJOVkkhN/oLWd2AWTkgwt7yLfppYsDk2+/g/DZJnAm2sWZI9d44kyMW86kPfEuv4/8wJPfz3DM",
            "dz/HfPdzzHc/x3yPQx4pvFrv9zzSO+i9N49MdHHm6Pc8cWaaY86MccyZMY45M8YxZ864kEfefL7HnNlFED99d0+J5OpD7+Wb",
            "6MJl4EyyizPe73jizJMccybAMWcCHHMmwDFnEpDPeOKpfs9nAp9J9+YzT3Vxxv8tT5xROP6/+nSX3wPf8OT3sxzzfZxjvo9z",
            "zPdxjvk+7WSR5/LJffseeezkxt6+RwqHT02iIXxr1/7qXc4Ev+aJMxLHnAlyzJkgx5wJcsyZJMsj7wz1ex45sfrMP+2vHvvq",
            "wf5qb/LI7v2miasP9pt6tN/0eqrvXtB1dKIzCx798j6z4G8=",
    ])

    /// `ad` with its audio on the programme's PID (0x101), as on the Xumo channel of round 3.
    private static let adOnProgrammeAudioPID = inflate([
            "7ZlNbBtFFIBnkzZNWoXGdhxTBaRpKVWEGnt3/VPHsNROaJxDKxkhcUIy4/XYXrJ/2d3ENqDIrSLUAyoXBKhcAAnOgUvFAZEc",
            "uKC2/JcWodIeKOICyYVTJPPGjZRYlYoCyPFIXUuz82bezL55M/vN80427RtCk2uPI2EVoabQRMJGY3jGL/RNTxs2LQ88R50F",
            "TaWiVH116stmd13ZNBpCaHmwZTsS1tATH+/5pMnHlc2B7T3LoZbtt9EaGmXJwdswisgzn77b3bZnkLgvh9Di5UXm91sINRp7",
            "D6N9vxEmDqyxtDy5sv+nVwSYn17UStLrR15iFZWrwtsY7n17m80zP5/6/bM7N2YuvXX8Or7x2B9/1uREDI9j1XIolhJx7ERl",
            "WcaFaDwhxglUzIRBIXImdyo7HsOZ56dAs0hVqJiy7LpOSx6WRTE6LotyHAornmenIpFqtRpe0IrU0okZzgrIZznlCHtSuOIZ",
            "OuhZtqdZppvCKikQVRGxQ0uKhIu0oFvqrCKm4IeJSfS6S5mEDaoUNYLd+QLkRGy7dVCHNO8UFSksggok2NBqtJhnfbEWeYeY",
            "ZapICaxWHMsgeWgqYc+huq65oJGsJYuqBxl1zoC0SEnxZcukiiwdlyRcIq6XB9v9tjur2dBws5M5O2+VSi5lDb2KA41cqNQt",
            "a5ZUQMhvlbk6vMZbBSI2ndZjVM0gHjNFMz3q6ASUoLygzzuknlctwyYto8A/nkM0E7oARYcwnZJDDMq6qlKtXPFsyM3SOlQr",
            "8mYmb2gmCK5KwfZoBv3XlWdSdZ6Z0zKBudahboVNmKqoTgkbBfAnmxEQlDjMBJ5jI1DEcAKyNjOmdSc1JTEBGdejthLDmg2T",
            "A0sA5i4GEz2niKgBK5SeX0odG0PBlWxGEIU0lKygv+6u9OukuX660fvLxs0edJosqAk5LCfDkiihSdy/+nCS1Qqfbxwe2vPi",
            "64/sqpAVBGkOdZoQ/88Ysmmfj+O9ycfx3uTjeG+KXYQN59ryIupC87Ztlwem17e2y8xF7P8QOCNvcubXlsrAj6R7SHJ/ATgT",
            "Pbf7Hv+3nPFzzBk/x5zxc8yZuJtDQvjNznJmG0AGPzq7g3ibnj/XO/bOewifbABnYm2cOXCNJ87EueVMRki0+X3wB578foJj",
            "vgc45nuAY74HOOZ7AuJI4bVat8eRvj7fvXFkso0zB7/niTMTHHNmmGPODHPMmWGOOXPCgzjy5gsd5sw2ggTo+zsKJJce+qDQ",
            "QGcvAGdSbZzxfccTZ57kmDNBjjkT5JgzQY45k4R4pieR7vZ4JviFdG8881QbZwLf8sQZheP/q0+3+T34DU9+P8kx30c45vsI",
            "x3wf4ZjvE24O9Vw4umvfIw8dXd3Z90hh/7Ex1I9vbTtfvcuZ0Nc8cUbimDMhjjkT4pgzIY45k2Jx5J3+bo8jR5ee/afz1UNf",
            "PThf7Uwc2X7eNHr1wXlTh86b3kh33Qu6go60VsGjV+6zCv4G",
    ])
}
