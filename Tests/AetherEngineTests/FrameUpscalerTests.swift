#if !targetEnvironment(simulator)
import Foundation
import Testing
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
@testable import AetherEngine

private enum UpscalerGate {
    static var gpuAvailable: Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    /// `isSupported` is true on GitHub's macOS runner VMs, yet every real ML pass fails there, so one
    /// real pass decides.
    static let mlAvailable: Bool = {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *), gpuAvailable,
              VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              let plan = UpscaleRouteDecision.makePlan(
                  source: SourceGeometry(width: 1280, height: 720, sarNum: 1, sarDen: 1),
                  display: CGSize(width: 1920, height: 1080), mlScaleFactors: { _, _ in [1.5] }),
              let up = FrameUpscaler(plan: plan, frameInterval: 1.0 / 24),
              let frame = try? TestFrames.nv12(1280, 720)
        else { return false }
        guard up.upscale(frame) != nil else {
            print("[FrameUpscalerTests] VT super resolution reports support but a real pass failed, skipping the ML tests")
            return false
        }
        return true
    }()
}

/// One frame in, one frame out: sizes, colour tags, flat-field fidelity, mid-stream size changes and
/// the disable paths. GPU and OS 26 gated; the ML tests also need VT low-latency super resolution.
@Suite("Frame upscaler", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)),
       .enabled(if: UpscalerGate.gpuAvailable))
struct FrameUpscalerTests {

    private static let uhd = CGSize(width: 3840, height: 2160)

    init() {
        if #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) { FrameUpscaler.resetMetalFXCostMemoryForTesting() }
    }

