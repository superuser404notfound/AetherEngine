import Foundation
import Testing
import AVFoundation
import QuartzCore
@testable import AetherEngine

/// Audit GPU-206: the held still and the scrub preview poll an `AVPlayerItem` with a short sleep until it is
/// displayable or a deadline passes. Wrapped in `try?`, the sleep of a cancelled task returns at once, so a
/// cancelled wait spun the main actor until its deadline (3 s for the held still, 2 s for the preview). The
/// item here comes from a loopback socket that accepts and never answers, so it stays pending: a wait that
/// returns before its deadline returned because it saw the cancellation. The waits get a 600 s budget
/// and only have to return before it. Any tighter wall-clock bound loses to a starved runner: the
/// main actor took 22 s just to start the task once, and on 2026-11-19 a correct wait came back after
/// 72 s against the old 60 s bound. A wait that ignores the cancellation still fails, at the suite's
/// time limit.
@Suite("Picture waits end with their task", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct PictureWaitCancellationTests {

    @Test("a cancelled scrub preview stops waiting for its item")
    func cancelledScrubPreviewStops() async throws {
        let (fd, port) = try #require(LoopbackPort.listen(backlog: 4))
        defer { close(fd) }
        let view = AetherScrubPreviewView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/preview.mp4"))
        let start = ContinuousClock.now
        let task = Task { @MainActor in await view.present(url, budget: .seconds(600)) }
        task.cancel()
        #expect(await task.value == false)
        #expect(ContinuousClock.now - start < .seconds(600), "returned at its deadline, not at the cancellation")
    }

    @Test("a cancelled held still stops waiting for its item")
    func cancelledHeldStillStops() async throws {
        let (fd, port) = try #require(LoopbackPort.listen(backlog: 4))
        defer { close(fd) }
        let presenter = HeldStillPresenter()
        let host = CALayer()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/still.mp4"))
        let start = ContinuousClock.now
        let task = Task { @MainActor in
            await presenter.show(file: url, pastFirstFrameBy: 0, gravity: .resizeAspect, on: host,
                                 bounds: CGRect(x: 0, y: 0, width: 160, height: 90), budgetSeconds: 600)
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(ContinuousClock.now - start < .seconds(600), "returned at its deadline, not at the cancellation")
        #expect(!presenter.isShowing)
    }
}
