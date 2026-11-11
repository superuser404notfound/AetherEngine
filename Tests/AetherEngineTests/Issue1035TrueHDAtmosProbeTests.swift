import Testing
import Foundation
@testable import AetherEngine

/// AE#1035: a probe settles TrueHD Atmos from the track's major sync, as a session does since PR #838.
/// The committed fixture is FFmpeg's own TrueHD, which probes with an unknown profile like an undecoded
/// Atmos track. No public tool writes TrueHD Atmos and a rewritten major sync fails FFmpeg's parser
/// checksum, so the Atmos case runs on a real sample when `AE_TRUEHD_ATMOS_PROBE_SAMPLE` names one (a
/// container whose TrueHD Atmos track starts past the analysis window, e.g. FFmpeg FATE's
/// `truehd/atmos.thd` muxed into MKV behind 70 s of video, past the 60 s analysis window).
@Suite("AE#1035 TrueHD Atmos in the probe")
struct Issue1035TrueHDAtmosProbeTests {

    /// 0.05 s of 5.1 silence, `ffmpeg -f lavfi -i anullsrc=r=48000:cl=5.1 -c:a truehd -strict -2`, in MKV.
    /// Its header probe reports `profile == nil`, the same nil an undecoded Atmos track gets.
    static let plainTrueHDBase64 = """
    GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAJaxFNm3TA
    v4RfcQECTbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIBRE27jFOrhBxT
    u2tTrIIJT+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hLYhUtIq17GD
    D0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJDpqlhP5iUa4ayUU4JNaGcvRImI
    QEkAAAAAAAAWVK5rzr+EnFfkzq4BAAAAAAAAP9eBAXPFiGKqZ46pCxYSnIEAIrWcg3VuZIiBAIaI
    QV9UUlVFSESDgQLhkZ+BBrWIQOdwAAAAAABiZIEQVe6BABJUw2dAgr+Ek+XsU3NzoGPAgGfImkWj
    h0VOQ09ERVJEh41MYXZmNjIuMTIuMTAxc3PWY8CLY8WIYqpnjqkLFhJnyKFFo4dFTkNPREVSRIeU
    TGF2YzYyLjI4LjEwMSB0cnVlaGRnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjA1MDAwMDAwMAAf
    Q7Z1R32/hBCwJxDngQCjQJyBAACA0Ez/2Phyb7oAB4APt1IAAAAAjH8gPAAAAAAAAAAA5NEgFyA6
    8eoAAAEQAAAAAQhAAAAAA2qCBIABAyAAQIAAJEAx1HQCAAAGOo6AQAAAgABizvHqAAAlUAAAAAEI
    QAAAAAIQYgpmggSAAQMgAEDIABAyAAQIAAAAAkQDHUdAIAAAY6joBAAADHUdAIAAAY6joBAAACAA
    EPWjnoEAAQDwDQAAYARgCZFAgBACAOrakUCAEAIAQAiiVKOUgQACALAIAChgAmAEQADpHUAA6R2j
    lIEAAwBACABQYAJgBEAA6R1AAOkdo5SBAAMA4AgAeGACYARAAOkdQADpHaOUgQAEALAIAKBgAmAE
    QADpHUAA6R2jlIEABQBQCADIYAJgBEAA6R1AAOkdo5SBAAYA4AgA8GACYARAAOkdQADpHaOUgQAH
    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
    t4r3gQHxggHM8IEJ
    """

    static var plain: Data { Data(base64Encoded: plainTrueHDBase64, options: .ignoreUnknownCharacters)! }

    static func probe(_ data: Data, detecting: ProbeDetail, options: AtmosDetectionOptions = .init()) throws -> TrackInfo {
        let probe = try AetherEngine.probe(
            source: .custom(DataIOReader(data: data), formatHint: "matroska"),
            detecting: detecting, atmosDetection: options)
        return try #require(probe.audioTracks.first)
    }

