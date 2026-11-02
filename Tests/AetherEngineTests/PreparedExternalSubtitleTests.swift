import Combine
import Testing
import Foundation
@testable import AetherEngine

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct PreparedExternalSubtitleTests {
    private func file(_ text: String, ext: String = "srt") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.\(ext)")
        try Data(text.utf8).write(to: url)
        return url
    }
    private var text: String { "1\n00:02:01,000 --> 00:02:03,000\nFixture\n\n" }
    private func player() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.state = .paused
        engine.activeSubtitleTrackIndex = 7
        engine.subtitleCues = [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Old"))]
        return engine
    }

    @Test func prepareDoesNotChangeOldSelectionAndCommitDoesNotReadFile() async throws {
        let engine = try player()
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prepared = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        #expect(engine.activeSubtitleTrackIndex == 7)
        #expect(engine.subtitleCues.first?.text == "Old")
        #expect(engine.subtitleTracks.isEmpty)
        #expect(prepared.cueCount == 1)
        try FileManager.default.removeItem(at: url)
        let track = try engine.commitExternalSubtitle(prepared)
        #expect(track.isExternal)
        #expect(engine.activeSubtitleTrackIndex == track.id)
        #expect(engine.subtitleCues.first?.text == "Fixture")
        #expect(engine.state == .paused)
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(prepared) }
    }

    @Test func aSeekInFlightIsStillTheSameSession() async throws {
        let engine = try player()
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        engine.state = .seeking
        let prepared = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        let track = try engine.commitExternalSubtitle(prepared)
        #expect(engine.activeSubtitleTrackIndex == track.id)
        let stale = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        engine.state = .idle
        #expect(throws: ExternalSubtitlePreparationError.stale) { try engine.commitExternalSubtitle(stale) }
    }

    @Test func invalidAndPlaylistFilesNeverClearOldSubtitle() async throws {
        for payload in ["not a subtitle", "", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nhttps://127.0.0.1:1/video.m3u8\n"] {
            let engine = try player()
            let url = try file(payload)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            await #expect(throws: ExternalSubtitlePreparationError.self) {
                try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
            }
            #expect(engine.activeSubtitleTrackIndex == 7)
            #expect(engine.subtitleCues.first?.text == "Old")
            #expect(engine.subtitleTracks.isEmpty)
        }
    }

    @Test func stoppedGenerationAndNewIntentRejectPreparedCandidate() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let first = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        engine.stop()
        engine.state = .paused // even a subsequently playable engine cannot revive the old handle
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(first) }
        let second = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        engine.clearSubtitle()
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(second) }
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test func exactRegisteredIDAndRemovedAssetAreRespected() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let descriptor = ExternalSubtitleTrack(url: url)
        let first = engine.registerExternalSubtitleTrack(descriptor)
        let second = engine.registerExternalSubtitleTrack(descriptor)
        engine.activeSecondaryExternalSubtitleTrackID = first.id
        let candidate = try await engine.prepareExternalSubtitle(id: second.id)
        #expect(try engine.commitExternalSubtitle(candidate).id == second.id)
        let removed = try await engine.prepareExternalSubtitle(id: second.id)
        engine.removeExternalSubtitleTrack(id: second.id)
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(removed) }
    }

    @Test func secondaryRemainsWhenPrimaryCommits() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        engine.activeSecondaryExternalSubtitleTrackID = 8
        engine.secondarySubtitleCues = [SubtitleCue(id: 2, startTime: 0, endTime: 10, body: .text("Secondary"))]
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        try engine.commitExternalSubtitle(candidate)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == 8)
        #expect(engine.secondarySubtitleCues.first?.text == "Secondary")
    }

    @Test func ownerDiscardAndSharedIntent() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let other = try player()
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        #expect(throws: ExternalSubtitlePreparationError.self) { try other.commitExternalSubtitle(candidate) }
        candidate.discard()
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(candidate) }
        let first = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        let second = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        _ = try engine.commitExternalSubtitle(first, secondary: true)
        #expect(throws: ExternalSubtitlePreparationError.self) { try engine.commitExternalSubtitle(second) }
        #expect(engine.subtitleCues.first?.text == "Old")
        #expect(engine.secondarySubtitleCues.first?.text == "Fixture")
    }

    @Test func configuredLimitsAndNonRegularFilesPreserveSelection() async throws {
        // Pin the defaults documented in docs/api.md; callers may choose other positive bounds.
        let defaults = ExternalSubtitlePreparationPolicy()
        #expect(defaults.maximumFileBytes == 4 * 1024 * 1024)
        #expect(defaults.maximumCueCount == 50_000)
        #expect(defaults.maximumCueBytes == 8192)
        #expect(defaults.maximumTextBytes == 8 * 1024 * 1024)
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        for policy in [ExternalSubtitlePreparationPolicy(maximumFileBytes: 1),
                       .init(maximumCueCount: 0), .init(maximumCueBytes: 1), .init(maximumTextBytes: 1)] {
            await #expect(throws: ExternalSubtitlePreparationError.resourceLimit) {
                try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url), policy: policy)
            }
            #expect(engine.subtitleCues.first?.text == "Old")
            #expect(engine.subtitleTracks.isEmpty)
        }
        let link = url.deletingLastPathComponent().appendingPathComponent("link.srt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: ExternalSubtitlePreparationError.resourceLimit) {
            try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: link))
        }
        let prepared = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url),
            policy: .init(maximumFileBytes: 1000, maximumCueCount: 1, maximumCueBytes: 100, maximumTextBytes: 100))
        #expect(prepared.cueCount == 1)
    }

    @Test func cancelledPreparationDoesNotPublish() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let task = Task { try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url)) }
        task.cancel()
        await #expect(throws: ExternalSubtitlePreparationError.cancelled) { try await task.value }
        #expect(engine.subtitleCues.first?.text == "Old")
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test func oneRegisteredTrackCanOccupyBothChannels() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let track = engine.registerExternalSubtitleTrack(ExternalSubtitleTrack(url: url))
        let primary = try await engine.prepareExternalSubtitle(id: track.id)
        _ = try engine.commitExternalSubtitle(primary)
        let secondary = try await engine.prepareExternalSubtitle(id: track.id)
        _ = try engine.commitExternalSubtitle(secondary, secondary: true)
        #expect(engine.activeSubtitleTrackIndex == track.id)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == track.id)
        #expect(engine.subtitleCues.compactMap(\.text) == engine.secondarySubtitleCues.compactMap(\.text))
    }

    private final class ValidationThread: @unchecked Sendable {
        let lock = NSLock()
        var observedMainThread: Bool?
        func record() { lock.withLock { observedMainThread = Thread.isMainThread } }
        var observed: Bool? { lock.withLock { observedMainThread } }
    }

    @Test func fileAdmissionRunsOffMainActor() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let observed = ValidationThread()
        SubtitleDecoder.preparedFileValidationObserverForTesting = { candidate in
            if candidate == url { observed.record() }
        }
        defer { SubtitleDecoder.preparedFileValidationObserverForTesting = nil }
        let engine = try player()
        let prepared = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        #expect(prepared.cueCount == 1)
        #expect(observed.observed == false)
    }

    @Test(arguments: [false, true])
    func preparedASSKeepsRequestedStyleAndSecondaryHeader(preserve: Bool) async throws {
        let ass = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Hello{\\i0} world
        """
        let url = try file(ass, ext: "ass")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: preserve))
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        let track = try engine.commitExternalSubtitle(candidate, secondary: true)
        let cue = try #require(engine.secondarySubtitleCues.first)
        if preserve {
            let header = try #require(engine.secondarySidecarASSHeader)
            #expect(header.contains("PlayResX: 1920"))
            let builder = ASSScriptBuilder(header: header)
            #expect(builder.add(rawEventText: try #require(cue.text), start: cue.startTime, end: cue.endTime))
            #expect(builder.script().contains("{\\i1}Hello{\\i0} world"))
        } else {
            #expect(engine.secondarySidecarASSHeader == nil)
            #expect(cue.text == "Hello world")
            guard case .richText(let runs) = cue.body else { Issue.record("default ASS styling was lost"); return }
            #expect(runs.first?.isItalic == true)
        }
        #expect(engine.subtitleCues.first?.text == "Old")
        #expect(engine.externalSubtitleRegistry[track.id]?.preparationPolicy != nil)
    }

    @Test func registeredPolicyIsRetainedAndCanBeExplicitlyChanged() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let policy = ExternalSubtitlePreparationPolicy(maximumCueCount: 1)
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url), policy: policy)
        let track = try engine.commitExternalSubtitle(candidate)
        try Data((text + "2\n00:02:04,000 --> 00:02:06,000\nSecond\n\n").utf8).write(to: url)
        await #expect(throws: ExternalSubtitlePreparationError.resourceLimit) {
            try await engine.prepareExternalSubtitle(id: track.id)
        }
        #expect(engine.subtitleCues.count == 1)
        let replacementPolicy = ExternalSubtitlePreparationPolicy(maximumCueCount: 2)
        let replacement = try await engine.prepareExternalSubtitle(id: track.id, policy: replacementPolicy)
        #expect(try engine.commitExternalSubtitle(replacement).id == track.id)
        #expect(engine.subtitleCues.count == 2)
        #expect(engine.externalSubtitleRegistry[track.id]?.preparationPolicy == replacementPolicy)
    }

    @Test func synchronousTrackObserverCannotConsumeCandidateTwice() async throws {
        let url = try file(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try player()
        let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(url: url))
        var rejection: ExternalSubtitlePreparationError?
        let observer = engine.$subtitleTracks.dropFirst().sink { _ in
            do { _ = try engine.commitExternalSubtitle(candidate) }
            catch { rejection = error as? ExternalSubtitlePreparationError }
        }
        defer { observer.cancel() }
        _ = try engine.commitExternalSubtitle(candidate)
        #expect(rejection == .stale)
        #expect(engine.subtitleTracks.count == 1)
    }
}
