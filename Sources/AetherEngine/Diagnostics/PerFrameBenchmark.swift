import Foundation
import CoreMedia
import CoreVideo
import Metal

/// One timed piece of per-frame work, in microseconds of wall time per frame.
public struct PerFrameBenchmarkResult: Codable, Sendable, Equatable {
    public let name: String
    public let iterations: Int
    public let minMicroseconds: Double
    public let medianMicroseconds: Double
    public let p95Microseconds: Double
    public let p99Microseconds: Double
    public let maxMicroseconds: Double
    /// Why a case did not run, or what else it measured (the frame chain's GPU time).
    public let note: String?
}

/// What `AetherEngine.runPerFrameBenchmarks` measured, and where.
public struct PerFrameBenchmarkReport: Codable, Sendable, Equatable {
    public let device: String
    public let os: String
    public let width: Int
    public let height: Int
    public let results: [PerFrameBenchmarkResult]
}

extension AetherEngine {
    /// Times the per-frame work the software path does around each decoded frame, at the given picture
    /// size (4K P010 by default): the output metadata normalizer's three outcomes, the renderer's sample
    /// buffer, the HDR10 key-frame SEI scan and the frame chain. For finding regressions and judging
    /// optimisations on a device; `aetherctl bench` runs it, and a tvOS host can call it.
    @MainActor
    public static func runPerFrameBenchmarks(iterations: Int = 300, width: Int = 3840,
                                             height: Int = 2160) -> PerFrameBenchmarkReport {
        PerFrameBenchmark(iterations: max(iterations, 10), width: width, height: height).run()
    }
}

@MainActor
struct PerFrameBenchmark {
    let iterations: Int
    let width: Int
    let height: Int
    /// False skips the frame chain cases, which compile the chain's kernels (minutes on a cold CI runner)
    /// and wait on the GPU: for the unit test, which checks the case list and the report.
    var includesChain = true
    static let warmup = 20

