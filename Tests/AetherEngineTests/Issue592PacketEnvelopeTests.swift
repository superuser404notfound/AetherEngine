import Foundation
import Testing
@testable import AetherEngine

/// AE#592: every compressed byte on the software VOD route crosses this envelope twice, once into
/// the on-disk spool and once back out, at roughly 425 KB per video packet. The endurance question
/// is device-bound, but the per-byte cost is not, and a lower one moves the whole curve rather than
/// one threshold.
///
/// The round-trip cases are the safety net for changing the encoding: the envelope is documented as
/// lossless, and DTS, duration and side data must survive a cache hit.
@Suite("AE#592: the stored packet envelope")
struct Issue592PacketEnvelopeTests {

    private func packet(payload: Int, sideData: Int = 0) -> SoftwareStoredPacket {
        SoftwareStoredPacket(
            pts: -9_223_372_036_854_775_000, dts: -4_000, duration: 1_001, position: 1 << 40,
            streamIndex: 3, flags: Int32.min,
            timeBaseNumerator: 1, timeBaseDenominator: 90_000,
            bytes: Data(repeating: 0xA5, count: payload),
            sideData: (0..<sideData).map {
                .init(type: UInt32($0) &+ 0xFFFF_0000, bytes: Data(repeating: UInt8($0 & 0xFF), count: 64 + $0))
            })
    }

    @Test("a packet survives the round trip whole")
    func roundTripIsLossless() throws {
        for p in [packet(payload: 0), packet(payload: 1), packet(payload: 425_000, sideData: 3)] {
            let back = try SoftwareStoredPacket.decode(p.encoded())
            #expect(back == p)
        }
    }

    @Test("side data keeps its order and its types")
    func sideDataOrderSurvives() throws {
        let p = packet(payload: 2_048, sideData: 5)
        let back = try SoftwareStoredPacket.decode(p.encoded())
        #expect(back.sideData.map(\.type) == p.sideData.map(\.type))
        #expect(back.sideData.map(\.bytes) == p.sideData.map(\.bytes))
    }

    @Test("extreme scalars are not narrowed")
    func extremeScalarsSurvive() throws {
        let p = SoftwareStoredPacket(
            pts: .min, dts: .max, duration: .min, position: .max,
            streamIndex: .max, flags: .min, timeBaseNumerator: .min, timeBaseDenominator: .max,
            bytes: Data(), sideData: [])
        #expect(try SoftwareStoredPacket.decode(p.encoded()) == p)
    }

    /// The binary property list encoder uniqued every object through a `Set`, which hashed the
    /// whole payload on every packet: 92 % of the envelope's encode time in a release profile of a
    /// 91 Mbit/s HEVC session. The envelope is now the payload plus a fixed header, so its size
    /// says whether anything else crept back in.
    @Test("the envelope is a fixed header, the payload and the side data, nothing else")
    func envelopeSizeIsExact() throws {
        let p = packet(payload: 425_000, sideData: 3)
        let side = p.sideData.reduce(0) { $0 + SoftwareStoredPacket.sideDataHeaderBytes + $1.bytes.count }
        #expect(try p.encoded().count == SoftwareStoredPacket.headerBytes + 425_000 + side)
    }

    @Test("a truncated envelope throws instead of reading past its end")
    func truncatedEnvelopeThrows() throws {
        let data = try packet(payload: 4_096, sideData: 2).encoded()
        for cut in [0, 1, SoftwareStoredPacket.headerBytes - 1, SoftwareStoredPacket.headerBytes + 10, data.count - 1] {
            #expect(throws: (any Error).self) { try SoftwareStoredPacket.decode(data.prefix(cut)) }
        }
    }

    @Test("an envelope of another version or with trailing bytes throws")
    func foreignEnvelopeThrows() throws {
        var data = try packet(payload: 16).encoded()
        var trailing = data
        trailing.append(0)
        #expect(throws: (any Error).self) { try SoftwareStoredPacket.decode(trailing) }
        data[data.startIndex] = 0xFF
        #expect(throws: (any Error).self) { try SoftwareStoredPacket.decode(data) }
    }

    @Test("a slice decodes like the whole buffer")
    func sliceDecodes() throws {
        let p = packet(payload: 777, sideData: 1)
        var framed = Data([1, 2, 3])
        framed.append(try p.encoded())
        #expect(try SoftwareStoredPacket.decode(framed.dropFirst(3)) == p)
    }

    /// Reported, not asserted: a throughput floor pinned here would be a CI coin toss. The number is
    /// the deliverable, read off the run. Each round gets its own payload, so nothing is reused
    /// across iterations and a copy the encoder makes is a copy this measures.
    @Test("throughput of the envelope, reported", .offCooperativePoolOneLane)
    func throughputReport() throws {
        let rounds = 200
        var packets: [SoftwareStoredPacket] = []
        packets.reserveCapacity(rounds)
        for i in 0..<rounds {
            var payload = Data(count: 425_000)
            payload.withUnsafeMutableBytes { raw in
                let b = raw.bindMemory(to: UInt64.self)
                for j in 0..<b.count { b[j] = UInt64(i &* 2_654_435_761 &+ j &* 40_503) }
            }
            packets.append(SoftwareStoredPacket(
                pts: Int64(i) * 1_001, dts: Int64(i) * 1_001 - 2_002, duration: 1_001,
                position: Int64(i) * 425_000, streamIndex: 0, flags: 1,
                timeBaseNumerator: 1, timeBaseDenominator: 90_000,
                bytes: payload,
                sideData: [.init(type: 0x1234, bytes: Data(repeating: UInt8(i & 0xFF), count: 96))]))
        }

        var encoded: [Data] = []
        encoded.reserveCapacity(rounds)
        let encStart = DispatchTime.now()
        for p in packets { encoded.append(try p.encoded()) }
        let encSeconds = Double(DispatchTime.now().uptimeNanoseconds - encStart.uptimeNanoseconds) / 1e9

        let decStart = DispatchTime.now()
        for d in encoded { _ = try SoftwareStoredPacket.decode(d) }
        let decSeconds = Double(DispatchTime.now().uptimeNanoseconds - decStart.uptimeNanoseconds) / 1e9

        let mb = Double(encoded.reduce(0) { $0 + $1.count }) / 1_048_576
        let overhead = Double(encoded.reduce(0) { $0 + $1.count }) / Double(rounds * (425_000 + 96))
        print(String(format:
            "[AE592] %d packets, %.1f MB: encode %.3f s = %.0f MB/s (%.0f us/pkt), "
            + "decode %.3f s = %.0f MB/s (%.0f us/pkt), envelope overhead x%.4f",
            rounds, mb, encSeconds, mb / encSeconds, encSeconds / Double(rounds) * 1e6,
            decSeconds, mb / decSeconds, decSeconds / Double(rounds) * 1e6, overhead))
        #expect(encSeconds > 0 && decSeconds > 0)
    }
}
