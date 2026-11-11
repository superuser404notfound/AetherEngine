import Foundation
import Testing
@testable import AetherEngine

/// AE#1029: `probe(...)` honours `LoadOptions.skipsContainerAttachments`, as `load` has since AE#956.
/// Without it a probe of a Matroska file reads every attached font, so a byte budget sized for a
/// header stops the probe before it answers.
///
/// Fixture: a 2.0 MiB Matroska (one tiny H.264 stream, one 2 MiB attachment of zeros placed before
/// the first Cluster), stored raw-deflated because the zeros compress to almost nothing. Regenerate with:
///
///     ffmpeg -f lavfi -i color=c=black:s=16x16:r=1:d=1 -c:v libx264 -preset ultrafast -crf 51 \
///       -pix_fmt yuv420p -bsf:v filter_units=remove_types=6 v.mkv
///     head -c 2097152 /dev/zero > big.ttf
///     mkvmerge --no-date --disable-track-statistics-tags -o fonts.mkv v.mkv \
///       --attachment-mime-type font/ttf --attach-file big.ttf
///     python3 -c "import zlib,base64;c=zlib.compressobj(9,zlib.DEFLATED,-15); \
///       print(base64.b64encode(c.compress(open('fonts.mkv','rb').read())+c.flush()).decode())"
struct Issue1029ProbeSkipAttachmentsTests {

    private static func fixture() throws -> Data {
        guard let deflated = Data(base64Encoded: base64.joined()) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try (deflated as NSData).decompressed(using: .zlib) as Data
        #expect(data.count > 2 << 20)
        return data
    }

    /// Smaller than the attachment, larger than the header plus one bridge buffer (256 KiB).
    private static let budget = ProbeLimits(maxInputBytes: 1 << 20)

    private static func options(skipping: Bool) -> LoadOptions {
        var options = LoadOptions()
        options.skipsContainerAttachments = skipping
        return options
    }

    @Test func controlledCustomProbeAnswersUnderABudgetSmallerThanTheAttachment() throws {
        let data = try Self.fixture()
        let probe = try AetherEngine.probe(source: .custom(DataIOReader(data: data), formatHint: "matroska"),
                                           options: Self.options(skipping: true), limits: Self.budget)
        #expect(probe.videoCodecName == "h264")
    }

    @Test func controlledCustomProbeWithoutTheOptionStillPaysForTheAttachment() throws {
        let data = try Self.fixture()
        #expect(throws: ProbeError.inputLimit) {
            _ = try AetherEngine.probe(source: .custom(DataIOReader(data: data), formatHint: "matroska"),
                                       options: Self.options(skipping: false), limits: Self.budget)
        }
    }

    @Test func controlledFileProbeAnswersUnderTheSameBudget() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ae1029-\(UUID().uuidString).mkv")
        try Self.fixture().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try AetherEngine.probe(url: url, options: Self.options(skipping: true), limits: Self.budget)
        #expect(probe.videoCodecName == "h264")
    }

    /// The uncontrolled opens take the option too: the reader sees the header and the cluster, not the attachment.
    @Test func uncontrolledCustomProbeReadsFewerBytesThanTheAttachment() throws {
        let data = try Self.fixture()
        let skipping = CountingReader(data: data)
        _ = try AetherEngine.probe(source: .custom(skipping, formatHint: "matroska"), options: Self.options(skipping: true))
        let reading = CountingReader(data: data)
        _ = try AetherEngine.probe(source: .custom(reading, formatHint: "matroska"), options: Self.options(skipping: false))
        #expect(skipping.bytesRead < 1 << 20)
        #expect(reading.bytesRead >= 2 << 20)
    }

    private final class CountingReader: IOReader, @unchecked Sendable {
        private let inner: DataIOReader
        private let lock = NSLock()
        private var count: Int64 = 0
        var bytesRead: Int64 { lock.withLock { count } }

        init(data: Data) { inner = DataIOReader(data: data) }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            let n = inner.read(buffer, size: size)
            if n > 0 { lock.withLock { count += Int64(n) } }
            return n
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { inner.seek(offset: offset, whence: whence) }
        func close() { inner.close() }
    }

    private static let base64 = [
        "7djfS51lHADw92Sx6iYTXG1s9LJgW20djyYu1i70eHQIOWMe1y6CUjuemT9GHpVaEL47pmes0VpYsC0Y0xiRiBUVzQJhjCSoywYx",
        "qOgiqF1kXewmqPcog/6AoC4+H573ed7v9/nywAPvzfvd3PL97Gx6Kkqkb8bP79Ht6T+iO9PHS0PdoyNHCwPd6ek49Wp02/2dE/lE",
        "EAs37ru3/dzo1+1Lr3W+P1nd9l5f5/zxyor1cGN2YaAcvtS+dCoOt3QuxWExrJ5bj6uyV/Jr8dJ6+aamuf64vLrrRsdCAAAAAPzP",
        "lP/7Vx++9kHxnnRj+8TsYH9PrmdoMByvTdYn94S7wjhxq4NQTu5J1j3VdGloYHwoN5LPxZnUo8lUuHNH9kguzHSPDAznCoUdD4UN",
        "9Y/09I9mTkxmjgVBYe50YuGVw2Mv/Lrrizf33Xf48+kvy+2FxqmFxuK1KFG4WprfWjVzfcPgYjFKlKLgfBRs+/h8cWz4uanXDz3T",
        "/mTL/vqats6OmqZDzb0X302kl+/+68egOh+v372cqAyCimBtCle3PZ8I7jjyTeLt8MGfipOPn/0qPued8jk/nFuMKi9HldnFyfjK",
        "ldnLa0vX4mTXZ1HiRqbdZwD8K8q90Mow2N19KZ63tw5P9/Tnk6Ojfa3PlvqODo/WlF+fjrcAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/nOtC6XNvxSO7f5w/6YH",
        "mj8Ze+vnKJh9IwqCiXjvrlxpcu/2nUH18pbOpYEzS6c/ioJPT96MEqvFsPrEb1FFVfZK/s9C4ULv8kR+5WzL7HTLgeaOTMvBzPSp",
        "J7rH+xrqkrXxSNUWCt/2Lp/svVqa31o1c33D4GJ+5eI/q2fi6t64uu6xcnU42N/zYl1DfX7lQstsKdN1sCnb1nEgM30mldpbHrXJ",
        "1C1/Aw==",
    ]
}
