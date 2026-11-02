import Foundation
import Testing
import CoreVideo
import Metal
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The GPU route for 10-bit AV1 (`GPUFrameConverter`) must hand the display the picture dav1d would
/// have: the same film grain, the same P010 samples `sws_scale` writes. Opt-in media check, since no
/// clip is committed: `AV1_FILM_GRAIN_CLIP` names a 10-bit AV1 file with film grain (an `.ivf` or
/// `.mkv`), `AV1_FILM_GRAIN_FRAMES` how many frames to compare (48 by default). Both decoders take the
/// same packets; every frame is compared sample for sample.
@Suite("AV1 film grain on the GPU matches dav1d (media)", .serialized)
struct AV1FilmGrainGPUTests {

    nonisolated static let clip = ProcessInfo.processInfo.environment["AV1_FILM_GRAIN_CLIP"]
        .map { URL(fileURLWithPath: $0) }
    nonisolated static let frameLimit = ProcessInfo.processInfo.environment["AV1_FILM_GRAIN_FRAMES"]
        .flatMap(Int.init) ?? 48

    @Test("every sample matches dav1d's grain and sws_scale's P010", .enabled(if: AV1FilmGrainGPUTests.clip != nil))
    func gpuMatchesDav1d() throws {
        let url = try #require(Self.clip)
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))

        let cpuFrames = FrameSink()
        let gpuFrames = FrameSink()
        let saved = GPUFrameConverter.enabled
        defer { GPUFrameConverter.enabled = saved }

        GPUFrameConverter.enabled = false
        let cpu = SoftwareVideoDecoder()
        try cpu.open(stream: stream) { pb, pts, _ in cpuFrames.add(pb, pts: pts) }
        defer { cpu.close() }
        GPUFrameConverter.enabled = true
        let gpu = SoftwareVideoDecoder()
        try gpu.open(stream: stream) { pb, pts, _ in gpuFrames.add(pb, pts: pts) }
        defer { gpu.close() }
        #expect(cpu.gpuConversionCounts == nil)
        #expect(gpu.gpuConversionCounts != nil)

        var report = Report()
        var packets = 0
        while report.frames < Self.frameLimit, let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex {
                packets += 1
                cpu.decode(packet: pkt)
                gpu.decode(packet: pkt)
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            while let a = cpuFrames.first, let b = gpuFrames.first {
                cpuFrames.removeFirst()
                gpuFrames.removeFirst()
                report.compare(a, b)
            }
        }

        let counts = try #require(gpu.gpuConversionCounts)
        print("[AV1FilmGrainGPUTests] \(packets) packets, \(report.frames) frames compared; GPU converted "
              + "\(counts.converted), grained \(counts.grained), copied \(counts.copied); "
              + "Y mismatches \(report.yMismatches), CbCr mismatches \(report.uvMismatches), "
              + "largest difference \(report.maxDifference)"
              + (report.firstMismatch.map { "; first at \($0)" } ?? ""))
        #expect(report.frames > 0)
        #expect(counts.grained > 0, "the clip carried no film grain, so the grain path was not exercised")
        #expect(report.yMismatches == 0)
        #expect(report.uvMismatches == 0)
        #expect(report.ptsMismatches == 0)
    }

    /// `AV1_FILM_GRAIN_BENCH=gpu` or `cpu`: decodes the whole clip through one route and prints the CPU time
    /// the process spent (user + system) against the wall time. Run in release for numbers that mean anything.
    nonisolated static let benchRoute = ProcessInfo.processInfo.environment["AV1_FILM_GRAIN_BENCH"]

    @Test("CPU time of one route over the clip", .enabled(if: AV1FilmGrainGPUTests.clip != nil && AV1FilmGrainGPUTests.benchRoute != nil))
    func benchmark() throws {
        let url = try #require(Self.clip)
        let gpuRoute = Self.benchRoute == "gpu"
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let saved = GPUFrameConverter.enabled
        defer { GPUFrameConverter.enabled = saved }
        GPUFrameConverter.enabled = gpuRoute
        let counter = Counter()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, _, _ in counter.increment() }
        defer { decoder.close() }

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let cpuStart = cpuSeconds()
        let wallStart = Date()
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        let cpu = cpuSeconds() - cpuStart
        let wall = Date().timeIntervalSince(wallStart)
        let frames = counter.value
        print(String(format: "[AV1FilmGrainGPUTests] bench %@: %d frames, CPU %.2f s (%.2f ms/frame), wall %.2f s (%.0f fps)",
                     gpuRoute ? "GPU route" : "CPU route", frames, cpu, cpu * 1000 / Double(max(frames, 1)),
                     wall, Double(frames) / wall))
        #expect(frames > 0)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    struct Frame {
        let pts: CMTime
        let width: Int, height: Int
        let y: [UInt16], uv: [UInt16]
    }

    struct Report {
        var frames = 0
        var yMismatches = 0
        var uvMismatches = 0
        var ptsMismatches = 0
        var maxDifference = 0
        var firstMismatch: String?

        mutating func compare(_ a: Frame, _ b: Frame) {
            frames += 1
            if CMTimeCompare(a.pts, b.pts) != 0 { ptsMismatches += 1 }
            for (plane, x, y) in [("Y", a.y, b.y), ("CbCr", a.uv, b.uv)] {
                for i in 0..<min(x.count, y.count) where x[i] != y[i] {
                    if plane == "Y" { yMismatches += 1 } else { uvMismatches += 1 }
                    maxDifference = max(maxDifference, abs(Int(x[i] >> 6) - Int(y[i] >> 6)))
                    if firstMismatch == nil {
                        // A CbCr row holds `width` samples too: width / 2 pairs.
                        firstMismatch = "frame \(frames - 1) \(plane) sample \(i % a.width),\(i / a.width): "
                            + "dav1d+sws \(x[i] >> 6) vs GPU \(y[i] >> 6)"
                    }
                }
            }
        }
    }

    final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Frame] = []

        var first: Frame? { lock.withLock { frames.first } }
        func removeFirst() { lock.withLock { _ = frames.removeFirst() } }

        func add(_ pb: CVPixelBuffer, pts: CMTime) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            func plane(_ index: Int, rows: Int, samples: Int) -> [UInt16] {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, index)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, index)
                var out = [UInt16](repeating: 0, count: rows * samples)
                out.withUnsafeMutableBytes { dst in
                    for r in 0..<rows {
                        (dst.baseAddress! + r * samples * 2).copyMemory(from: base + r * stride, byteCount: samples * 2)
                    }
                }
                return out
            }
            let frame = Frame(pts: pts, width: width, height: height,
                              y: plane(0, rows: height, samples: width),
                              uv: plane(1, rows: (height + 1) / 2, samples: ((width + 1) / 2) * 2))
            lock.withLock { frames.append(frame) }
        }
    }
}

