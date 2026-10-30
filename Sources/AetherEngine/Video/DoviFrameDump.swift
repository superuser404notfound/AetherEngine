// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// One Profile 7 FEL frame composed both ways, for looking at what the enhancement layer does to it.
@_spi(Diagnostics)
public struct DoviFrameDump: Sendable {
    public let seconds: Double
    public let width: Int
    public let height: Int
    /// Full-precision P010 planes (16-bit words, video range: the 10-bit code is word / 64 with the
    /// fraction kept), luma then interleaved Cb/Cr at 4:2:0, tightly packed.
    public let felLuma: Data
    public let felChroma: Data
    public let melLuma: Data
    public let melChroma: Data
    public let l1AvgPQ: UInt16
    public let l1MaxPQ: UInt16
    /// The RPU itself switches the residual off for this frame, so `fel*` and `mel*` are the same picture.
    public let residualDisabledByRpu: Bool
}

extension AetherEngine {

    /// Decodes the keyframe at or before `seconds` (both layers, VideoToolbox) and composes it with the
    /// residual (FEL) and without it (MEL) on the dual-layer composer, at full precision. For offline
    /// inspection. The MEL picture is composed from a copy of the parameters with the residual flag set,
    /// so no process-wide state changes; the FEL picture needs `DoviFelComposer.residualEnabled` to be on
    /// (its default) and the call throws when a host has switched it off.
    @_spi(Diagnostics)
    public nonisolated static func doviFrameDump(url: URL, at seconds: Double, options: LoadOptions = .init()) throws -> DoviFrameDump {
        enum DumpError: Error { case noKeyframe, noRpu, noEnhancementLayer, decodeFailed, composeFailed, residualSwitchedOff }

        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url, extraHeaders: options.httpHeaders, profile: .stillExtraction)
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else { throw AetherEngineError.noVideoStream }
        guard demuxer.seek(to: seconds) else { throw DumpError.noKeyframe }

        var found: UnsafeMutablePointer<AVPacket>?
        for _ in 0..<64 {
            guard let p = (try? demuxer.readPacket()) ?? nil else { break }
            if p.pointee.stream_index == videoIdx, p.pointee.flags & AV_PKT_FLAG_KEY != 0 { found = p; break }
            av_packet_unref(p)
            var opt: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&opt)
        }
        guard let packet = found else { throw DumpError.noKeyframe }
        defer {
            av_packet_unref(packet)
            var opt: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&opt)
        }
        let pts = Double(packet.pointee.pts) * av_q2d(stream.pointee.time_base)

        // Rewrites `packet` in place to the base layer; the enhancement layer comes back on its own.
        let layers = DoviRpuConverter.separateDualLayers(packet, extractEL: true)
        var elPacket = layers.elPacket
        defer { if elPacket != nil { av_packet_unref(elPacket!); trackedPacketFree(&elPacket) } }
        guard let el = elPacket else { throw DumpError.noEnhancementLayer }
        guard let raw = layers.rpuData else { throw DumpError.noRpu }

        var params: DoviMetalParams?
        var avgPQ: UInt16 = 0, maxPQ: UInt16 = 0
        raw.withUnsafeBufferPointer { buf in
            guard let b = buf.baseAddress, let rpu = DoviRpuGuard.parse(b, buf.count) else { return }
            defer { dovi_rpu_free(rpu) }
            params = DoviFelComposer.parseRpuParameters(rpu: rpu)
            if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
                if let l1 = dm.pointee.dm_data.level1 { avgPQ = l1.pointee.avg_pq; maxPQ = l1.pointee.max_pq }
                dovi_rpu_free_vdr_dm_data(dm)
            }
        }
        guard let params else { throw DumpError.noRpu }

        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer: CVPixelBuffer?
            func set(_ b: CVPixelBuffer) { lock.withLock { buffer = b } }
            var value: CVPixelBuffer? { lock.withLock { buffer } }
        }
        let blSlot = Slot(), elSlot = Slot()

        let bl = HardwareVideoDecoder()
        defer { bl.close() }
        try bl.open(stream: stream) { buffer, _, _ in blSlot.set(buffer) }
        bl.decode(packet: packet)
        bl.flush()

        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        if let data = el.pointee.data {
            A53SEIParser.forEachNAL(data, Int(el.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
                let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
                switch (nal[0] >> 1) & 0x3F {
                case 32: vps = bytes
                case 33: sps = bytes
                case 34: pps = bytes
                default: break
                }
            }
        }
        guard let vps, let sps, let pps else { throw DumpError.noEnhancementLayer }
        let elDecoder = HardwareVideoDecoder()
        defer { elDecoder.close() }
        try elDecoder.open(parameterSets: [vps, sps, pps], timeBase: stream.pointee.time_base) { buffer, _, _ in elSlot.set(buffer) }
        elDecoder.decode(packet: el)
        elDecoder.flush()

        guard let blBuffer = blSlot.value, let elBuffer = elSlot.value else { throw DumpError.decodeFailed }
        guard let composer = DoviFelComposer() else { throw DumpError.composeFailed }
        composer.chromaFormat = .yuv420   // the planes below are P010's, whatever AETHER_FEL_CHROMA says

        // The composer adds the disable flag itself while this process-wide switch is off, which would
        // turn the FEL picture into a MEL one.
        guard DoviFelComposer.residualEnabled else { throw DumpError.residualSwitchedOff }

        func planes(_ buffer: CVPixelBuffer) -> (Data, Data) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            func plane(_ i: Int) -> Data {
                let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, i) * (i == 0 ? 2 : 4)
                let rows = CVPixelBufferGetHeightOfPlane(buffer, i)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, i)
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, i)!
                var out = Data(capacity: rowBytes * rows)
                for y in 0..<rows { out.append(Data(bytes: base + y * stride, count: rowBytes)) }
                return out
            }
            return (plane(0), plane(1))
        }

        // Full precision keeps the VDR bits below the 10-bit code in P010's low six bits.
        var felParams = params; felParams.ditherMode = .fullPrecision
        var melParams = params; melParams.ditherMode = .fullPrecision; melParams.flags.insert(.disableResidual)
        guard let fel = composer.compose(baseBuffer: blBuffer, enhancementBuffer: elBuffer, params: felParams) else {
            throw DumpError.composeFailed
        }
        let felPlanes = planes(fel)
        guard let mel = composer.compose(baseBuffer: blBuffer, enhancementBuffer: elBuffer, params: melParams) else {
            throw DumpError.composeFailed
        }
        let melPlanes = planes(mel)

        return DoviFrameDump(seconds: pts, width: CVPixelBufferGetWidth(fel), height: CVPixelBufferGetHeight(fel),
                             felLuma: felPlanes.0, felChroma: felPlanes.1,
                             melLuma: melPlanes.0, melChroma: melPlanes.1,
                             l1AvgPQ: avgPQ, l1MaxPQ: maxPQ,
                             residualDisabledByRpu: params.flags.contains(.disableResidual))
    }
}
#endif
