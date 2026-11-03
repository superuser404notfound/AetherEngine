// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Foundation
import CoreVideo
import Metal
import Testing
import Dovi
@testable import AetherEngine

/// Output capture of the production GPU composer on decoded frames, for offline picture-quality gates
/// (an external script drives it and reads the result back). Skipped unless
/// `AETHER_GPU_CAPTURE_DIR` names a directory prepared by such a script (format below):
///
///     manifest.json                [{"name", "width", "height", "elWidth", "elHeight", "frames"}]
///     <name>/bl.yuv, el.yuv        yuv420p10le, `frames` pictures each (planar, tightly packed)
///     <name>/rpu_<j>.bin           the j-th picture's RPU, as in an RPU.bin (no start code, no NAL header)
///
/// For every picture it composes the base layer and the enhancement layer with the real composer and writes the
/// un-quantised 12-bit VDR planes (Y, then Cb, then Cr, little-endian 16-bit words holding the code) as
/// `<name>/gpu_<variant>_<j>.u16`, and the dither-off 10-bit output as `gpu10_<variant>_<j>.u16`; GPU times
/// land in `timings.json`. Variants: `prod` (what ships), `cosited` (the pre-Annex B chroma read) and
/// `annexb_luma` (the DEBUG Annex B luma read); `AETHER_GPU_CAPTURE_VARIANTS` (comma list) picks a subset.
@Suite(.offCooperativePoolOneLane)
struct DoviGpuCaptureTests {

    static let captureDir: URL? = ProcessInfo.processInfo.environment["AETHER_GPU_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }

    struct Entry: Decodable {
        let name: String
        let width: Int, height: Int, elWidth: Int, elHeight: Int, frames: Int
    }

    /// A P010 buffer filled from a yuv420p10le picture (`planes` at `offset` words into `words`).
    static func makeP010(_ words: UnsafeBufferPointer<UInt16>, offset: Int, width: Int, height: Int) -> CVPixelBuffer? {
        guard let buffer = DoviGpuCurveSweepTests.makeBuffer(width: width, height: height) else { return nil }
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            let dst = (yBase + y * yStride).assumingMemoryBound(to: UInt16.self)
            let src = offset + y * width
            for x in 0..<width { dst[x] = words[src + x] << 6 }
        }
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cbOff = offset + width * height, crOff = cbOff + cw * ch
        for y in 0..<ch {
            let dst = (uvBase + y * uvStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<cw {
                dst[2 * x] = words[cbOff + y * cw + x] << 6
                dst[2 * x + 1] = words[crOff + y * cw + x] << 6
            }
        }
        return buffer
    }

    static func words(_ url: URL) throws -> [UInt16] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    }

    /// Planes of a compose output as 16-bit words: Y, Cb, Cr (the raw VDR code, or the 10-bit code).
    static func planeWords(_ b: CVPixelBuffer, shift: Int) -> [UInt16] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
        let cw = CVPixelBufferGetWidthOfPlane(b, 1), ch = CVPixelBufferGetHeightOfPlane(b, 1)
        var out = [UInt16](repeating: 0, count: w * h + 2 * cw * ch)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        let yb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = yb[y * ys + x] >> UInt16(shift) } }
        let cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1) / 2
        let cb = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt16.self)
        for y in 0..<ch {
            for x in 0..<cw {
                out[w * h + y * cw + x] = cb[y * cs + 2 * x] >> UInt16(shift)
                out[w * h + cw * ch + y * cw + x] = cb[y * cs + 2 * x + 1] >> UInt16(shift)
            }
        }
        return out
    }

    @Test("captures the production composer's output on prepared frames",
          .enabled(if: DoviGpuCaptureTests.captureDir != nil && MTLCreateSystemDefaultDevice() != nil, "set AETHER_GPU_CAPTURE_DIR"))
    func capture() throws {
        let dir = try #require(Self.captureDir)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let wanted = ProcessInfo.processInfo.environment["AETHER_GPU_CAPTURE_VARIANTS"].map { Set($0.split(separator: ",").map(String.init)) }
        let reps = Int(ProcessInfo.processInfo.environment["AETHER_GPU_CAPTURE_REPS"] ?? "") ?? 5
        let composer = try #require(DoviFelComposer())
        var variants: [(String, DoviComposerFlags)] = [("prod", [])]
        #if DEBUG
        variants += [("cosited", [.debugCositedElChroma]), ("annexb_luma", [.debugAnnexBElLuma])]
        #endif
        variants = variants.filter { wanted?.contains($0.0) ?? true }

        var timings: [String: [String: [Double]]] = [:]   // clip -> variant -> per-frame median GPU ms
        for entry in entries {
            let base = dir.appendingPathComponent(entry.name)
            let blWords = try Self.words(base.appendingPathComponent("bl.yuv"))
            let elWords = try Self.words(base.appendingPathComponent("el.yuv"))
            let blFrame = entry.width * entry.height + 2 * ((entry.width + 1) / 2) * ((entry.height + 1) / 2)
            let elFrame = entry.elWidth * entry.elHeight + 2 * ((entry.elWidth + 1) / 2) * ((entry.elHeight + 1) / 2)
            for j in 0..<entry.frames {
                var rpuBytes = [UInt8](try Data(contentsOf: base.appendingPathComponent("rpu_\(j).bin")))
                if rpuBytes.first == 0x19 { rpuBytes = [0x7C, 0x01] + rpuBytes }   // the unspec62 NAL header libdovi expects
                let parsed: DoviMetalParams? = rpuBytes.withUnsafeBufferPointer { buf in
                    guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
                    defer { dovi_rpu_free(rpu) }
                    return DoviFelComposer.parseRpuParameters(rpu: rpu)
                }
                let params = try #require(parsed, "\(entry.name) frame \(j): the RPU does not parse")
                let bl = try #require(blWords.withUnsafeBufferPointer { Self.makeP010($0, offset: j * blFrame, width: entry.width, height: entry.height) })
                let el = try #require(elWords.withUnsafeBufferPointer { Self.makeP010($0, offset: j * elFrame, width: entry.elWidth, height: entry.elHeight) })
                for (variant, flags) in variants {
                    var raw = params; raw.ditherMode = .debugRawVDR; raw.flags.formUnion(flags)
                    var ten = params; ten.ditherMode = .none; ten.flags.formUnion(flags)
                    var ms = [Double]()
                    for rep in 0..<(reps + 1) {
                        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: raw))
                        #if DEBUG
                        if rep > 0 { ms.append(composer.lastGpuSecondsForTesting * 1000) }   // the first run warms the pipelines
                        #endif
                        if rep == 0 {
                            let words = Self.planeWords(out, shift: 4)
                            try words.withUnsafeBytes { Data($0) }.write(to: base.appendingPathComponent("gpu_\(variant)_\(j).u16"))
                        }
                    }
                    let out10 = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: ten))
                    let words10 = Self.planeWords(out10, shift: 6)
                    try words10.withUnsafeBytes { Data($0) }.write(to: base.appendingPathComponent("gpu10_\(variant)_\(j).u16"))
                    if !ms.isEmpty {
                        ms.sort()
                        timings[entry.name, default: [:]][variant, default: []].append(ms[ms.count / 2])
                    }
                }
            }
        }
        try JSONEncoder().encode(timings).write(to: dir.appendingPathComponent("timings.json"))
    }
}
#endif