/// The same check without media, so it runs wherever Metal does: a synthetic 10-bit 4:2:0 picture, 200 by
/// 120 so blocks and overlaps meet the edges, under three fixed sets of AV1 film grain parameters, against
/// the digests of what dav1d 1.5.4's own `dav1d_apply_grain` makes of the same picture and parameters
/// (`Scripts/av1-film-grain-reference.c`, which prints them; rerun it when dav1d moves).
@Suite("AV1 film grain on the GPU matches dav1d (synthetic)", .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct AV1FilmGrainGPUReferenceTests {

    static let width = 200, height = 120
    static func ySample(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 37 + y * 101 + ((x * y) & 255) * 3) % 1024) }
    static func uSample(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 53 + y * 29 + 300) % 1024) }
    static func vSample(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 19 + y * 71 + 700) % 1024) }

    struct Grain {
        var seed: UInt64
        var yPoints: [(UInt8, UInt8)]
        var cbPoints: [(UInt8, UInt8)] = []
        var crPoints: [(UInt8, UInt8)] = []
        var chromaScalingFromLuma = false
        var scalingShift: Int32
        var lag: Int32
        var coeffsY: [Int8] = []
        var coeffsCb: [Int8] = []
        var coeffsCr: [Int8] = []
        var coeffShift: Int32
        var grainScaleShift: Int32 = 0
        var uvMult: (Int32, Int32) = (0, 0)
        var uvMultLuma: (Int32, Int32) = (0, 0)
        var uvOffset: (Int32, Int32) = (0, 0)
        var overlap: Bool
        var restrictedRange: Bool
    }

    /// Separate luma and chroma points, lag 3, overlap, clipped to the restricted range.
    static let separateChroma = Grain(
        seed: 0x1234, yPoints: [(0, 20), (64, 40), (128, 60), (255, 30)],
        cbPoints: [(0, 30), (255, 50)], crPoints: [(16, 10), (128, 45), (240, 20)],
        scalingShift: 10, lag: 3,
        coeffsY: (0..<24).map { Int8(($0 * 29) % 41 - 20) },
        coeffsCb: (0..<25).map { Int8(($0 * 17) % 37 - 18) }, coeffsCr: (0..<25).map { Int8(($0 * 23) % 31 - 15) },
        coeffShift: 7, uvMult: (-40, 25), uvMultLuma: (60, -30), uvOffset: (20, -35),
        overlap: true, restrictedRange: true)
    /// Chroma scaled from luma, lag 0, no overlap, full range, grain scale shift 1.
    static let chromaFromLuma = Grain(
        seed: 0xBEEF, yPoints: [(0, 64), (255, 96)], chromaScalingFromLuma: true,
        scalingShift: 9, lag: 0, coeffsCb: [30], coeffsCr: [-22], coeffShift: 6, grainScaleShift: 1,
        uvMultLuma: (64, 64), overlap: false, restrictedRange: false)
    /// Luma grain only, lag 1, overlap: chroma passes through.
    static let lumaOnly = Grain(
        seed: 0x7, yPoints: [(32, 80), (160, 50), (224, 100)],
        scalingShift: 11, lag: 1, coeffsY: (0..<4).map { Int8(10 - $0 * 7) }, coeffShift: 8,
        overlap: true, restrictedRange: false)

    /// FNV-1a 64 over each sample's low then high byte, as the reference program hashes them.
    static func digest(_ samples: [UInt16]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for s in samples {
            h = (h ^ UInt64(s & 0xFF)) &* 0x100_0000_01B3
            h = (h ^ UInt64(s >> 8)) &* 0x100_0000_01B3
        }
        return h
    }

    static func set<T, E>(_ tuple: inout T, _ values: [E]) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            let typed = raw.bindMemory(to: E.self)
            for (i, v) in values.enumerated() { typed[i] = v }
        }
    }

    static func attach(_ g: Grain, to frame: UnsafeMutablePointer<AVFrame>) throws {
        let p = try #require(av_film_grain_params_create_side_data(frame))
        p.pointee.type = AV_FILM_GRAIN_PARAMS_AV1
        p.pointee.seed = g.seed
        p.pointee.width = Int32(width); p.pointee.height = Int32(height)
        p.pointee.subsampling_x = 1; p.pointee.subsampling_y = 1
        p.pointee.bit_depth_luma = 10; p.pointee.bit_depth_chroma = 10
        var aom = AVFilmGrainAOMParams()
        aom.num_y_points = Int32(g.yPoints.count)
        set(&aom.y_points, g.yPoints.flatMap { [$0.0, $0.1] })
        aom.chroma_scaling_from_luma = g.chromaScalingFromLuma ? 1 : 0
        aom.num_uv_points = (Int32(g.cbPoints.count), Int32(g.crPoints.count))
        var uv = [UInt8](repeating: 0, count: 2 * 10 * 2)
        for (i, pt) in g.cbPoints.enumerated() { uv[i * 2] = pt.0; uv[i * 2 + 1] = pt.1 }
        for (i, pt) in g.crPoints.enumerated() { uv[20 + i * 2] = pt.0; uv[20 + i * 2 + 1] = pt.1 }
        set(&aom.uv_points, uv)
        aom.scaling_shift = g.scalingShift
        aom.ar_coeff_lag = g.lag
        set(&aom.ar_coeffs_y, g.coeffsY)
        var coeffsUV = [Int8](repeating: 0, count: 2 * 25)
        for (i, c) in g.coeffsCb.enumerated() { coeffsUV[i] = c }
        for (i, c) in g.coeffsCr.enumerated() { coeffsUV[25 + i] = c }
        set(&aom.ar_coeffs_uv, coeffsUV)
        aom.ar_coeff_shift = g.coeffShift
        aom.grain_scale_shift = g.grainScaleShift
        aom.uv_mult = g.uvMult
        aom.uv_mult_luma = g.uvMultLuma
        aom.uv_offset = g.uvOffset
        aom.overlap_flag = g.overlap ? 1 : 0
        aom.limit_output_range = g.restrictedRange ? 1 : 0
        p.pointee.codec.aom = aom
    }

    /// The synthetic picture through `GPUFrameConverter`, read back as 10-bit Y, Cb and Cr planes.
    static func convert(_ grain: Grain?) throws -> (y: [UInt16], u: [UInt16], v: [UInt16]) {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = Int32(width); f.pointee.height = Int32(height)
        f.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        #expect(av_frame_get_buffer(f, 0) == 0)
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        func fill(_ plane: UnsafeMutablePointer<UInt8>, stride: Int32, w: Int, h: Int, _ sample: (Int, Int) -> UInt16) {
            for y in 0..<h {
                let row = UnsafeMutableRawPointer(plane + y * Int(stride)).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { row[x] = sample(x, y) }
            }
        }
        fill(f.pointee.data.0!, stride: f.pointee.linesize.0, w: width, h: height, ySample)
        fill(f.pointee.data.1!, stride: f.pointee.linesize.1, w: cw, h: ch, uSample)
        fill(f.pointee.data.2!, stride: f.pointee.linesize.2, w: cw, h: ch, vSample)
        if let grain { try attach(grain, to: f) }

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                         kCVPixelBufferMetalCompatibilityKey as String: true]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                    attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let pb = try #require(buffer)
        let converter = try #require(GPUFrameConverter())
        #expect(GPUFrameConverter.accepts(f))
        #expect(converter.convert(f, into: pb))

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var y: [UInt16] = [], u: [UInt16] = [], v: [UInt16] = []
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for r in 0..<height {
            let row = (yBase + r * yStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width { y.append(row[x] >> 6) }
        }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in 0..<ch {
            let row = (cBase + r * cStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<cw { u.append(row[2 * x] >> 6); v.append(row[2 * x + 1] >> 6) }
        }
        return (y, u, v)
    }

    static func input() -> (y: [UInt16], u: [UInt16], v: [UInt16]) {
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        return ((0..<height).flatMap { y in (0..<width).map { ySample($0, y) } },
                (0..<ch).flatMap { y in (0..<cw).map { uSample($0, y) } },
                (0..<ch).flatMap { y in (0..<cw).map { vSample($0, y) } })
    }

    @Test("without grain the frame reaches P010 unchanged, as sws_scale writes it")
    func plainConversion() throws {
        let out = try Self.convert(nil)
        let source = Self.input()
        #expect(out.y == source.y)
        #expect(out.u == source.u)
        #expect(out.v == source.v)
    }

    @Test("each parameter set grains the picture exactly as dav1d 1.5.4 does", arguments: [
        ("separate chroma points, lag 3, overlap, restricted range", separateChroma,
         UInt64(0x0A79_4163_CECE_F7C4), UInt64(0x71A7_0EC9_C22D_61A6), UInt64(0x59FE_E10A_9622_0C74)),
        ("chroma from luma, lag 0, full range", chromaFromLuma,
         UInt64(0xDBE9_F1CE_A211_666A), UInt64(0x2178_A90C_22E4_10FA), UInt64(0xEA55_0257_B0BE_5A8B)),
        ("luma only, lag 1, overlap", lumaOnly,
         UInt64(0x8514_48C0_0FB0_C78E), UInt64(0xBFD4_86A4_FE08_C751), UInt64(0x43C0_DFEE_3FB8_DEE5)),
    ])
    func matchesDav1d(_ name: String, _ grain: Grain, _ y: UInt64, _ u: UInt64, _ v: UInt64) throws {
        let out = try Self.convert(grain)
        #expect(Self.digest(out.y) == y, "\(name): luma")
        #expect(Self.digest(out.u) == u, "\(name): Cb")
        #expect(Self.digest(out.v) == v, "\(name): Cr")
    }
}