    private func plan(_ w: Int, _ h: Int, sar: (Int, Int) = (1, 1), display: CGSize = uhd, ml: [Float]) throws -> UpscalePlan {
        try #require(UpscaleRouteDecision.makePlan(
            source: SourceGeometry(width: w, height: h, sarNum: sar.0, sarDen: sar.1),
            display: display, mlScaleFactors: { _, _ in ml }))
    }

    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    private func upscaler(_ plan: UpscalePlan, frameInterval: Double = 1.0 / 24) throws -> FrameUpscaler {
        try #require(FrameUpscaler(plan: plan, frameInterval: frameInterval))
    }

    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func sd2xPlusMetalFXDeliversTargetSize() throws {
        let p = try plan(720, 480, sar: (8, 9), ml: [2])
        #expect(p.mlScale == 2 && p.targetWidth == 2880 && p.targetHeight == 2160 && p.needsMetalFX)
        let up = try upscaler(p)
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<10 {
            let out = try #require(up.upscale(input))
            #expect(CVPixelBufferGetWidth(out) == 2880 && CVPixelBufferGetHeight(out) == 2160)
            #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        let s = up.stats
        #expect(s.framesUpscaled == 10 && s.failures == 0)
        print(String(format: "[FrameUpscalerTests] 720x480 ML 2x + MetalFX -> 2880x2160: mean %.2f ms, max %.2f ms", s.meanMs, s.maxMs))
    }

    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func outputCarriesSquarePixelsAndInputColour() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: [2]))
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        let out = try #require(up.upscale(input))
        let par = try #require(CVBufferCopyAttachment(out, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any])
        #expect(par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? Int == 1)
        #expect(par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? Int == 1)
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            let a = CVBufferCopyAttachment(input, key, nil) as? String
            let b = CVBufferCopyAttachment(out, key, nil) as? String
            #expect(a != nil && a == b, "\(key)")
        }
    }

    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func mlOnlyPlanSkipsMetalFX() throws {
        let p = try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5])
        #expect(p.mlScale == 1.5 && !p.needsMetalFX)
        let up = try upscaler(p)
        let out = try #require(up.upscale(try TestFrames.nv12(1280, 720)))
        #expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080)
        print(String(format: "[FrameUpscalerTests] 1280x720 ML 1.5x -> 1920x1080: %.2f ms", up.stats.meanMs))
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func metalFXOnlyPlanSkipsML() throws {
        let p = try plan(720, 480, sar: (8, 9), ml: [])
        #expect(p.mlScale == nil && p.needsMetalFX)
        let up = try upscaler(p)
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<5 {
            let out = try #require(up.upscale(input))
            #expect(CVPixelBufferGetWidth(out) == 2880 && CVPixelBufferGetHeight(out) == 2160)
        }
        print(String(format: "[FrameUpscalerTests] 720x480 MetalFX -> 2880x2160: mean %.2f ms", up.stats.meanMs))
    }

    /// MetalFX alone keeps every sample. VT's ML pass carries a +-1 texture (MetalFX sharpening lifts it a
    /// little) and its edge ringing is clamped away, so the ML paths get +-4 with no border exemption.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func flatGreyStaysFlatGrey() throws {
        let grey = try TestFrames.nv12(720, 480, y: 126, c: 128)
        let mfx = try #require(try upscaler(try plan(720, 480, sar: (8, 9), ml: [])).upscale(grey))
        let all = TestFrames.planeRange(mfx)
        #expect(all.y.lowerBound >= 124 && all.y.upperBound <= 128, "MetalFX Y \(all.y)")
        #expect(all.c.lowerBound >= 126 && all.c.upperBound <= 130, "MetalFX C \(all.c)")

        guard UpscalerGate.mlAvailable else { return }
        let mlOnly = try upscaler(try plan(720, 480, display: CGSize(width: 1440, height: 960), ml: [2]))
        let both = try upscaler(try plan(720, 480, sar: (8, 9), ml: [2]))
        for (name, up) in [("ML", mlOnly), ("ML+MetalFX", both)] {
            let out = try #require(up.upscale(grey))
            let r = TestFrames.planeRange(out)
            #expect(r.y.lowerBound >= 122 && r.y.upperBound <= 130, "\(name) Y \(r.y)")
            #expect(abs(r.meanY - 126) < 0.5, "\(name) mean Y \(r.meanY)")
            #expect(abs(r.meanC - 128) < 0.5, "\(name) mean C \(r.meanC)")
        }
    }

    /// The edge clamp is pinned on a vertical gradient: the outer 12 rows repeat row 12 (top) and row
    /// h-13 (bottom), the outer 12 columns repeat column 12 / w-13.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func mlOutputBorderIsClamped() throws {
        let up = try upscaler(try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5]))
        let out = try #require(up.upscale(try TestFrames.nv12(1280, 720, vertical: true)))
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let p = CVPixelBufferGetBaseAddressOfPlane(out, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
        func y(_ x: Int, _ r: Int) -> UInt8 { p[r * s + x] }
        #expect(y(w / 2, 12) != y(w / 2, h - 13), "the input must not be flat")
        var mismatches = 0
        for r in 0..<12 {
            for x in 0..<w where y(x, r) != y(x, 12) || y(x, h - 1 - r) != y(x, h - 13) { mismatches += 1 }
        }
        for r in 0..<h {
            for x in 0..<12 where y(x, r) != y(12, r) || y(w - 1 - x, r) != y(w - 13, r) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func reconfiguresOnInputSizeChange() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: FrameUpscaler.mlScaleFactors(720, 480)))
        let first = try #require(up.upscale(try TestFrames.nv12(720, 480, par: (8, 9))))
        #expect(CVPixelBufferGetWidth(first) == 2880 && CVPixelBufferGetHeight(first) == 2160)
        let second = try #require(up.upscale(try TestFrames.nv12(704, 576)))
        #expect(CVPixelBufferGetWidth(second) == 2640 && CVPixelBufferGetHeight(second) == 2160)
        #expect(!up.isDisabled)
    }

    /// A cropped stream: the decoder buffer has padding rows below a clean aperture. The aperture is the
    /// picture, the padding (white here) must not reach the output, and the output carries no aperture or
    /// field tags of the input's geometry.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func upscalesTheCleanApertureOnly() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: []))
        let input = try TestFrames.nv12(720, 496, par: (8, 9), y: 126, c: 128)
        TestFrames.paint(input, rows: 480..<496, y: 235)
        let aperture: [String: Any] = [kCVImageBufferCleanApertureWidthKey as String: 720,
                                       kCVImageBufferCleanApertureHeightKey as String: 480,
                                       kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
                                       kCVImageBufferCleanApertureVerticalOffsetKey as String: -8]
        CVBufferSetAttachment(input, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(input, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)

        let out = try #require(up.upscale(input))
        #expect(CVPixelBufferGetWidth(out) == 2880 && CVPixelBufferGetHeight(out) == 2160)
        #expect(up.plan.sourceWidth == 720 && up.plan.sourceHeight == 480)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferCleanApertureKey, nil) == nil)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferFieldCountKey, nil) == nil)
        #expect(CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nil) != nil)
        let range = TestFrames.planeRange(out)
        #expect(range.y.lowerBound >= 124 && range.y.upperBound <= 128, "Y \(range.y)")
    }

    /// A VT pass that never calls back (session invalidated by backgrounding, media-services reset) must
    /// not hold the frame thread: bounded wait, original frame delivered, and the abandoned destination
    /// never handed out later.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func hungMLPassTimesOutAndNeverReusesItsBuffer() throws {
        let up = try upscaler(try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5]),
                              frameInterval: 1.0 / 60)
        let hung = BufferLog()
        up.mlSubmitOverride = { params, _ in if let b = params.destinationFrame?.buffer { hung.add(b) } }
        let input = try TestFrames.nv12(1280, 720)
        for _ in 0..<2 {
            let t0 = Date()
            #expect(up.upscale(input) == nil)
            #expect(Date().timeIntervalSince(t0) < 0.5)
        }
        #expect(up.stats.failures == 2 && !up.isDisabled)
        up.mlSubmitOverride = nil
        for _ in 0..<6 {
            let out = try #require(up.upscale(input))
            #expect(!hung.contains(out))
        }
        #expect(hung.count == 2)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func unsupportedFormatPassesThrough() throws {
        let up = try upscaler(try plan(720, 480, ml: []))
        let tenBit = try TestFrames.buffer(720, 480, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(up.upscale(tenBit) == nil)
        #expect(!up.isDisabled)
        #expect(up.upscale(try TestFrames.nv12(720, 480)) != nil)
    }

    /// The ladder: an over-budget ML + MetalFX stage first drops MetalFX and delivers the clamped ML output
    /// at its own size with the source's pixel aspect; only the ML-only stage tripping again disables.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func ladderDropsMetalFXBeforeDisabling() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: [2]), frameInterval: 0.0001)
        let events = EventLog()
        up.onEvent = { events.add($0) }
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<FrameUpscaler.budgetWindow {
            let out = try #require(up.upscale(input))
            #expect(CVPixelBufferGetWidth(out) == 2880 && CVPixelBufferGetHeight(out) == 2160)
        }
        #expect(!up.isDisabled && up.isDegraded)
        #expect(up.plan.targetWidth == 1440 && up.plan.targetHeight == 960 && !up.plan.needsMetalFX)
        let degraded = events.all.compactMap { e -> UpscalePlan? in
            if case let .degraded(p, _, _) = e { return p }; return nil
        }
        #expect(degraded.map(\.targetWidth) == [1440] && degraded.map(\.targetHeight) == [960])

        for i in 0..<(FrameUpscaler.budgetWindow - 1) {
            let out = try #require(up.upscale(input), "frame \(i)")
            #expect(CVPixelBufferGetWidth(out) == 1440 && CVPixelBufferGetHeight(out) == 960)
            let par = try #require(CVBufferCopyAttachment(out, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any])
            #expect(par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? Int == 8)
            #expect(par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? Int == 9)
            #expect(!up.isDisabled)
        }
        _ = up.upscale(input)
        #expect(up.isDisabled)
        #expect(up.upscale(input) == nil)
        if case .disabled = events.all.last {} else { Issue.record("last event \(String(describing: events.all.last))") }
    }

    /// A degraded stage stays ML only when another input size rebuilds it, and republishes as degraded.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func degradedStageStaysMLOnlyAcrossARebuild() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: [2]), frameInterval: 0.0001)
        let events = EventLog()
        up.onEvent = { events.add($0) }
        let sd = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<FrameUpscaler.budgetWindow { _ = up.upscale(sd) }
        try #require(up.isDegraded && !up.isDisabled)
        let other = try TestFrames.nv12(640, 360)
        guard FrameUpscaler.mlScaleFactors(640, 360).contains(where: { $0 > 1 }) else { return }
        let out = try #require(up.upscale(other))
        #expect(!up.plan.needsMetalFX && up.plan.sourceWidth == 640)
        #expect(CVPixelBufferGetWidth(out) == up.plan.targetWidth && CVPixelBufferGetHeight(out) == up.plan.targetHeight)
        #expect(CVPixelBufferGetWidth(out) < 3840)
        if case let .firstFrame(p, degraded) = events.all.last {
            #expect(degraded && p.sourceWidth == 640)
        } else { Issue.record("last event \(String(describing: events.all.last))") }
    }

    /// A degrade is remembered for the process: a fresh stage with the same plan and interval (a host
    /// rebuild) starts ML only instead of paying for another overrun window.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func degradeIsRememberedForTheProcess() throws {
        let p = try plan(720, 480, sar: (8, 9), ml: [2])
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        let first = try upscaler(p, frameInterval: 0.0001)
        for _ in 0..<FrameUpscaler.budgetWindow { _ = first.upscale(input) }
        try #require(first.isDegraded && !first.isDisabled)

        let up = try upscaler(p, frameInterval: 0.0001)
        let events = EventLog()
        up.onEvent = { events.add($0) }
        let out = try #require(up.upscale(input))
        #expect(CVPixelBufferGetWidth(out) == 1440 && CVPixelBufferGetHeight(out) == 960)
        #expect(up.isDegraded && !up.isDisabled)
        let all = events.all
        try #require(all.count == 2)
        if case let .degraded(dp, reason, _) = all[0] {
            #expect(dp.targetWidth == 1440 && dp.targetHeight == 960)
            #expect(reason.contains("MetalFX to 2880x2160 overran on this device earlier"), "\(reason)")
        } else { Issue.record("first event \(all[0])") }
        if case let .firstFrame(fp, degraded) = all[1] { #expect(degraded && fp.targetWidth == 1440) } else {
            Issue.record("second event \(all[1])")
        }
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func lighterOrSlowerPlansAreNotAffected() throws {
        MetalFXCostMemory.record(.init(width: 2880, height: 2160, frameInterval: 1.0 / 60, meanMs: 20))
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        let lighter = try upscaler(try plan(720, 480, sar: (8, 9), display: CGSize(width: 1920, height: 1080), ml: []),
                                   frameInterval: 1.0 / 60)
        let a = try #require(lighter.upscale(input))
        #expect(CVPixelBufferGetWidth(a) == 1440 && CVPixelBufferGetHeight(a) == 1080 && !lighter.isDisabled)
        let slower = try upscaler(try plan(720, 480, sar: (8, 9), ml: []), frameInterval: 1.0 / 24)
        let b = try #require(slower.upscale(input))
        #expect(CVPixelBufferGetWidth(b) == 2880 && CVPixelBufferGetHeight(b) == 2160 && !slower.isDisabled)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func metalFXOnlyPlanStartsDisabledWhenRemembered() throws {
        MetalFXCostMemory.record(.init(width: 2880, height: 2160, frameInterval: 1.0 / 24, meanMs: 40))
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: []), frameInterval: 1.0 / 24)
        #expect(up.upscale(try TestFrames.nv12(720, 480, par: (8, 9))) == nil)
        #expect(up.isDisabled && !up.isDegraded)
        #expect(up.disabledReason == "MetalFX too slow on this device at 2880x2160", "\(String(describing: up.disabledReason))")
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func metalFXOnlyStillDisablesDirectly() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: []), frameInterval: 0.0001)
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<FrameUpscaler.budgetWindow { _ = up.upscale(input) }
        #expect(up.isDisabled && !up.isDegraded)
    }

    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func timingBreakdownIsRecorded() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: FrameUpscaler.mlScaleFactors(720, 480)))
        let input = try TestFrames.nv12(720, 480, par: (8, 9))
        for _ in 0..<FrameUpscaler.budgetWindow { _ = try #require(up.upscale(input)) }
        let t = up.stats.stageMeanMs
        for (name, v) in [("copy", t.copy), ("ml", t.ml), ("clamp", t.clamp), ("metal", t.metal),
                          ("metalGPU", t.metalGPU), ("attach", t.attach)] {
            #expect(v >= 0, "\(name) \(v)")
        }
        #expect(t.total > 0 && t.metal > 0)
        let sum = t.copy + t.ml + t.clamp + t.metal + t.attach
        #expect(abs(t.total - sum) <= max(1, 0.2 * t.total), "total \(t.total) vs sum \(sum)")
        print("[FrameUpscalerTests] \(t.logLine(frames: FrameUpscaler.budgetWindow, intervalMs: 1000.0 / 24))")
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func budgetGuardDisablesAfterSustainedOverrun() throws {
        let up = try upscaler(try plan(720, 480, ml: []), frameInterval: 0.0001)
        let events = EventLog()
        up.onEvent = { events.add($0) }
        let input = try TestFrames.nv12(720, 480)
        for i in 0..<47 {
            #expect(up.upscale(input) != nil, "frame \(i)")
            #expect(!up.isDisabled)
        }
        _ = up.upscale(input)
        #expect(up.isDisabled)
        #expect(up.upscale(input) == nil)
        let all = events.all
        #expect(all.count == 2)
        if case .firstFrame = all.first {} else { Issue.record("first event \(String(describing: all.first))") }
        if case let .disabled(_, stats) = all.last { #expect(stats.framesUpscaled == 48) } else {
            Issue.record("last event \(String(describing: all.last))")
        }
    }

    /// Deinterlaced SD runs at field rate: the configured interval says 25 fps, the frames arrive at 50.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func budgetFollowsTheDeliveredFrameRate() throws {
        let up = try upscaler(try plan(720, 480, ml: []), frameInterval: 1.0 / 25)
        let input = try TestFrames.nv12(720, 480)
        #expect(abs(up.frameBudgetMs - 30) < 0.001)
        for i in 0..<8 { _ = up.upscale(input, pts: CMTime(value: Int64(i), timescale: 50)) }
        #expect(abs(up.frameBudgetMs - 30) < 0.001, "seven deltas still use the configured interval")
        _ = up.upscale(input, pts: CMTime(value: 8, timescale: 50))
        #expect(abs(up.frameBudgetMs - 15) < 0.001)
        #expect(abs(up.mlTimeout - 0.06) < 0.0001)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func liveIntervalIgnoresNonPositiveDeltas() throws {
        #expect(FrameUpscaler.liveInterval(deltas: [], configured: 0.04) == 0.04)
        #expect(FrameUpscaler.liveInterval(deltas: Array(repeating: 0.02, count: 7), configured: 0.04) == 0.04)
        #expect(FrameUpscaler.liveInterval(deltas: [0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 5], configured: 0.04) == 0.02)
        let up = try upscaler(try plan(720, 480, ml: []), frameInterval: 1.0 / 25)
        let input = try TestFrames.nv12(720, 480)
        for v in [0, 0, 1, 1, 0, 2, 3, 4, 5, 6, 7, 8, 9] as [Int64] {
            _ = up.upscale(input, pts: CMTime(value: v, timescale: 50))
        }
        #expect(abs(up.frameBudgetMs - 15) < 0.001)
    }
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func seekGapsDoNotStretchTheInterval() throws {
        let up = try upscaler(try plan(720, 480, ml: []), frameInterval: 1.0 / 25)
        let input = try TestFrames.nv12(720, 480)
        for i in 0..<10 { _ = up.upscale(input, pts: CMTime(value: Int64(i) * 5, timescale: 1)) }
        #expect(abs(up.frameBudgetMs - 30) < 0.001)
        #expect(abs(up.mlTimeout - 0.12) < 0.0001)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func deliveredPlanFollowsTheFirstFrame() throws {
        let up = try upscaler(try plan(720, 480, ml: []), frameInterval: 1.0 / 25)
        #expect(up.deliveredPlan == nil)
        _ = up.upscale(try TestFrames.nv12(720, 480), pts: .zero)
        #expect(up.deliveredPlan?.sourceWidth == 720)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func backgroundRefusalIsClassified() {
        let notPermitted = NSError(domain: MTLCommandBufferErrorDomain,
                                   code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
        #expect(FrameUpscaler.isBackgroundRefusal(notPermitted))
        #expect(!FrameUpscaler.isBackgroundRefusal(NSError(domain: MTLCommandBufferErrorDomain,
                                                           code: Int(MTLCommandBufferError.Code.timeout.rawValue))))
        #expect(!FrameUpscaler.isBackgroundRefusal(NSError(domain: NSCocoaErrorDomain,
                                                           code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))))
    }

    /// iOS refuses GPU work in the background. That must neither count as a failure nor disable the stage
    /// for the rest of the film; any other error still does after three in a row.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func backgroundRefusalNeverDisables() throws {
        let up = try upscaler(try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5]))
        let input = try TestFrames.nv12(1280, 720)
        let notPermitted = NSError(domain: MTLCommandBufferErrorDomain,
                                   code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
        up.mlSubmitOverride = { _, done in done(notPermitted) }
        for _ in 0..<6 { #expect(up.upscale(input) == nil) }
        #expect(!up.isDisabled && up.stats.failures == 0)
        up.mlSubmitOverride = nil
        #expect(up.upscale(input) != nil)

        up.mlSubmitOverride = { _, done in done(NSError(domain: NSCocoaErrorDomain, code: 1)) }
        for _ in 0..<3 { #expect(up.upscale(input) == nil) }
        #expect(up.isDisabled)
    }
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func lateCompletionReleasesTheAbandonedBuffers() throws {
        let up = try upscaler(try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5]),
                              frameInterval: 1.0 / 60)
        let late = CompletionLog()
        up.mlSubmitOverride = { _, done in late.add(done) }
        #expect(up.upscale(try TestFrames.nv12(1280, 720)) == nil)
        #expect(up.abandonedMLPasses == 1)
        late.finishAll()
        #expect(up.abandonedMLPasses == 0)
        #expect(!up.isDisabled)
    }

    /// Timeouts that never complete keep their buffers out of the pools; past 8 the stage gives up.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func tooManyOutstandingTimeoutsDisable() throws {
        let up = try upscaler(try plan(1280, 720, display: CGSize(width: 1920, height: 1080), ml: [1.5]),
                              frameInterval: 1.0 / 60)
        let input = try TestFrames.nv12(1280, 720)
        for i in 1...9 {
            up.mlSubmitOverride = { _, _ in }
            #expect(up.upscale(input) == nil)
            #expect(up.isDisabled == (i == 9), "timeout \(i)")
            guard i < 9 else { break }
            #expect(up.abandonedMLPasses == i)
            up.mlSubmitOverride = nil
            #expect(up.upscale(input) != nil, "recovery after timeout \(i)")
        }
        #expect(up.disabledReason?.contains("too many ML timeouts") == true, "\(String(describing: up.disabledReason))")
    }
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func kernelsCompileOncePerDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let a = try #require(UpscaleKernels.shared(for: device))
        let b = try #require(UpscaleKernels.shared(for: device))
        #expect(a === b)
        _ = try upscaler(try plan(720, 480, ml: []))
        #expect(UpscaleKernels.shared(for: device) === a)
    }

    /// Another size mid-stream republishes: the engine replaces `activeUpscale` with the new plan.
    @Test(.enabled(if: UpscalerGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func firstFrameIsSentAgainAfterARebuild() throws {
        let up = try upscaler(try plan(720, 480, sar: (8, 9), ml: []))
        let events = EventLog()
        up.onEvent = { events.add($0) }
        for _ in 0..<3 { _ = try #require(up.upscale(try TestFrames.nv12(720, 480, par: (8, 9)))) }
        for _ in 0..<3 { _ = try #require(up.upscale(try TestFrames.nv12(704, 576))) }
        let plans = events.all.compactMap { e -> UpscalePlan? in if case let .firstFrame(p, _) = e { return p }; return nil }
        try #require(plans.count == 2)
        #expect(plans.map(\.sourceWidth) == [720, 704] && plans.map(\.sourceHeight) == [480, 576])
        let status = UpscaleStatus.afterFirstFrame(plans[1], current: UpscaleStatus.afterFirstFrame(plans[0], current: nil))
        #expect(status.sourceSize == CGSize(width: 704, height: 576))
        #expect(status.targetSize == CGSize(width: plans[1].targetWidth, height: plans[1].targetHeight))
    }
}

private final class CompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable (Error?) -> Void] = []
    func add(_ done: @escaping @Sendable (Error?) -> Void) { lock.lock(); pending.append(done); lock.unlock() }
    func finishAll() {
        lock.lock(); let all = pending; pending = []; lock.unlock()
        for done in all { done(nil) }
    }
}

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private extension FrameUpscaler {
    /// No timing: the configured interval stays in force.
    func upscale(_ input: CVPixelBuffer) -> CVPixelBuffer? { upscale(input, pts: .invalid) }
}

private final class BufferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CVPixelBuffer] = []
    func add(_ b: CVPixelBuffer) { lock.lock(); buffers.append(b); lock.unlock() }
    func contains(_ b: CVPixelBuffer) -> Bool { lock.lock(); defer { lock.unlock() }; return buffers.contains { $0 === b } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return buffers.count }
}

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FrameUpscaler.Event] = []
    func add(_ e: FrameUpscaler.Event) { lock.lock(); events.append(e); lock.unlock() }
    var all: [FrameUpscaler.Event] { lock.lock(); defer { lock.unlock() }; return events }
}

