// Only with the TrueHDObjectAudio trait (off by default): the decoder and its library are not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// End to end on a real TrueHD Atmos elementary stream: decode, render, encode. The sample is not
/// in the repository (Dolby's "Unfold" demo, TrueHD Atmos, LFE + 15 objects, 27 s), so these run
/// only when `AE_TRUEHD_ATMOS_SAMPLE` names a `.thd` file.
@Suite("TrueHD Atmos sample, decode to APAC")
struct TrueHDAtmosSampleTests {

    private static var sample: Data? {
        ProcessInfo.processInfo.environment["AE_TRUEHD_ATMOS_SAMPLE"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    @Test("objects decode with positions and render into the height speakers")
    func decodesAndRendersHeights() throws {
        guard let data = Self.sample else { return }
        let decoder = try TrueHDObjectAudioDecoder()
        let layout = SpatialSpeakerLayout.l714
        var renderer: ObjectAudioRenderer?
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 256) }
        defer { out.forEach { $0.deallocate() } }
        var energy = [Double](repeating: 0, count: layout.channelCount)
        var frames = 0, updates = 0, raisedObjects = 0
        var roles: [ObjectAudioRole] = []

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                try decoder.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                offset += n
                while let block = try decoder.nextBlock() {
                    if renderer == nil { renderer = ObjectAudioRenderer(layout: layout, roles: block.roles); roles = block.roles }
                    updates += block.updates.count
                    for u in block.updates {
                        raisedObjects += u.states.enumerated().filter {
                            block.roles[$0.offset] == .object && ($0.element?.position.z ?? 0) > 0.3
                        }.count
                    }
                    renderer!.render(inputs: block.planes, frameCount: block.frameCount,
                                     updates: block.updates, outputs: out)
                    for c in 0..<layout.channelCount {
                        for i in 0..<block.frameCount { energy[c] += Double(out[c][i] * out[c][i]) }
                    }
                    frames += block.frameCount
                }
            }
        }
        let rms = energy.map { ($0 / Double(max(frames, 1))).squareRoot() }
        print("[TrueHDAtmosSample] frames=\(frames) roles=\(roles) updates=\(updates) raisedObjectStates=\(raisedObjects)")
        print("[TrueHDAtmosSample] 7.1.4 rms dBFS: " + zip(layout.speakers, rms).map {
            "\($0.0.rawValue)=\(String(format: "%.1f", 20 * log10(max($0.1, 1e-9))))" }.joined(separator: " "))

        #expect(frames == 1_298_000)
        #expect(roles.filter { $0 == .object }.count == 15)
        #expect(roles.filter { $0 == .lfe }.count == 1)
        #expect(updates > 800, "OAMD every 1536 samples over 27 s")
        #expect(raisedObjects > 0, "Unfold moves objects overhead")
        for (c, speaker) in layout.speakers.enumerated() where speaker.isHeight {
            #expect(rms[c] > 1e-4, "\(speaker.rawValue) carries the overhead objects")
        }
    }

    @Test("the bridge turns the whole sample into contiguous APAC packets in real time and then some")
    func bridgesToAPAC() throws {
        guard let data = Self.sample else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l916, decoder: TrueHDObjectAudioDecoder())
        defer { bridge.close() }
        var pts: [Int64] = []
        var bytes = 0
        let start = Date()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(3000, raw.count - offset)
                let pkt = av_packet_alloc()!
                defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
                _ = av_new_packet(pkt, Int32(n))
                pkt.pointee.data.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                pkt.pointee.pts = offset == 0 ? 0 : Int64.min
                for fp in try bridge.feed(packet: pkt) {
                    pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
                    var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
                }
                offset += n
            }
        }
        for fp in bridge.flush() {
            pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
            var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
        }
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(pts.count * 1024) / 48_000
        print("[TrueHDAtmosSample] 9.1.6 APAC: \(pts.count) packets, \(String(format: "%.2f", seconds)) s, "
              + "\(bytes * 8 / Int(seconds) / 1000) kbps, \(String(format: "%.1f", seconds / elapsed))x realtime (debug build)")
        #expect(pts.first == Int64(0))
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        // Two packets of encoder priming, then the sample's 1,298,000 frames.
        #expect(pts.count == 2 + Int((1_298_000.0 / 1024).rounded(.up)))
    }
}
#endif
