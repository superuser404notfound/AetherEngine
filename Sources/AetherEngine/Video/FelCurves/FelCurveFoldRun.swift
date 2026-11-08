// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

@_spi(Diagnostics)
public struct FelCurveFoldResult: Sendable {
    /// The Profile 8.1 RPU of every video frame in presentation order, as unspec62 NAL payloads without
    /// their 2-byte NAL header (the layout of a dovi_tool RPU file entry).
    public let rpus: [[UInt8]]
    public let scenesFitted: Int
    public let scenesWithoutResidual: Int
    public let scenesFailed: Int
    public let seconds: Double
}

extension AetherEngine {
    /// Diagnostic: runs a whole Profile 7 FEL source through the curve fold the segment producer uses and
    /// returns the RPUs it produced, so they can be injected into the base layer and played back by the
    /// platform decoder.
    @_spi(Diagnostics)
    public nonisolated static func felCurveFold(url: URL, options: LoadOptions = .init()) throws -> FelCurveFoldResult {
        let start = Date()
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx), let par = stream.pointee.codecpar else {
            throw AetherEngineError.noVideoStream
        }
        let framing = A53SEIParser.nalFraming(codec: .hevc, extradata: par.pointee.extradata.map { UnsafePointer($0) },
                                              size: Int(par.pointee.extradata_size))
        let lookahead = FelCurveLookahead(videoStreamIndex: Int32(videoIdx), stream: stream, framing: framing)
        var out: [(Int64, [UInt8])] = []
        while let packet = try lookahead.next(read: { try demuxer.readPacket() }) {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == Int32(videoIdx), let data = packet.pointee.data else { continue }
            let pts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
            A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, len in
                guard (nal[0] >> 1) & 0x3F == 62, len > 2 else { return }
                out.append((pts, [UInt8](UnsafeBufferPointer(start: nal + 2, count: len - 2))))
            }
        }
        out.sort { $0.0 < $1.0 }
        return FelCurveFoldResult(rpus: out.map(\.1), scenesFitted: lookahead.scenesFitted,
                                  scenesWithoutResidual: lookahead.scenesWithoutResidual,
                                  scenesFailed: lookahead.scenesFailed, seconds: Date().timeIntervalSince(start))
    }
}
#endif
