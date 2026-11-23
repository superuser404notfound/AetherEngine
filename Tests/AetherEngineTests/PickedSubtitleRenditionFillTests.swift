import Testing
import Foundation
@testable import AetherEngine

/// AE#984 round 2 (golfista): AVPlayer must never hold a selected rendition whose sidecar is still
/// decoding. Measured with a bare AVPlayer on tvOS 27 and macOS 27: picked before `readyToPlay`, a
/// rendition answering 404 delayed readiness by the whole wait and failed the item after ~30 s; picked
/// mid-play with a long wait, media loading stopped. So the pick's sidecar fills first, the others wait
/// until the item is ready, and the select reaches AVPlayer only once the sidecar is in.
@Suite("Picked rendition fills first and is selected once decoded (AE#984)")
struct PickedSubtitleRenditionFillTests {

    private static func vtt(_ line: String) -> String {
        "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n\(line)\n"
    }

    private static func provider(_ origin: SidecarOrigin, paths: [String]) -> RemoteHLSSubtitleProvider {
        RemoteHLSSubtitleProvider(
            tracks: paths.enumerated().map { i, path in
                RemoteHLSSubtitleProvider.Track(
                    externalID: 100_000 + i,
                    source: ExternalSubtitleTrack(url: origin.url(path), name: "Track \(i)", language: "en"))
            },
            masterBody: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"
            https://jf.test/videos/42/main.m3u8
            """,
            programDuration: 60, defaultHeaders: [:], mediaURL: nil)
    }

    @Test("Held fills wait for a pick, and the picked one runs before the rest", .timeLimit(.minutes(3)))
    func pickedFillRunsFirst() async throws {
        let paths = ["/a.vtt", "/b.vtt", "/c.vtt"]
        let origin = try #require(SidecarOrigin(files: Dictionary(
            uniqueKeysWithValues: paths.map { ($0, Self.vtt($0)) })))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: paths)
        defer { provider.cancelFill() }

        provider.startFill(holdingUnpicked: true)
        await provider.awaitFill()
        #expect(origin.requests.isEmpty, "nothing fills before a pick or readiness")
        #expect(provider.renditionServe(ordinal: 2) == .retryLater)

        provider.prioritizeFill(ordinal: try #require(provider.ordinal(forExternalID: 100_002)))
        await provider.awaitFill()
        #expect(origin.requests.map(\.path) == ["/c.vtt"])
        #expect(provider.renditionServe(ordinal: 2) == .complete)
        #expect(provider.renditionServe(ordinal: 0) == .retryLater)

        provider.releaseHeldFills()
        await provider.awaitFill()
        #expect(origin.requests.map(\.path) == ["/c.vtt", "/a.vtt", "/b.vtt"])
        #expect((0..<3).allSatisfy { provider.renditionServe(ordinal: $0) == .complete })
    }

    @Test("A pick takes over from a running fill of another rendition", .timeLimit(.minutes(3)))
    func pickPreemptsUnpickedFill() async throws {
        let paths = ["/a.vtt", "/b.vtt", "/c.vtt"]
        let origin = try #require(SidecarOrigin(files: Dictionary(
            uniqueKeysWithValues: paths.map { ($0, Self.vtt($0)) }), delaySeconds: 1))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: paths)
        defer { provider.cancelFill() }

        provider.startFill()          // not held: /a.vtt starts at once
        provider.prioritizeFill(ordinal: 2)
        await provider.awaitFill()

        let order = origin.requests.map(\.path)
        // /a.vtt may already have been asked when the pick took over, so /c.vtt is first or second.
        // The preempted /a.vtt resumes right after it, ahead of /b.vtt, which never started.
        let c = try #require(order.firstIndex(of: "/c.vtt"))
        #expect(c <= 1)
        #expect(Array(order[c...]) == ["/c.vtt", "/a.vtt", "/b.vtt"])
        #expect((0..<3).allSatisfy { provider.renditionServe(ordinal: $0) == .complete })
    }

    @Test("A failed sidecar is fetched again when its rendition is picked", .timeLimit(.minutes(3)))
    func failedFillRetriesOnPick() async throws {
        let origin = try #require(SidecarOrigin(files: [:]))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: ["/late.vtt"])
        defer { provider.cancelFill() }

        provider.startFill()
        await provider.awaitFill()
        #expect(provider.renditionServe(ordinal: 0) == .failedFill)

        origin.put("/late.vtt", Self.vtt("Late line"))
        provider.prioritizeFill(ordinal: 0)
        #expect(provider.renditionServe(ordinal: 0) != .failedFill, "the retry is pending at once")
        await provider.awaitFill()
        #expect(provider.renditionServe(ordinal: 0) == .complete)
        #expect(origin.requests.map(\.path) == ["/late.vtt", "/late.vtt"])
    }

    @Test("A request for a held rendition starts its fill", .timeLimit(.minutes(3)))
    func requestForHeldRenditionStartsItsFill() async throws {
        let paths = ["/a.vtt", "/b.vtt"]
        let origin = try #require(SidecarOrigin(files: Dictionary(
            uniqueKeysWithValues: paths.map { ($0, Self.vtt($0)) })))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: paths)
        defer { provider.cancelFill() }

        provider.startFill(holdingUnpicked: true)
        // Something other than the engine (AVKit's own menu) selected the second rendition.
        #expect(provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0) == nil)
        await provider.awaitFill()
        #expect(origin.requests.map(\.path) == ["/b.vtt"])
        #expect(provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0)?.contains("/b.vtt") == true)
    }

    @Test("A request for a rendition never overtakes the host's pick that is still on its way",
          .timeLimit(.minutes(3)))
    func requestDoesNotOvertakeHostPick() async throws {
        let paths = ["/a.vtt", "/b.vtt"]
        let origin = try #require(SidecarOrigin(files: Dictionary(
            uniqueKeysWithValues: paths.map { ($0, Self.vtt($0)) }), delaySeconds: 1))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: paths)
        defer { provider.cancelFill() }

        provider.startFill(holdingUnpicked: true)
        provider.prioritizeFill(ordinal: 0)      // the host picked A
        #expect(provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0) == nil)   // AVPlayer still on B
        #expect(provider.renditionWasRefused(ordinal: 1))
        await provider.awaitFill()
        #expect(origin.requests.map(\.path).first == "/a.vtt")
        #expect(provider.renditionServe(ordinal: 0) == .complete)

        // Once the host's pick is in, a request for B is a pick of its own.
        _ = provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0)
        await provider.awaitFill()
        #expect(origin.requests.map(\.path) == ["/a.vtt", "/b.vtt"])
        #expect(provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0)?.contains("/b.vtt") == true)
        #expect(!provider.renditionWasRefused(ordinal: 1), "a full answer clears the refusal")
    }

    @Test("Starting the fills again over the same stores keeps them pending throughout",
          .timeLimit(.minutes(3)))
    func restartKeepsStoresPending() async throws {
        let origin = try #require(SidecarOrigin(files: ["/a.vtt": Self.vtt("A")]))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: ["/a.vtt"])
        defer { provider.cancelFill() }

        provider.startFill(holdingUnpicked: true)
        provider.startFill(holdingUnpicked: true)
        #expect(provider.renditionServe(ordinal: 0) == .retryLater)
    }

    @Test("Cancelling the fills tells a waiting select they are not coming", .timeLimit(.minutes(3)))
    func cancelMarksStrandedStoresFailed() async throws {
        let origin = try #require(SidecarOrigin(files: ["/a.vtt": Self.vtt("A")]))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: ["/a.vtt"])

        provider.startFill(holdingUnpicked: true)
        #expect(provider.renditionServe(ordinal: 0) == .retryLater)
        provider.cancelFill()
        #expect(provider.renditionServe(ordinal: 0) == .failedFill)
        #expect(origin.requests.isEmpty)
    }

    @Test("A pick of a finished rendition fetches nothing", .timeLimit(.minutes(3)))
    func pickOfFinishedRenditionIsFree() async throws {
        let origin = try #require(SidecarOrigin(files: ["/a.vtt": Self.vtt("A")]))
        defer { origin.stop() }
        let provider = Self.provider(origin, paths: ["/a.vtt"])
        defer { provider.cancelFill() }

        provider.startFill()
        await provider.awaitFill()
        provider.prioritizeFill(ordinal: 0)
        await provider.awaitFill()
        #expect(origin.requests.count == 1)
    }

    // MARK: - Settle wait

    @MainActor
    @Test("The select waits until the sidecar is in, gives up on a failure, and steps aside for a newer pick",
          .timeLimit(.minutes(3)))
    func settleOutcomes() async {
        let store = NativeSubtitleCueStore()
        store.markExternalFillPending()
        let ready = Task { @MainActor in
            await AetherEngine.awaitInjectedRenditionSettled(
                serve: { store.wholeProgramServe }, isCurrent: { true }, pollNanoseconds: 10_000_000)
        }
        store.markFinished()
        #expect(await ready.value == .ready)

        let failing = NativeSubtitleCueStore()
        failing.markExternalFillPending()
        let failed = Task { @MainActor in
            await AetherEngine.awaitInjectedRenditionSettled(
                serve: { failing.wholeProgramServe }, isCurrent: { true }, pollNanoseconds: 10_000_000)
        }
        failing.markExternalFillFailed()
        #expect(await failed.value == .failed)

        let pending = NativeSubtitleCueStore()
        pending.markExternalFillPending()
        let pick = PickFlag()
        let superseded = Task { @MainActor in
            await AetherEngine.awaitInjectedRenditionSettled(
                serve: { pending.wholeProgramServe }, isCurrent: { pick.isCurrent }, pollNanoseconds: 10_000_000)
        }
        pick.isCurrent = false
        #expect(await superseded.value == .superseded)
    }

    // MARK: - Loopback windowed rendition

    @MainActor
    @Test("A windowed segment of a failed sidecar is served empty at once", .timeLimit(.minutes(3)))
    func windowedSegmentOfFailedSidecarIsImmediate() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let store = NativeSubtitleCueStore()
        store.markExternalFillPending()
        store.markExternalFillFailed()
        let segments = (0..<8).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "hvc1.2.4.L150.B0", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            nativeSubtitleStores: [store],
            nativeSubtitleLanguages: ["eng"],
            nativeSubtitleRenditionInfos: [NativeSubtitleRenditionInfo(language: "eng", name: "English",
                                                                       isForced: false)],
            nativeSubtitleWholeProgram: false)

        // The old path held a failed store's window for the full 3 s readiness wait, for nothing.
        let began = Date()
        let empty = provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 2)
        #expect(empty?.hasPrefix("WEBVTT") == true)
        #expect(empty?.contains("-->") == false)
        #expect(Date().timeIntervalSince(began) < 2.5, "a failed sidecar has nothing coming, so no wait")
    }
}

@MainActor
private final class PickFlag {
    var isCurrent = true
}
