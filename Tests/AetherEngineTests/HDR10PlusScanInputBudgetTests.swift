import Testing
import Foundation
@testable import AetherEngine

/// The HDR10+ scan drops every stream but video (AVDISCARD_ALL), and the demuxer reads and throws away
/// those streams' blocks inside one `av_read_frame`, where the scan's packet and packet-byte caps never see
/// them. The fixture is the adversarial shape: two tiny video packets, then ~24 MiB of another stream. The
/// scan must stop on its input budget instead of reading the file to its end.
@Suite("HDR10+ scan: the input byte budget holds below the demuxer")
struct HDR10PlusScanInputBudgetTests {

    @Test("A tail of dropped foreign blocks stops the scan on its byte cap, on local and custom inputs",
          arguments: [false, true])
    func foreignTailHitsTheInputBudget(customReader: Bool) throws {
        let data = try TailHeavyMatroska.make(foreignBytes: 24 * 1024 * 1024)
        try ProbeTestFixtures.withFile(data) { url in
            let outcome = try Self.scan(url, customReader: customReader, maxBytes: 1024)
            #expect(outcome.stopReason == .byteCap)
            #expect(outcome.packetsRead == 2)
        }
    }

    @Test("A budget that covers the file still reaches EOF, so the cap is the budget and not the fixture")
    func coveringBudgetReachesEOF() throws {
        let data = try TailHeavyMatroska.make(foreignBytes: 24 * 1024 * 1024)
        try ProbeTestFixtures.withFile(data) { url in
            let outcome = try Self.scan(url, customReader: false, maxBytes: 16 * 1024 * 1024)
            #expect(outcome.stopReason == .demuxEOF)
        }
    }

    @Test("The input budget is four times maxBytes with a 4 MiB floor, and saturates")
    func inputBudgetArithmetic() {
        #expect(AetherEngine.hdr10PlusInputByteBudget(maxBytes: 16 * 1024 * 1024) == 64 * 1024 * 1024)
        #expect(AetherEngine.hdr10PlusInputByteBudget(maxBytes: 0) == 4 * 1024 * 1024)
        #expect(AetherEngine.hdr10PlusInputByteBudget(maxBytes: -5) == 4 * 1024 * 1024)
        #expect(AetherEngine.hdr10PlusInputByteBudget(maxBytes: .max) == .max)
    }

    private static func scan(_ url: URL, customReader: Bool, maxBytes: Int64) throws -> HDR10PlusDetectionOutcome {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        if customReader {
            try demuxer.open(reader: try #require(FileIOReader(url: url)))
        } else {
            try demuxer.open(url: url)
        }
        return AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(maxPackets: 32, maxBytes: maxBytes, timeBudget: 60))
    }
}

/// Matroska with the plain HDR10 fixture's two HEVC frames at the head and a long PCM tail after them.
/// `junkTail` swaps the PCM clusters for zeros that no EBML element starts in, which libavformat
/// resyncs through byte by byte inside a single `av_read_frame`.
enum TailHeavyMatroska {

    /// `bareRecord` leaves the hvcC as its 22-byte header with no parameter-set arrays, the record of a
    /// source whose parameter sets are in-band.
    static func make(foreignBytes: Int, junkTail: Bool = false, bareRecord: Bool = false) throws -> Data {
        let mp4 = try ProbeTestFixtures.decode(HDR10PlusProbeIntegrationTests.hdr10Base64)
        var (hvcC, frames) = try hevcTrack(mp4)
        if bareRecord { hvcC = Array(hvcC.prefix(22)) + [0] }

        var out = Data()
        out += element([0x1A, 0x45, 0xDF, 0xA3],
                       element([0x42, 0x82], Array("matroska".utf8)) +
                       element([0x42, 0x87], uint(4)) +
                       element([0x42, 0x85], uint(2)))

        let info = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], uint(1_000_000)))
        let video = element([0xAE],
                            element([0xD7], uint(1)) + element([0x73, 0xC5], uint(1)) +
                            element([0x83], uint(1)) + element([0x86], Array("V_MPEGH/ISO/HEVC".utf8)) +
                            element([0x63, 0xA2], hvcC) +
                            // DefaultDuration: without a frame rate, stream analysis at open reads
                            // (and queues) seconds of the tail looking for one.
                            element([0x23, 0xE3, 0x83], uint(40_000_000)) +
                            element([0xE0], element([0xB0], uint(64)) + element([0xBA], uint(64))))
        let audio = element([0xAE],
                            element([0xD7], uint(2)) + element([0x73, 0xC5], uint(2)) +
                            element([0x83], uint(2)) + element([0x86], Array("A_PCM/INT/LIT".utf8)) +
                            element([0xE1], element([0xB5], float64(48_000)) +
                                            element([0x9F], uint(2)) + element([0x62, 0x64], uint(16))))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], video + audio)

        // 32 KiB of 16-bit stereo at 48 kHz is 170 ms. One cluster per block keeps every relative
        // timestamp at zero.
        let blockBytes = 32 * 1024
        var clusters: [UInt8] = []
        clusters += element([0x1F, 0x43, 0xB6, 0x75],
                            element([0xE7], uint(0)) +
                            simpleBlock(track: 1, relative: 0, payload: frames[0]) +
                            simpleBlock(track: 1, relative: 40, payload: frames[1]))
        let silence = [UInt8](repeating: 0, count: blockBytes)
        if junkTail { clusters += [UInt8](repeating: 0, count: foreignBytes) }
        for i in 0..<(junkTail ? 0 : max(1, foreignBytes / blockBytes)) {
            clusters += element([0x1F, 0x43, 0xB6, 0x75],
                                element([0xE7], uint(100 + i * 170)) +
                                simpleBlock(track: 2, relative: 0, payload: silence))
        }
        out += element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters)
        return out
    }

    /// The hvcC payload and the sample bytes of the fixture's single video track (one chunk).
    private static func hevcTrack(_ mp4: Data) throws -> (hvcC: [UInt8], frames: [[UInt8]]) {
        let bytes = [UInt8](mp4)
        func box(_ type: String) throws -> Int {
            let tag = Array(type.utf8)
            let at = try #require((4...(bytes.count - 4)).first { Array(bytes[$0..<$0 + 4]) == tag })
            return at - 4
        }
        func u32(_ i: Int) -> Int { bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) } }
        let hvcCAt = try box("hvcC")
        let hvcC = Array(bytes[(hvcCAt + 8)..<(hvcCAt + u32(hvcCAt))])
        let stsz = try box("stsz")
        let count = u32(stsz + 16)
        let sizes = (0..<count).map { u32(stsz + 20 + 4 * $0) }
        var offset = u32(try box("stco") + 16)
        var frames: [[UInt8]] = []
        for size in sizes {
            frames.append(Array(bytes[offset..<offset + size]))
            offset += size
        }
        try #require(frames.count == 2)
        return (hvcC, frames)
    }

    private static func simpleBlock(track: UInt8, relative: Int, payload: [UInt8]) -> [UInt8] {
        element([0xA3], [0x80 | track, UInt8((relative >> 8) & 0xFF), UInt8(relative & 0xFF), 0x80] + payload)
    }

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        var size: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { size.append(UInt8((payload.count >> shift) & 0xFF)) }
        return id + size + payload
    }

    private static func uint(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = v
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return bytes
    }

    private static func float64(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) }
    }
}
