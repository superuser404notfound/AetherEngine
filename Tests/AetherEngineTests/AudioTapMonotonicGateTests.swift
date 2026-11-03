import XCTest
import AVFAudio
@testable import AetherEngine

final class AudioTapMonotonicGateTests: XCTestCase {
    private let sr = AudioTapDefaults.sampleRate
    private let thr = AudioTapDefaults.overlapTrimThreshold

    private func decide(_ sourceTime: Double, _ frames: Int, _ disc: Bool, _ lastEnd: Double?) -> AudioTapGateDecision {
        AudioTapMonotonicGate.decide(sourceTime: sourceTime, frameLength: frames, discontinuity: disc,
                                     lastEnd: lastEnd, sampleRate: sr, overlapTrimThreshold: thr)
    }

    func testFirstBufferAndDiscontinuityPass() {
        XCTAssertEqual(decide(5.0, 4800, false, nil), .pass)         // no lastEnd yet
        XCTAssertEqual(decide(1.0, 4800, true, 10.0), .pass)         // flagged discontinuity ignores lastEnd
    }

    func testForwardAbuttingPasses() {
        XCTAssertEqual(decide(2.0, 4800, false, 2.0), .pass)         // exactly abuts
        XCTAssertEqual(decide(2.5, 4800, false, 2.0), .pass)         // ahead
    }

    func testSmallOverlapTrims() {
        // lastEnd 2.0, buffer starts 0.1 s earlier -> trim 4800 frames (0.1 s at 48k).
        XCTAssertEqual(decide(1.9, 9600, false, 2.0), .trim(dropFrames: 4800))
    }

    func testFullyContainedDrops() {
        // 0.05 s buffer entirely before lastEnd.
        XCTAssertEqual(decide(1.9, 2400, false, 2.0), .drop)
    }

    func testLargeBackwardJumpForcesDiscontinuity() {
        XCTAssertEqual(decide(0.5, 4800, false, 2.0), .forceDiscontinuity)  // 1.5 s > threshold
    }

    private func buf(_ sourceTime: Double, frames: Int, disc: Bool = false) -> AudioTapBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.floatChannelData![0][i] = Float(i) }   // ramp, so trim is verifiable
        return AudioTapBuffer(buffer: b, sourceTime: sourceTime, discontinuity: disc)
    }

    func testFilterTrimsSeamOverlapToMonotonic() {
        let out = Box<[AudioTapBuffer]>([])
        let filter = AudioTapMonotonicFilter(downstream: { out.value.append($0); return true })
        filter.accept(buf(0.0, frames: 96_000))                 // ends at 2.0 s
        filter.accept(buf(1.9, frames: 96_000))                 // 0.1 s seam overlap
        XCTAssertEqual(out.value.count, 2)
        XCTAssertEqual(out.value[1].sourceTime, 2.0, accuracy: 1e-6)  // restamped to lastEnd
        XCTAssertEqual(out.value[1].buffer.frameLength, 96_000 - 4800) // 0.1 s trimmed
        XCTAssertEqual(out.value[1].buffer.floatChannelData![0][0], 4800.0) // first retained sample
    }

    func testFilterDropsFullyContained() {
        let out = Box<[AudioTapBuffer]>([])
        let filter = AudioTapMonotonicFilter(downstream: { out.value.append($0); return true })
        filter.accept(buf(0.0, frames: 96_000))                 // ends at 2.0 s
        filter.accept(buf(1.9, frames: 2400))                   // 0.05 s buffer, 0.1 s overlap: contained
        XCTAssertEqual(out.value.count, 1)
    }

    /// Reference box so the `@Sendable` downstream closure can accumulate into test-captured state.
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
}
