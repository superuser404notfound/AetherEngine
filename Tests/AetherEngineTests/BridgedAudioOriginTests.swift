// Tests/AetherEngineTests/BridgedAudioOriginTests.swift
// AE#561 follow-up: `baseMediaDecodeTime` is `unsigned int(64)`, so a negative published timestamp
// is not merely unusual, it is unrepresentable. The audio bridge stamps the FRAME it hands the
// encoder, and an encoder declaring `initial_padding` stamps its first PACKET a padding below that
// frame (256 samples on the AC-3 family, 0 on FLAC). At source position 0 that published -256 as
// 2^64 - 256, and AVPlayer placed the first audio fragment 584 thousand years out, losing its audio.
// Nothing discards the priming here, because the muxer writes no edit list on purpose, so the
// counter carries the padding and the content pays its 5.3 ms instead.
import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// Every `(trackID, baseMediaDecodeTime)` in the segment, in fragment order.
private func trackOrigins(_ segment: Data) -> [(track: UInt32, tfdt: UInt64)] {
    func u32(_ off: Int) -> UInt32 {
        segment.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
    }
    func u64(_ off: Int) -> UInt64 {
        segment.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt64.self)) }
    }
    func boxes(_ range: Range<Int>) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var off = range.lowerBound
        while off + 8 <= range.upperBound {
            let size = Int(u32(off))
            guard size >= 8, off + size <= range.upperBound else { break }
            let type = String(bytes: segment[off + 4..<off + 8], encoding: .isoLatin1) ?? "????"
            out.append((type, (off + 8)..<(off + size)))
            off += size
        }
        return out
    }

    var out: [(UInt32, UInt64)] = []
    for (type, moof) in boxes(0..<segment.count) where type == "moof" {
        for (t2, traf) in boxes(moof) where t2 == "traf" {
            var track: UInt32 = 0
            var tfdt: UInt64 = 0
            for (t3, body) in boxes(traf) {
                switch t3 {
                case "tfhd":
                    track = u32(body.lowerBound + 4)
                case "tfdt":
                    tfdt = segment[body.lowerBound] == 1
                        ? u64(body.lowerBound + 4)
                        : UInt64(u32(body.lowerBound + 4))
                default:
                    break
                }
            }
            out.append((track, tfdt))
        }
    }
    return out
}

@Suite("Bridged audio starts on a representable timeline", .serialized)
struct BridgedAudioOriginTests {

    /// 5.1 PCM in Matroska routes audio through the bridge in surround-compat mode, so the encoder
    /// is EAC3 and declares a 256-sample `initial_padding`. Every published `tfdt` has to stay a
    /// timestamp rather than a wrapped negative, and the audio track has to start near zero rather
    /// than near 2^64.
    @Test("No published timestamp is a wrapped negative",
          .enabled(if: fixtureExists("bridge-eac3-51.mkv"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func bridgedAudioOriginIsRepresentable() throws {
        let engine = HLSVideoEngine(url: fixtureURL("bridge-eac3-51.mkv"), dvModeAvailable: false)
        let playbackURL = try engine.start()
        defer { engine.stop() }
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(),
                                               resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)

        // The encoder time base is 1/48000, so a whole minute of audio is 2.88e6 ticks. Anything
        // above the signed ceiling is a negative that wrapped, which is the failure this pins;
        // the tighter bound below is what makes it a statement about the origin rather than a
        // statement about overflow.
        let signedCeiling = UInt64(Int64.max)
        var audioOrigin: UInt64?
        for index in 0...2 {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("seg\(index).mp4"))
            else { break }
            for (track, tfdt) in trackOrigins(data) {
                #expect(tfdt < signedCeiling,
                        "seg\(index) track \(track) published tfdt \(tfdt), a negative timestamp wrapped into the unsigned field")
                if track == 2, audioOrigin == nil { audioOrigin = tfdt }
            }
        }

        // The session's first audio fragment is the bridge's origin, and it has to sit within a
        // segment of zero rather than a padding below it. 1/48000 is the encoder time base.
        let origin = try #require(audioOrigin, "no audio track was produced, so nothing was witnessed")
        #expect(origin < 48_000 * 10,
                "the bridged audio timeline starts at \(origin) in 1/48000, nowhere near the source's own start")
    }
}