    /// A typical HDR10 master (BT.2020, 1000 nit, MaxCLL 1000 / 400), in Core Video's byte layout.
    static let hdr10 = HDR10StaticMetadataSEI.Values(
        masteringDisplay: HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                              masteringMinNits: 0.005).masteringDisplayColorVolume,
        contentLightLevel: HDR10StaticMetadataSEI.contentLightLevel(maxCLL: 1000, maxFALL: 400))

    func run() -> PerFrameBenchmarkReport {
        var results: [PerFrameBenchmarkResult] = []
        if let frame = makeFrame() {
            results.append(normalizerAlreadyTagged(frame))
            results.append(normalizerInPlace(frame))
            results.append(normalizerOwnedCopy(frame))
            results.append(rendererSampleBuffer(frame))
            if includesChain {
                results.append(chainPassThrough(frame, onePass: true))
                results.append(chainPassThrough(frame, onePass: false))
            } else {
                results.append(Self.skipped("chain: pass-through, wall time", "not requested"))
                results.append(Self.skipped("chain: two passes through RGB, wall time", "not requested"))
            }
        } else {
            results.append(Self.skipped("frames", "could not create a \(width)x\(height) P010 buffer"))
        }
        results.append(keyFrameSEIScan())
        return PerFrameBenchmarkReport(device: Self.deviceName(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                                       width: width, height: height, results: results)
    }

    // MARK: - Cases

    /// The common case once the frame carries everything: five attachment reads and compares.
    private func normalizerAlreadyTagged(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        _ = apply(normalizer, frame, modifiable: true)
        return time("normalizer: frame already tagged") { _ = apply(normalizer, frame, modifiable: false) }
    }

    /// A decoder buffer VideoToolbox lets us modify: the attachments are written in place.
    private func normalizerInPlace(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        return time("normalizer: tag in place", prepare: { Self.strip(frame) }) {
            _ = apply(normalizer, frame, modifiable: true)
        }
    }

    /// A decoder buffer VideoToolbox still owns: the frame is copied into a pool of our own first.
    private func normalizerOwnedCopy(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        Self.strip(frame)
        return time("normalizer: owned copy") { _ = apply(normalizer, frame, modifiable: false) }
    }

    /// Every frame on its way to the display layer, with the format description cache hit.
    private func rendererSampleBuffer(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let renderer = SampleBufferRenderer()
        _ = apply(VideoToolboxOutputMetadataNormalizer(), frame, modifiable: true)
        var n: Int64 = 0
        return time("renderer: sample buffer") {
            n += 1
            _ = renderer.createSampleBuffer(from: frame, pts: CMTime(value: n, timescale: 24))
        }
    }

    /// A 4K key frame of about 250 KB: the in-band scan for the HDR10 SEI walks every NAL of it.
    private func keyFrameSEIScan() -> PerFrameBenchmarkResult {
        let packet = Self.keyFramePacket(sliceBytes: 250_000)
        return packet.withUnsafeBufferPointer { bytes in
            time("sei: HDR10 scan of a 250 KB key frame") {
                _ = HDR10StaticMetadataSEI.scan(bytes.baseAddress!, size: bytes.count, codec: .hevc,
                                                framing: .lengthPrefixed(size: 4))
            }
        }
    }

    /// The chain's colour round trip: as one kernel (what a chain of pass-through stages runs), and as the
    /// two passes through the RGB texture that every other stage needs.
    private func chainPassThrough(_ frame: CVPixelBuffer, onePass: Bool) -> PerFrameBenchmarkResult {
        let name = onePass ? "chain: pass-through, wall time" : "chain: two passes through RGB, wall time"
        #if targetEnvironment(simulator)
        return Self.skipped(name, "the frame chain is not built for the simulator")
        #else
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) else {
            return Self.skipped(name, "the frame chain needs OS 26")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let chain = try? FrameChain(device: device, queue: queue, sourceWidth: width, sourceHeight: height,
                                          targetWidth: width, targetHeight: height, stages: [PassThroughStage()],
                                          fusesRoundTrip: onePass)
        else { return Self.skipped(name, "no Metal device or the chain could not be built") }
        let picture = FrameUpscaler.pictureRegion(of: frame)
        var gpu: [Double] = []
        var result = time(name) {
            if let (_, ms) = try? chain.process(frame, picture: picture) { gpu.append(ms) }
        }
        gpu.sort()
        if !gpu.isEmpty {
            result = PerFrameBenchmarkResult(
                name: result.name, iterations: result.iterations, minMicroseconds: result.minMicroseconds,
                medianMicroseconds: result.medianMicroseconds, p95Microseconds: result.p95Microseconds,
                p99Microseconds: result.p99Microseconds, maxMicroseconds: result.maxMicroseconds,
                note: String(format: "GPU median %.0f us", gpu[gpu.count / 2] * 1000))
        }
        return result
        #endif
    }

    // MARK: - Helpers

    private func apply(_ normalizer: VideoToolboxOutputMetadataNormalizer, _ frame: CVPixelBuffer,
                       modifiable: Bool) -> CVPixelBuffer {
        normalizer.applyingOutputMetadata(
            to: frame, isModifiable: modifiable,
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, pixelAspectRatio: nil, hdr10: Self.hdr10)
    }

    private static func strip(_ frame: CVPixelBuffer) {
        CVBufferRemoveAttachment(frame, kCVImageBufferMasteringDisplayColorVolumeKey)
        CVBufferRemoveAttachment(frame, kCVImageBufferContentLightLevelInfoKey)
    }

    /// Times `body` after a warm-up; `prepare` runs before each call, outside the timing.
    private func time(_ name: String, prepare: () -> Void = {}, _ body: () -> Void) -> PerFrameBenchmarkResult {
        for _ in 0 ..< Self.warmup { prepare(); body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            prepare()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            body()
            samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000)
        }
        samples.sort()
        func at(_ q: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        return PerFrameBenchmarkResult(name: name, iterations: iterations, minMicroseconds: samples[0],
                                       medianMicroseconds: at(0.5), p95Microseconds: at(0.95),
                                       p99Microseconds: at(0.99), maxMicroseconds: samples[samples.count - 1],
                                       note: nil)
    }

    private static func skipped(_ name: String, _ why: String) -> PerFrameBenchmarkResult {
        PerFrameBenchmarkResult(name: name, iterations: 0, minMicroseconds: 0, medianMicroseconds: 0,
                                p95Microseconds: 0, p99Microseconds: 0, maxMicroseconds: 0, note: why)
    }

    /// A 10-bit 4:2:0 IOSurface frame, written once so its pages are real, tagged as PQ BT.2020.
    private func makeFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                                        kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0 ..< CVPixelBufferGetPlaneCount(buffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, 0x40, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// AUD, the HDR10 SEI, then slice data with no `00 00` in it (as after emulation prevention).
    static func keyFramePacket(sliceBytes: Int) -> [UInt8] {
        var rbsp: [UInt8] = [137, 24] + [UInt8](hdr10.masteringDisplay ?? Data()) + [144, 4]
            + [UInt8](hdr10.contentLightLevel ?? Data()) + [0x80]
        var sei: [UInt8] = [39 << 1, 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 { sei.append(3); zeros = 0 }
            sei.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        rbsp.removeAll()
        let nals: [[UInt8]] = [[35 << 1, 1, 0x50], sei]
            + (0 ..< 4).map { i in [19 << 1, 1] + (0 ..< sliceBytes / 4).map { UInt8(0x11 &+ UInt8(truncatingIfNeeded: $0 &* 7 &+ i)) | 1 } }
        return nals.flatMap { nal in
            [UInt8(nal.count >> 24 & 0xFF), UInt8(nal.count >> 16 & 0xFF), UInt8(nal.count >> 8 & 0xFF),
             UInt8(nal.count & 0xFF)] + nal
        }
    }

    private static func deviceName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
