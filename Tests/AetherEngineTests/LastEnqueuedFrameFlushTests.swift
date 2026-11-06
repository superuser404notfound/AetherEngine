import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// AE#711 follow-up: `lastEnqueuedFrame` is what a software rebuild holds when the layer cannot read
/// back what it shows (off screen, before tvOS 17.4). A flush that keeps the displayed image (seek,
/// recovery) leaves that frame on screen, so it must stay readable; only a flush that clears the
/// picture drops it.
@Suite("The last enqueued frame follows the picture through a flush")
struct LastEnqueuedFrameFlushTests {

    @MainActor
    private func rendererShowingAFrame() throws -> SampleBufferRenderer {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Issue407CadenceTests.makePixelBuffer()
        for ms in [0, 42] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: Issue407CadenceTests.pts(ms: ms))
        }
        renderer.drainReorderBuffer()
        try #require(renderer.lastEnqueuedFrame != nil)
        return renderer
    }

    @Test("a flush that keeps the displayed image keeps the frame")
    @MainActor
    func keepingFlushKeepsTheFrame() throws {
        let renderer = try rendererShowingAFrame()
        renderer.flush(removingDisplayedImage: false)
        #expect(renderer.lastEnqueuedFrame != nil)
    }

    @Test("a flush that clears the picture drops the frame")
    @MainActor
    func clearingFlushDropsTheFrame() throws {
        let renderer = try rendererShowingAFrame()
        renderer.flush()
        #expect(renderer.lastEnqueuedFrame == nil)
    }
}

/// The test origin's fast body fill has to serve exactly the bytes `patternByte(at:)` names, or every
/// patterned test would compare the reader against a different body than the one it was sent.
@Suite("Test origin pattern fill")
struct ThrottledOriginPatternTests {

    @Test("the copied pattern equals the per-byte pattern across run and 64 KB boundaries")
    func patternBytesMatchPatternByte() {
        for offset in [0, 1, 255, 256, 65_535, 16_777_000, 4_294_967_200] as [Int64] {
            let count = 70_000
            let expected = (0..<count).map { ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
            #expect(ThrottledOriginServer.patternBytes(at: offset, count: count) == expected, "offset \(offset)")
        }
    }
}
