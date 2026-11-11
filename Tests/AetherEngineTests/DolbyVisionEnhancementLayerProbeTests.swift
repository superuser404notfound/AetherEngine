import Testing
import Foundation
@testable import AetherEngine

/// `probeDolbyVisionEnhancementLayer` on the clips the Dolby Vision pulse probe builds
/// (Probes/DolbyVisionPulse, `Scripts/build.sh`); skipped where they have not been built.
struct DolbyVisionEnhancementLayerProbeTests {

    static let clips = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Probes/DolbyVisionPulse/out")
    static let fel = clips.appendingPathComponent("p7fel_l1.mp4")
    static let mel = clips.appendingPathComponent("p7mel_l1.mp4")
    static let profile81 = clips.appendingPathComponent("count_mel.mp4")
    static let clipsBuilt = [fel, mel, profile81].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }

    @Test("A Profile 7 FEL clip reads as FEL, a MEL clip as MEL, and a Profile 8.1 clip as neither",
          .enabled(if: clipsBuilt, "needs the DV pulse clips: Probes/DolbyVisionPulse/Scripts/build.sh"))
    func classifiesBothLayers() throws {
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.fel) == .fel)
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.mel) == .mel)
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: Self.profile81) == nil)
    }

    @Test("A source with no Dolby Vision reads as neither layer")
    func nonDolbyVisionSourceIsNil() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plain.ts")
        try TinyTransportStreamFixture.data.write(to: file)
        #expect(try AetherEngine.probeDolbyVisionEnhancementLayer(url: file) == nil)
    }

    // MARK: - AE#1030: the same answer from the controlled probe

    /// Generous enough for one 4K keyframe of the pulse clips, which the default 2 MiB packet ceiling refuses.
    static let clipLimits = ProbeLimits(maxInputBytes: 32 * 1024 * 1024, maxPacketBytes: 16 * 1024 * 1024)

    static func customProbe(_ url: URL, detecting: ProbeDetail = .dolbyVisionEnhancementLayer) throws -> SourceProbe {
        let reader = try #require(FileIOReader(url: url))
        defer { reader.close() }
        return try AetherEngine.probe(
            source: .custom(reader, formatHint: "mp4"), detecting: detecting,
            limits: clipLimits, cancellation: ProbeCancellation())
    }

    @Test("A custom-reader probe under caller limits reads FEL, MEL, and nothing for Profile 8.1",
          .enabled(if: clipsBuilt, "needs the DV pulse clips: Probes/DolbyVisionPulse/Scripts/build.sh"))
    func controlledProbeClassifiesBothLayers() throws {
        #expect(try Self.customProbe(Self.fel).dolbyVisionEnhancementLayer == .fel)
        #expect(try Self.customProbe(Self.mel).dolbyVisionEnhancementLayer == .mel)
        #expect(try Self.customProbe(Self.profile81).dolbyVisionEnhancementLayer == nil)
    }

    @Test("Not asking for the layer leaves it nil, and asking leaves the rest of the probe as it was",
          .enabled(if: clipsBuilt, "needs the DV pulse clips: Probes/DolbyVisionPulse/Scripts/build.sh"))
    func layerIsOptIn() throws {
        let plain = try Self.customProbe(Self.fel, detecting: [])
        let asked = try Self.customProbe(Self.fel)
        #expect(plain.dolbyVisionEnhancementLayer == nil)
        #expect(asked.dvProfile == plain.dvProfile)
        #expect(asked.videoFormat == plain.videoFormat)
    }

    @Test("A source that declares no Profile 7 reads no packet for the layer")
    func nonProfile7ReadsNoPacket() throws {
        let noPackets = ProbeLimits(maxPackets: 0)
        let probe = try AetherEngine.probe(
            source: .custom(DataIOReader(data: TinyTransportStreamFixture.data), formatHint: "mpegts"),
            detecting: .dolbyVisionEnhancementLayer, limits: noPackets, cancellation: ProbeCancellation())
        #expect(probe.dolbyVisionEnhancementLayer == nil)
        // The contrast: a pass that does read packets trips the same zero ceiling.
        #expect(throws: ProbeError.packetLimit) {
            try AetherEngine.probe(
                source: .custom(DataIOReader(data: TinyTransportStreamFixture.data), formatHint: "mpegts"),
                detecting: .hdr10Plus, limits: noPackets, cancellation: ProbeCancellation())
        }
    }

    @Test("A cancelled probe throws instead of answering",
          .enabled(if: clipsBuilt, "needs the DV pulse clips: Probes/DolbyVisionPulse/Scripts/build.sh"))
    func cancelledProbeThrows() throws {
        let reader = try #require(FileIOReader(url: Self.fel))
        defer { reader.close() }
        let token = ProbeCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try AetherEngine.probe(
                source: .custom(reader, formatHint: "mp4"), detecting: .dolbyVisionEnhancementLayer,
                limits: Self.clipLimits, cancellation: token)
        }
    }
}
