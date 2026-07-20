import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// SW-PiP Phase C: composites active subtitle cues into decoded software-path frames so the system
/// PiP window (which renders only the sample-buffer layer) shows subtitles. Enabled ONLY while
/// pictureInPictureActive; fullscreen subtitles stay with the host's on-frame overlay. Playback wins
/// over subtitles: every failure path returns the original buffer untouched.
final class SubtitleFrameCompositor: @unchecked Sendable {

    struct TextLayout: Equatable {
        let fontSize: CGFloat
        let bottomMargin: CGFloat
        let maxTextWidth: CGFloat
    }

    /// Plain window check; cue times and SW frame PTS share the source axis.
    nonisolated static func activeCues(in cues: [SubtitleCue], at seconds: Double) -> [SubtitleCue] {
        cues.filter { $0.startTime <= seconds && seconds < $0.endTime }
    }

    /// Default look: readable in a small window, resolution-independent.
    nonisolated static func textLayout(frameWidth: CGFloat, frameHeight: CGFloat) -> TextLayout {
        TextLayout(
            fontSize: frameHeight * 0.05,
            bottomMargin: frameHeight * 0.06,
            maxTextWidth: frameWidth * 0.9
        )
    }

    /// Canvas -> frame mapping per the SubtitleImage contract: width-aligned, center-anchored
    /// vertically (a cropped rip's canvas can be taller than the coded video); .zero canvas means
    /// canvas == frame.
    nonisolated static func imageRect(position: CGRect, canvasSize: CGSize, frameWidth: CGFloat, frameHeight: CGFloat) -> CGRect {
        guard canvasSize != .zero, canvasSize.width > 0 else { return position }
        let scale = frameWidth / canvasSize.width
        let frameCenterY = frameHeight / 2
        let canvasCenterY = canvasSize.height / 2
        let x = position.minX * scale
        let y = frameCenterY + (position.minY - canvasCenterY) * scale
        return CGRect(x: x, y: y, width: position.width * scale, height: position.height * scale)
    }
}
