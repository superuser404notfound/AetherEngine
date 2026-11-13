import Testing
import Foundation
@testable import AetherEngine

/// #93 residual: PiP entry mid-restart started the lazy native subtitle readers, whose side
/// demuxer opened a second WAN connection that competed with the producer restart for the
/// starved link (device: readers ran during a 44 s restart and exited with 0 cues). The lazy
/// start now defers until the restart settles.
@MainActor
struct NativeReaderDeferralTests {

    private func prepared() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 3, language: "de")]
        engine.nativeSubtitleReaderParams = (url: URL(string: "https://s/x.mkv")!,
                                             stores: [NativeSubtitleCueStore()])
        return engine
    }

    @Test("lazy readers start immediately when no restart is in flight")
    func immediateStart() throws {
        let engine = try prepared()
        engine.testHookRestartInFlightOverride = false
        engine.startLazyNativeSubtitleReadersWhenIdle()
        #expect(engine.nativeSubtitleReadersTask != nil)
        engine.cancelNativeSubtitleReaders()
    }

    @Test("lazy readers defer while a restart is in flight and start once it settles", .timeLimit(.minutes(3)))
    func deferThenStart() async throws {
        let engine = try prepared()
        engine.testHookRestartInFlightOverride = true
        engine.startLazyNativeSubtitleReadersWhenIdle()
        #expect(engine.nativeSubtitleReadersTask == nil)
        #expect(engine.nativeSubtitleReaderDeferralTask != nil)
        engine.testHookRestartInFlightOverride = false
        try await waitFor { engine.nativeSubtitleReadersTask != nil }
        engine.cancelNativeSubtitleReaders()
    }

    @Test("deselect cancels a pending deferral; readers never start")
    func deselectCancelsDeferral() async throws {
        let engine = try prepared()
        engine.testHookRestartInFlightOverride = true
        engine.startLazyNativeSubtitleReadersWhenIdle()
        #expect(engine.nativeSubtitleReaderDeferralTask != nil)
        engine.cancelNativeSubtitleReaders()
        engine.testHookRestartInFlightOverride = false
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(engine.nativeSubtitleReadersTask == nil)
    }
}
