import Foundation
import AetherEngine

// MARK: - serve

func runServe(url: URL, dvModeAvailable: Bool, forceDVWithoutDisplay: Bool = false,
              dolbyVisionHandling: DolbyVisionHandling = .automatic,
              nativeSubsIndex: Int? = nil, startPosition: Double? = nil,
              audioDelayMs: Int = 0, iFrames: Bool = false,
              objectAudioRendering: ObjectAudioRendering = .off, audioStreamIndex: Int32? = nil,
              stereo: StereoPresentation? = nil) -> Never {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    var flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    if forceDVWithoutDisplay { flagSuffix += " [--force-dv]" }
    if dolbyVisionHandling == .baseLayerOnly { flagSuffix += " [--dv-base-layer]" }
    if let idx = nativeSubsIndex { flagSuffix += " [--native-subs \(idx)]" }
    if let pos = startPosition { flagSuffix += " [--start-position \(pos)]" }
    if audioDelayMs != 0 { flagSuffix += " [--audio-delay \(audioDelayMs)]" }
    if iFrames { flagSuffix += " [--iframes]" }
    if case .apac(let layout) = objectAudioRendering { flagSuffix += " [--atmos-bed \(layout.rawValue)]" }
    if let audioStreamIndex { flagSuffix += " [--audio-index \(audioStreamIndex)]" }
    if let stereo { flagSuffix += " [--stereo \(stereo)]" }
    print(EngineLog.redacted("aetherctl serve: \(url.absoluteString)\(flagSuffix)"))
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable,
        forceDolbyVisionOnNonDVDisplay: forceDVWithoutDisplay,
        dolbyVisionHandling: dolbyVisionHandling,
        // AE#532: a session gates this on its own probe; the harness has none, so it asks the audit
        // for the whole verdict. A source with nothing to correct never gets past the gate inside.
        dolbyVisionRPUProfile: DolbyVisionRecordAudit.rpuCorrection(url: url),
        audioSourceStreamIndexOverride: audioStreamIndex,
        objectAudioRendering: objectAudioRendering,
        // nil (no flag) is the session as this system gets it; a flag resolves it as visionOS would.
        stereoPresentation: stereo ?? .automatic,
        stereoOnAnySystem: stereo != nil
    )
    // Resume anchor exactly like AetherEngine.loadNative's load(startPosition:) (#99 repro).
    engine.initialStartSeconds = startPosition
    // AE#464: every muxer this session builds writes its audio timestamps with this offset. Set
    // before start(), like the resume anchor above, because the first producer is built inside it.
    engine.audioDelaySeconds = Double(audioDelayMs) / 1000.0
    // Enable native WebVTT subtitle renditions before start() so the master declares the SUBTITLES group (#55). Must precede start().
    if nativeSubsIndex != nil {
        engine.requestNativeSubtitleTrack()
    }
    // AE#682: the LoadOptions.serveIFramePlaylist path. Must precede start().
    if iFrames {
        engine.requestIFramePlaylist()
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
        print("[native-subs] \(languages.count) WebVTT SUBTITLES rendition(s) declared in the master, cue stores attached")
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

func runValidate(url: URL, dvModeAvailable: Bool, forceDVWithoutDisplay: Bool = false,
                 dolbyVisionHandling: DolbyVisionHandling = .automatic) -> Int32 {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    var flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    if forceDVWithoutDisplay { flagSuffix += " [--force-dv]" }
    if dolbyVisionHandling == .baseLayerOnly { flagSuffix += " [--dv-base-layer]" }
    print(EngineLog.redacted("aetherctl validate: \(url.absoluteString)\(flagSuffix)"))
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable,
        forceDolbyVisionOnNonDVDisplay: forceDVWithoutDisplay,
        dolbyVisionHandling: dolbyVisionHandling,
        dolbyVisionRPUProfile: DolbyVisionRecordAudit.rpuCorrection(url: url)
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
