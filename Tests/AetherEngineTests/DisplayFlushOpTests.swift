import XCTest
@testable import AetherEngine

/// Issue #90: the software-decode path blanked the display on every seek. SoftwarePlaybackHost.seek()
/// flushed the renderer, and SampleBufferRenderer.flush() unconditionally removed the displayed image
/// (modern: flush(removingDisplayedImage: true); legacy: flushAndRemoveImage()), so the visible frame
/// was cleared before the post-seek keyframe decoded, a black flash on slow sources (MPEG-2). The
/// hardware/AVPlayer path holds the last frame through a seek. DisplayFlushOp is the pure decision split
/// out of flush() so the hold-vs-clear contract is unit-testable without a live AVSampleBufferDisplayLayer.
final class DisplayFlushOpTests: XCTestCase {

    // MARK: - Seek holds the last frame (the fix)

    func testSeekOnModernRendererHoldsDisplayedImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: false, modernRenderer: true)
        XCTAssertEqual(op, .rendererFlush(removingDisplayedImage: false),
            "a seek must forward removingDisplayedImage: false so the last frame stays on screen")
    }

    func testSeekOnLegacyRendererHoldsLastFrame() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: false, modernRenderer: false)
        XCTAssertEqual(op, .holdImage,
            "the legacy path is the regression: a seek must call flush() (hold), not flushAndRemoveImage()")
    }

    // MARK: - Stop / teardown still clears the visible frame (unchanged default)

    func testStopOnModernRendererRemovesDisplayedImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: true, modernRenderer: true)
        XCTAssertEqual(op, .rendererFlush(removingDisplayedImage: true),
            "stop/teardown must forward removingDisplayedImage: true")
    }

    func testStopOnLegacyRendererRemovesImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: true, modernRenderer: false)
        XCTAssertEqual(op, .removeImage,
            "stop/teardown on the legacy path must call flushAndRemoveImage()")
    }
}
