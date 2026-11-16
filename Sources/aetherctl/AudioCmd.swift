import Foundation
import AetherEngine

// MARK: - audio

/// Load a source through the audio-only path and play it, printing the synchronizer clock once a second. Smoke-tests FFmpeg decode -> AVSampleBufferAudioRenderer on macOS.
func runAudio(url: URL, seconds playSeconds: Double, gainDB: Double? = nil) -> Int32 {
    print(EngineLog.redacted("aetherctl audio: \(url.absoluteString) (play \(playSeconds)s)"))
    // Must use CFRunLoopRun, not a blocking semaphore: AetherEngine is @MainActor, so parking the main thread would deadlock the executor.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await audioSmokeTest(url: url, seconds: playSeconds, gainDB: gainDB)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func audioSmokeTest(url: URL, seconds playSeconds: Double, gainDB: Double?) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }
    do {
        try await engine.load(url: url, options: LoadOptions(audioOnly: true, normalizationGainDB: gainDB))
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    let backend = engine.playbackBackend
    print("backend=\(backend.rawValue) decoder=\(engine.activeAudioDecoder ?? "?") "
          + "delivery=\(engine.audioDelivery.rawValue) duration=\(String(format: "%.1f", engine.duration))s")
    guard backend == .audio else {
        print("FAIL: expected backend .audio, got \(backend.rawValue)")
        return 1
    }
    let duration = engine.duration
    let ticks = max(1, Int(playSeconds))
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print(String(format: "  t=%.2fs", engine.currentTime))
    }
    let finalTime = engine.currentTime
    let endState = engine.state
    let finalDuration = engine.duration
    print("  final duration=\(String(format: "%.1f", finalDuration))s")
    if gainDB != nil {
        print("  normalization: \(engine.normalizationGainReport?.summary ?? "no report")")
    }
    engine.stop()
    if finalTime <= 0.5 {
        print("FAIL: clock did not advance (t=\(finalTime)); decode or render path is silent")
        return 1
    }
    // If sampling stopped well before EOF, the engine must still be .playing; .idle here means the demuxer raced to EOF (missing-back-pressure regression).
    if duration > 0, playSeconds < duration - 1.0 {
        if case .playing = endState {
            // expected
        } else {
            print("FAIL: engine left .playing early (state=\(endState)) at t=\(String(format: "%.2f", finalTime))s of \(String(format: "%.1f", duration))s; demuxer raced to EOF")
            return 1
        }
    }
    print("OK: audio path advanced the clock to \(String(format: "%.2f", finalTime))s (state=\(endState), duration=\(String(format: "%.1f", duration))s)")
    return 0
}
