import Testing
import Foundation
@testable import AetherEngine

/// External PGS sidecar decode (Jellyfin serves external PGS tracks as raw .sup streams). The
/// fixture is local-only like the restart-witness clips (extract one with:
/// `ffmpeg -i <mkv-with-pgs> -map 0:s:0 -c copy Fixtures/external-pgs.sup`); the test skips when
/// absent (CI). Requires FFmpegBuild >= 2.1.3 (sup demuxer in the allowlist).
@Suite("Sidecar PGS decode")
struct SidecarPGSDecodeTests {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AetherEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("external-pgs.sup")
    }

    @Test("raw .sup sidecar decodes into image cues with monotonic timing")
    func supSidecarDecodes() async throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { return }
        let result = try await SubtitleDecoder.decodeFile(url: fixtureURL, httpHeaders: [:], preserveASSMarkup: false)
        #expect(!result.cues.isEmpty)
        var lastStart = -1.0
        for cue in result.cues {
            guard case .image(let image) = cue.body else {
                Issue.record("non-image cue in PGS sidecar")
                return
            }
            #expect(image.cgImage.width > 0)
            #expect(cue.endTime > cue.startTime)
            #expect(cue.startTime >= lastStart)
            lastStart = cue.startTime
        }
    }

    @Test("OCR fill turns a .sup sidecar's image cues into non-empty text cues")
    func supSidecarOCRFill() async throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { return }
        let result = try await SubtitleDecoder.decodeFile(url: fixtureURL, httpHeaders: [:], preserveASSMarkup: false)
        let store = NativeSubtitleCueStore()
        SubtitleImageOCR.appendRecognized(cues: Array(result.cues.prefix(8)), language: "eng", to: store)
        let recognized = store.snapshotCues()
        #expect(!recognized.isEmpty)
        for cue in recognized {
            #expect(cue.text?.isEmpty == false)
            #expect(cue.endTime > cue.startTime)
        }
    }
}
