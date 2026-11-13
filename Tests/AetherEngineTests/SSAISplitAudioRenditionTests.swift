import Foundation
import Testing
@testable import AetherEngine

/// Pluto TV: the variant's programme segments carry audio of their own, its stitched ad segments
/// are video only on a new PID, and the sound of both lives in the demuxed audio rendition. The
/// session therefore reads its audio from the rendition (a side demuxer), and the ad's video PID
/// switch has to work with that side demuxer present. It was gated on there being none, so the ad
/// video fell through as foreign packets and nothing past the seam was cut.
///
/// - `programme`: H.264 at 25 fps on 0x100, AAC on 0x101, clock from 1.4 s, 6 s.
/// - `adVideo`: H.264 alone on 0x102, clock from 1.4 s again, 4 s.
/// - `programmeAudio` / `adAudio`: the rendition, AAC on 0x101, 6 s and 4 s, the same clocks.
///
/// Regenerate with the recipe in `Issue996SSAISeamTests` at `r=25` and `-g 25 -keyint_min 25`
/// (`-streamid` per PID, `adVideo` without the audio input, the two audio fixtures without the video
/// input). At 2 fps the TS demuxer's late release of each PID's last frame cost a second per seam.
@Suite("SSAI seam with a demuxed audio rendition", .serialized, .timeLimit(.minutes(3)))
struct SSAISplitAudioRenditionTests {

