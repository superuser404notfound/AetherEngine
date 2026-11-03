import XCTest
import AVFAudio
@testable import AetherEngine

/// #95: controller lifecycle around the tap's AsyncStream. Reader factory is injected
/// (startReader), so no media or session is involved; full engine wiring is exercised by
/// `aetherctl audiotap`.
@MainActor
final class AudioTapControllerTests: XCTestCase {

    private func makeBuffer() -> AudioTapBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: 480)!
        b.frameLength = 480
        return AudioTapBuffer(buffer: b, sourceTime: 1.0, discontinuity: false)
    }

    func testYieldReachesConsumerAndTeardownFinishes() async {
        let controller = AudioTapController()
        let stream = controller.makeStream(startReader: { onStop in onStop {} })
        let yield = controller.makeYield()!
        yield(makeBuffer())
        controller.teardown()

        var received: [AudioTapBuffer] = []
        for await buf in stream { received.append(buf) }   // ends because teardown finished it
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sourceTime, 1.0, accuracy: 0.001)
    }

    /// #864 follow-up (qoli's characterization): a consumer that falls behind keeps every queued
    /// buffer, loses what arrives while the queue is full, and the first buffer after that gap is
    /// flagged, so it cannot be mistaken for PCM contiguous with the last one it received.
    func testOverflowFlagsTheFirstBufferAfterTheGap() async {
        func packet(_ index: Int, discontinuity: Bool = false) -> AudioTapBuffer {
            let pcm = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: 4800)!
            pcm.frameLength = 4800
            return AudioTapBuffer(buffer: pcm, sourceTime: Double(index) / 10, discontinuity: discontinuity)
        }
        let controller = AudioTapController()
        let stream = controller.makeStream(startReader: { onStop in onStop {} })
        let emit = controller.makeYield()!
        var iterator = stream.makeAsyncIterator()
        emit(packet(0, discontinuity: true))
        _ = await iterator.next()
        let capacity = AudioTapController.streamCapacity
        for index in 1...(capacity + 1) { emit(packet(index)) }   // the last one finds the queue full
        var queued: [AudioTapBuffer] = []
        for _ in 0..<capacity { queued.append(await iterator.next()!) }
        XCTAssertEqual(queued.first!.sourceTime, 0.1, accuracy: 1e-6)
        XCTAssertEqual(queued.last!.sourceTime, Double(capacity) / 10, accuracy: 1e-6)
        XCTAssertFalse(queued.contains(where: \.discontinuity))
        emit(packet(capacity + 2))
        let afterGap = await iterator.next()!
        XCTAssertEqual(afterGap.sourceTime, Double(capacity + 2) / 10, accuracy: 1e-6)
        XCTAssertTrue(afterGap.discontinuity)
        emit(packet(capacity + 3))
        let next = await iterator.next()!
        XCTAssertFalse(next.discontinuity)
        controller.teardown()
    }

    func testTeardownStopsReaderAndYieldGoesDead() {
        let controller = AudioTapController()
        var stopped = false
        _ = controller.makeStream(startReader: { onStop in onStop { stopped = true } })
        XCTAssertTrue(controller.hasDeliverySource)
        let yield = controller.makeYield()!
        controller.teardown()
        XCTAssertTrue(stopped)
        yield(makeBuffer())   // must be a harmless no-op after teardown
        XCTAssertNil(controller.makeYield())
    }

    func testNoDeliverySourceWhenStartReaderRegistersNothing() {
        let controller = AudioTapController()
        _ = controller.makeStream(startReader: { _ in })
        XCTAssertFalse(controller.hasDeliverySource)
    }
}
