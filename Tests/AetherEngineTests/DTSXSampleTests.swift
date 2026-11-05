// Only with the DTSXObjectAudio trait (off by default): the decoder is not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// End to end on real DTS-HD elementary streams: verdict, decode, the bed regression, encode. The samples are
/// not in the repository, so each test runs only when its variable names a `.dts` file:
/// `AE_DTSX_SAMPLE` the "DTS:X Object Emulator" demo (standard 7.1.4, 95 s),
/// `AE_DTSX_ALTERNATE_SAMPLE` Trinnov's "Experience" trailer (7.1.4 plus five moving objects, 44 s,
/// refused),
/// `AE_DTS_HD_MA_SAMPLE` a DTS-HD Master Audio stream without DTS:X (FFmpeg's FATE
/// `dts/master_audio_7.1_24bit.dts`). LibDTSX's README (the decoder these replaced) says where to
/// get them.
@Suite("DTS:X samples, decode to APAC")
struct DTSXSampleTests {

    private static func sample(_ variable: String) -> Data? {
        ProcessInfo.processInfo.environment[variable].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    /// Frames the decoder hands out for the whole stream, the held last one included.
    private static func decodedFrames(_ data: Data) throws -> Int {
        let decoder = try DTSXObjectAudioDecoder()
        var frames = 0
        try data.withUnsafeBytes { try decoder.push($0) }
        decoder.releaseHeldBlocks()
        while let block = try decoder.nextBlock() { frames += block.frameCount }
        return frames
    }

    /// The verdict on the head of a stream, fed in 4096-byte pieces as packets would arrive.
    private static func verdict(_ data: Data) throws -> DTSXObjectAudioDecoder.Verdict? {
        let decoder = try DTSXObjectAudioDecoder()
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                if let verdict = decoder.verdict(feeding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n])) {
                    return verdict
                }
                offset += n
            }
            return nil
        }
    }

    @Test("DTS:X is recognised on its head; objects and plain DTS-HD MA are refused")
    func verdicts() throws {
        if let data = Self.sample("AE_DTSX_SAMPLE") {
            #expect(try Self.verdict(data.prefix(1 << 20)) == .renders("7.1.4"))
        }
        if let data = Self.sample("AE_DTSX_ALTERNATE_SAMPLE") {
            let verdict = try Self.verdict(data.prefix(1 << 20))
            // FFmpeg does not recognise this trailer's extension at all, so it decodes as the 7.1 bed.
            guard case .refused = verdict else {
                Issue.record("the alternate presentation was not refused: \(String(describing: verdict))")
                return
            }
        }
        if let data = Self.sample("AE_DTS_HD_MA_SAMPLE") {
            let verdict = try Self.verdict(data.prefix(1 << 20))
            guard case .refused(let reason) = verdict else {
                Issue.record("plain DTS-HD MA was not refused: \(String(describing: verdict))")
                return
            }
            #expect(reason.contains("no DTS:X extension"), "\(reason)")
        }
    }

    @Test("the standard presentation is built from its bed: heights overhead, the floor under them")
    func standardPresentationFromItsBed() throws {
        guard let data = Self.sample("AE_DTSX_SAMPLE") else { return }
        let decoder = try DTSXObjectAudioDecoder()
        let layout = SpatialSpeakerLayout.l714
        var placement: ObjectAudioPlacement?
        var regression: BedRegression?
        var snapshot = ObjectAudioGainSnapshot()
        let capacity = 8192
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        defer { out.forEach { $0.deallocate() } }
        // The exact separation, bed minus the folded heights, computed here only to measure against.
        var exact: [[Float]] = Array(repeating: [], count: layout.channelCount)
        var built: [[Float]] = Array(repeating: [], count: layout.channelCount)
        var frames = 0, firstInputFrame: Int64 = -1
        var roles: [ObjectAudioRole] = [], bedRoles: [ObjectAudioRole] = []

        func take(_ block: ObjectAudioDecodedBlock) {
            let bed = block.bed!
            if placement == nil {
                placement = ObjectAudioPlacement(layout: layout, roles: block.roles)
                regression = BedRegression(layout: layout, bedRoles: bed.roles, folds: bed.folds)
                roles = block.roles; bedRoles = bed.roles
                firstInputFrame = block.inputFrameOffset
            }
            placement!.apply(block.updates)
            placement!.snapshot(into: &snapshot)
            regression!.setGains(snapshot)
            let got = regression!.process(elements: block.planes, bed: bed.planes, frameCount: block.frameCount, output: out)
            for c in 0..<layout.channelCount { built[c].append(contentsOf: UnsafeBufferPointer(start: out[c], count: got)) }
            for (plane, role) in bed.roles.enumerated() {
                let speaker: SpatialSpeaker
                if case .bed(let s) = role { speaker = s } else { speaker = .lfe }
                var channel = Array(UnsafeBufferPointer(start: bed.planes[plane], count: block.frameCount))
                for fold in bed.folds where fold.plane == plane {
                    for i in channel.indices { channel[i] -= fold.gain * block.planes[fold.element][i] }
                }
                exact[layout.speakers.firstIndex(of: speaker)!].append(contentsOf: channel)
            }
            for (k, role) in block.roles.enumerated() {
                guard case .bed(let s) = role else { continue }
                exact[layout.speakers.firstIndex(of: s)!].append(contentsOf: UnsafeBufferPointer(start: block.planes[k], count: block.frameCount))
            }
            frames += block.frameCount
        }

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                try decoder.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                offset += n
                while let block = try decoder.nextBlock() { take(block) }
            }
        }
        decoder.releaseHeldBlocks()
        while let block = try decoder.nextBlock() { take(block) }
        let tail = regression!.drain(output: out)
        for c in 0..<layout.channelCount { built[c].append(contentsOf: UnsafeBufferPointer(start: out[c], count: tail)) }

        // Whole frames of 512, the first two of which only prime the decoder.
        #expect(firstInputFrame == 1024)
        #expect(frames > 0 && frames % 512 == 0)
        #expect(frames == (try Self.decodedFrames(data)))
        #expect(roles == [.bed(.topFrontLeft), .bed(.topFrontRight), .bed(.topRearLeft), .bed(.topRearRight)])
        #expect(bedRoles == [.bed(.center), .bed(.left), .bed(.right), .bed(.sideLeft), .bed(.sideRight), .lfe,
                             .bed(.rearLeft), .bed(.rearRight)])
        #expect(built.allSatisfy { $0.count == frames })

        func snr(_ c: [Int]) -> Double {
            var s = 0.0, e = 0.0
            for ch in c { for i in 0..<frames { let r = Double(exact[ch][i]); s += r * r; e += (r - Double(built[ch][i])) * (r - Double(built[ch][i])) } }
            return 10 * log10(s / max(e, 1e-30))
        }
        let heights = layout.speakers.indices.filter { layout.speakers[$0].isHeight }
        let all = Array(layout.speakers.indices)
        let level = 10 * log10(heights.map { c in built[c].reduce(0.0) { $0 + Double($1 * $1) } }.reduce(0, +)
                                / heights.map { c in exact[c].reduce(0.0) { $0 + Double($1 * $1) } }.reduce(0, +))
        print("[DTSXSample] built from the bed against the exact separation: all \(String(format: "%.1f", snr(all))) dB, "
              + "heights \(String(format: "%.1f", snr(heights))) dB, height level \(String(format: "%+.2f", level)) dB, "
              + "per channel " + all.map { "\(layout.speakers[$0].rawValue)=\(String(format: "%.0f", snr([$0])))" }.joined(separator: " "))
        #expect(snr(all) > 20)
        #expect(abs(level) < 1)
    }

    @Test("the bridge turns the whole standard sample into contiguous APAC packets")
    func bridgesToAPAC() throws {
        guard let data = Self.sample("AE_DTSX_SAMPLE") else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l714, decoder: DTSXObjectAudioDecoder())
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
        print("[DTSXSample] 7.1.4 APAC: \(pts.count) packets, \(String(format: "%.2f", seconds)) s, "
              + "\(bytes * 8 / Int(seconds) / 1000) kbps, \(String(format: "%.1f", seconds / elapsed))x realtime (debug build)")
        // The first block sits after the two priming frames, so the encoder starts 1024 frames in.
        #expect(pts.first == Int64(1024))
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        // Two packets of encoder priming, then every frame after the priming frames.
        #expect(pts.count == 2 + Int((Double(try Self.decodedFrames(data)) / 1024).rounded(.up)))
    }
}
#endif
