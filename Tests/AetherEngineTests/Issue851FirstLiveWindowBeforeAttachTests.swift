// AE#851: the loopback built its first live window behind AVPlayer's first playlist request, so the
// whole wait ran on AVPlayer's playlist timer, which gives up after about 20 s on tvOS (-16839). A
// cushion a 1x origin needs longer than that to fill could never start. The engine now waits out the
// same gate before the item is attached, and the request is then answered at once.
import XCTest
@testable import AetherEngine

final class Issue851FirstLiveWindowBeforeAttachTests: XCTestCase {

    private func makeProvider(cushion: Double?) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        var sizing = LiveWindowSizing(targetSegmentDurationSeconds: 1, dvrWindowSeconds: nil)
        sizing.edgeCushionSeconds = cushion
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.4D001E,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (720, 576),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 1_500_000,
            isLive: true,
            liveWindowSizing: sizing,
            firstServeLatchCoversEngineCut: false
        )
        return (provider, cache)
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// A 1x origin: eight 1 s segments, one every 0.1 s, against an 8 s cushion.
    func testTheWindowIsBuiltBeforeAndTheRequestIsAnsweredAtOnce() async {
        let (provider, cache) = makeProvider(cushion: 8)
        defer { cache.close() }
        let producer = Thread {
            for i in 0..<8 {
                Thread.sleep(forTimeInterval: 0.1)
                provider.appendLiveSegment(index: i, startSeconds: Double(i), durationSeconds: 1)
            }
        }
        producer.start()

        let capture = EngineLogCapture()
        defer { capture.end() }
        await AetherEngine.awaitFirstLiveWindow(provider)
        XCTAssertTrue(capture.lines.contains { $0.contains("AE#851 first live window ready") })
        XCTAssertTrue(capture.lines.contains { $0.contains("8 segments / 8.000s >= 8.000s holdback") })

        var served = false
        let request = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertLessThan(request, 0.1, "the playlist request must not wait on the window again")
    }

    /// A stopped session releases the wait, and the line says the window never came.
    func testACancelledGateReleasesTheWait() async {
        let (provider, cache) = makeProvider(cushion: 30)
        defer { cache.close() }
        let capture = EngineLogCapture()
        defer { capture.end() }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.2)
            provider.cancelWaiters()
        }
        let started = DispatchTime.now()
        await AetherEngine.awaitFirstLiveWindow(provider)
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        XCTAssertLessThan(waited, 2)
        XCTAssertTrue(capture.lines.contains { $0.contains("AE#851 first live window not ready") })
    }
}
