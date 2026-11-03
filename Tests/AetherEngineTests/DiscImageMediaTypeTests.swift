import Testing
import Foundation
@testable import AetherEngine

@Suite("Disc image media types (AE#860)")
struct DiscImageMediaTypeTests {

    @Test("the type is matched without parameters, case or padding")
    func normalizesTheType() {
        #expect(DiscImageMediaType.isDiscImage(contentType: "application/x-iso9660-image"))
        #expect(DiscImageMediaType.isDiscImage(contentType: "Application/X-ISO9660-Image"))
        #expect(DiscImageMediaType.isDiscImage(contentType: " application/x-iso9660-image ; charset=binary"))
        #expect(DiscImageMediaType.isDiscImage(contentType: "application/x-cd-image"))
        #expect(DiscImageMediaType.isDiscImage(contentType: "application/vnd.efi.iso"))
    }

    @Test("media and generic types are not disc images")
    func rejectsOtherTypes() {
        #expect(!DiscImageMediaType.isDiscImage(contentType: nil))
        #expect(!DiscImageMediaType.isDiscImage(contentType: ""))
        #expect(!DiscImageMediaType.isDiscImage(contentType: "application/octet-stream"))
        #expect(!DiscImageMediaType.isDiscImage(contentType: "video/mp4"))
        #expect(!DiscImageMediaType.isDiscImage(contentType: "video/x-matroska"))
        #expect(!DiscImageMediaType.isDiscImage(contentType: "application/x-iso9660-image-but-not"))
    }

    @Test("a generic type routes only over a volume signature at sector 16")
    func genericTypeNeedsTheSignature() {
        func body(_ signature: String?) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: DiscImageMediaType.volumeSignatureEnd)
            if let signature {
                bytes.replaceSubrange(DiscImageMediaType.volumeSignatureOffset..<DiscImageMediaType.volumeSignatureEnd,
                                      with: Array(signature.utf8))
            }
            return bytes
        }
        let generic = "Application/Octet-Stream; charset=binary"
        #expect(DiscImageMediaType.isGeneric(contentType: generic))
        for signature in ["CD001", "BEA01", "NSR02", "NSR03"] {
            #expect(DiscImageMediaType.suggestsDiscImage(contentType: generic, prefix: body(signature)))
        }
        #expect(!DiscImageMediaType.suggestsDiscImage(contentType: generic, prefix: body(nil)))
        #expect(!DiscImageMediaType.suggestsDiscImage(contentType: generic, prefix: body("TEA01")))
        #expect(!DiscImageMediaType.suggestsDiscImage(contentType: generic, prefix: Array(body("CD001").dropLast())))
        #expect(!DiscImageMediaType.suggestsDiscImage(contentType: "video/mp2t", prefix: body("CD001")))
        #expect(!DiscImageMediaType.suggestsDiscImage(contentType: nil, prefix: body("CD001")))
        #expect(DiscImageMediaType.suggestsDiscImage(contentType: "application/x-iso9660-image", prefix: []))
    }
}

extension PrewarmStoreSuites {
    /// AE#860: an extensionless URL whose origin declares a disc image type reaches the disc
    /// adapter; the type stays a hint that the disc readers confirm.
    /// `.serialized`: the warm case and the recognized-URL memo are process-wide.
    @Suite("Extensionless disc images by Content-Type (AE#860)", .serialized, .timeLimit(.minutes(2)))
    struct ExtensionlessDiscImageTests {

        private static let iso = RemoteDiscSessionReleaseTests.isoImage(vob: RemoteDiscSessionReleaseTests.vob)

        private func url(_ origin: KeepAliveRangeOrigin) -> URL {
            URL(string: "http://127.0.0.1:\(origin.port)/t4/play/\(UUID().uuidString)")!
        }

