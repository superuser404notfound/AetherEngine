import AVFoundation
import Testing
@testable import AetherEngine

@Suite("AudioOutput video renderer retirement", .timeLimit(.minutes(3)))
@MainActor
struct AudioOutputRendererLifecycleTests {
    private final class WeakOutput {
        weak var value: AudioOutput?
        init(_ value: AudioOutput?) { self.value = value }
    }

    @Test("a stopped synchronizer removes its renderer without waiting for its clock")
    func stoppedClockRemoval() async throws {
        let output = AudioOutput()
        let layer = AVSampleBufferDisplayLayer()
        output.attachVideoLayer(layer)
        output.stop()
        let retirement = try #require(output.detachVideoLayer(layer))
        await retirement.value
        #expect(!output.synchronizer.renderers.contains { $0 === layer.sampleBufferRenderer })
        // Reattachment is safe only after the completion.
        output.attachVideoLayer(layer)
        await output.detachVideoLayer(layer)?.value
    }

    @Test("retirement is nonblocking, deduplicated, and retains the output through cancellation")
    func lifetimeAndDuplicateRemoval() async throws {
        var output: AudioOutput? = AudioOutput()
        let weakOutput = WeakOutput(output)
        let layer = AVSampleBufferDisplayLayer()
        output?.attachVideoLayer(layer)
        var continuation: CheckedContinuation<Void, Never>?
        var removals = 0
        let retirement = try #require(output?.detachVideoLayer(layer) { _, _ in
            removals += 1
            await withCheckedContinuation { continuation = $0 }
        })
        let duplicate = try #require(output?.detachVideoLayer(layer) { _, _ in
            Issue.record("a duplicate detach must not start another removal")
        })
        try await waitFor { continuation != nil }
        #expect(removals == 1)
        // Reaching here on the main actor proves detach did not block on the completion.
        output = nil
        retirement.cancel()
        #expect(weakOutput.value != nil)
        continuation?.resume()
        continuation = nil
        await retirement.value
        await duplicate.value
        try await waitFor { weakOutput.value == nil }
    }

    @Test("detaching an unrelated layer leaves the owned attachment intact")
    func unrelatedLayerIsIgnored() async throws {
        let output = AudioOutput()
        let owned = AVSampleBufferDisplayLayer()
        output.attachVideoLayer(owned)
        #expect(output.detachVideoLayer(AVSampleBufferDisplayLayer()) == nil)
        #expect(output.synchronizer.renderers.contains { $0 === owned.sampleBufferRenderer })
        await output.detachVideoLayer(owned)?.value
    }
}
