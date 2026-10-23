import Foundation
import Testing
@testable import AetherEngine

/// AE#105: a still requested past the demuxer's known duration otherwise seeks far past EOF and
/// decodes a blank garbage frame that reports `image=ok`. The seek target is clamped to the last
/// safely-decodable position. This is defense-in-depth behind the BDTitleSelector decoy fix that
/// stops a mis-selected decoy title (76s demuxer, 5:23 declared) from being the scrub target at all.
struct FrameDecodeContextClampTests {

    @Test("a request within the known duration is left untouched")
    func inRangePassthrough() {
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 42.0, duration: 76.64) == 42.0)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 0.0, duration: 76.64) == 0.0)
    }

    @Test("a request far past the known duration clamps to just inside the end")
    func pastDurationClamps() {
        // The AE#105 case: demuxer duration 76.64s, host scrub asked for 611.25s.
        let clamped = FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 76.64)
        #expect(clamped < 76.64)
        #expect(clamped > 0)
    }

    @Test("an unknown duration (<= 0) disables clamping so normal sources are unaffected")
    func unknownDurationPassthrough() {
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 0) == 611.25)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 5.0, duration: -1) == 5.0)
    }

    @Test("scrubbing to the very end within tolerance is not treated as past-EOF")
    func endScrubTolerated() {
        // Rounding can put the last-frame request a hair past the reported duration; that must not clamp.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 76.7, duration: 76.64) == 76.7)
    }

    @Test("a file that starts at t > 0 measures its end from its own origin")
    func nonZeroStart() {
        // A 60 s span beginning at 1000 s ends at 1060 s: a request inside it is left alone.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 1030, duration: 60, start: 1000) == 1030)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 1060.5, duration: 60, start: 1000) == 1060.5)
        // Past the end it lands just inside it, never back in the span's own zero-based range.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 2000, duration: 60, start: 1000) == 1059)
        // A degenerate start is the zero-based behaviour.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 76.64, start: .nan)
                == FrameDecodeContext.clampSeekSeconds(requested: 611.25, duration: 76.64))
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 2000, duration: 60, start: -5)
                == FrameDecodeContext.clampSeekSeconds(requested: 2000, duration: 60))
    }

    @Test("the clamp origin is the container's start, not the video's, when the video starts later")
    func containerOrigin() {
        // Audio from 0, video from 5 s: the container span runs from 0, so a 60 s duration ends at 60.
        let origin = FrameDecodeContext.clampOrigin(formatStartTime: 0, videoStartSeconds: 5)
        #expect(origin == 0)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 60.5, duration: 60, start: origin) == 60.5)
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 100, duration: 60, start: origin) == 59)
        // Measured from the video's start the same request would have clamped to 64, past the real end.
        #expect(FrameDecodeContext.clampSeekSeconds(requested: 100, duration: 60, start: 5) == 64)
        // A container start in AV_TIME_BASE units, and the no-timestamp case falling back to the video.
        #expect(FrameDecodeContext.clampOrigin(formatStartTime: 2_500_000, videoStartSeconds: 5) == 2.5)
        #expect(FrameDecodeContext.clampOrigin(formatStartTime: Int64.min, videoStartSeconds: 5) == 5)
        #expect(FrameDecodeContext.clampOrigin(formatStartTime: Int64.min, videoStartSeconds: nil) == 0)
    }
}
