// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

#if DEBUG
/// Cross-check feed: writes four captured frames of each real FEL title (decoded BL and EL as
/// yuv420p10le, an RPU.bin) next to our own raw 12-bit output with and without the residual, in a
/// layout an independent implementation can read. These titles have no reference output, so comparing
/// against another implementation is a second-implementation check of the MMR and 8-piece interpretation,
/// not a ground truth.
///
/// `AETHER_REAL_EXPORT=<dir> swift test --filter exportRealTitle`
struct DoviRealFileExportTests {

    static func planar10(_ b: CVPixelBuffer) -> Data {
        var d = Data()
        func put(_ v: UInt16) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8)) }
        let y = DoviCpuModelTests.plane(b, 0, components: 1)
        for v in y.raw { put(v >> 6) }
        let uv = DoviCpuModelTests.plane(b, 1, components: 2)
        for c in 0..<2 { for i in stride(from: c, to: uv.raw.count, by: 2) { put(uv.raw[i] >> 6) } }
        return d
    }

    @Test("export a real title for the DoViBaker cross-check",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_REAL_EXPORT"] != nil),
          .enabled(if: !DoviFelRealFileTests.firstTwoClips.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: [0, 1].filter { DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[$0]) })
    func exportRealTitle(index: Int) throws {
        let name = DoviFelRealFileTests.fixtures[index]
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AETHER_REAL_EXPORT"]!)
            .appendingPathComponent("title\(index)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 4, stride: 40))
        let sess = try DoviFelRealFileTests.open(name, composer: rec)
        defer { sess.decoder.close(); sess.demuxer.close() }
        DoviFelRealFileTests.feed(sess, count: 300)
        sess.decoder.flush()
        try #require(rec.captures.count == 4, "only \(rec.captures.count) frames reached the composer")
        // Pair every captured frame with its own RPU: the survey's "one parameter set" holds per file section,
        // not per frame. The key is the serialised block with the per-frame fields blanked.
        func key(_ p: DoviMetalParams) -> Data {
            var q = p; q.frameIndex = 0; q.ditherMode = .none; q.blWidth = 0; q.blHeight = 0; q.elWidth = 0; q.elHeight = 0; q.minPq = 0; q.maxPq = 0; q.avgPq = 0
            return q.serialize()
        }
        var rpuByKey: [Data: [UInt8]] = [:]
        let dm = Demuxer()
        try dm.open(url: DoviFelRealFileTests.url(name))
        defer { dm.close() }
        let vi = Int32(dm.videoStreamIndex)
        var seen = 0
        while seen < 600, let pkt = try dm.readPacket() {
            defer { av_packet_unref(pkt); var o: UnsafeMutablePointer<AVPacket>? = pkt; trackedPacketFree(&o) }
            guard pkt.pointee.stream_index == vi else { continue }
            seen += 1
            let r = DoviRpuConverter.separateDualLayers(pkt, extractEL: false, useCustomBlockSource: true, extractParams: true)
            if let raw = r.rpuData, let params = r.rpuParams { rpuByKey[key(params)] = raw }
        }
        var rpuBin = Data()
        for cap in rec.captures {
            let raw = try #require(rpuByKey[key(cap.params)], "no RPU in the first 600 packets matches a captured frame's parameters")
            rpuBin.append(contentsOf: [0, 0, 0, 1])
            rpuBin.append(contentsOf: raw.prefix(2) == [0x7c, 0x01] ? Array(raw.dropFirst(2)) : raw)
        }
        print("[export] \(name): \(rpuByKey.count) distinct parameter sets in \(seen) packets")

        var bl = Data(), el = Data(), ours = Data(), base = Data()
        for cap in rec.captures {
            bl.append(Self.planar10(cap.bl)); el.append(Self.planar10(cap.el))
            var raw = cap.params; raw.ditherMode = .debugRawVDR
            var baseOnly = raw; baseOnly.flags.insert(.disableResidual)
            for (p, out) in [(raw, 0), (baseOnly, 1)] {
                let buf = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: p, frameIndex: 0))
                for plane in DoviTestSupport.rawVDR(buf) { for v in plane {
                    let bytes = [UInt8(v & 0xff), UInt8(v >> 8)]
                    if out == 0 { ours.append(contentsOf: bytes) } else { base.append(contentsOf: bytes) }
                } }
            }
        }
        let first = try #require(rec.captures.first)
        try bl.write(to: dir.appendingPathComponent("bl_dec.yuv"))
        try el.write(to: dir.appendingPathComponent("el_dec.yuv"))
        try rpuBin.write(to: dir.appendingPathComponent("out.rpu"))
        try ours.write(to: dir.appendingPathComponent("ours12.yuv"))
        try base.write(to: dir.appendingPathComponent("ours12_base.yuv"))
        try "\(CVPixelBufferGetWidth(first.bl)) \(CVPixelBufferGetHeight(first.bl)) \(rec.captures.count)\n"
            .write(to: dir.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8)
        print("[export] \(name): \(CVPixelBufferGetWidth(first.bl))x\(CVPixelBufferGetHeight(first.bl)) x\(rec.captures.count) -> \(dir.path)")
    }
}
#endif
#endif
