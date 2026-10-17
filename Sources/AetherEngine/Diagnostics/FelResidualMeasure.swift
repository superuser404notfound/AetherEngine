// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreVideo
import CoreMedia
import os

/// Diagnostic: how much the enhancement-layer residual changes the picture. With `AETHER_FEL_MEASURE=N`
/// in the environment, every Nth composed frame is composed a second time with the residual off (what a
/// minimal enhancement layer would give) and the two are compared in 10-bit codes per plane: absolute
/// differences for size, and the signed mean (FEL minus MEL) for direction, so a residual that brightens
/// shows as a positive `signed`. Dithering
/// is disabled in both so only the residual differs. Off by default; costs two extra compositions per
/// sampled frame, which can briefly take pool buffers, so it is for measurement runs, not playback.
enum FelResidualMeasure {
    static let stride: Int = {
        guard let v = ProcessInfo.processInfo.environment["AETHER_FEL_MEASURE"], let n = Int(v), n > 0 else { return 0 }
        return n
    }()

    private static let queue = DispatchQueue(label: "aether.fel.measure", qos: .utility)

    /// True while a sample is queued or running. A sample retains its two source buffers and takes two
    /// pool buffers, so a sample that arrives while one is in flight is skipped rather than queued
    /// behind it: a stride smaller than the sampling time would otherwise pile up held buffers.
    private static let inFlight = OSAllocatedUnfairLock(initialState: false)

    static func sampleIfDue(composer: DoviFelComposer, base: CVPixelBuffer, enhancement: CVPixelBuffer,
                            params: DoviMetalParams, frameIndex: UInt32, pts: CMTime) {
        guard stride > 0, Int(frameIndex) % stride == 0 else { return }
        guard inFlight.withLock({ busy in
            if busy { return false }
            busy = true
            return true
        }) else { return }
        let b = SendableBuffer(value: base), e = SendableBuffer(value: enhancement)
        queue.async {
            defer { inFlight.withLock { $0 = false } }
            measure(composer: composer, base: b.value, enhancement: e.value, params: params, frameIndex: frameIndex, pts: pts)
        }
    }

    private static func measure(composer: DoviFelComposer, base: CVPixelBuffer, enhancement: CVPixelBuffer,
                                params: DoviMetalParams, frameIndex: UInt32, pts: CMTime) {
        var full = params; full.ditherMode = .none; full.flags.remove(.disableResidual)
        var mel = params; mel.ditherMode = .none; mel.flags.insert(.disableResidual)
        guard let a = composer.compose(baseBuffer: base, enhancementBuffer: enhancement, params: full, frameIndex: frameIndex),
              let m = composer.compose(baseBuffer: base, enhancementBuffer: enhancement, params: mel, frameIndex: frameIndex)
        else { return }
        let planes = ["Y", "Cb", "Cr"]
        var parts: [String] = []
        for (k, name) in planes.enumerated() {
            let s = stats(a, m, plane: k)
            parts.append(String(format: "%@ diff=%.2f%% mean=%.3f signed=%+.3f p99=%d max=%d ge2=%.3f%% ge4=%.3f%%",
                                name, s.diffPct, s.mean, s.signedMean, s.p99, s.max, s.ge2Pct, s.ge4Pct))
            if k == 0 {
                let mean: String = s.bandMean.map { String(format: "%.2f", $0) }.joined(separator: "/")
                let signed: String = s.bandSignedMean.map { String(format: "%+.2f", $0) }.joined(separator: "/")
                let share: String = s.bandFrac.map { String(format: "%.1f", $0) }.joined(separator: "/")
                parts.append("Yband[0-255|256-511|512-767|768+] mean=\(mean) signed=\(signed) share%=\(share)")
            }
        }
        EngineLog.emit("[FELMeasure] pts=\(String(format: "%.3f", pts.seconds)) " + parts.joined(separator: " | "), category: .swPlayback)
    }

    private struct Stats { var diffPct = 0.0, mean = 0.0, signedMean = 0.0, p99 = 0, max = 0, ge2Pct = 0.0, ge4Pct = 0.0, bandMean = [Double](repeating: 0, count: 4), bandSignedMean = [Double](repeating: 0, count: 4), bandFrac = [Double](repeating: 0, count: 4) }

    private static func stats(_ x: CVPixelBuffer, _ y: CVPixelBuffer, plane k: Int) -> Stats {
        CVPixelBufferLockBaseAddress(x, .readOnly); CVPixelBufferLockBaseAddress(y, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(x, .readOnly); CVPixelBufferUnlockBaseAddress(y, .readOnly) }
        let p = k == 0 ? 0 : 1
        let w = CVPixelBufferGetWidthOfPlane(x, p), h = CVPixelBufferGetHeightOfPlane(x, p)
        let stx = CVPixelBufferGetBytesPerRowOfPlane(x, p) / 2, sty = CVPixelBufferGetBytesPerRowOfPlane(y, p) / 2
        let px = CVPixelBufferGetBaseAddressOfPlane(x, p)!.assumingMemoryBound(to: UInt16.self)
        let py = CVPixelBufferGetBaseAddressOfPlane(y, p)!.assumingMemoryBound(to: UInt16.self)
        var hist = [Int](repeating: 0, count: 1024)
        var bandSum = [Int](repeating: 0, count: 4), bandSigned = [Int](repeating: 0, count: 4), bandN = [Int](repeating: 0, count: 4)
        var signedSum = 0
        let comps = k == 0 ? 1 : 2, off = k == 2 ? 1 : 0
        for row in 0..<h {
            for col in 0..<w {
                let i = col * comps + (comps == 2 ? off : 0)
                let a = Int(px[row * stx + i] >> 6), b = Int(py[row * sty + i] >> 6)
                let d = abs(a - b)
                hist[min(d, 1023)] += 1
                signedSum += a - b
                if k == 0 { let band = min(b >> 8, 3); bandSum[band] += d; bandSigned[band] += a - b; bandN[band] += 1 }
            }
        }
        let n = w * h
        var s = Stats()
        var sum = 0, cum = 0, p99Set = false
        for d in 0..<1024 {
            sum += d * hist[d]
            cum += hist[d]
            if hist[d] > 0 { s.max = d }
            if !p99Set, cum * 100 >= n * 99 { s.p99 = d; p99Set = true }
        }
        s.diffPct = Double(n - hist[0]) * 100 / Double(n)
        s.mean = Double(sum) / Double(n)
        s.signedMean = Double(signedSum) / Double(n)
        s.ge2Pct = Double(hist[2...].reduce(0, +)) * 100 / Double(n)
        s.ge4Pct = Double(hist[4...].reduce(0, +)) * 100 / Double(n)
        for i in 0..<4 {
            if bandN[i] > 0 {
                s.bandMean[i] = Double(bandSum[i]) / Double(bandN[i])
                s.bandSignedMean[i] = Double(bandSigned[i]) / Double(bandN[i])
            }
            s.bandFrac[i] = Double(bandN[i]) * 100 / Double(n)
        }
        return s
    }
}
#endif
