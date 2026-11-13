import Foundation
import Combine
import Testing
@testable import AetherEngine

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct SoftwareRepositionResultTests {
    actor Gate {
        private var waits: [Int: CheckedContinuation<Demuxer.RepositionOutcome, Never>] = [:]
        private(set) var count = 0
        func next() async -> Demuxer.RepositionOutcome {
            let id = count; count += 1
            return await withCheckedContinuation { waits[id] = $0 }
        }
        func finish(_ id: Int, _ result: Demuxer.RepositionOutcome) {
            waits.removeValue(forKey: id)?.resume(returning: result)
        }
    }

    private func demuxer() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        return dem
    }

    private func loadedHost(_ reposition: @escaping SoftwarePlaybackHost.Reposition) async throws -> SoftwarePlaybackHost {
        let host = SoftwarePlaybackHost(reposition: reposition)
        do {
            try await host.load(demuxer: demuxer(), startPosition: nil, audioSourceStreamIndex: nil)
            return host
        } catch { host.stop(); throw error }
    }

    @Test("Failed resume never publishes readiness, target clock or first-frame readiness")
    func failedResume() async throws {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .stalled })
        defer { host.stop() }
        do {
            try await host.load(demuxer: demuxer(), startPosition: 42, audioSourceStreamIndex: nil)
            Issue.record("failed resume returned successfully")
        } catch SoftwarePlaybackHost.HostError.repositionFailed {} catch { throw error }
        #expect(!host.isReady)
        #expect(!host.isPlaying)
        #expect(!host.isVideoReadyForDisplay)
        #expect(host.currentTime == 0)
        #expect(host.sourceClockSeconds == 0)
    }

    @Test("Successful resume retains its anchor without claiming a displayed first frame")
    func successfulResume() async throws {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        try await host.load(demuxer: demuxer(), startPosition: 42, audioSourceStreamIndex: nil)
        #expect(host.isReady)
        #expect(host.currentTime == 42)
        #expect(!host.isVideoReadyForDisplay)
        #expect(!host.isPlaying)
    }

    @Test("Stop during resume cannot publish readiness or resurrect the target clock")
    func stoppedResume() async throws {
        let gate = Gate()
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in await gate.next() })
        let dem = try demuxer()
        let load = Task { try await host.load(demuxer: dem, startPosition: 42, audioSourceStreamIndex: nil) }
        try await waitFor { await gate.count >= 1 }
        host.stop()
        await gate.finish(0, .landed)
        do { try await load.value; Issue.record("stopped resume returned successfully") }
        catch is CancellationError {} catch { throw error }
        #expect(!host.isReady)
        #expect(host.currentTime == 0)
        #expect(!host.isPlaying)
    }

    @Test("Caller cancellation during resume cannot publish a successful load")
    func cancelledResume() async throws {
        let gate = Gate()
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in await gate.next() })
        defer { host.stop() }
        let dem = try demuxer()
        let load = Task { try await host.load(demuxer: dem, startPosition: 42, audioSourceStreamIndex: nil) }
        try await waitFor { await gate.count >= 1 }
        load.cancel()
        await gate.finish(0, .landed)
        do { try await load.value; Issue.record("cancelled resume returned successfully") }
        catch is CancellationError {} catch { throw error }
        #expect(!host.isReady)
        #expect(!host.isPlaying)
        #expect(host.currentTime == 0)
    }

    @Test("Failed software seek stays failed through engine finalization and keeps its request identity", arguments: [false, true])
    func failedSeek(wireFailure: Bool) async throws {
        let host = try await loadedHost { _, _, _, _, _ in .stalled }
        let engine = try AetherEngine()
        engine.softwareHost = host
        engine.duration = 100
        engine.state = .paused
        defer { engine.stop() }
        let failureSink = wireFailure ? host.$failure.compactMap { $0 }.sink { engine.publishError($0) } : nil
        defer { failureSink?.cancel() }
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        await engine.seek(to: 42)
        #expect(host.failure?.kind == .softwarePipelineFailed)
        #expect(!host.isPlaying)
        #expect(host.currentTime != 42)
        #expect(engine.currentTime != 42)
        #expect(!engine.isSeeking)
        guard case .error = engine.state else { Issue.record("failed seek was finalized as playable"); return }
        #expect(events.map(\.outcome) == [.began, .stalled])
        #expect(Set(events.map(\.id)).count == 1)
        host.play()
        #expect(!host.isPlaying)
    }

    @Test("A late failed seek cannot poison a newer successful paused seek")
    func supersededFailure() async throws {
        let gate = Gate()
        let host = try await loadedHost { _, _, _, _, _ in await gate.next() }
        let engine = try AetherEngine()
        engine.softwareHost = host
        engine.duration = 100
        engine.state = .paused
        defer { engine.stop() }
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let first = Task { await engine.seek(to: 12) }
        try await waitFor { await gate.count >= 1 }
        let second = Task { await engine.seek(to: 24) }
        try await waitFor { await gate.count >= 2 }
        await gate.finish(0, .stalled)
        await first.value
        #expect(host.failure == nil)
        await gate.finish(1, .landed)
        await second.value
        #expect(host.currentTime == 24)
        #expect(engine.currentTime == 24)
        #expect(engine.state == .paused)
        #expect(!engine.isSeeking)
        #expect(host.failure == nil)
        #expect(events.filter { $0.target == 12 }.map(\.outcome) == [.began, .superseded])
        #expect(events.filter { $0.target == 24 }.count == 2)
        #expect(events.last?.target == 24)
        if case .landed = events.last?.outcome {} else { Issue.record("newest seek did not land") }
    }

}
