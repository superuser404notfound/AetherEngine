// The launch helper the real-origin suites depend on, tested on its two failure exits rather than
// through a server: both of them used to be a wall-clock deadline that a blocking read never
// reached, which is the shape a hung CI job leaves no other trace of.
#if os(macOS)

import Foundation
import Testing

@Suite("Python origin launch", .timeLimit(.minutes(3)))
struct PythonOriginLaunchTests {

    /// The regression this file exists for. A blocking `read` cannot be cancelled, so a test parked
    /// in one ignores its `.timeLimit` trait and the job dies at its own ceiling with the log
    /// discarded. Cancelling the launch has to end it, which it can only do by killing the
    /// interpreter whose pipe the read is waiting on.
    @Test("an origin that never announces a port is cancellable, not a hang")
    func neverReadyIsCancellable() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-never-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // Listens, so the pipe stays open, and says nothing on it. Writing the marker first is what
        // lets the test cancel while the read is genuinely parked rather than before it starts.
        let script = """
            import pathlib, socket, time
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            pathlib.Path(r"\(marker.path)").write_text("up")
            time.sleep(600)
            """

        let launch = Task { await PythonOrigin.launch(prefix: "aether-never-ready", script: script) }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        launch.cancel()
        #expect(await launch.value == nil)
    }

    /// The ordinary failure: the script throws on startup. Before, this spent the full ten second
    /// deadline in 50 ms sleeps; the pipe closing says it immediately.
    @Test("an origin that dies before it listens fails the launch")
    func deadInterpreterFailsTheLaunch() async {
        let result = await PythonOrigin.launch(
            prefix: "aether-dead-origin", script: "import sys\nsys.exit(3)\n")
        #expect(result == nil)
    }

    @Test("a healthy origin hands back the port it bound")
    func healthyOriginReportsItsPort() async throws {
        let script = """
            import socket
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            print("READY", s.getsockname()[1], flush=True)
            import time
            time.sleep(600)
            """
        let launched = try #require(await PythonOrigin.launch(prefix: "aether-ready-origin", script: script))
        defer {
            launched.process.terminate()
            try? FileManager.default.removeItem(at: launched.workDir)
        }
        #expect(launched.port > 0)
    }
}

#endif
