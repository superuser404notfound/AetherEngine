import Foundation
import Testing

/// The test origins' port ledger: the engine's per-origin state outlives a suite, so a recycled port
/// would hand one suite's learned origin budget to the next.
@Suite("Loopback test origins never reuse a port within the process")
struct LoopbackPortTests {

    @Test("a port an origin already had is refused")
    func claimRefusesAnIssuedPort() throws {
        let listener = try #require(LoopbackListener())
        defer { listener.stop() }
        #expect(!LoopbackPort.claim(listener.port))
    }

    @Test("origins opened and stopped one after another all get distinct ports")
    func stoppedOriginsDoNotHandBackTheirPort() throws {
        var seen: Set<UInt16> = []
        for _ in 0..<200 {
            let listener = try #require(LoopbackListener())
            listener.stop()
            #expect(seen.insert(listener.port).inserted, "port \(listener.port) handed out twice")
        }
    }
}
