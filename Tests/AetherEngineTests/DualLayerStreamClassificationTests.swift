// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import Metal
import AetherLibavcodec
@testable import AetherEngine

/// Stream classification is decided once, from the first RPU's `el_type`, before
/// the enhancement decoder opens. A per-frame `disable_residual_flag` is a kernel flag
/// (`DoviComposerFlags.disableResidual`, honoured by the composer) and must never shut
/// off the enhancement layer for the rest of the session.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct DualLayerStreamClassificationTests {

    // MARK: - Fixtures

    private static let frameTicks: Int64 = 3754

    private static func pts(_ frame: Int64) -> CMTime {
        CMTime(value: frame * frameTicks, timescale: 90000)
    }

    private static var metalAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<next], radix: 16) { bytes.append(byte) }
            i = next
        }
        return bytes
    }

    /// 2-byte HEVC NAL header + payload.
    private func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// Pack complete NALs into an AVCC (4-byte BE length prefix) AVPacket.
    private func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            bytes.append(UInt8((n >> 24) & 0xFF))
            bytes.append(UInt8((n >> 16) & 0xFF))
            bytes.append(UInt8((n >> 8) & 0xFF))
            bytes.append(UInt8(n & 0xFF))
            bytes.append(contentsOf: nal)
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    private func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }

    private func packetResult(
        isFEL: Bool,
        isMEL: Bool = false,
        params: DoviMetalParams? = nil
    ) -> DoviRpuConverter.DualLayerPacketResult {
        DoviRpuConverter.DualLayerPacketResult(
            elPacket: nil, rpuData: nil, rpuParams: params,
            isFEL: isFEL, isMEL: isMEL, success: true
        )
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        guard status == kCVReturnSuccess, let buf = out else { return nil }
        return buf
    }

    private static func baseLayer() -> CVPixelBuffer? { makeBuffer(width: 256, height: 256) }
    private static func enhancementLayer() -> CVPixelBuffer? { makeBuffer(width: 128, height: 128) }

    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 256; p.blHeight = 256; p.elWidth = 128; p.elHeight = 128
        return p
    }

    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [(CVPixelBuffer, CMTime)] = []

        func record(_ buffer: CVPixelBuffer, _ pts: CMTime, _ hdr10: Data?) {
            lock.lock()
            buffers.append((buffer, pts))
            lock.unlock()
        }

        var snapshot: [(CVPixelBuffer, CMTime)] {
            lock.lock(); defer { lock.unlock() }; return buffers
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return buffers.count }
    }

    // MARK: - classifyStream unit tests

    @Test("classifyStream maps a FEL packet result to FEL")
    func classifyFEL() {
        #expect(DoviRpuConverter.classifyStream(packetResult(isFEL: true)) == .fel)
    }

    @Test("classifyStream maps a MEL packet result to MEL")
    func classifyMEL() {
        #expect(DoviRpuConverter.classifyStream(packetResult(isFEL: false, isMEL: true)) == .mel)
    }

    @Test("classifyStream maps a packet with no RPU signal to undetermined")
    func classifyUndetermined() {
        #expect(DoviRpuConverter.classifyStream(packetResult(isFEL: false)) == .undetermined)
    }

    @Test("classifyStream ignores the per-frame disable_residual kernel flag")
    func classifyIgnoresDisableResidualFlag() {
        var p = Self.params()
        p.flags.insert(.disableResidual)
        // This is what `separateDualLayers` now produces for a FEL RPU with
        // `disable_residual_flag` set: FEL reporting plus the kernel flag.
        let result = packetResult(isFEL: true, params: p)
        #expect(DoviRpuConverter.classifyStream(result) == .fel)
    }

    // MARK: - Converter integration over a real RPU

    @Test("a real FEL RPU classifies FEL, not MEL")
    func realFELRPUClassifiesFEL() {
        // Raw unspec62 NAL (header included) from a FEL title; shared with DoviFelMathTests.
        let rpu = Self.hexToBytes(DoviFelMathTests.clipARpuHex)
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA, 0xBB]), rpu])
        defer { free(pkt) }

        let result = DoviRpuConverter.separateDualLayers(pkt)
        #expect(result.isFEL)
        #expect(!result.isMEL)
        #expect(DoviRpuConverter.classifyStream(result) == .fel)
        #expect(result.rpuParams != nil)
    }

    // MARK: - Decoder one-shot latch

    @Test("a FEL stream stays FEL across a disable_residual RPU and later reports")
    func felStaysFELAcrossDisableResidualFrame() {
        let decoder = DualLayerVideoDecoder()
        defer { decoder.close() }
        #expect(decoder.streamClassificationForTesting == .undetermined)

        var residualParams = Self.params()
        residualParams.flags.insert(.disableResidual)

        decoder.classifyPacketResultForTesting(packetResult(isFEL: true))
        #expect(decoder.streamClassificationForTesting == .fel)
        #expect(decoder.engagesEnhancementLayerForTesting())

        // One RPU with the residual switched off: kernel flag only, the EL keeps decoding.
        decoder.classifyPacketResultForTesting(packetResult(isFEL: true, params: residualParams))
        #expect(decoder.streamClassificationForTesting == .fel)
        #expect(decoder.engagesEnhancementLayerForTesting())

        // A later MEL report cannot flip the one-shot latch either.
        decoder.classifyPacketResultForTesting(packetResult(isFEL: false, isMEL: true))
        #expect(decoder.streamClassificationForTesting == .fel)
        #expect(decoder.engagesEnhancementLayerForTesting())
    }

    @Test("the first RPU decides: MEL never engages the enhancement layer")
    func melNeverEngagesEnhancementLayer() {
        let decoder = DualLayerVideoDecoder()
        defer { decoder.close() }

        decoder.classifyPacketResultForTesting(packetResult(isFEL: false, isMEL: true))
        #expect(decoder.streamClassificationForTesting == .mel)
        #expect(!decoder.engagesEnhancementLayerForTesting())

        // A later FEL report cannot reopen what MEL never opened.
        decoder.classifyPacketResultForTesting(packetResult(isFEL: true))
        #expect(decoder.streamClassificationForTesting == .mel)
        #expect(!decoder.engagesEnhancementLayerForTesting())
    }

    @Test("a MEL-primed decoder delivers the base layer directly")
    func melBypassesToBaseLayer() async throws {
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeStreamForTesting(.mel)
        defer { decoder.close() }

        let bl = try #require(Self.baseLayer())
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(0), hdr10Data: nil)

        // A bypass is a `fulfil` onto `OrderedDelivery`'s queue
        // (`queue.async`), not a synchronous call to `onFrame` on the calling
        // thread, so `handleBaseLayerFrame` returning is no longer proof the
        // frame has been delivered.
        try await waitFor { deliveries.count == 1 }
        let got = deliveries.snapshot
        #expect(got.count == 1)
        #expect(got.first?.0 === bl)
    }

    @Test("a frame whose RPU disables the residual still composes with its enhancement layer")
    func disableResidualFrameStillComposes() async throws {
        guard Self.metalAvailable else { return }
        let bl = try #require(Self.baseLayer())
        let el = try #require(Self.enhancementLayer())
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder()
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeStreamForTesting(.fel)
        defer { decoder.close() }

        var p = Self.params()
        p.flags.insert(.disableResidual)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: p, displayMetadataNAL: nil)

        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(1), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(1))

        try await waitFor { deliveries.count == 1 }
        let got = try #require(deliveries.snapshot.first)
        #expect(got.0 !== bl, "a disable_residual RPU must not bypass composition")
    }
}
#endif
