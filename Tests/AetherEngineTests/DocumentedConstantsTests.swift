import XCTest
import AVFoundation
import AetherLibavcodec
@testable import AetherEngine

/// The documentation quotes numbers. "32 entries", "six hours", "a quarter of the tmp volume's free
/// space, capped at 2 GiB", "the historical default of 10". Every one of those is a constant living
/// somewhere in `Sources/`, copied into prose by hand, and nothing has ever held the two together:
/// change the constant and the docs keep asserting the old value in a sentence that still reads
/// perfectly. That is the same failure the API-coverage tests exist for, one level down. A wrong
/// number is worse than a missing one, because a reader budgets against it.
///
/// So each check below pins a documented number to the code that owns it, and names the sentence to
/// fix when it moves. The check is deliberately NOT "the constant is right": that is a product
/// decision and belongs in the test that covers the behaviour. It is "the docs and the code still
/// say the same thing", and the fix for a failure here is usually one word in one Markdown file.
///
/// Adding a number to the docs? Pin it here in the same commit.
@MainActor
final class DocumentedConstantsTests: XCTestCase {

    // MARK: - Documentation corpus

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func documentation() throws -> String {
        let root = Self.repoRoot
        guard let readme = try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8),
              let entries = try? FileManager.default.contentsOfDirectory(
                  atPath: root.appendingPathComponent("docs").path)
        else { throw XCTSkip("running outside a source checkout; no docs to check against") }
        let markdown = entries.filter { $0.hasSuffix(".md") }.sorted().compactMap {
            try? String(contentsOf: root.appendingPathComponent("docs/\($0)"), encoding: .utf8)
        }
        return ([readme] + markdown).joined(separator: "\n")
    }

    /// Asserts the docs still contain the sentence fragment that states this number.
    private func assertDocumented(_ phrase: String, _ docs: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(docs.contains(phrase), """
            The documentation no longer contains "\(phrase)".
            Either the wording moved (update this pin) or the statement was dropped (put it back).
            """, file: file, line: line)
    }

    // MARK: - The reroute verdict memory (#199)

    /// docs/api.md and README both state the shape of the memory a same-URL live retune rides on.
    /// A shorter TTL or a smaller table silently makes that paragraph's "cheap" claim wrong.
    func testRerouteVerdictMemoryMatchesItsDocumentedShape() throws {
        let docs = try documentation()
        let now = Date()
        let url = URL(string: "https://origin.example/live/ch1.m3u8")!

        var memory = RerouteVerdictMemory()
        memory.record(url, now: now)

        XCTAssertTrue(memory.remembers(url, now: now.addingTimeInterval(6 * 3600 - 60)),
                      "documented as six hours; a verdict one minute short of that must still hold")
        XCTAssertFalse(memory.remembers(url, now: now.addingTimeInterval(6 * 3600 + 60)),
                       "documented as six hours; past it the origin gets another chance")
        assertDocumented("for six hours, 32 entries", docs)

        // Capacity, from the outside: 32 fresh entries evict the oldest one.
        var full = RerouteVerdictMemory()
        for i in 0..<33 {
            full.record(URL(string: "https://origin.example/ch\(i).m3u8")!,
                        now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(full.remembers(URL(string: "https://origin.example/ch0.m3u8")!, now: now),
                       "documented as 32 entries; the 33rd must evict the oldest")
        XCTAssertTrue(full.remembers(URL(string: "https://origin.example/ch32.m3u8")!, now: now))
    }

    // MARK: - Forward buffer window

    /// README and docs/api.md both quote the default and the clamp of `forwardBufferSegments`.
    func testForwardWindowDefaultAndClampAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(nil), 10, "documented default")
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(1), 4, "documented floor")
        XCTAssertEqual(HLSVideoEngine.clampedForwardWindow(Int.max), 2700, "documented ceiling")
        assertDocumented("Clamped to 4...2700", docs)
        assertDocumented("nil (10, about 40 s)", docs)
    }

    // MARK: - Retention budget

    /// The README's Seek row and the `forwardBufferSegments` entry both rest on the 2 GiB cap.
    func testRetentionBudgetCapIsTwoGiB() throws {
        let docs = try documentation()
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: nil),
                       2 << 30, "documented as a 2 GiB cap")
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 8 << 30),
                       2 << 30, "a quarter of 8 GiB is the cap itself")
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 4 << 30),
                       1 << 30, "documented as a quarter of the volume's free space below the cap")
        assertDocumented("2 GiB cap", docs)
    }

    // MARK: - Probe budgets

    func testRecoveryPointRoutingMatchesDocumentedThreshold() throws {
        let docs = try documentation()
        var evidence = H264RecoveryPoint.Evidence()
        for _ in 0..<2 {
            evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: true)
        }
        XCTAssertFalse(evidence.requiresCompatibilityPath)
        evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: true)
        XCTAssertTrue(evidence.requiresCompatibilityPath)
        assertDocumented("Three positive samples select software compatibility", docs)
    }

    /// docs/api.md states the defaults a host overrides with `probesize` / `maxAnalyzeDuration`.
    func testProbeBudgetDefaultsAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(DemuxerOpenProfile.playback.probesize, 50 * 1024 * 1024, "documented as 50 MB")
        XCTAssertEqual(DemuxerOpenProfile.playback.maxAnalyzeDuration, 60 * 1_000_000, "documented as 60 s")
        assertDocumented("defaults 50 MB / 60 s", docs)
    }

    // MARK: - Startup ladder

    /// docs/api.md prints the ladder as a table AND states the total under it, which is the number a
    /// host's progress bar divides by. Adding a checkpoint without touching that sentence is exactly
    /// the change this catches.
    func testStartupLadderTotalMatchesTheDocumentedNumber() throws {
        let docs = try documentation()
        XCTAssertEqual(StartupCheckpoint.allCases.count, 9, "documented as nine checkpoints")
        XCTAssertEqual(StartupCheckpoint.total, 8, "documented: .dispatched is the origin, so total is eight")
        XCTAssertEqual(StartupCheckpoint.presenting.rawValue, StartupCheckpoint.total,
                       "the ladder must end exactly at total, or a bar never reaches 100%")
        assertDocumented("`total` is eight", docs)
    }

    // MARK: - Audio tap format

    /// README and docs/api.md both promise mono Float32 48 kHz to anything consuming the tap
    /// (SpeechAnalyzer, ShazamKit), and those consumers are configured against that promise.
    func testAudioTapFormatIsMonoFloat32At48k() throws {
        let docs = try documentation()
        let format = AetherEngine.audioTapFormat
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        assertDocumented("mono Float32 48 kHz", docs)
    }

    // MARK: - Subtitle windows

    /// docs/formats.md explains the subtitle pipeline in terms of these four windows, and the
    /// relationships between them carry the explanation: the prefetch margin exists BECAUSE it sits
    /// beyond the drain lead, and the OCR prefetch beyond the OCR window, for the same reason. A
    /// number that moves without its sentence turns a correct explanation into a plausible one.
    func testSubtitleWindowsAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(AetherEngine.subtitleDrainLeadSeconds, 60, "documented as the 60 s lead window")
        XCTAssertEqual(AetherEngine.subtitleForwardPrefetchLeadMarginSeconds, 15, "documented as a 15 s margin")
        XCTAssertEqual(AetherEngine.subtitleOCRLeadSeconds, 240, "documented as the OCR worker's 240 s window")
        XCTAssertEqual(AetherEngine.subtitleOCRPrefetchLeadSeconds, 270, "documented as raised to 270 s while OCR is armed")

        XCTAssertGreaterThan(AetherEngine.subtitleForwardPrefetchLeadMarginSeconds, 0,
                             "the margin IS the fix for #362: at parity the set at the edge has its clear stored nowhere")
        XCTAssertGreaterThan(AetherEngine.subtitleOCRPrefetchLeadSeconds, AetherEngine.subtitleOCRLeadSeconds,
                             "the prefetch has to clear the OCR window, or the store does not hold what the worker reads")
        assertDocumented("60 s lead window", docs)
        assertDocumented("15 s margin", docs)
        assertDocumented("clears the OCR worker's own 240 s window by 30 s", docs)
    }

    // MARK: - Audio bridge shape

    /// docs/formats.md states the caps and the rates a host picks `audioBridgeMode` on, and the
    /// 7.1-to-5.1 fold is a known limitation an adopter reads before choosing `.lossless`.
    func testAudioBridgeCapsAndRatesAreWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(AudioBridge.maxEncodedChannels(for: AV_CODEC_ID_EAC3), 6,
                       "documented as capping 7.1 sources to 5.1")
        XCTAssertEqual(AudioBridge.maxEncodedChannels(for: AV_CODEC_ID_FLAC), 8,
                       "documented as FLAC up to 7.1")
        XCTAssertEqual(AudioBridge.encoderBitRate(for: AV_CODEC_ID_EAC3, channels: 2), 256_000,
                       "the stereo rate the #165 cascade still reaches on a build without FLAC")
        XCTAssertEqual(AudioBridge.encoderBitRate(for: AV_CODEC_ID_EAC3, channels: 6), 768_000,
                       "documented as 768 kbps 5.1")
        XCTAssertEqual(AudioBridge.encoderBitRate(for: AV_CODEC_ID_FLAC, channels: 8), 0,
                       "FLAC is VBR; a rate here would cap a lossless path")
        assertDocumented("128 kbps per channel (768 kbps 5.1)", docs)
        assertDocumented("caps 7.1 sources to 5.1", docs)
        assertDocumented("Two channels or fewer have no surround to carry", docs)
    }

    // MARK: - External subtitle ids

    /// A host tells its own tracks from the engine's by this base, and docs/api.md prints the number.
    func testExternalSubtitleTrackIDBaseIsDocumented() throws {
        let docs = try documentation()
        XCTAssertEqual(AetherEngine.externalSubtitleTrackIDBase, 100_000)
        assertDocumented("`100_000`", docs)
    }

    // MARK: - Rate pitch correction (#434)

    /// Not a number, the same failure one step over: `setRate` documented the software path as playing
    /// speed without pitch correction, and it never did. Both surfaces were running AVFoundation's
    /// TimeDomain default, so the sentence read perfectly and described nothing in the build. A reporter
    /// came within one step of gating a group-playback speed feature on decode route because of it.
    /// The algorithm is pinned now, and this holds the three places that say so to what the code does.
    func testRateChangesArePitchPreservingOnBothPaths() throws {
        XCTAssertEqual(AudioRatePolicy.pitchAlgorithm, .timeDomain,
                       "documented as TimeDomain; Varispeed is the one that lets pitch ride the rate")

        // The software path, which is the surface the documentation was wrong about.
        XCTAssertEqual(AudioOutput().renderer.audioTimePitchAlgorithm, AudioRatePolicy.pitchAlgorithm,
                       "the SW renderer is what the synchronizer's timebase rate runs through")

        // The native path, both hosts of it, via the call they share.
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        AudioRatePolicy.apply(to: item)
        XCTAssertEqual(item.audioTimePitchAlgorithm, AudioRatePolicy.pitchAlgorithm)

        assertDocumented("Pitch-preserving on both decode routes", try documentation())

        // The docstring an adopter reads in Xcode is where this drifted, so it gets pinned too.
        let engineSource = try sourceFile("Sources/AetherEngine/AetherEngine.swift")
        XCTAssertTrue(engineSource.contains("Both paths are pitch-preserving"),
                      "setRate's own documentation must keep saying which paths correct pitch")
    }

    /// The docs corpus is README + docs/; a claim living in a source docstring is read straight.
    private func sourceFile(_ relativePath: String) throws -> String {
        guard let text = try? String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
                                     encoding: .utf8)
        else { throw XCTSkip("running outside a source checkout; no sources to check against") }
        return text
    }
}
