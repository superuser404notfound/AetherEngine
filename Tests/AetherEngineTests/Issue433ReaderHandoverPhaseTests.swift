import Testing
import Foundation
@testable import AetherEngine

/// #433: a producer restart that replaces the reader left `playbackPhase` on `.stalled(reconnecting: true)`
/// for the rest of the session, over normally playing video (measured: 454.8 s, 298 s of it playing).
///
/// The axis is per SESSION, its dedupe gate is per reader INSTANCE, and the two got out of step at the
/// handover: the replacement demuxer is opened first and wired to the sink afterwards, so every delivery
/// `find_stream_info` made went through the gate into a nil sink. The gate then held `.flowing` as its
/// opinion, and the reader that was now serving the session had nothing left to say. The dying reader's
/// `.reconnecting` was the last word anyone heard.
///
/// The rule this pins: a gate deduplicates what a LISTENER has heard, so a listener that just attached has
/// heard nothing, whatever the reader said into the void before it arrived.
@Suite("Reader handover keeps the network axis readable (#433)", .serialized)
struct Issue433ReaderHandoverPhaseTests {

    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [ReaderNetworkPhase] = []
        func append(_ phase: ReaderNetworkPhase) {
            lock.lock(); phases.append(phase); lock.unlock()
        }
        var snapshot: [ReaderNetworkPhase] {
            lock.lock(); defer { lock.unlock() }
            return phases
        }
    }

    /// The reported handover, at the reader: the restart opens the replacement demuxer and only then hands
    /// it the sink (`HLSVideoEngine.restart`, `AetherEngine+Loading` on both software paths). What a
    /// listener sees must not depend on which side of `open()` it attached from.
    @Test("a reader wired after its open still announces the delivery the session is riding on",
          .timeLimit(.minutes(3)))
    func sinkAttachedAfterOpenStillHearsDelivery() throws {
        let serverMaybe = ThrottledOriginServer(totalSize: 32 * 1024 * 1024, respond: { _, _, _ in .serve206 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!

        // Arm 1, the historical wiring: the listener is there before the first byte.
        let early = AVIOReader(url: url)
        defer { early.markClosed(); early.close() }
        let earlyPhases = PhaseLog()
        early.onNetworkPhaseChanged = { earlyPhases.append($0) }
        try early.open()
        #expect(Self.readForward(early, bytes: 512 * 1024) > 0)

        // Arm 2, the restart's wiring: the reader delivers through its open, THEN the sink arrives.
        let late = AVIOReader(url: url)
        defer { late.markClosed(); late.close() }
        try late.open()
        #expect(Self.readForward(late, bytes: 512 * 1024) > 0, "the pre-wiring reads are the open's own")
        let latePhases = PhaseLog()
        late.onNetworkPhaseChanged = { latePhases.append($0) }
        #expect(Self.readForward(late, bytes: 512 * 1024) > 0)

        #expect(earlyPhases.snapshot.contains(.flowing),
                "control arm: a wired-first reader reports its delivery: \(earlyPhases.snapshot)")
        #expect(latePhases.snapshot.contains(.flowing),
                "a listener that attached after the open heard nothing at all: \(latePhases.snapshot)")
    }

    /// The same rule, spelled at the gate: attaching a listener clears the opinion the reader formed while
    /// nobody was listening. Without this, `shouldEmit` answers a question about a sink that never existed.
    @Test("a fresh listener has heard nothing, whatever the gate already believes")
    func gateForgetsForANewListener() {
        var gate = NetworkPhaseGate()
        #expect(gate.shouldEmit(.flowing) == true)
        #expect(gate.shouldEmit(.flowing) == false)
        gate.forgetForNewListener()
        #expect(gate.shouldEmit(.flowing) == true, "the new listener must be told the phase it never heard")
    }

    /// The session-level shape of the report: the dying reader parked the engine on `.reconnecting`, the
    /// replacement formed its `.flowing` opinion before the sink existed, and the phase then described a
    /// reader that no longer served the session while the picture played.
    @MainActor
    @Test("the replacement reader clears the phase the dying one left behind")
    func replacementReaderClearsTheStall() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        // AE#440: the session in this report was playing a picture, so its transport had rolled.
        engine.hasTransportRolled = true

        var dyingReaderGate = NetworkPhaseGate()
        if dyingReaderGate.shouldEmit(.reconnecting) { engine.setReaderNetworkPhase(.reconnecting) }
        #expect(engine.playbackPhase == .stalled(reconnecting: true))

        // The replacement's open runs before the restart wires the sink: these deliveries reach no one.
        var replacementGate = NetworkPhaseGate()
        _ = replacementGate.shouldEmit(.flowing)
        // The restart installs it and hands it the session's sink.
        replacementGate.forgetForNewListener()
        if replacementGate.shouldEmit(.flowing) { engine.setReaderNetworkPhase(.flowing) }

        #expect(engine.playbackPhase == .playing,
                "the phase must describe the reader that is serving, not the one that was aborted")
    }

    private static func readForward(_ reader: AVIOReader, bytes: Int) -> Int {
        let slice = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got = 0
        while got < bytes {
            let n = reader.read(into: buf, size: Int32(min(slice, bytes - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }
}