    static var atmosSample: URL? {
        ProcessInfo.processInfo.environment["AE_TRUEHD_ATMOS_PROBE_SAMPLE"].map { URL(fileURLWithPath: $0) }
    }

    @Test func fixtureIsTheUndecodedCase() throws {
        let plain = try Self.probe(Self.plain, detecting: [])
        #expect(plain.codec == "truehd")
        #expect(plain.profile == nil)
        #expect(plain.trueHDAtmos == nil)
    }

    @Test func atmosSampleSettlesAtmosAndNamesTheProfile() throws {
        guard let url = Self.atmosSample else { return }
        let base = try AetherEngine.probe(url: url)
        let probe = try AetherEngine.probe(url: url, detecting: .atmos)
        let before = try #require(base.audioTracks.first { $0.codec == "truehd" })
        let track = try #require(probe.audioTracks.first { $0.id == before.id })
        #expect(before.profile == nil, "the sample must start past the analysis window")
        #expect(track.trueHDAtmos == .atmos)
        #expect(track.profile == AetherEngine.trueHDAtmosProfileName)
        #expect(track.isAtmos == false, "isAtmos stays the E-AC-3 JOC answer")
    }

    @Test func atmosSampleSettlesInAControlledProbe() throws {
        guard let url = Self.atmosSample else { return }
        // The caller's byte budget bounds the whole probe, this pass included, so it has to reach the track.
        let limits = ProbeLimits(maxInputBytes: 256 << 20, timeBudget: 30)
        let probe = try AetherEngine.probe(source: .url(url), detecting: .atmos, limits: limits)
        let track = try #require(probe.audioTracks.first { $0.codec == "truehd" })
        #expect(track.trueHDAtmos == .atmos)
    }

    @Test func aBudgetShortOfTheTrackStopsTheProbeInsteadOfAnsweringNo() throws {
        guard let url = Self.atmosSample else { return }
        #expect(throws: ProbeError.inputLimit) {
            try AetherEngine.probe(source: .url(url), detecting: .atmos, limits: ProbeLimits())
        }
    }

    @Test func plainMajorSyncSettlesNoAtmos() throws {
        let track = try Self.probe(Self.plain, detecting: .atmos)
        #expect(track.trueHDAtmos == .noAtmos)
        #expect(track.profile == nil)
    }

    @Test func aCapBeforeAnyMajorSyncIsUnsettledNotNoAtmos() throws {
        let track = try Self.probe(Self.plain, detecting: .atmos, options: AtmosDetectionOptions(maxBytes: 1))
        #expect(track.trueHDAtmos == .unsettled)
        #expect(track.profile == nil)
    }

    @Test func otherDetailsLeaveTheVerdictUnset() throws {
        let track = try Self.probe(Self.plain, detecting: .hdr10Plus)
        #expect(track.trueHDAtmos == nil)
    }

    @Test func passReadsOnlyUntilTheFirstMajorSync() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.plain), formatHint: "matroska")
        _ = demuxer.seekBounded(to: 0, timeout: 5)
        let outcome = AetherEngine.detectTrueHDAtmos(
            demuxer: demuxer, targetIndex: demuxer.audioStreamIndex, options: AtmosDetectionOptions())
        #expect(outcome.verdict == .noAtmos)
        #expect(outcome.packetsRead == 1)
    }

    @Test func nonTrueHDTargetIsUnsettledWithoutARead() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(
            data: Data(base64Encoded: AtmosDetectionProbeIntegrationTests.eac3PlainBase64,
                       options: .ignoreUnknownCharacters)!), formatHint: "mp4")
        let outcome = AetherEngine.detectTrueHDAtmos(
            demuxer: demuxer, targetIndex: demuxer.audioStreamIndex, options: AtmosDetectionOptions())
        #expect(outcome.verdict == .unsettled)
        #expect(outcome.packetsRead == 0)
    }
}
