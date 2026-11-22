import Foundation
import AetherLibavutil
@testable import AetherEngine

/// #853: interlaced frames built in memory from a pattern moving sideways (the same smooth pattern as
/// `TelecineCadenceFixtures`, uncompressed), so the inverse telecine graph and the cadence sampler can be
/// tested on exact pixels without a codec.
///
/// - Film: progressive frames 6 px apart, put on video by a 3:2 pulldown, top field first. Four film
///   frames A B C D become five video frames: (A,A) (B,B) (B,C) (C,D) (D,D), as (top, bottom) fields.
/// - Video: every field its own instant, 2.4 px apart (the film's speed at 59.94 fields a second).
///
/// Video frame `k` carries PTS `firstPTS + k` on `timeBase` (1001/30000), flagged interlaced and top
/// field first, like an NTSC DVD frame out of libavcodec.
enum TelecineFrameSynthesizer {

    static let width: Int32 = 160
    static let height: Int32 = 120
    static let timeBase = AVRational(num: 1001, den: 30000)
    static let frameRate = DeinterlaceConfig.SourceFrameRate(num: 30000, den: 1001)
    /// Pixels the pattern moves per film frame.
    static let filmStep = 6.0
    /// Film frames after which the pattern repeats exactly: 20 x 6 px is three of its 40 px periods.
    static let filmPeriod = 20

    static func luma(x: Int, y: Int, shift: Double) -> UInt8 {
        let value = 128 + 90 * sin(2 * .pi * (Double(x) + shift) / 40) * cos(2 * .pi * Double(y) / 80)
        return UInt8(clamping: Int(value.rounded()))
    }

    /// The film frames each video frame's (top, bottom) fields come from, for a 3:2 pulldown.
    static func pulldownFields(videoFrame k: Int) -> (top: Int, bottom: Int) {
        let cycle = k / 5, phase = k % 5
        let base = cycle * 4
        switch phase {
        case 0: return (base, base)
        case 1: return (base + 1, base + 1)
        case 2: return (base + 1, base + 2)
        case 3: return (base + 2, base + 3)
        default: return (base + 3, base + 3)
        }
    }

    /// A video frame whose even rows show the pattern at `topShift` and odd rows at `bottomShift`.
    static func frame(topShift: Double, bottomShift: Double, pts: Int64,
                      interlaced: Bool = true) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = width
        f.pointee.height = height
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.sample_aspect_ratio = AVRational(num: 8, den: 9)
        if interlaced {
            f.pointee.flags |= (1 << 3) | (1 << 4)  // AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST
        }
        _ = av_frame_get_buffer(f, 0)
        let lumaStride = Int(f.pointee.linesize.0)
        let luma = f.pointee.data.0!
        for y in 0..<Int(height) {
            let shift = y % 2 == 0 ? topShift : bottomShift
            for x in 0..<Int(width) { luma[y * lumaStride + x] = Self.luma(x: x, y: y, shift: shift) }
        }
        for plane in 1...2 {
            let stride = Int(plane == 1 ? f.pointee.linesize.1 : f.pointee.linesize.2)
            let data = plane == 1 ? f.pointee.data.1! : f.pointee.data.2!
            for y in 0..<Int(height / 2) { memset(data + y * stride, 128, Int(width / 2)) }
        }
        return f
    }

    static func telecinedFrame(_ k: Int, firstPTS: Int64 = 0) -> UnsafeMutablePointer<AVFrame> {
        let fields = pulldownFields(videoFrame: k)
        return frame(topShift: Double(fields.top) * filmStep, bottomShift: Double(fields.bottom) * filmStep,
                     pts: firstPTS + Int64(k))
    }

    static func interlacedVideoFrame(_ k: Int, firstPTS: Int64 = 0) -> UnsafeMutablePointer<AVFrame> {
        let fieldStep = filmStep * 24 / 60
        return frame(topShift: Double(2 * k) * fieldStep, bottomShift: Double(2 * k + 1) * fieldStep,
                     pts: firstPTS + Int64(k))
    }

    /// The film frame `frame` reproduces exactly (mean luma difference below half a level), searched
    /// over `0..<filmFrames`; nil when it matches none (a deinterlaced or combed picture).
    static func matchingFilmFrame(_ frame: UnsafeMutablePointer<AVFrame>, filmFrames: Int) -> Int? {
        // NV12 as well, since a GPU graph's output downloads to it with the same luma plane.
        guard frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue || frame.pointee.format == AV_PIX_FMT_NV12.rawValue,
              let luma = frame.pointee.data.0 else { return nil }
        let rowBytes = Int(frame.pointee.linesize.0)
        for index in 0..<filmFrames {
            let shift = Double(index) * filmStep
            var total = 0
            for y in stride(from: 0, to: Int(height), by: 3) {
                for x in stride(from: 0, to: Int(width), by: 2) {
                    total += abs(Int(luma[y * rowBytes + x]) - Int(Self.luma(x: x, y: y, shift: shift)))
                }
            }
            let samples = ((Int(height) + 2) / 3) * (Int(width) / 2)
            if Double(total) / Double(samples) < 0.5 { return index }
        }
        return nil
    }
}
