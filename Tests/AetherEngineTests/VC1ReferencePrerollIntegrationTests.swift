import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import Testing
@testable import AetherEngine

@Suite(.serialized, .offCooperativePool, .timeLimit(.minutes(3)))
struct VC1ReferencePrerollIntegrationTests {
    final class Frames: @unchecked Sendable {
        var samples: [(Double, Int, Int)] = []
        func take(_ b: CVPixelBuffer, _ pts: CMTime) {
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
            guard let raw = CVPixelBufferGetBaseAddressOfPlane(b, 0) else { return }
            let data = raw.assumingMemoryBound(to: UInt8.self)
            let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
            var low = 255, high = 0
            for y in Swift.stride(from: h/4, to: h*3/4, by: 8) {
                for x in Swift.stride(from: w/4, to: w*3/4, by: 8) {
                    low = min(low, Int(data[y*stride+x])); high = max(high, Int(data[y*stride+x]))
                }
            }
            samples.append((pts.seconds, low, high))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_VC1_RESUME_FILE"] != nil),
          arguments: [789.92911257, 796.46233333], [false, true])
    func firstOutput(position: Double, warm: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AETHER_VC1_RESUME_FILE"])
        let dem = Demuxer()
        try dem.open(url: URL(fileURLWithPath: path))
        defer { dem.close() }
        let decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        let frames = Frames()
        let index = dem.videoStreamIndex
        try decoder.open(stream: #require(dem.stream(at: index))) { b, pts, _ in frames.take(b, pts) }
        defer { decoder.close() }
        func readUntil(_ count: Int) throws {
            for _ in 0..<20000 {
                guard frames.samples.count < count, let packet = try dem.readPacket() else { return }
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&owned) }
                if packet.pointee.stream_index == index { decoder.decode(packet: packet) }
            }
        }
        if warm {
            #expect(dem.seekBounded(to: position + 595, timeout: 8))
            try readUntil(30)
            decoder.flush()
            frames.samples.removeAll()
        }
        let stream = try #require(dem.stream(at: index))
        let tb = stream.pointee.time_base
        let outcome = await SoftwareVC1ReferencePreroll.reposition(
            dem: dem, target: position + 600, origin: 600, videoIndex: index,
            timeBase: Double(tb.num) / Double(tb.den), budget: 30,
            queue: DispatchQueue(label: "vc1.real"), closesOnCancel: false,
            isSuperseded: { false }, fallback: { dem, target, budget, queue, obsolete in
                await dem.seekBounded(to: target, timeout: budget, on: queue, isSuperseded: obsolete)
            })
        #expect(outcome == .landed)
        decoder.skipUntilPTS = CMTime(seconds: position + 600, preferredTimescale: 90000)
        try readUntil(4)
        print("VC1_PRIMED_FIRST target=\(position) warm=\(warm) frames=\(frames.samples)")
        let first = try #require(frames.samples.first)
        #expect(first.2 - first.1 > 16)
    }
}