private enum TestFrames {
    struct Failure: Error {}

    static func buffer(_ w: Int, _ h: Int, format: OSType) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw Failure() }
        return pb
    }

    /// A 420v BT.709 frame, a soft gradient unless `y`/`c` pin it flat.
    static func nv12(_ w: Int, _ h: Int, par: (Int, Int)? = nil, y fixedY: UInt8? = nil, c fixedC: UInt8? = nil,
                     vertical: Bool = false) throws -> CVPixelBuffer {
        let pb = try buffer(w, h, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        if let par {
            let dict: [String: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: par.0,
                                       kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: par.1]
            CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, dict as CFDictionary, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            for x in 0..<w { yp[row * ys + x] = fixedY ?? UInt8(40 + ((vertical ? row : x) * 160) / max((vertical ? h : w) - 1, 1)) }
        }
        for row in 0..<(h / 2) {
            for x in 0..<(w / 2) {
                cp[row * cs + x * 2] = fixedC ?? UInt8(112 + (row * 32) / max(h / 2 - 1, 1))
                cp[row * cs + x * 2 + 1] = fixedC ?? UInt8(144 - (x * 32) / max(w / 2 - 1, 1))
            }
        }
        return pb
    }

    static func paint(_ pb: CVPixelBuffer, rows: Range<Int>, y value: UInt8) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        for row in rows { memset(p + row * stride, Int32(value), CVPixelBufferGetWidth(pb)) }
    }

    /// Min/max and mean of each plane.
    static func planeRange(_ pb: CVPixelBuffer)
        -> (y: ClosedRange<Int>, c: ClosedRange<Int>, meanY: Double, meanC: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        func scan(_ plane: Int, _ bytes: Int) -> (ClosedRange<Int>, Double) {
            let p = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            var lo = 255, hi = 0, sum = 0, count = 0
            for row in 0..<h {
                for x in 0..<(w * bytes) {
                    let v = Int(p[row * stride + x])
                    lo = min(lo, v); hi = max(hi, v); sum += v; count += 1
                }
            }
            return (lo...hi, Double(sum) / Double(max(count, 1)))
        }
        let y = scan(0, 1), c = scan(1, 2)
        return (y.0, c.0, y.1, c.1)
    }
}
#endif
