// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Diagnostic probe result for Dolby Vision Profile 7 FEL dual-layer Metal reconstruction.
@_spi(Diagnostics)
public struct FelProbeResult: Sendable {
    public let packetsProcessed: Int
    /// Frames delivered, composed or not: a frame that bypassed the composer comes out as its base layer.
    public let framesReconstructed: Int
    /// Frames the composer actually reconstructed. Zero means the stream never composed (a bypass on
    /// every frame, a failed shader, a stream that is not FEL), whatever `framesReconstructed` says.
    public let composedFrames: Int
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let isFEL: Bool
    public let durationSeconds: Double
    public let fps: Double
    public let avgLuma: Double
    public let avgCb: Double
    public let avgCr: Double
    public let stdDevCb: Double
    public let stdDevCr: Double
    public let isChromaValid: Bool
    /// Frames that came out carrying a `DolbyVisionRPUData` attachment (per-frame L1/L2 display
    /// metadata). Should equal `framesReconstructed` on a Profile 7 source.
    public let framesWithDVMetadata: Int
    /// Distinct RPU payloads seen. Dolby Vision L1 is usually per-frame, so a healthy stream produces
    /// a value close to `framesWithDVMetadata`; a single distinct payload means static metadata,
    /// which a static-metadata clip legitimately has, or something upstream collapsed it.
    public let distinctDVPayloads: Int
    /// Byte length of the first RPU payload attached, for eyeballing against the bitstream.
    public let firstDVPayloadBytes: Int
    /// Leading bytes of the first RPU payload, hex. A well-formed payload starts `19`, the
    /// Dolby Vision RPU prefix, because the `unspec62` NAL's 2-byte header has been stripped.
    public let firstDVPayloadPrefix: String
}

extension AetherEngine {

