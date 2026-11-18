import Foundation
import Testing
@testable import AetherEngine

/// AE#1052, round 4: a bitmap rendition is filled only by the OCR worker or a sidecar fill. A
/// request for one nothing fills used to sit in the 3 s readiness wait (30 s whole-program) and
/// come back empty anyway, holding the loopback connection AVPlayer also loads video on. On tvOS a
/// seek never landed that way. Reached when the user picks another bitmap track in AVKit's menu
/// before the host reacts, or when a plain select names a bitmap track that is not the overlay's.
@MainActor
struct Issue1052BitmapFillWaitTests {

    private func provider(stores: [NativeSubtitleCueStore], wholeProgram: Bool = false,
                          cache: SegmentCache) -> VideoSegmentProvider {
        let segments = (0..<8).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        return VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "hvc1.2.4.L150.B0", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            nativeSubtitleStores: stores,
            nativeSubtitleLanguages: stores.map { _ in "eng" },
            nativeSubtitleRenditionInfos: stores.map { _ in
                NativeSubtitleRenditionInfo(language: "eng", name: "English", isForced: false) },
            nativeSubtitleWholeProgram: wholeProgram)
    }

    private func seconds(_ work: () -> String?) -> (String?, Double) {
        let began = Date()
        let result = work()
        return (result, Date().timeIntervalSince(began))
    }

    @Test("only a bitmap store with a fill running is worth waiting for")
    func waitsOnlyWhileFilled() {
        let text = NativeSubtitleCueStore()
        #expect(text.waitsForFill)

        let bitmap = NativeSubtitleCueStore(fillsOnDemand: true)
        #expect(!bitmap.waitsForFill)
        bitmap.fillStarted()
        bitmap.fillStarted()   // a sidecar fill overlapping the worker
        bitmap.fillEnded()
        #expect(bitmap.waitsForFill)
        bitmap.fillEnded()
        #expect(!bitmap.waitsForFill)
        bitmap.fillEnded()     // an extra end never goes below nothing
        bitmap.fillStarted()
        #expect(bitmap.waitsForFill)
    }

    @Test("a segment of a bitmap rendition nothing fills is served at once", .timeLimit(.minutes(3)))
    func unfilledBitmapSegmentIsImmediate() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let p = provider(stores: [NativeSubtitleCueStore(fillsOnDemand: true)], cache: cache)
        let (vtt, took) = seconds { p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 3) }
        #expect(vtt != nil)
        #expect(took < 1.0)
    }

    @Test("a bitmap rendition the OCR worker fills keeps the readiness wait", .timeLimit(.minutes(3)))
    func filledBitmapSegmentStillWaits() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let store = NativeSubtitleCueStore(fillsOnDemand: true)
        store.fillStarted()
        let p = provider(stores: [store], cache: cache)
        let (_, took) = seconds { p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 3) }
        #expect(took >= 2.5)
    }

    @Test("the whole-program file of an unfilled bitmap rendition skips the 30 s wait",
          .timeLimit(.minutes(3)))
    func unfilledBitmapWholeProgramIsImmediate() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let p = provider(stores: [NativeSubtitleCueStore(fillsOnDemand: true)], wholeProgram: true, cache: cache)
        let (vtt, took) = seconds { p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0) }
        #expect(vtt != nil)
        #expect(took < 1.0)
    }

    @Test("arming and cancelling the OCR worker starts and ends its store's fill", .timeLimit(.minutes(3)))
    func workerArmsAndReleasesFill() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-pgs-fill.mkv"))
        let store = NativeSubtitleCueStore(fillsOnDemand: true)
        session.nativeSubtitleCueStoresForSession = [store]
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }

        engine.startSubtitleOCRWorker(ordinal: 0, streamIndex: 3)
        #expect(store.waitsForFill)
        engine.startSubtitleOCRWorker(ordinal: 0, streamIndex: 3)   // a re-arm counts once
        engine.cancelSubtitleOCRWorker()
        #expect(!store.waitsForFill)

        // A cancel after the session moved on releases the store it armed, not the new one.
        engine.startSubtitleOCRWorker(ordinal: 0, streamIndex: 3)
        let next = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-next.mkv"))
        let nextStore = NativeSubtitleCueStore(fillsOnDemand: true)
        nextStore.fillStarted()
        next.nativeSubtitleCueStoresForSession = [nextStore]
        engine.nativeVideoSession = next
        engine.cancelSubtitleOCRWorker()
        #expect(!store.waitsForFill)
        #expect(nextStore.waitsForFill)
    }
}
