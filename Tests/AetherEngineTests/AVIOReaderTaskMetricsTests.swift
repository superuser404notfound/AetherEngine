import Testing
@testable import AetherEngine

@Suite("AVIOReader slow first-byte task metrics")
struct AVIOReaderTaskMetricsTests {

    @Test("a slow task lists host-only hops in order and rounds milliseconds")
    func slowTaskListsOrderedHostOnlyHops() {
        let hops = [
            AVIOReader.HopTiming(
                host: "remux.atlasvideoplayer.com", port: 443, status: 302,
                ttfbMs: 9_011.6, totalMs: 9_013.6),
            AVIOReader.HopTiming(
                host: "addon.debridio.com", port: 443, status: 302,
                ttfbMs: 209.6, totalMs: 210.6),
            AVIOReader.HopTiming(
                host: "store-076.wnam.tb-cdn.io", port: 443, status: 206,
                ttfbMs: 179.6, totalMs: 261.6),
        ]

        let line = AVIOReader.slowFirstByteLine(taskSeconds: 9.4866, hops: hops)

        #expect(line == "[AVIOReader] slow first byte: task=9487ms over 3 hops: "
            + "remux.atlasvideoplayer.com:443 status=302 ttfb=9012ms total=9014ms -> "
            + "addon.debridio.com:443 status=302 ttfb=210ms total=211ms -> "
            + "store-076.wnam.tb-cdn.io:443 status=206 ttfb=180ms total=262ms")
        #expect(line?.contains("/") == false)
        #expect(line?.contains("?") == false)
    }

    @Test("a hop without an HTTP response omits status")
    func missingStatusIsOmitted() {
        let line = AVIOReader.slowFirstByteLine(
            taskSeconds: 1.5,
            hops: [AVIOReader.HopTiming(
                host: "cdn.example.com", port: 8443, status: nil,
                ttfbMs: 1_100.4, totalMs: 1_499.6)]
        )

        #expect(line == "[AVIOReader] slow first byte: task=1500ms over 1 hops: "
            + "cdn.example.com:8443 ttfb=1100ms total=1500ms")
        #expect(line?.contains("status=") == false)
    }

    @Test("summed first-byte wait controls the strict one-second threshold")
    func thresholdUsesSummedFirstByteWait() {
        let fastHop = AVIOReader.HopTiming(
            host: "cdn.example.com", port: 443, status: 200,
            ttfbMs: 200, totalMs: 3_000)
        let boundaryHop = AVIOReader.HopTiming(
            host: "cdn.example.com", port: 443, status: 200,
            ttfbMs: 1_000, totalMs: 3_000)
        let slowHop = AVIOReader.HopTiming(
            host: "cdn.example.com", port: 443, status: 200,
            ttfbMs: 1_200, totalMs: 3_000)

        #expect(AVIOReader.slowFirstByteLine(taskSeconds: 3, hops: [fastHop]) == nil)
        #expect(AVIOReader.slowFirstByteLine(taskSeconds: 3, hops: [boundaryHop]) == nil)
        #expect(AVIOReader.slowFirstByteLine(taskSeconds: 3, hops: [slowHop]) != nil)
    }
}
