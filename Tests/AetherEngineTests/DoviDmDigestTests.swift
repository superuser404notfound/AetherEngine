// Only with the DualLayerDolbyVision trait: the digest reads RPUs with libdovi, which the dual-layer route links.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// `DoviDmDigest`: the field-by-field reading of an RPU's display-management metadata that the
/// `aetherctl dmpass` measurement and the on-device `AETHER_DM_DIGEST` digest are built on.
///
/// The fixtures are two synthetic RPU pairs (source P7 NAL, converted P8.1 payload as the engine attaches
/// it), one carrying every display-management level of Content Mapping v4.0 and one plain v2.9. Neither is media.
struct DoviDmDigestTests {

    private static func hexBytes(_ parts: [String]) -> [UInt8] {
        let s = parts.joined()
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private static let fullSource: [UInt8] = hexBytes([
        "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000",
        "400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a86d9e67b2f863efc18",
        "9e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e9e04c349fd3bb77ec2cd5de3a147d44c",
        "0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d57bbb6e411483b92966413698fce6bc31bd620fadd40",
        "5bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc3983779e7568311b004800004004004000004012000010010010000010",
        "04800004004004000006895980000d7a8959be7f3ac7095991328000004000000302000003000200000300070d8890c06182",
        "978c23814500000300698f96bfffc000000300000300000300180803f3805470300800410a6680c028218008008008008004",
        "000180564700100100100100080002014000000300450228048307d0000287cf81849ffc0408285078a048301c0040040000",
        "b080180080080080080080016102500100100100100100082400c14c980e07c04160a6eb23014ff84d03e8033c286c41d4c0",
        "bb83d134042285808800003fe0002033b8804b80",
    ])

    private static let fullOutput: [UInt8] = hexBytes([
        "19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301a2566000035ea2566f9fce",
        "b1c256644ca00000100000030080000003008000000301c36224301860a5e308e0514000001a63e5affff000000300000300",
        "000300060200fce0151c300800410a6680c02821800800800800800400018056470010010010010008000201400000030045",
        "0228048307d0000287cf81849ffc0408285078a048301c0040040000b0801800800800800800800161025001001001001001",
        "00082400c14c980e07c04160a6eb23014ff84d03e8033c286c41d4c0bb83d134042285808800003fe00020b42a68cf80",
    ])

    private static let plainSource: [UInt8] = hexBytes([
        "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000",
        "400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a86d9e67b2f863efc18",
        "9e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e9e04c349fd3bb77ec2cd5de3a147d44c",
        "0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d57bbb6e411483b92966413698fce6bc31bd620fadd40",
        "5bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc3983779e7568311b004800004004004000004012000010010010000010",
        "048000040040040000072566000035ea2566f9fceb1c256644ca0000030100000300080000030008000003001c3622430186",
        "0a5e308e051400000301a63e5affff000003000003000003000060200f80e150903008007ff9b900c0282180080080080080",
        "0400018056470010010010010008000300b01e00200200200200100006017384004004004004002000101152890440280000",
        "030000030000030090627100001271001900d8e697b880",
    ])

    private static let plainOutput: [UInt8] = hexBytes([
        "19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301c95980000d7a8959be7f3a",
        "c7095991328000004000000302000003000200000300070d8890c06182978c23814500000300698f96bfffc0000003000003",
        "00000300180803e03854243008007ff9b900c02821800800800800800400018056470010010010010008000300b01e002002",
        "00200200100006017384004004004004002000101152890440280000030000030000030090627100001271001900104b23dd",
        "80",
    ])

    @Test("a v4.0 source RPU reads with every display-management level and the v4.0 label")
    func readsEveryLevel() throws {
        let reading = try #require(DoviDmDigest.read(rpu: Self.fullSource))
        #expect(reading.levels == [1, 2, 3, 5, 6, 8, 9, 10, 11, 254, 255])
        #expect(DoviDmDigest.cmVersion(reading) == "v4.0")
    }

    @Test("a plain RPU without an L254 block is labelled v2.9")
    func plainRpuIsVersionTwoNine() throws {
        let reading = try #require(DoviDmDigest.read(rpu: Self.plainSource))
        #expect(!reading.levels.contains(254))
        #expect(DoviDmDigest.cmVersion(reading) == "v2.9")
    }

    @Test("the header-less payload form reads like the NAL form")
    func payloadAndNalFormsAgree() throws {
        let nal = Self.fullSource
        let payload = Array(nal.dropFirst(2))
        #expect(nal[0] == 0x7C && nal[1] == 0x01)
        #expect(DoviDmDigest.read(rpu: nal) == DoviDmDigest.read(rpu: payload))
    }

    @Test("a corrupt RPU does not read")
    func corruptRpuDoesNotRead() {
        var broken = Self.fullSource
        broken[broken.count / 2] ^= 0x55
        #expect(DoviDmDigest.read(rpu: broken) == nil)
        #expect(DoviDmDigest.read(rpu: []) == nil)
    }

    @Test("converting to profile 8.1 changes only the fields mode 2 is defined to change")
    func conversionChangesOnlyExpectedFields() throws {
        for (source, output) in [(Self.fullSource, Self.fullOutput), (Self.plainSource, Self.plainOutput)] {
            let s = try #require(DoviDmDigest.read(rpu: source))
            let o = try #require(DoviDmDigest.read(rpu: output))
            let diffs = DoviDmDigest.differences(source: s, output: o)
            #expect(!diffs.isEmpty, "the header and mapping do change")
            #expect(diffs.filter { !DoviDmDigest.isExpectedChange($0.name) }.isEmpty)
            #expect(s.levels == o.levels)
            #expect(DoviDmDigest.cmVersion(s) == DoviDmDigest.cmVersion(o))
        }
    }

    @Test("a different clip's display metadata is reported as an unexpected change")
    func foreignMetadataIsFlagged() throws {
        let s = try #require(DoviDmDigest.read(rpu: Self.fullSource))
        let o = try #require(DoviDmDigest.read(rpu: Self.plainOutput))
        let unexpected = DoviDmDigest.differences(source: s, output: o).filter { !DoviDmDigest.isExpectedChange($0.name) }
        #expect(!unexpected.isEmpty)
        #expect(unexpected.contains { $0.name.hasPrefix("L3") || $0.name.hasPrefix("L254") || $0.name.hasPrefix("L6") })
    }

    /// `fullSource` with one bit of `rgb_to_lms_coef4` changed (12430 to 12431, CRC repaired): a source whose colour
    /// matrix is not the Profile 8.1 one. `modifiedOutput` is what the engine's mode 2 conversion
    /// (`DoviRpuConverter.convertedUnspec62(_, removeMapping: true)`) makes of it, header-less like an attachment.
    private static let modifiedSource: [UInt8] = hexBytes([
        "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000",
        "400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a86d9e67b2f863efc18",
        "9e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e9e04c349fd3bb77ec2cd5de3a147d44c",
        "0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d57bbb6e411483b92966413698fce6bc31bd620fadd40",
        "5bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc3983779e7568311b004800004004004000004012000010010010000010",
        "04800004004004000006895980000d7a8959be7f3ac7095991328000004000000302000003000200000300070d8890c06182",
        "978c23c14500000300698f96bfffc000000300000300000300180803f3805470300800410a6680c028218008008008008004",
        "000180564700100100100100080002014000000300450228048307d0000287cf81849ffc0408285078a048301c0040040000",
        "b080180080080080080080016102500100100100100100082400c14c980e07c04160a6eb23014ff84d03e8033c286c41d4c0",
        "bb83d134042285808800003fe0002042b51a8c80",
    ])

    private static let modifiedOutput: [UInt8] = hexBytes([
        "19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301a2566000035ea2566f9fce",
        "b1c256644ca00000100000030080000003008000000301c36224301860a5e308e0514000001a63e5affff000000300000300",
        "000300060200fce0151c300800410a6680c02821800800800800800400018056470010010010010008000201400000030045",
        "0228048307d0000287cf81849ffc0408285078a048301c0040040000b0801800800800800800800161025001001001001001",
        "00082400c14c980e07c04160a6eb23014ff84d03e8033c286c41d4c0bb83d134042285808800003fe00020b42a68cf80",
    ])

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &pb)
        return try #require(pb)
    }

    private static func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Notes `source`, attaches `attached` and reads it back, as `OrderedDelivery` does.
    private static func observe(_ probe: DoviDmPassthroughProbe, key: Int64, source: [UInt8], attached: [UInt8]) throws -> DoviDmPassthroughProbe.Frame {
        let buffer = try pixelBuffer()
        probe.noteSource(key: key, rpu: source)
        DoviDisplayMetadata.attach(rpuNAL: [0x7C, 0x01] + attached, to: buffer)
        return try #require(probe.observe(buffer: buffer, key: key, pts: CMTime(value: key, timescale: 1000)))
    }

    private static func verdict(_ frame: DoviDmPassthroughProbe.Frame) -> String { String(frame.line.split(separator: " ")[3]) }

    @Test("the mode 2 allow-list holds the four header fields and the mapping, nothing else")
    func allowListIsTight() {
        for name in ["hdr.guessed_profile", "hdr.el_type", "hdr.el_spatial_resampling", "hdr.disable_residual", "map.nlq", "map.c0.pivots"] {
            #expect(DoviDmDigest.isExpectedChange(name), "\(name)")
        }
        for name in ["hdr.vdr_rpu_profile", "hdr.rpu_format", "hdr.vdr_rpu_level", "hdr.el_bit_depth", "hdr.spatial_resampling",
                     "hdr.coefficient_data_type", "hdr.coefficient_log2_denom", "hdr.vdr_rpu_normalized_idc", "hdr.use_prev_vdr_rpu",
                     "dm.rgb_to_lms_coef", "L1", "L6"] {
            #expect(!DoviDmDigest.isExpectedChange(name), "\(name)")
        }
    }

    @Test("a source that already carries the Profile 8.1 matrices shows no normalisation")
    func defaultMatricesAreUnchanged() throws {
        for (source, output) in [(Self.fullSource, Self.fullOutput), (Self.plainSource, Self.plainOutput)] {
            let o = try #require(DoviDmDigest.read(rpu: output))
            let diffs = DoviDmDigest.differences(source: try #require(DoviDmDigest.read(rpu: source)), output: o)
            #expect(diffs.filter(DoviDmDigest.isNormalisedChange).isEmpty)
            for (name, constant) in DoviDmDigest.normalisedByModeTwo { #expect(o[name] == constant, "\(name)") }
        }
    }

    @Test("a source with another colour matrix is reset by mode 2 and reported as normalised, not as a failure")
    func modifiedMatrixIsNormalised() throws {
        let s = try #require(DoviDmDigest.read(rpu: Self.modifiedSource))
        let o = try #require(DoviDmDigest.read(rpu: Self.modifiedOutput))
        #expect(s["dm.rgb_to_lms_coef"] != o["dm.rgb_to_lms_coef"])
        let diffs = DoviDmDigest.differences(source: s, output: o)
        #expect(diffs.filter(DoviDmDigest.isNormalisedChange).map(\.name) == ["dm.rgb_to_lms_coef"])
        #expect(diffs.filter { !DoviDmDigest.isExpectedChange($0.name) && !DoviDmDigest.isNormalisedChange($0) }.isEmpty)
        // A reset field whose output is not the Profile 8.1 constant is not a normalisation.
        #expect(!DoviDmDigest.isNormalisedChange(.init(name: "dm.rgb_to_lms_coef", source: "1", output: "2")))
        #expect(!DoviDmDigest.isNormalisedChange(.init(name: "dm.source_max_pq", source: "1", output: "2")))
    }

    @Test("the probe passes the corpus-like pair, reports the matrix reset as normalised and fails a foreign RPU")
    func probeVerdicts() throws {
        let probe = DoviDmPassthroughProbe(environment: ["AETHER_DM_DIGEST": "log"])
        let pass = try Self.observe(probe, key: 1, source: Self.fullSource, attached: Self.fullOutput)
        #expect(Self.verdict(pass) == "pass" && pass.normalised.isEmpty && pass.unexpected.isEmpty)
        let normalised = try Self.observe(probe, key: 2, source: Self.modifiedSource, attached: Self.modifiedOutput)
        #expect(Self.verdict(normalised) == "normalised")
        #expect(normalised.normalised.map(\.name) == ["dm.rgb_to_lms_coef"] && normalised.unexpected.isEmpty)
        #expect(normalised.line.contains("NORMALISED[dm.rgb_to_lms_coef"))
        let fail = try Self.observe(probe, key: 3, source: Self.fullSource, attached: Self.plainOutput)
        #expect(Self.verdict(fail) == "FAIL" && !fail.unexpected.isEmpty)
        let s = probe.currentSummary()
        #expect(s.frames == 3 && s.passing == 2 && s.normalisedFrames == 1 && s.normalisedFields == ["dm.rgb_to_lms_coef": 1])
    }

    private final class FrameBox: @unchecked Sendable { var frames: [DoviDmPassthroughProbe.Frame] = [] }

    @Test("the JSON line is built only when there is a file or a sink")
    func jsonOnlyForAConsumer() throws {
        let bare = DoviDmPassthroughProbe(environment: ["AETHER_DM_DIGEST": "log"])
        #expect(try Self.observe(bare, key: 1, source: Self.fullSource, attached: Self.fullOutput).json.isEmpty)
        let box = FrameBox()
        let withSink = DoviDmPassthroughProbe(environment: ["AETHER_DM_DIGEST": "hex"], sink: { box.frames.append($0) })
        let f = try Self.observe(withSink, key: 1, source: Self.fullSource, attached: Self.fullOutput)
        let hex = Self.hexString(Self.fullOutput)
        #expect(box.frames.count == 1)
        #expect(f.line.contains("out_hex=" + hex))
        #expect(f.json.contains("\"out_hex\":\"" + hex + "\""))
    }

    @Test("the source ring drops the oldest RPU first")
    func sourceRingEvictsOldest() throws {
        let probe = DoviDmPassthroughProbe(environment: ["AETHER_DM_DIGEST": "log"])
        for k in 0..<4100 { probe.noteSource(key: Int64(k), rpu: Self.fullSource) }
        let buffer = try Self.pixelBuffer()
        DoviDisplayMetadata.attach(rpuNAL: [0x7C, 0x01] + Self.fullOutput, to: buffer)
        let evicted = try #require(probe.observe(buffer: buffer, key: 0, pts: CMTime(value: 0, timescale: 1000)))
        #expect(Self.verdict(evicted) == "no-source")
        let kept = try #require(probe.observe(buffer: buffer, key: 4099, pts: CMTime(value: 4099, timescale: 1000)))
        #expect(Self.verdict(kept) == "pass")
        let boundary = try #require(probe.observe(buffer: buffer, key: 4, pts: CMTime(value: 4, timescale: 1000)))
        #expect(Self.verdict(boundary) == "pass", "4100 noted into a ring of 4096 keeps keys 4 and up")
    }

    @Test("flush starts over: summary, counter and sources are cleared")
    func flushResets() throws {
        let probe = DoviDmPassthroughProbe(environment: ["AETHER_DM_DIGEST": "log"])
        let first = try Self.observe(probe, key: 7, source: Self.fullSource, attached: Self.fullOutput)
        #expect(first.n == 1 && probe.currentSummary().frames == 1)
        probe.flush()
        let cleared = probe.currentSummary()
        #expect(cleared.frames == 0 && cleared.passing == 0 && cleared.levelFrames.isEmpty)
        let buffer = try Self.pixelBuffer()
        DoviDisplayMetadata.attach(rpuNAL: [0x7C, 0x01] + Self.fullOutput, to: buffer)
        let second = try #require(probe.observe(buffer: buffer, key: 7, pts: CMTime(value: 7, timescale: 1000)))
        #expect(second.n == 1, "the counter restarted")
        #expect(Self.verdict(second) == "no-source", "the source ring was cleared")
    }
}
#endif
