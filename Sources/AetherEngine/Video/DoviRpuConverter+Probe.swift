import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Result of a `doviConvertProbe` run over a source's HEVC video stream.
public struct DoviConvertProbeResult: Sendable {
    public let packetsProcessed: Int
    public let conversions: Int
    public let failures: Int
    public let outputPath: String
    public let videoStreamFound: Bool
    /// Enhancement-layer type of the first P7 RPU seen ("FEL"/"MEL"), or nil if not a P7 source.
    public let enhancementLayerType: String?
}

extension AetherEngine {

    // MARK: - Dovi convert probe (aetherctl dovitest)

    private nonisolated static let doviProbeStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// The head of the probe's output: the source's VPS/SPS/PPS, so `dovi_tool`'s parser can walk the stream. hvcC keeps them out of band and they are re-emitted start-coded; Annex-B extradata already is start-coded and is written as it is.
    nonisolated static func doviProbeParameterSets(
        extradata: UnsafePointer<UInt8>?, size: Int, framing: VideoNALFraming
    ) -> Data {
        guard let extradata, size > 0 else { return Data() }
        switch framing {
        case .annexB:
            return Data(bytes: extradata, count: size)
        case .lengthPrefixed:
            var out = Data()
            for nal in parseHVCCParameterSets(extradata, size) {
                out.append(contentsOf: doviProbeStartCode)
                out.append(contentsOf: nal)
            }
            return out
        }
    }

    /// One packet as Annex B: every NAL behind a four-byte start code, whichever framing the packet arrived in.
    nonisolated static func doviProbeAnnexB(_ packet: UnsafePointer<AVPacket>, framing: VideoNALFraming) -> Data {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return Data() }
        var out = Data()
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, len in
            out.append(contentsOf: doviProbeStartCode)
            out.append(nal, count: len)
        }
        return out
    }

    /// Walk every HEVC video packet, run `convertPacketToProfile81`, and write the result as Annex B for validation with `dovi_tool extract-rpu`. The source's own NAL framing is resolved once from its extradata and used for the converter, the enhancement-layer probe and the writer alike, so an Annex-B source (a disc remux) is walked as what it is. False returns are counted as failures but still emitted. A read or write error ends the run by throwing rather than reporting the part that was done.
    public nonisolated static func doviConvertProbe(
        url: URL,
        outputPath: String,
        options: LoadOptions = .init()
    ) throws -> DoviConvertProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            return DoviConvertProbeResult(
                packetsProcessed: 0, conversions: 0, failures: 0,
                outputPath: outputPath, videoStreamFound: false,
                enhancementLayerType: nil
            )
        }

        // O_NOFOLLOW: the output name may sit in a directory other users can write to.
        let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        var extradata: UnsafePointer<UInt8>?
        var extradataSize = 0
        if let cp = stream.pointee.codecpar, let ed = cp.pointee.extradata, cp.pointee.extradata_size > 0 {
            extradata = UnsafePointer(ed)
            extradataSize = Int(cp.pointee.extradata_size)
        }
        let framing = A53SEIParser.nalFraming(codec: .hevc, extradata: extradata, size: extradataSize)
        try handle.write(contentsOf: doviProbeParameterSets(
            extradata: extradata, size: extradataSize, framing: framing))

        var packetsProcessed = 0
        var conversions = 0
        var failures = 0
        var elType: String? = nil

        while let packet = try demuxer.readPacket() {
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            guard packet.pointee.stream_index == videoIdx else { continue }
            packetsProcessed += 1
            if elType == nil {
                elType = DoviRpuConverter.enhancementLayerType(packet, framing: framing)
            }
            if DoviRpuConverter.convertPacketToProfile81(packet, framing: framing) {
                conversions += 1
            } else {
                failures += 1
            }
            try handle.write(contentsOf: doviProbeAnnexB(packet, framing: framing))
        }

        return DoviConvertProbeResult(
            packetsProcessed: packetsProcessed,
            conversions: conversions,
            failures: failures,
            outputPath: outputPath,
            videoStreamFound: true,
            enhancementLayerType: elType
        )
    }
}
