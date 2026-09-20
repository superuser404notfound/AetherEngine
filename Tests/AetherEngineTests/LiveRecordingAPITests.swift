import Testing
import Foundation
@testable import AetherEngine

/// The guards and the lifecycle of the public recording API (AE#560).
@Suite("Live recording API", .serialized)
@MainActor
struct LiveRecordingAPITests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).ts")
    }

    // MARK: - Guards

    @Test("a session that is not live refuses")
    func refusesNonLive() async throws {
        let engine = try AetherEngine()
        await #expect(throws: RecordingFailure.notLive) {
            try await engine.startRecording(to: tempURL())
        }
        #expect(engine.recordingState == .idle)
    }

    @Test("the remote bypass route refuses, because the engine holds no source connection")
    func refusesRemoteBypass() async throws {
        let engine = try AetherEngine()
        engine._testSetLiveRoute(isLive: true, route: .remoteBypass)
        await #expect(throws: RecordingFailure.unsupportedRoute(.remoteBypass)) {
            try await engine.startRecording(to: tempURL())
        }
        #expect(engine.recordingState == .idle)
    }

    @Test("a live session with no route component refuses rather than recording nothing")
    func refusesWithoutHost() async throws {
        let engine = try AetherEngine()
        engine._testSetLiveRoute(isLive: true, route: .loopback)
        await #expect(throws: RecordingFailure.unsupportedRoute(.loopback)) {
            try await engine.startRecording(to: tempURL())
        }
    }

    @Test("stopRecording on an idle engine is a no-op and does not throw")
    func stopWhenIdleIsNoOp() async throws {
        let engine = try AetherEngine()
        await engine.stopRecording()
        #expect(engine.recordingState == .idle)
    }

    // MARK: - Lifecycle

    @Test("a source reset ends the recording rather than writing past the seam")
    func sourceResetEndsRecording() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host)
        #expect({ if case .recording = engine.recordingState { return true }; return false }())
        #expect(host.installedSink != nil)

        engine.endRecordingIfRunning(reason: .sourceReset)
        #expect(engine.recordingState == .ended(.sourceReset))
        #expect(host.installedSink == nil, "the sink must be removed from the route")
    }

    @Test("ending twice keeps the first reason")
    func endingIsIdempotent() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host)
        engine.endRecordingIfRunning(reason: .stoppedByHost)
        engine.endRecordingIfRunning(reason: .sessionEnded)
        #expect(engine.recordingState == .ended(.stoppedByHost))
    }

    @Test("a second start while recording refuses and names the running file")
    func refusesWhileAlreadyRecording() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host)
        await #expect(throws: RecordingFailure.alreadyRecording(url)) {
            try await engine.startRecording(to: self.tempURL())
        }
        engine.endRecordingIfRunning(reason: .stoppedByHost)
    }

    @Test("stopRecording ends a running recording")
    func stopEndsRunningRecording() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host)
        await engine.stopRecording()
        #expect(engine.recordingState == .ended(.stoppedByHost))
    }
}