        @Test("an extensionless URL declaring an ISO type opens through the disc adapter")
        func declaredISOOpensAsDisc() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.iso, contentType: "application/x-iso9660-image"))
            defer { origin.stop() }
            let source = url(origin)
            #expect(!Demuxer.isDiscImageURL(source))

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(demuxer.isDiscSource, "the declared disc image was handed to libavformat raw")
            #expect(Demuxer.isDiscImageURL(source), "a recognized disc URL was not remembered")
        }

        @Test("a warm open learns the type from the warm")
        func warmedISOOpensAsDisc() async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.iso, contentType: "application/x-iso9660-image; charset=binary"))
            defer { origin.stop() }
            let source = url(origin)
            _ = await SourcePrewarmFetcher.warm(url: source, extraHeaders: [:], byteBudget: 1 << 20, into: .shared)
            #expect(SourcePrewarmStore.shared.isWarm(for: source), "the warm was not taken")
            defer { _ = SourcePrewarmStore.shared.take(for: source) }

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(demuxer.isDiscSource)
        }

        @Test("ordinary extensionless media keeps the streaming path")
        func ordinaryMediaStreams() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "video/mp2t"))
            defer { origin.stop() }
            let source = url(origin)

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(!demuxer.isDiscSource)
            #expect(!Demuxer.isDiscImageURL(source))
        }

        @Test("a mislabelled media body is not taken for a disc and still plays")
        func mislabelledMediaStreams() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "application/x-iso9660-image"))
            defer { origin.stop() }
            let source = url(origin)

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(!demuxer.isDiscSource)
            #expect(!Demuxer.isDiscImageURL(source), "a body with no disc structure was remembered as a disc")
        }

        @Test("a controlled probe enables the disc probe once the response declares an ISO type")
        func controlledProbeEnablesTheDiscProbe() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.iso, contentType: "application/x-iso9660-image"))
            defer { origin.stop() }
            let control = try ProbeControl(limits: nil, cancellation: ProbeCancellation())
            let reader = ProbeHTTPReader(url: url(origin), headers: [:], control: control)
            defer { reader.close() }

            #expect(!reader.discImageProbeEnabled)
            try reader.open()
            #expect(reader.discImageProbeEnabled, "the probe reader ignored the declared disc image type")

            let probe = try AetherEngine.probe(url: url(origin), cancellation: ProbeCancellation())
            #expect(probe.videoWidth == 64)
        }

        @Test("an octet-stream ISO opens through the disc adapter")
        func octetStreamISOOpensAsDisc() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.iso, contentType: "Application/Octet-Stream; charset=binary"))
            defer { origin.stop() }
            let source = url(origin)

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(demuxer.isDiscSource, "the octet-stream ISO was handed to libavformat raw")
            #expect(Demuxer.isDiscImageURL(source), "a recognized disc URL was not remembered")
        }

        @Test("a warmed octet-stream ISO reads the signature from the warm")
        func warmedOctetStreamISOOpensAsDisc() async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Self.iso, contentType: "application/octet-stream"))
            defer { origin.stop() }
            let source = url(origin)
            _ = await SourcePrewarmFetcher.warm(url: source, extraHeaders: [:], byteBudget: 1 << 20, into: .shared)
            #expect(SourcePrewarmStore.shared.isWarm(for: source), "the warm was not taken")
            defer { _ = SourcePrewarmStore.shared.take(for: source) }

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(demuxer.isDiscSource)
        }

        @Test("octet-stream media keeps the streaming path")
        func octetStreamMediaStreams() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "application/octet-stream"))
            defer { origin.stop() }
            let source = url(origin)

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(!demuxer.isDiscSource)
            #expect(!Demuxer.isDiscImageURL(source))
        }

        @Test("a volume signature over media with no disc structure is not taken for a disc and still plays")
        func signatureOnlyMediaStreams() throws {
            var body = TinyTransportStreamFixture.data
            while body.count < DiscImageMediaType.volumeSignatureEnd * 2 { body.append(TinyTransportStreamFixture.data) }
            body.replaceSubrange(DiscImageMediaType.volumeSignatureOffset..<DiscImageMediaType.volumeSignatureEnd,
                                 with: Array("CD001".utf8))
            let origin = try #require(KeepAliveRangeOrigin(data: body, contentType: "application/octet-stream"))
            defer { origin.stop() }
            let source = url(origin)

            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: source)
            #expect(!demuxer.isDiscSource)
            #expect(!Demuxer.isDiscImageURL(source), "a body with no disc structure was remembered as a disc")
        }

        @Test("a controlled probe enables the disc probe for an octet-stream ISO or UDF image")
        func controlledProbeReadsTheSignature() throws {
            var udf = UDFFixture.makeDVD(files: UDFOnlyDVDImageTests.files())
            for (sector, id) in [(16, "BEA01"), (17, "NSR02"), (18, "TEA01")] {
                udf.replaceSubrange(sector * 2048 + 1 ..< sector * 2048 + 6, with: Array(id.utf8))
            }
            for image in [Self.iso, udf] {
                let origin = try #require(KeepAliveRangeOrigin(data: image, contentType: "application/octet-stream"))
                defer { origin.stop() }
                let control = try ProbeControl(limits: nil, cancellation: ProbeCancellation())
                let reader = ProbeHTTPReader(url: url(origin), headers: [:], control: control)
                defer { reader.close() }

                try reader.open()
                #expect(reader.discImageProbeEnabled, "the probe reader ignored the volume signature")
            }
        }

        @Test("a controlled probe of ordinary media keeps the disc probe off")
        func controlledProbeOfMediaSkipsTheDiscProbe() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "video/mp2t"))
            defer { origin.stop() }
            let control = try ProbeControl(limits: nil, cancellation: ProbeCancellation())
            let reader = ProbeHTTPReader(url: url(origin), headers: [:], control: control)
            defer { reader.close() }

            try reader.open()
            #expect(!reader.discImageProbeEnabled)
        }
    }
}
