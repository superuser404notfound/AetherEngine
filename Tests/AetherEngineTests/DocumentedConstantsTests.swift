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
    func testLiveReplayQuarantineBoundsMatchDocumentation() throws {
        XCTAssertEqual(LivePacketReplayGuard.maximumPendingBytes, 96 * 1_024 * 1_024)
        XCTAssertEqual(LivePacketReplayGuard.maximumPendingPackets, 10_000)
        assertDocumented("Quarantine is bounded to 96 MiB and 10,000 packets", try documentation())
    }

    func testSoftwarePositioningBudgetMatchesDocumentation() throws {
        XCTAssertEqual(SoftwarePlaybackHost.seekBudgetSeconds, 30)
        assertDocumented("**30 s positioning\nbudget**", try documentation())
    }

    func testItemDiagnosticBoundsMatchDocumentation() throws {
        let docs = try documentation()
        XCTAssertEqual(ItemDiagnosticReadPool.maximumConcurrentReads, 2)
        XCTAssertEqual(AVPlayerItemDiagnostics.maximumPendingRetirements, 1)
        XCTAssertEqual(AVPlayerItemDiagnostics.accessLogLimit, 5)
        assertDocumented("**two concurrent diagnostic reads**", docs)
        assertDocumented("**one pending retirement\nread**", docs)
        assertDocumented("five entries per item", docs)
    }

    func testPartialCompositionHoldBoundsMatchDocumentation() throws {
        let docs = try documentation()
        XCTAssertEqual(H264PartialCompositionRepair.maximumReorderDepth, 16)
        XCTAssertEqual(H264PartialCompositionRepair.maximumHeldPackets, 1024)
        XCTAssertEqual(H264PartialCompositionRepair.maximumHeldBytes, 32 << 20)
        XCTAssertEqual(H264PartialCompositionRepair.maximumProofPictures, 64)
        assertDocumented("to **16 pictures**", docs)
        assertDocumented("**1024 interleaved packets and\n32 MiB**", docs)
        assertDocumented("within **64 pictures**", docs)
    }

    func testDualLayerRouteBudgetMatchesDocumentation() throws {
        let fel = try felDocument()
        XCTAssertEqual(DualLayerRouteDecision.maximumPixelsPerSecond, 311_040_000)
        XCTAssertEqual(DualLayerRouteDecision.assumedFrameRate, 24)
        XCTAssertEqual(DualLayerRouteDecision.assumedEnhancementLayerAreaFraction, 0.25)
        assertDocumented("311.04 Mpx/s", fel)
        assertDocumented("UHD\n3840x2160 at 30 fps plus a 1920x1080 enhancement layer at 30 fps", fel)
        assertDocumented("an unknown frame rate is budgeted as 24", fel)
        assertDocumented("A 24p UHD FEL master needs 80% of the budget", fel)
    }

    #if DualLayerDolbyVision
    func testDualLayerPipelineBoundsMatchDocumentation() throws {
        let docs = try documentation()
        let fel = try felDocument()
        XCTAssertEqual(DualLayerVideoDecoder.maxLayerSkewFrames, 3)
        XCTAssertEqual(DualLayerVideoDecoder.maxEnhancementLayerQueueFrames, 10)
        XCTAssertEqual(FrameSideDataRing.capacity, 32)
        XCTAssertEqual(FrameSideDataRing.jitterToleranceTicks, 300)
        XCTAssertEqual(DoviFelComposer.maxFramesInFlight, 3)
        XCTAssertEqual(SampleBufferRenderer.felVideoLookaheadFrames, 9)
        XCTAssertEqual(DoviFelComposer.outputPoolAllocationThreshold, 15)
        XCTAssertEqual(DoviFelComposer.outputPoolReserve, 3)
        XCTAssertEqual(DualLayerVideoDecoder.maxBorrowedParamsRun, 3)
        XCTAssertEqual(SampleBufferRenderer.hardwareDecoderReorderDepth, 4)
        XCTAssertEqual(DualLayerVideoDecoder.settledKeyMemory, 64)
        XCTAssertEqual(DualLayerVideoDecoder.summaryIntervalSeconds, 1.0)
        // About 36 ms: ten attempts with a sleep between each pair.
        XCTAssertEqual(Double(DoviFelComposer.outputPoolAttempts - 1) * DoviFelComposer.outputPoolRetryInterval,
                       0.036, accuracy: 1e-9)

        assertDocumented("once K = 3 newer base-layer", fel)
        assertDocumented("is the maximum layer skew, 3;", fel)
        assertDocumented("waiting enhancement frames capped at 10", fel)
        assertDocumented("At most 10 enhancement frames wait", fel)
        assertDocumented("fixed capacity 32", fel)
        assertDocumented("within ±300 ticks", fel)
        assertDocumented("wait for one of 3 in-flight slots", fel)
        assertDocumented("look-ahead (9)", fel)
        assertDocumented("the in-flight slots (3) + 1, so 15", fel)
        assertDocumented("a reserve of 3 more", fel)
        assertDocumented("allocation threshold 15 + reserve 3", fel)
        assertDocumented("`maxBorrowedParamsRun` (3)", fel)
        assertDocumented("the renderer's 4-frame reorder buffer", fel)
        assertDocumented("last 64\n  settled base-layer keys", fel)
        assertDocumented("for at most about 36 ms", fel)
        assertDocumented("Counters feed a 1 Hz summary", fel)
        _ = docs
    }
    #endif

    private func felDocument() throws -> String {
        let url = Self.repoRoot.appendingPathComponent("docs/dolby-vision-fel.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("running outside a source checkout; no docs to check against")
        }
        return text
    }

    /// docs/formats.md quotes the lead a software-path live join keeps behind the newest media.
    func testSoftwareLiveJoinLeadMatchesDocumentation() throws {
        XCTAssertEqual(SoftwareLiveJoinPolicy.leadSeconds, 4)
        XCTAssertEqual(SoftwareLiveJoinPolicy.minimumSettleSeconds, 0.3)
        XCTAssertEqual(SoftwareLiveJoinPolicy.maximumSettleSeconds, 1.5)
        XCTAssertEqual(SoftwareLiveJoinPolicy.calmWindowSeconds, 0.25)
        assertDocumented("`SoftwareLiveJoinPolicy.leadSeconds` (4 s) behind the newest media", try documentation())
    }

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

    func testWholeProbeDefaultsMatchDocumentation() throws {
        let docs = try documentation()
        let limits = ProbeLimits()
        XCTAssertEqual(limits.maxInputBytes, 8 * 1024 * 1024)
        XCTAssertEqual(limits.maxPackets, 128)
        XCTAssertEqual(limits.maxPacketBytes, 2 * 1024 * 1024)
        XCTAssertEqual(limits.timeBudget, 5)
        assertDocumented("`maxInputBytes` (8 MiB), `maxPackets` (128)", docs)
        assertDocumented("`maxPacketBytes` (2 MiB), `timeBudget` (5 s)", docs)
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

    // MARK: - The Atmos rendition's CHANNELS value

    /// docs/formats.md and docs/architecture.md both print the CHANNELS value a stream-copied
    /// E-AC-3 JOC rendition is advertised with, and the object count in it is the part a reader
    /// checks against Dolby's delivery kit. If the engine ever sources it from the `dec3` box's
    /// `complexity_index_type_a` instead of stating it, both sentences stop being true at once.
    func testAtmosRenditionChannelsValueIsWhatTheDocsSay() throws {
        let docs = try documentation()
        XCTAssertEqual(VideoSegmentProvider.atmosChannelsAttribute, "16/JOC",
                       "documented as the object count, a slash, then JOC")
        assertDocumented(#"`CHANNELS="16/JOC"`"#, docs)
    }

    // MARK: - External subtitle ids

    /// A host tells its own tracks from the engine's by this base, and docs/api.md prints the number.
    /// docs/api.md and formats.md quote the APAC rate, the limiter and the bed log cadence (#731).
    func testTrueHDAtmosNumbersAreWhatTheDocsSay() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let docs = try documentation()
        #if TrueHDObjectAudio || DTSXObjectAudio
        XCTAssertEqual(SpatialAudioBridge.bitRatePerChannel, 320_000)
        assertDocumented("320 kbps per bed channel", docs)
        XCTAssertEqual(BedLevelMeter.firstWindowSeconds, 5)
        XCTAssertEqual(BedLevelMeter.windowSeconds, 30)
        assertDocumented("after the first 5 s of audio (and again after every seek), then every 30 s", docs)
        XCTAssertEqual(SpatialAudioBridge.silentFeedPacketThreshold, 1200)
        assertDocumented("returns nothing for 1200 packets in a row, a second of TrueHD", docs)
        XCTAssertEqual(ObjectMetadataHold.maxHeldFrames, 4_800)
        assertDocumented("(it waits at most 100 ms)", docs)
        #endif
        XCTAssertEqual(PeakLimiter.threshold, 0.98)
        assertDocumented("nothing leaves above −0.18 dBFS", docs)
        XCTAssertEqual(PeakLimiter.releaseSeconds, 0.25)
        assertDocumented("a 250 ms release", docs)
        XCTAssertEqual(APACSampleEntry.codecsString(channelCount: 12), "apac.31.03")
        XCTAssertEqual(APACSampleEntry.codecsString(channelCount: 16), "apac.31.04")
    }

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

    // MARK: - The version the engine reports about itself (AetherPlayer#7)

    /// `AetherEngine.version` is the number a host puts in its About panel and in the header of the
    /// log a reporter attaches, so a stale one does not read as stale: it reads as a fact about the
    /// build under discussion, and an analysis then runs against the wrong engine. Nothing in the
    /// compiler knows that 7.2.0 stopped being true.
    ///
    /// A release already rewrites three statements of the same number, so the constant is pinned to
    /// all three. A forgotten bump is a red test here rather than a log line that lies.
    func testReportedVersionMatchesEveryPublishedStatementOfIt() throws {
        assertDocumented(#"from: "\#(AetherEngine.version)""#, try documentation())

        let examples = try sourceFile("Examples/README.md")
        XCTAssertTrue(examples.contains("starting from `\(AetherEngine.version)`"), """
            Examples/README.md no longer says "starting from `\(AetherEngine.version)`".
            The dependency step an adopter follows has to name the version the engine reports.
            """)

        let newestRelease = try sourceFile("CHANGELOG.md")
            .split(separator: "\n")
            .first { $0.hasPrefix("## [") && !$0.hasPrefix("## [Unreleased]") }
            .map { $0.drop { $0 != "[" }.dropFirst().prefix { $0 != "]" } }
            .map(String.init)
        XCTAssertEqual(newestRelease, AetherEngine.version, """
            AetherEngine.version says \(AetherEngine.version), the newest CHANGELOG entry says \
            \(newestRelease ?? "nothing"). Both move in the release prep commit, together with the \
            README install snippets.
            """)
    }

    /// The README's Swift and Xcode rows are the toolchain CI builds and tests with, not a taste
    /// (audit OPS-103): every macOS job runs on the `xcode-27` image and none selects another Xcode.
    /// Moving CI to another image without the rows, or the rows without CI, fails here.
    func testToolchainRowsAreTheOnesCITestsWith() throws {
        let ci = try sourceFile(".github/workflows/ci.yml")
        let macOSJobs = ci.components(separatedBy: "runs-on: ").dropFirst()
            .map { entry in entry.prefix { !$0.isNewline } }
            .filter { !$0.hasPrefix("ubuntu") }
        XCTAssertFalse(macOSJobs.isEmpty, "ci.yml has no macOS job")
        XCTAssertTrue(macOSJobs.allSatisfy { $0 == "xcode-27" }, "macOS jobs run on \(macOSJobs)")
        XCTAssertFalse(ci.contains("xcode-version:"), "a job selects its own Xcode instead of the image's")
        let docs = try documentation()
        assertDocumented("| Xcode | 27.0 |", docs)
        assertDocumented("| Swift | 6.4 |", docs)
    }

    /// The docs corpus is README + docs/; a claim living in a source docstring is read straight.
    private func sourceFile(_ relativePath: String) throws -> String {
        guard let text = try? String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
                                     encoding: .utf8)
        else { throw XCTSkip("running outside a source checkout; no sources to check against") }
        return text
    }

    // MARK: - Picture-order pairing (docs/dolby-vision-fel.md §5.3)

    #if DualLayerDolbyVision
    func testPictureOrderPairingBoundMatchesDocumentation() throws {
        XCTAssertEqual(DualLayerPictureAlignment.maxSlotDistance, 16)
        assertDocumented("more than 16 slots off its unit", try felDocument())
    }
    #endif
}
