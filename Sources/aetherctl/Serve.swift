import Foundation
import AetherEngine

// MARK: - serve

func runServe(url: URL, dvModeAvailable: Bool, nativeSubsIndex: Int? = nil,
              startPosition: Double? = nil) -> Never {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    var flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    if let idx = nativeSubsIndex { flagSuffix += " [--native-subs \(idx)]" }
    if let pos = startPosition { flagSuffix += " [--start-position \(pos)]" }
    print("aetherctl serve: \(url.absoluteString)\(flagSuffix)")
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable
    )
    // Resume anchor exactly like AetherEngine.loadNative's load(startPosition:) (#99 repro).
    engine.initialStartSeconds = startPosition
    // Request native mov_text track before start() so the muxer's init moov declares it (#55). Must precede start().
    if nativeSubsIndex != nil {
        engine.requestNativeSubtitleTrack()
    }
    let playbackURL: URL
    do {
        playbackURL = try engine.start()
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
    // Attach cue stores for all declared text tracks after start (#55 all-tracks). Legacy --native-subs N kept for CLI compat; ALL non-bitmap tracks are now declared.
    if nativeSubsIndex != nil {
        let languages = engine.attachAllNativeSubtitleStores()
        print("[native-subs] \(languages.count) mov_text track(s) declared in init moov, cue stores attached")
        print("[native-subs] languages: \(languages.map { $0 ?? "und" })")
        print("[native-subs] use a full AetherEngine session to feed cues via the native multi-decode reader")
    }

    print("")
    print("=== PLAYBACK URL ===")
    print(playbackURL.absoluteString)
    print("====================")
    print("")
    print("Engine is parked. Hit Ctrl-C to tear down.")
    print("")

    // Trap SIGINT to release the ephemeral port and avoid demuxer HTTP session leak.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("")
        print("aetherctl: SIGINT, stopping engine")
        engine.stop()
        exit(0)
    }
    sigintSource.resume()

    RunLoop.main.run()
    exit(0)  // unreachable, RunLoop.main.run() never returns
}

// MARK: - validate

func runValidate(url: URL, dvModeAvailable: Bool) -> Int32 {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    let flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    print("aetherctl validate: \(url.absoluteString)\(flagSuffix)")
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable
    )
    let playbackURL: URL
    do {
        playbackURL = try engine.start()
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    defer { engine.stop() }

    print("")
    print("=== PLAYBACK URL ===")
    print(playbackURL.absoluteString)
    print("====================")
    print("")
    print("Running mediastreamvalidator...")
    print("")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["mediastreamvalidator", playbackURL.absoluteString]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        print("ERROR: failed to launch xcrun mediastreamvalidator: \(error)")
        print("Hint: install Xcode + run `xcode-select --install`.")
        return 1
    }

    // Read output before waitUntilExit: mediastreamvalidator can exceed the ~64 KB pipe buffer, causing deadlock if you wait first.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        print(text)
    }

    print("")
    print("mediastreamvalidator exit code: \(process.terminationStatus)")
    return process.terminationStatus
}