    private final class Reader: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private let bytes: Data
        private var position = 0
        init(_ bytes: Data) { self.bytes = bytes }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                let count = min(Int(size), bytes.count - position)
                guard count > 0 else { return 0 }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, count) }
                position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        private var lastSound = 0.0
        private var finalized = 0
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        func sound(_ last: Double) { lock.withLock { lastSound = max(lastSound, last) } }
        func segment() { lock.withLock { finalized += 1 } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
        var lastSoundSeconds: Double { lock.withLock { lastSound } }
        var segments: Int { lock.withLock { finalized } }
    }

    private struct Run {
        let exit: String?
        let lastSoundSeconds: Double
        let segments: Int
    }

    private func run(main: Data, rendition: Data) async throws -> Run {
        let demuxer = Demuxer()
        try demuxer.open(reader: Reader(main), formatHint: "mpegts")
        let side = Demuxer()
        try side.open(reader: Reader(rendition), formatHint: "mpegts", isLive: true)
        let videoIndex = demuxer.videoStreamIndex
        let video = try #require(demuxer.stream(at: videoIndex))
        #expect(demuxer.audioStreamIndex >= 0, "the variant carries muxed programme audio")
        let audioIndex = side.audioStreamIndex
        let audioStream = try #require(side.stream(at: audioIndex))
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
            audio: audio, sideAudioDemuxer: side, cache: cache, baseIndex: 0,
            targetSegmentDurationSeconds: 1, videoFallbackDurationPts: 45_000,
            desiredFirstVideoTfdtPts: 0, segmentBoundaries: [], isLive: true, bufferAheadSegments: 64)
        producer.sourceAnnouncesDiscontinuities = true
        let outcome = Outcome()
        producer.onPumpFinished = { outcome.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in }
        producer.onLiveSegmentSound = { _, _, last in outcome.sound(last) }
        producer.onLiveSegmentFinalized = { _, _, _, _ in outcome.segment() }
        producer.start()
        defer {
            producer.stop()
            if outcome.reason != nil { cache.close() }
        }
        try await waitFor { outcome.reason != nil }
        return Run(exit: outcome.reason?.description, lastSoundSeconds: outcome.lastSoundSeconds,
                   segments: outcome.segments)
    }


    @Test("the ad's video PID switch works with the rendition as the audio source, and sound continues")
    func adSeamWithRenditionAudio() async throws {
        let programmeOnly = try await run(main: Self.programme, rendition: Self.programmeAudio)
        let withAd = try await run(main: Self.programme + Self.adVideo,
                                   rendition: Self.programmeAudio + Self.adAudio)
        #expect(withAd.exit == "eof")
        #expect(withAd.segments > programmeOnly.segments + 2,
                "the ad is cut (programme \(programmeOnly.segments), with ad \(withAd.segments))")
        #expect(withAd.lastSoundSeconds > programmeOnly.lastSoundSeconds + 3,
                "sound continues through the ad (programme \(programmeOnly.lastSoundSeconds)s, with ad \(withAd.lastSoundSeconds)s)")
    }

    // MARK: - Clock runs

    @Test("a source that restarted first waits for the other to reach the seam")
    func restartedSourceWaits() {
        var epochs = DualSourceSeamEpochs()
        epochs.observe(.main, micros: 5_900_000)
        epochs.observe(.side, micros: 5_000_000)
        #expect(epochs.sideFirst(mainMicros: 0, sideMicros: 0) == nil, "same run: the timestamps decide")
        epochs.observe(.side, micros: 1_400_000)
        #expect(epochs.sideFirst(mainMicros: 0, sideMicros: 0) == false, "the ad's audio waits for the programme's last video")
        epochs.observe(.main, micros: 1_400_000)
        #expect(epochs.sideFirst(mainMicros: 0, sideMicros: 0) == nil)
    }

    @Test("a large forward step is a restart as well, back from the ad onto the programme clock")
    func forwardStepIsARestart() {
        var epochs = DualSourceSeamEpochs()
        epochs.observe(.main, micros: 4_000_000)
        epochs.observe(.main, micros: 900_000_000)
        #expect(epochs.mainEpoch == 1)
        epochs.observe(.side, micros: 4_000_000)
        epochs.observe(.side, micros: 4_500_000)
        #expect(epochs.sideFirst(mainMicros: 0, sideMicros: 0) == true, "the side finishes the ad first")
    }

    @Test("a restart only one source ever shows stops holding the other back after a bounded stretch")
    func unmatchedRestartIsBounded() {
        var epochs = DualSourceSeamEpochs()
        epochs.observe(.main, micros: 6_000_000)
        epochs.observe(.side, micros: 6_000_000)
        epochs.observe(.main, micros: 1_000_000)
        var side: Int64 = 6_000_000
        while side <= 6_000_000 + DualSourceSeamEpochs.maxLagMicros {
            side += 20_000
            epochs.observe(.side, micros: side)
            if epochs.sideFirst(mainMicros: 0, sideMicros: 0) == nil { break }
        }
        #expect(epochs.sideFirst(mainMicros: 0, sideMicros: 0) == nil, "the side joins the main's run")
        #expect(side > 6_000_000 + DualSourceSeamEpochs.maxLagMicros - 20_000)
    }

    @Test("a wrap-corrected rendition clock is ordered against the video by its distance, not raw")
    func wrapCorrectedRunIsOffset() {
        var epochs = DualSourceSeamEpochs()
        // Programme: both clocks together near 632 s.
        epochs.observe(.main, micros: 632_000_000)
        epochs.observe(.side, micros: 632_100_000)
        // Ad, the field values: video restarts at 1 s, the rendition at 2^33 ticks + 1 s.
        epochs.observe(.main, micros: 1_000_000)
        epochs.observe(.side, micros: 95_444_717_688)
        #expect(epochs.mainEpoch == epochs.sideEpoch)
        #expect(epochs.sideFirst(mainMicros: 3_000_000, sideMicros: 95_444_717_688 + 1_000_000) == true,
                "1 s into the ad's audio comes before 2 s into its video")
        #expect(epochs.sideFirst(mainMicros: 1_500_000, sideMicros: 95_444_717_688 + 1_000_000) == false)
    }

    @Test("clocks that start a run close together are compared as they are")
    func closeClocksKeepRawOrder() {
        var epochs = DualSourceSeamEpochs()
        epochs.observe(.main, micros: 1_400_000)
        epochs.observe(.side, micros: 1_750_000)
        #expect(epochs.sideOffsetMicros == 0)
        #expect(epochs.sideFirst(mainMicros: 2_000_000, sideMicros: 1_900_000) == nil)
    }

    @Test("ordinary interleave and reorder jitter is not a restart")
    func jitterIsNotARestart() {
        var epochs = DualSourceSeamEpochs()
        epochs.observe(.main, micros: 10_000_000)
        epochs.observe(.main, micros: 9_200_000)
        epochs.observe(.main, micros: 10_040_000)
        #expect(epochs.mainEpoch == 0)
    }

    // MARK: - Fixtures

    private static func inflate(_ lines: [String]) -> Data {
        let compressed = Data(base64Encoded: lines.joined())!
        return try! (compressed as NSData).decompressed(using: .zlib) as Data
    }

    private static let programme = inflate([
        "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",
    ])

    private static let adVideo = inflate([
        "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",
    ])

    private static let programmeAudio = inflate([
        "7ZrLSxtRGMW/O5M2SiPJTJ5WpQ0ShC5CJr5iam2ikHSRRaD/QEMIpUihdKGtBskfkKXgvxG7qbqx2bVptPbhY1VpwZ2LuOmLwHTu",
        "4OaiuNHEHJi7GLjczcdhzo/D4UsnFBdNN0LEqkQ604k1S55HKruZSj1/UXja/bjwcu5ZvhDR5oszNb2zTjpBLqJKjzk7sQbdW7W9",
        "0TFOOmvMLlVUc/YfxuxO/jn+WVkGmD3JIvYs0aJjiev+jn6VSjeCZD/I6SeZknzY/C5RJjeXH4uGo7GwFtFo+m5XNRDjr2yzGXTZ",
        "npT7r+mSZkybpfZpdZXTG7pHue4b9VPdj0zdu/dznaDsxRdD9+EiXeNPexndE4oCzEgFmJEKMCNHuFf/lQWv3trD8OoorFeTbMzQ",
        "ncUzgu49uxi6jwMzUgVmpArMSBWYkTHu1QWH4FXnNwyvTgAzMs51XxdzpPIVQ/f7wIx0AzPSDcxINzAjJ7lX/4o50v0Fw6sPgBk5",
        "ZeguTYg50vsZQ/eHwIz0ADPSA8xID3gfKb0Wc6R/B8OrGjAjeR8prYk5sveT1Ue2mpFeYEZ6gRnpBe8jpT9ijuzbtvrIdvSRckzM",
        "kQNbVh/Zakb6gBnpA2akD7yPlF+JOfJO3eoj29FHym/FHBn8aPWRrWakH5iRfmBG+sH7SPm3mCMHa1Yf2Y4+0jaeEXauQh/O6t5x",
        "C1i8j4TduUooAWBGBoAZGUDuI28bXp03cuQ5z6Z9V0z7Dr3vNGz+Bw==",
    ])

    private static let adAudio = inflate([
        "c3cQFGBw+qDKwHiQgeE/438Gxj8NIh5CjGxubrkFqemcwalFZZnJqQaG5TXOp/4PLuDuwCDAwLCBF+x2BsYPDFobWTb9HxrAPQDo",
        "dqYNQmC3PwS6nR9EvHm0YcoQcLsjowF7AANDNU8dKNwPMHxraGBVZGC/kfj/o08D8/0/95gYfBLLks2M9Iws9AwNDBmcFDgOSliA",
        "ZBn3/1EUYEnokRkgjjsjo2E2A/3CipquB4a7ESjcd52BhvtTcLhzXk8cDCGLnwMMd+MahgFMtJSEu4Og4BAuIwWHcBkpOITLSBNQ",
        "Xv3Vg5JXua8NjbxqOmTzqiOjGTDcGa18UMKd9+rQCHfzIVxGCg3hMlJoCJeRQkO4jLQA5dUqHpS8yn9laORVyyFcRlqBwn0najtS",
        "8PLQCHfrIVxGCg/hMlJ4CJeRwkO4jLQB5dWfqO1I4UtDI6/aDuEy0g4Y7kyWqO1I0YtDI9zth3AZKTKEy0iRIVxGigzx8UimStR2",
        "pPiFoZFXDYdwGQkaj2TagdqOlDw/Oh5J6zJSdAiXkaJDuIwUHeLjkUw/UNuR0udGxyNpPh7ZH8DAbAFsRw6WtACOfyVw/MuexRP/",
        "AA==",
    ])

}