    /// Diagnostic probe that decodes both the base layer and the enhancement layer (typically 1080p) in hardware,
    /// evaluates inverse NLQ and reshaping curves on Apple GPU via Metal, and produces 10-bit P010 frames.
    @_spi(Diagnostics)
    public nonisolated static func felDecodeProbe(
        url: URL,
        maxPackets: Int = 100,
        options: LoadOptions = .init()
    ) throws -> FelProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, demuxer.stream(at: videoIdx) != nil else {
            throw AetherEngineError.noVideoStream
        }
        // An `hev1` file with in-band parameter sets has an empty hvcC; the load path completes it
        // from the head of the stream before routing, and the probe must open the decoders on the
        // same record or it reports a failure the real route does not have. Seeks back to 0.
        VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(demuxer: demuxer, streamIndex: videoIdx)
        guard let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }

        final class Accum: @unchecked Sendable {
            var framesReconstructed = 0
            var width = 0
            var height = 0
            var pixelFormat = ""
            var isFEL = false
            var sumLuma: Double = 0
            var sumCb: Double = 0
            var sumCr: Double = 0
            var sumSqCb: Double = 0
            var sumSqCr: Double = 0
            var pixelSampleCount: Int = 0
            var framesWithDVMetadata = 0
            var dvPayloads = Set<Data>()
            var firstDVPayloadBytes = 0
            var firstDVPayloadPrefix = ""
            let lock = NSLock()
        }

        let accum = Accum()
        let startTime = CFAbsoluteTimeGetCurrent()

        let dualDecoder = DualLayerVideoDecoder()
        try dualDecoder.open(stream: stream) { pixelBuffer, pts, _ in
            accum.lock.lock()
            defer { accum.lock.unlock() }
            if accum.framesReconstructed == 0 {
                accum.width = CVPixelBufferGetWidth(pixelBuffer)
                accum.height = CVPixelBufferGetHeight(pixelBuffer)
                let code = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let b0 = Character(UnicodeScalar((code >> 24) & 0xff) ?? " ")
                let b1 = Character(UnicodeScalar((code >> 16) & 0xff) ?? " ")
                let b2 = Character(UnicodeScalar((code >> 8) & 0xff) ?? " ")
                let b3 = Character(UnicodeScalar(code & 0xff) ?? " ")
                accum.pixelFormat = "\(b0)\(b1)\(b2)\(b3)"
            }

            // Per-frame Dolby Vision display metadata: check the attachment actually rode out
            // with the frame rather than trusting that it was set.
            if let rpu = CVBufferCopyAttachment(pixelBuffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data {
                accum.framesWithDVMetadata += 1
                accum.dvPayloads.insert(rpu)
                if accum.firstDVPayloadBytes == 0 {
                    accum.firstDVPayloadBytes = rpu.count
                    accum.firstDVPayloadPrefix = rpu.prefix(12).map { String(format: "%02x", $0) }.joined()
                }
            }

            // Sample pixels across center region to compute pixel stats
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            if let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
               let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                let y16 = yPlane.assumingMemoryBound(to: UInt16.self)
                let uv16 = uvPlane.assumingMemoryBound(to: UInt16.self)
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
                let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2

                // Sample 512 points across active center 50%
                let stepX = max(1, (w / 2) / 32)
                let stepY = max(1, (h / 2) / 16)
                let startX = (w / 4)
                let startY = (h / 4)
                for sy in stride(from: startY, to: startY + h / 2, by: stepY) {
                    for sx in stride(from: startX, to: startX + w / 2, by: stepX) {
                        let lumaVal = Double(y16[sy * yStride + sx] >> 6)
                        let cbVal = Double(uv16[(sy / 2) * uvStride + (sx / 2) * 2] >> 6)
                        let crVal = Double(uv16[(sy / 2) * uvStride + (sx / 2) * 2 + 1] >> 6)

                        accum.sumLuma += lumaVal
                        accum.sumCb += cbVal
                        accum.sumCr += crVal
                        accum.sumSqCb += cbVal * cbVal
                        accum.sumSqCr += crVal * crVal
                        accum.pixelSampleCount += 1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            accum.framesReconstructed += 1
        }
        defer { dualDecoder.close() }

        var packetsProcessed = 0

        while packetsProcessed < maxPackets {
            let maybePacket: UnsafeMutablePointer<AVPacket>?
            do {
                maybePacket = try demuxer.readPacket()
            } catch {
                break
            }
            guard let packet = maybePacket else { break }

            if packet.pointee.stream_index == videoIdx {
                packetsProcessed += 1
                dualDecoder.decode(packet: packet)
            }

            av_packet_unref(packet)
            var opt: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&opt)
        }

        // Not drained: `flush()` retires the frames still in flight rather than delivering them, so the
        // last few packets' frames are not counted. The decoder has no drain-and-deliver call, and the
        // verdicts are over a hundred frames, so the tail is left as it is.
        dualDecoder.flush()

        // A frame already in flight can still reach the callback on the decoder's delivery queue
        // while this thread reads the totals, so every read goes through one snapshot under the lock.
        accum.lock.lock()
        let framesReconstructed = accum.framesReconstructed
        let width = accum.width
        let height = accum.height
        let pixelFormat = accum.pixelFormat
        let sumLuma = accum.sumLuma
        let sumCb = accum.sumCb
        let sumCr = accum.sumCr
        let sumSqCb = accum.sumSqCb
        let sumSqCr = accum.sumSqCr
        let pixelSampleCount = accum.pixelSampleCount
        let framesWithDVMetadata = accum.framesWithDVMetadata
        let distinctDVPayloads = accum.dvPayloads.count
        let firstDVPayloadBytes = accum.firstDVPayloadBytes
        let firstDVPayloadPrefix = accum.firstDVPayloadPrefix
        accum.lock.unlock()

        let elapsed = max(CFAbsoluteTimeGetCurrent() - startTime, 0.001)
        let fps = Double(framesReconstructed) / elapsed

        let n = Double(max(1, pixelSampleCount))
        let meanLuma = sumLuma / n
        let meanCb = sumCb / n
        let meanCr = sumCr / n
        let varCb = max(0, (sumSqCb / n) - (meanCb * meanCb))
        let varCr = max(0, (sumSqCr / n) - (meanCr * meanCr))
        let stdDevCb = sqrt(varCb)
        let stdDevCr = sqrt(varCr)

        // Chroma is invalid if collapsed to flat 64 (stdDev < 1.0 and mean ~64)
        let isChromaFlat64 = (abs(meanCb - 64.0) < 1.0 && stdDevCb < 1.0)
        let isChromaValid = !isChromaFlat64 && (meanCb > 100.0)

        return FelProbeResult(
            packetsProcessed: packetsProcessed,
            framesReconstructed: framesReconstructed,
            composedFrames: dualDecoder.composedFrameCount,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            isFEL: dualDecoder.streamClassification == .fel,
            durationSeconds: elapsed,
            fps: fps,
            avgLuma: meanLuma,
            avgCb: meanCb,
            avgCr: meanCr,
            stdDevCb: stdDevCb,
            stdDevCr: stdDevCr,
            isChromaValid: isChromaValid,
            framesWithDVMetadata: framesWithDVMetadata,
            distinctDVPayloads: distinctDVPayloads,
            firstDVPayloadBytes: firstDVPayloadBytes,
            firstDVPayloadPrefix: firstDVPayloadPrefix
        )
    }

}

extension AetherEngine {
    /// Off composes every Profile 7 FEL frame without its residual, which is what a MEL stream
    /// decodes to; on is the full FEL result. For A/B viewing (`aetherctl play --cycle-el`): it
    /// takes effect from the next composed frame and applies to every session in the process.
    @_spi(Diagnostics)
    public nonisolated static var felResidualEnabled: Bool {
        get { DoviFelComposer.residualEnabled }
        set { DoviFelComposer.residualEnabled = newValue }
    }
}
#endif
