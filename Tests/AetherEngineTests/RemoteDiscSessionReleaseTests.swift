import Testing
import Foundation
@testable import AetherEngine

extension PrewarmStoreSuites {
    /// Audit NET-110 / DMX-110: the Demuxer builds the `HTTPDiscIOReader` for a remote disc image
    /// itself, so it is the only party that can end that reader's `URLSession`. The disc adapter's
    /// `ConcatIOReader.close()` is deliberately a no-op and the bridge does not own its reader, so a
    /// demuxer that forgot the reader left one uninvalidated session (and its pooled keep-alive
    /// socket) behind per open: 1000 opens measured as 1020 open sockets.
    ///
    /// The origin counts sockets that are still open, which is the one place the leak shows.
    /// `.serialized`: the warm case goes through the process-wide prewarm store.
    @Suite("Remote disc image sessions are released (audit NET-110)", .serialized, .timeLimit(.minutes(3)))
    struct RemoteDiscSessionReleaseTests {

        /// 0.5 s of 64x64 MPEG-2 video in an MPEG-PS pack stream (ffmpeg `-f vob`), 4096 bytes: the
        /// smallest title the DVD adapter can hand to `mpegps` and have it open.
        static let vob = Data(base64Encoded: """
            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
            ////////////////////////////////////////////////////////////////////////////////////////////////
            /////////////////////////////////////////////////////////////////////////////////////w==
            """, options: .ignoreUnknownCharacters)!

        static func isoImage(vob: Data) -> Data {
            let sector = ISO9660Fixture.sectorSize
            var image = ISO9660Fixture.make(files: [
                .init(name: "VTS_01_1.VOB", length: vob.count, content: [UInt8](vob.prefix(sector))),
            ])
            image.append(vob.dropFirst(sector))
            return image
        }

        private func url(_ origin: KeepAliveRangeOrigin, _ name: String = "disc.iso") -> URL {
            URL(string: "http://127.0.0.1:\(origin.port)/\(name)")!
        }

        private func drained(_ origin: KeepAliveRangeOrigin) async throws {
            try await waitFor { origin.openConnectionCount == 0 }
        }

        @Test("a disc image that opens releases its session when the demuxer closes")
        func openedDiscReleasesOnClose() async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.isoImage(vob: Self.vob)))
            defer { origin.stop() }

            let demuxer = Demuxer()
            try demuxer.open(url: url(origin))
            #expect(demuxer.isDiscSource, "the fixture was not taken for a disc")
            // Accepted, not open: whether URLSession still pools the keep-alive socket at this
            // instant is not this test's question, and on a CI runner it had already let go (0).
            #expect(origin.acceptedConnectionCount > 0, "the open never reached the origin")
            demuxer.close()

            try await drained(origin)
        }

        @Test("a disc image whose open throws releases its session")
        func failedOpenReleasesItsSession() async throws {
            // A pack-start-code-only title: recognised as a disc, and mpegps then finds no stream.
            let image = ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 2048)])
            let origin = try #require(KeepAliveRangeOrigin(data: image))
            defer { origin.stop() }

            for _ in 0..<3 {
                let demuxer = Demuxer()
                #expect(throws: (any Error).self) { try demuxer.open(url: url(origin)) }
                demuxer.close()
            }
            #expect(origin.acceptedConnectionCount > 0, "the open never reached the origin")

            try await drained(origin)
        }

        /// The root directory's length, past the reader's extent cap: `wrap` throws `malformed` instead of
        /// reporting "not a disc".
        private static func unparseableImage() -> Data {
            var image = ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 2048)])
            let lengthOffset = 16 * ISO9660Fixture.sectorSize + 156 + 10
            image.replaceSubrange(lengthOffset..<(lengthOffset + 4), with: ISO9660Fixture.le32(16 * 1024 * 1024))
            return image
        }

        @Test("a disc image whose structure cannot be parsed releases its session")
        func throwingWrapReleasesItsSession() async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.unparseableImage()))
            defer { origin.stop() }

            let demuxer = Demuxer()
            #expect(throws: (any Error).self) { try demuxer.open(url: url(origin)) }
            demuxer.close()

            #expect(origin.acceptedConnectionCount > 0, "the open never reached the origin")
            try await drained(origin)
        }

        @Test("a disc image whose structure cannot be parsed hands the warm back")
        func throwingWrapReturnsTheWarm() async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.unparseableImage()))
            defer { origin.stop() }
            let source = url(origin, "corrupt.iso")
            _ = await SourcePrewarmFetcher.warm(url: source, extraHeaders: [:], byteBudget: 1 << 20, into: .shared)
            #expect(SourcePrewarmStore.shared.isWarm(for: source), "the warm was not taken")
            defer { _ = SourcePrewarmStore.shared.take(for: source) }

            let demuxer = Demuxer()
            defer { demuxer.close() }
            #expect(throws: (any Error).self) { try demuxer.open(url: source) }

            #expect(SourcePrewarmStore.shared.isWarm(for: source),
                    "a throwing wrap dropped the warm instead of putting it back")
        }
    }
}
