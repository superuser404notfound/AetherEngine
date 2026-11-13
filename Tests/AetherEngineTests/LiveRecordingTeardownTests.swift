import Testing
import Foundation
@testable import AetherEngine

/// Audit FEA-105 / FEA-106: a stop or a zap that lands while a recording is being torn down, or while
/// a start is waiting for the previous file, must neither publish `.ended` early nor lose a failure, and
/// a start that was overtaken must not install a writer afterwards.
@Suite("Live recording teardown and start races (FEA-105, FEA-106)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct LiveRecordingTeardownTests {

    /// A gate that, once opened, stays open for every waiter.
    private final class Latch: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false
        func wait() {
            condition.lock()
            while !isOpen { condition.wait() }
            condition.unlock()
        }
        func open() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).ts")
    }

    private func isRecording(_ state: RecordingState) -> Bool {
        if case .recording = state { return true }
        return false
    }

    private func annexB(_ size: Int, nalType: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, nalType]
        bytes.append(contentsOf: [UInt8](repeating: 0x88, count: max(0, size - bytes.count)))
        return bytes
    }

    // MARK: - FEA-105

    @Test("a stop inside a scheduled teardown waits for its drain and publishes its failure")
    func stopJoinsAScheduledTeardown() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host, ceilingBytes: 4096)
        let writer = try #require(engine.activeRecording)
        let gate = Latch()
        writer.beforeWriteForTesting = { gate.wait() }

        // The first packet enters the held drain, the second breaks the ceiling: the demux thread's
        // offer is refused and the teardown is scheduled off it.
        annexB(2000, nalType: 0x65).withUnsafeBytes {
            writer.accept(packetBytes: $0, sourceStreamIndex: 0, pts: 0, dts: 0, duration: 3000, isKeyframe: true)
        }
        annexB(3000, nalType: 0x41).withUnsafeBytes {
            writer.accept(packetBytes: $0, sourceStreamIndex: 0, pts: 3000, dts: 3000, duration: 3000, isKeyframe: false)
        }
        try await waitFor { writer.isClosed }

        engine.endRecordingIfRunning(reason: .stoppedByHost)
        let publishedEarly = try await waitFor(upTo: .milliseconds(300)) { !self.isRecording(engine.recordingState) }
        #expect(!publishedEarly, "the file is still being drained, so nothing may claim it closed")

        gate.open()
        await engine.recordingFinish?.value
        #expect(engine.recordingState == .failed(.writeTooSlow(bytesWritten: 0, queuedBytesDropped: 3000)))
        #expect(engine.activeRecording == nil)
    }

    @Test("a clean stop still ends with .ended")
    func cleanStopStillEnds() async throws {
        let engine = try AetherEngine()
        let host = AetherEngine.TestRecordingHost()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try engine._testStartRecordingWithStubHost(to: url, host: host)
        await engine.stopRecording()
        #expect(engine.recordingState == .ended(.stoppedByHost))
    }

    // MARK: - FEA-106

    /// Holds `recordingFinish` open the way a slow drain does, and returns the handle that releases it.
    private func holdPreviousFinish(_ engine: AetherEngine) -> AsyncStream<Void>.Continuation {
        let (stream, release) = AsyncStream<Void>.makeStream()
        engine.recordingFinish = Task { for await _ in stream { break } }
        return release
    }

    @Test("a start that a stop overtook while it waited does not begin recording")
    func stopDuringTheStartsWaitCancelsIt() async throws {
        let engine = try AetherEngine()
        engine._testSetLiveRoute(isLive: true, route: .loopback)
        let release = holdPreviousFinish(engine)

        let url = tempURL()
        let starter = Task { @MainActor in try await engine.startRecording(to: url) }
        await Task.yield()
        let stopper = Task { @MainActor in await engine.stopRecording() }
        await Task.yield()

        release.yield(())
        release.finish()
        let outcome = await starter.result
        await stopper.value

        #expect({ if case .failure(let error) = outcome { return error is CancellationError }; return false }(),
                "the stop came after the start, so the start must not win: \(outcome)")
        #expect(engine.activeRecording == nil)
        #expect(!isRecording(engine.recordingState))
    }

    @Test("a start that a new load overtook while it waited does not record the new channel")
    func loadDuringTheStartsWaitCancelsIt() async throws {
        let engine = try AetherEngine()
        engine._testSetLiveRoute(isLive: true, route: .loopback)
        let release = holdPreviousFinish(engine)

        let url = tempURL()
        let starter = Task { @MainActor in try await engine.startRecording(to: url) }
        await Task.yield()
        engine.loadGeneration &+= 1

        release.yield(())
        release.finish()
        let outcome = await starter.result

        #expect({ if case .failure(let error) = outcome { return error is CancellationError }; return false }(),
                "a zap ends the session the start was asked for: \(outcome)")
        #expect(engine.activeRecording == nil)
    }
}
