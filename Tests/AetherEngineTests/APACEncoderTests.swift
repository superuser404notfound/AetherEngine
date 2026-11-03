import Testing
import Foundation
@testable import AetherEngine

/// The APAC encoder is Apple's, reached through `AVAudioConverter`. The spatial bridge stamps its
/// packets by count (#731), so the facts it relies on are pinned against the real encoder here:
/// packet length, priming, the cookie being the whole `dapa` box, every packet independently
/// decodable, and no multi-second lookahead with dynamic range control off.
@Suite("APAC encoder")
struct APACEncoderTests {

    /// Planar test signal: a different low-level tone per channel.
    private func withPlanes<R>(
        _ layout: SpatialSpeakerLayout, frames: Int, startFrame: Int = 0, _ body: ([UnsafePointer<Float>]) throws -> R
    ) rethrows -> R {
        let planes = (0..<layout.channelCount).map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames {
                p[i] = 0.1 * sin(Float(startFrame + i) * 2 * .pi * Float(200 + 50 * c) / 48_000)
            }
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        return try body(planes.map { UnsafePointer($0) })
    }

    @Test("every bed layout opens, with a dapa cookie, 2048 frames of priming and 1024-frame packets",
          arguments: SpatialSpeakerLayout.allCases)
    func opens(layout: SpatialSpeakerLayout) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        let cookie = [UInt8](encoder.magicCookie)
        #expect(cookie.count > 8)
        #expect(String(bytes: cookie[4..<8], encoding: .ascii) == "dapa")
        #expect(Int(cookie[0]) << 24 | Int(cookie[1]) << 16 | Int(cookie[2]) << 8 | Int(cookie[3]) == cookie.count,
                "the cookie is one complete box")
        #expect(encoder.leadingFrames == 2048)
        #expect(APACEncoder.framesPerPacket == 1024)
    }

    @Test("packets come out as fast as frames go in: priming plus input, a packet per 1024 frames, all sync")
    func packetCadence() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        let frames = 48_000
        var packets: [APACEncoder.Packet] = []
        var fed = 0
        while fed < frames {
            let n = min(2048, frames - fed)
            packets += try withPlanes(layout, frames: n, startFrame: fed) { try encoder.encode(planes: $0, frameCount: n) }
            fed += n
        }
        // With DRC off the encoder holds only its priming. A lookahead of seconds (DRC on) would leave
        // this one second of input with no packets at all.
        #expect(packets.count >= frames / 1024 - 2, "got \(packets.count) packets for 1 s of input")
        #expect(packets.allSatisfy { $0.isSync })
        #expect(packets.allSatisfy { !$0.data.isEmpty })
        let tail = try encoder.flush()
        let total = packets.count + tail.count
        let expected = (frames + encoder.leadingFrames + 1023) / 1024
        #expect(abs(total - expected) <= 1, "\(total) packets in total, \(expected) expected")
        #expect(try encoder.flush().isEmpty, "a second flush has nothing left")
    }

    @Test("after a reset the encoder starts over and keeps going")
    func resetStartsOver() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        _ = try withPlanes(layout, frames: 8192) { try encoder.encode(planes: $0, frameCount: 8192) }
        _ = try encoder.flush()
        encoder.reset()
        let again = try withPlanes(layout, frames: 8192) { try encoder.encode(planes: $0, frameCount: 8192) }
        #expect(again.count >= 4)
        #expect(again.first?.isSync == true)
    }

    @Test("an input longer than the converter's buffer is fed in slices, nothing dropped")
    func longInputIsSliced() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000, maxInputFrames: 4096)
        let frames = 4096 * 5 + 300
        let packets = try withPlanes(layout, frames: frames) { try encoder.encode(planes: $0, frameCount: frames) }
        let total = packets.count + (try encoder.flush()).count
        #expect(abs(total - (frames + encoder.leadingFrames + 1023) / 1024) <= 1)
    }

    @Test("encode after flush throws instead of swallowing the input")
    func encodeAfterFlushThrows() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        _ = try withPlanes(layout, frames: 2048) { try encoder.encode(planes: $0, frameCount: 2048) }
        _ = try encoder.flush()
        #expect(throws: APACEncoder.EncoderError.self) {
            try withPlanes(layout, frames: 1000) { try encoder.encode(planes: $0, frameCount: 1000) }
        }
    }

    @Test("a drain spanning several output buffers supplies its PCM exactly once")
    func fullOutputBuffersDoNotRepeatInput() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let frames = 65_536
        let large = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000,
                                    maxInputFrames: frames)
        let sliced = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000,
                                     maxInputFrames: 2048)
        try withPlanes(layout, frames: frames) { planes in
            var actual = try large.encode(planes: planes, frameCount: frames)
            #expect(actual.count > 16, "this drain must fill the 16-packet output buffer more than once")
            actual += try large.flush()
            var expected = try sliced.encode(planes: planes, frameCount: frames)
            expected += try sliced.flush()
            #expect(actual.map(\.data) == expected.map(\.data))
            let expectedCount = (frames + large.leadingFrames + 1023) / APACEncoder.framesPerPacket
            #expect(abs(actual.count - expectedCount) <= 1)
        }
    }

}
