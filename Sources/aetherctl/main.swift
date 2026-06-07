// aetherctl: standalone reproduction harness for AetherEngine on macOS.
//
// Three subcommands, all operating on a media source URL (file:// or
// http(s)://):
//
//   probe <url>     - Open the demuxer, print container + stream
//                     metadata, exit. No HLS server, no decoders.
//
//   serve <url>     - Spin up HLSVideoEngine + loopback HLS-fMP4
//                     server, park the process so curl /
//                     mediastreamvalidator / mp4dump / ffprobe can
//                     poke at the manifests + segments. Same shape
//                     the tvOS app's native render path consumes.
//
//   validate <url>  - Same as `serve` for a few seconds, then run
//                     Apple's `mediastreamvalidator` against the
//                     loopback manifest and print the report. Tears
//                     down on completion.
//
// Backwards compatibility: `aetherctl <url>` with no subcommand is
// treated as `serve <url>`, since that was the only mode the CLI
// used to support.

import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AetherEngine

// MARK: - RSS / footprint samplers (keeper for regression tracking)

/// Physical footprint in bytes from task_vm_info. This is the
/// jetsam-relevant metric on tvOS: it counts compressed + uncompressed
/// memory the process actually occupies, unlike resident_size which
/// can include kernel-shared pages. Returns -1 on failure.
func physFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

/// Resident memory in bytes from mach_task_basic_info. Secondary
/// metric: includes kernel-shared pages, so it's noisier than
/// phys_footprint but historically what `ps RSS` reports.
func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size
    ) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.resident_size) : -1
}

// Disable stdout buffering so `swift run aetherctl ... > log.txt` or
// `2>&1 | grep` pipelines see engine prints in real time. Swift's
// `print()` block-buffers when stdout isn't a tty, which masked the
// engine's EngineLog output and only let FFmpeg's stderr through on
// the first run.
setbuf(stdout, nil)

// MARK: - Usage

private func printUsage() {
    print("""
    aetherctl: standalone AetherEngine repro harness

    Usage:
      aetherctl probe <url>
      aetherctl serve [--no-dv] <url>
      aetherctl validate [--no-dv] <url>
      aetherctl swdecode [--frames N] <url>
      aetherctl extract [--at <sec>] [--snapshot] [--width <px>] [--loops <n>] <url>
      aetherctl audio <url>
      aetherctl customio [--memory] [--forward-only] [--audio-only] [--reload] [--switch-audio] [--select-subs] [--extract] <file>
      aetherctl live [--seconds N] [--seed <path>] [--dvr-window N] [--measure-rss] [--report-cache-bytes]
      aetherctl <url>             (alias for `serve`)

    Flags (serve / validate only):
      --no-dv        Pin HLSVideoEngine to dvModeAvailable=false, i.e.
                     pretend the display can't render Dolby Vision.
                     Mirrors what AetherEngine.loadNative passes on a
                     non-DV TV / on macOS (where displayCapabilities
                     reports supportsDolbyVision=false anyway).

    Flags (swdecode only):
      --frames N     Max packets to read / frames to wait for.
                     Default 100.

    Flags (extract only):
      --at <sec>     Seek position in seconds (default 60.0).
      --snapshot     Frame-accurate decode at full resolution instead
                     of nearest-keyframe thumbnail.
      --width <px>   Max output width for thumbnail mode (default 320).
      --loops <n>    Repeat extraction N times, cycling through 8
                     positions. Useful with `leaks --atExit`.

    Subcommands:
      probe     Open the demuxer, dump format + streams + duration, exit.
                No HLS server is started. Fastest way to answer
                "what's in this file?".

      serve     Spin up the engine and park the loopback HLS-fMP4
                server. Prints the local URL it served. Use curl /
                mediastreamvalidator / mp4dump / ffprobe from another
                terminal:

                  curl -i  http://127.0.0.1:<port>/master.m3u8
                  curl -o  /tmp/init.mp4  http://127.0.0.1:<port>/init.mp4
                  curl -o  /tmp/seg0.mp4  http://127.0.0.1:<port>/seg0.mp4
                  mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
                  mp4dump --verbosity 1 /tmp/init.mp4
                  ffprobe -v debug /tmp/seg0.mp4
                  open 'http://127.0.0.1:<port>/master.m3u8'

                Ctrl-C to tear down.

      validate  Spin up the engine, run Apple's `mediastreamvalidator`
                against the loopback manifest, print the report, tear
                down. Requires Xcode (xcrun) on the PATH.

      swdecode  Open SoftwareVideoDecoder for the source's video
                stream, feed packets, report counters + first-frame
                metadata. Tests the SW-pipeline path without needing
                a display layer. Use for AV1, VP9, MPEG-4 Part 2,
                MPEG-2, VC-1 sources.

      extract   Extract a still frame from a source. Thumbnail mode
                (default) seeks to the nearest keyframe and downscales
                to --width. Snapshot mode (--snapshot) decodes
                frame-accurately at full resolution. Use --loops N
                with `leaks --atExit` to detect memory leaks.
                Writes the first frame to /tmp/aetherctl-extract-<mode>.png.

      audio     Load a source through the engine's audio-only path
                (LoadOptions.audioOnly=true), play for ~10 seconds,
                print the synchronizer clock once a second, and report
                OK if the clock advanced or FAIL if it stayed silent.
                Smoke-tests the FFmpeg decode -> AVSampleBufferAudioRenderer
                pipeline end-to-end on macOS without a display layer.

      live      Start a synthetic endless MPEG-TS source (LiveFixture,
                loopback HTTP, no Content-Length, monotonic PTS / PCR
                across loop boundaries), load it with
                LoadOptions(isLive: true), play for --seconds (default
                20), and report whether isLive is true, state is
                .playing, and currentTime advanced past ~15s. --seed
                overrides the seed .ts (default
                Fixtures/user/h264-ts-sample.ts). --dvr-window N sets
                LoadOptions.dvrWindowSeconds (the sliding-live window size);
                omit it for a live-only run bounded by the 60 s floor.
                --measure-rss prints phys_footprint + resident_size every
                30 s (spike measurement harness, kept for regression
                tracking). --report-cache-bytes prints the segment cache's
                on-disk footprint every 60 s to verify the live window keeps
                disk bounded. --sliding is accepted but ignored (sliding is
                now the unconditional behaviour for a live session).
    """)
}

// MARK: - URL parsing

private func parseSourceURL(_ raw: String) -> URL {
    if let parsed = URL(string: raw), parsed.scheme != nil {
        return parsed
    }
    return URL(fileURLWithPath: raw)
}

// MARK: - probe

private func runProbe(url: URL) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl probe: \(url.absoluteString)")
    print("")
    let probe: SourceProbe
    do {
        probe = try AetherEngine.probe(url: url)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    let duration = String(format: "%.3f", probe.durationSeconds)
    let res = probe.videoWidth > 0 ? "\(probe.videoWidth)x\(probe.videoHeight)" : "n/a"
    let rate = probe.videoFrameRate.map { String(format: "%.3f", $0) } ?? "n/a"
    let codec = probe.videoCodecName ?? "(unknown)"

    print("Duration:    \(duration)s")
    print("Video:       codec=\(codec) resolution=\(res) fps=\(rate)")
    print("  format:    \(probe.videoFormat)")
    if probe.isDolbyVision {
        print("  HDR/DV:    Dolby Vision signaled")
    }
    print("")

    if probe.audioTracks.isEmpty {
        print("Audio:       (none)")
    } else {
        print("Audio tracks:")
        for track in probe.audioTracks {
            let lang = track.language ?? "und"
            let atmos = track.isAtmos ? " [Atmos]" : ""
            let def = track.isDefault ? " (default)" : ""
            print("  [\(track.id)] codec=\(track.codec) channels=\(track.channels) lang=\(lang)\(atmos)\(def)")
            print("       title=\(track.name)")
        }
    }
    print("")

    if probe.subtitleTracks.isEmpty {
        print("Subtitles:   (none)")
    } else {
        print("Subtitle tracks:")
        for track in probe.subtitleTracks {
            let lang = track.language ?? "und"
            let def = track.isDefault ? " (default)" : ""
            print("  [\(track.id)] codec=\(track.codec) lang=\(lang)\(def)")
            print("       title=\(track.name)")
        }
    }
    print("")

    let meta = probe.metadata
    print("Metadata:")
    print("  title:    \(meta.title ?? "(nil)")")
    print("  artist:   \(meta.artist ?? "(nil)")")
    print("  album:    \(meta.album ?? "(nil)")")
    print("  artwork:  \(meta.artworkData.map { "\($0.count) bytes" } ?? "0 bytes (none)")")
    return 0
}

// MARK: - serve

private func runServe(url: URL, dvModeAvailable: Bool) -> Never {
    // Mirror what the tvOS app does: route every engine log to stdout
    // instead of into a host overlay buffer, so the CLI session reads
    // linearly.
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    let flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    print("aetherctl serve: \(url.absoluteString)\(flagSuffix)")
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
        exit(1)
    }

    print("")
    print("=== PLAYBACK URL ===")
    print(playbackURL.absoluteString)
    print("====================")
    print("")
    print("Engine is parked. Hit Ctrl-C to tear down.")
    print("")

    // Trap SIGINT to clean up so the next run can rebind the same
    // (ephemeral) port if needed and so the demuxer's HTTP session
    // doesn't leak.
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

private func runValidate(url: URL, dvModeAvailable: Bool) -> Int32 {
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

    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        print(text)
    }

    print("")
    print("mediastreamvalidator exit code: \(process.terminationStatus)")
    return process.terminationStatus
}

// MARK: - swdecode

private func runSWDecode(url: URL, maxPackets: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl swdecode: \(url.absoluteString) (maxPackets=\(maxPackets))")
    print("")

    let result: SoftwareDecodeProbeResult
    do {
        result = try AetherEngine.swDecodeProbe(url: url, maxPackets: maxPackets)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    print("")
    print("=== SW DECODER RESULT ===")
    print("Codec:                \(result.codecName) (id=\(result.codecID))")
    print("Source resolution:    \(result.width)x\(result.height)")
    print("Decoder open:         \(result.openSucceeded ? "OK" : "FAILED")")
    if let err = result.openError {
        print("Open error:           \(err)")
    }
    print("Packets read:         \(result.packetsRead)")
    print("Packets fed (video):  \(result.packetsFedToDecoder)")
    print("Frames decoded:       \(result.framesDecoded)")
    if let fmt = result.firstFramePixelFormat {
        print("First frame pixfmt:   \(fmt)")
        print("First frame size:     \(result.firstFrameWidth)x\(result.firstFrameHeight)")
    } else {
        print("First frame:          (none decoded)")
    }
    if let err = result.firstError {
        print("First demux error:    \(err)")
    }
    print("=========================")
    print("")

    // Verdict
    if !result.openSucceeded {
        print("VERDICT: decoder open failed (libavcodec rejected the stream).")
        print("         Check FFmpegBuild --enable-decoder=\(result.codecName) +")
        print("         codec-private extradata in the source.")
        return 2
    }
    if result.framesDecoded == 0 {
        print("VERDICT: decoder opened but produced no frames from \(result.packetsFedToDecoder) packets.")
        print("         Suggests pixel-format conversion failure or no key-frame")
        print("         in the first \(result.packetsFedToDecoder) packets. Bump --frames")
        print("         if the source has a long GOP.")
        return 3
    }
    print("VERDICT: SW decode end-to-end healthy. \(result.framesDecoded) frames")
    print("         produced into \(result.firstFramePixelFormat ?? "?") pixel buffers.")
    print("         If real playback still hangs, the failure is downstream")
    print("         (SoftwarePlaybackHost frame-enqueue, AVSampleBufferDisplayLayer")
    print("         attach, audio-clock sync).")
    return 0
}

// MARK: - customio

/// A minimal `IOReader` over a local file, used to prove the custom-source
/// load path. `forwardOnly` simulates a non-seekable source by refusing
/// SEEK_SET/CUR/END (AVSEEK_SIZE still answers, so probing can size the file).
/// `inMemory` loads the whole file into a Data buffer instead of streaming
/// from the FileHandle.
final class FileHandleIOReader: IOReader, @unchecked Sendable {
    private let path: String
    private let data: Data?
    private let handle: FileHandle?
    private let totalSize: Int64
    private var position: Int64 = 0
    private let forwardOnly: Bool
    private let lock = NSLock()

    /// Counts cancel() invocations to verify the override is dynamically
    /// dispatched (cancel() is now a protocol requirement, not extension-only).
    nonisolated(unsafe) static var cancelCount = 0

    init(path: String, inMemory: Bool, forwardOnly: Bool) throws {
        self.path = path
        self.forwardOnly = forwardOnly
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        self.totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if inMemory {
            self.data = try Data(contentsOf: URL(fileURLWithPath: path))
            self.handle = nil
        } else {
            guard let h = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: "aetherctl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
            }
            self.data = nil
            self.handle = h
        }
    }

    func cancel() {
        FileHandleIOReader.cancelCount += 1
    }

    func makeIndependentReader() -> IOReader? {
        // A forward-only source cannot serve a second cursor (the concurrent
        // features seek the clone), so report no clone, matching a real
        // forward-only reader. A seekable file source clones to a fresh handle
        // over the same path with an independent cursor.
        if forwardOnly { return nil }
        return try? FileHandleIOReader(path: path, inMemory: false, forwardOnly: false)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer = buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        let want = Int(size)
        guard position >= 0 else { return -1 }
        let chunk: Data
        if let data = data {
            let start = Int(position)
            if start >= data.count { return 0 } // EOF
            let end = min(start + want, data.count)
            chunk = data.subdata(in: start..<end)
        } else if let handle = handle {
            handle.seek(toFileOffset: UInt64(position))
            chunk = handle.readData(ofLength: want)
            if chunk.isEmpty { return 0 } // EOF
        } else {
            return -1
        }
        chunk.copyBytes(to: buffer, count: chunk.count)
        position += Int64(chunk.count)
        return Int32(chunk.count)
    }

    /// FFmpeg AVSEEK_SIZE: a query for total size, not a reposition.
    private static let avSeekSize: Int32 = 0x10000

    func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        // AVSEEK_SIZE: query total size only, no reposition. Always answerable.
        if whence == Self.avSeekSize { return totalSize }
        if forwardOnly { return -1 }
        switch whence {
        case 0: position = max(0, offset)              // SEEK_SET
        case 1: position = max(0, position + offset)   // SEEK_CUR
        case 2: position = max(0, totalSize + offset)  // SEEK_END
        default: return -1
        }
        return position
    }

    func close() {
        try? handle?.close()
    }
}

/// Load media through the engine's custom IOReader source path and play
/// it, printing the engine state once a second. Confirms load(source:)
/// end-to-end on both the native path (seekable reader) and the software
/// path (seekable or forward-only).
private func runCustomIO(path: String, inMemory: Bool, forwardOnly: Bool, audioOnly: Bool, reload: Bool, switchAudio: Bool, selectSubs: Bool, extract: Bool) -> Int32 {
    EngineLog.handler = { print($0) }
    var modeDesc: String
    switch (inMemory, forwardOnly) {
    case (true, true):   modeDesc = "in-memory + forward-only"
    case (true, false):  modeDesc = "in-memory"
    case (false, true):  modeDesc = "forward-only streaming file"
    case (false, false): modeDesc = "seekable file"
    }
    if audioOnly { modeDesc += " + audio-only" }
    print("aetherctl customio: \(path) (\(modeDesc))")
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await customIOSmokeTest(path: path, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnly, reload: reload, switchAudio: switchAudio, selectSubs: selectSubs, extract: extract)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func customIOSmokeTest(path: String, inMemory: Bool, forwardOnly: Bool, audioOnly: Bool, reload: Bool, switchAudio: Bool, selectSubs: Bool, extract: Bool) async -> Int32 {
    let reader: FileHandleIOReader
    do {
        reader = try FileHandleIOReader(path: path, inMemory: inMemory, forwardOnly: forwardOnly)
    } catch {
        print("VERDICT: custom source failed: reader init error: \(error.localizedDescription)")
        return 1
    }

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: custom source failed: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions()
    options.suppressDisplayCriteria = true
    options.audioOnly = audioOnly

    do {
        try await engine.load(source: .custom(reader), options: options)
    } catch {
        print("VERDICT: custom source failed: load error: \(error.localizedDescription)")
        return 1
    }

    // Check state immediately after load returns (load is async and sets
    // state to .playing before returning on both the native and software
    // paths). A short file may complete and reset to .idle before the
    // first poll tick, so capture the post-load snapshot immediately.
    let postLoadState = engine.state
    let postLoadTime = engine.currentTime
    print(String(format: "  post-load state=%@ t=%.2fs dur=%.2fs",
                 "\(postLoadState)", postLoadTime, engine.duration))
    if case .playing = postLoadState {
        let verdict = String(format: "VERDICT: custom source playing. currentTime=%.2fs", postLoadTime)
        print(verdict)
    } else if case .error(let msg) = postLoadState {
        print("VERDICT: custom source failed: \(msg)")
        engine.stop()
        return 1
    } else {
        // State was .idle or .loading at load return; poll for up to 8s.
        let maxTicks = 8
        var reached = false
        for _ in 0..<maxTicks {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let t = engine.currentTime
            let st = engine.state
            print(String(format: "  state=%@ t=%.2fs", "\(st)", t))
            switch st {
            case .playing:
                let verdict = String(format: "VERDICT: custom source playing. currentTime=%.2fs", t)
                print(verdict)
                reached = true
            case .error(let msg):
                print("VERDICT: custom source failed: \(msg)")
                engine.stop()
                return 1
            default:
                break
            }
            if reached { break }
        }
        if !reached {
            let finalTime = engine.currentTime
            let finalState = engine.state
            print("VERDICT: custom source timed out after \(maxTicks)s (state=\(finalState), t=\(String(format: "%.2f", finalTime))s)")
            engine.stop()
            return 1
        }
    }

    // Feature checks follow. Engine is in .playing state here.
    if reload {
        do { try await engine.reloadAtCurrentPosition() } catch {
            print("VERDICT: reload threw: \(error.localizedDescription)"); engine.stop(); return 5
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if case .playing = engine.state {
            print("VERDICT: reload OK, still playing")
        } else {
            print("VERDICT: reload left state \(engine.state)"); engine.stop(); return 5
        }
    }
    if switchAudio {
        let current = engine.activeAudioTrackIndex
        guard let target = engine.audioTracks.map({ $0.id }).first(where: { $0 != current }) else {
            print("VERDICT: switch-audio: no second audio track to switch to (tracks=\(engine.audioTracks.map { $0.id }), active=\(String(describing: current)))")
            return 6
        }
        engine.selectAudioTrack(index: target)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if case .playing = engine.state {
            print("VERDICT: audio switch OK to id=\(target), still playing (was \(String(describing: current)))")
        } else {
            print("VERDICT: audio switch left state \(engine.state)"); return 6
        }
    }
    if selectSubs {
        guard let subID = engine.subtitleTracks.first?.id else {
            print("VERDICT: select-subs: no subtitle tracks in source"); return 7
        }
        engine.selectSubtitleTrack(index: subID)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let cueCount = engine.subtitleCues.count
        print("VERDICT: subtitle select id=\(subID), cues=\(cueCount) active=\(engine.isSubtitleActive)")
        if cueCount == 0 { print("VERDICT: select-subs FAILED: no cues produced"); return 7 }
    }
    if extract {
        guard let fx = engine.makeFrameExtractor() else {
            print("VERDICT: makeFrameExtractor returned nil"); engine.stop(); return 8
        }
        if let image = await fx.thumbnail(at: 1.0, maxWidth: 320) {
            print("VERDICT: extract OK, image \(image.width)x\(image.height)")
        } else {
            print("VERDICT: extract returned nil image"); await fx.shutdown(); engine.stop(); return 8
        }
        await fx.shutdown()
    }
    engine.stop()
    // Give the engine's demux teardown path (runs in a detached Task on the
    // native path) time to call Demuxer.close() -> markClosed() ->
    // reader.cancel() before we sample the counter.
    try? await Task.sleep(nanoseconds: 3_500_000_000)
    print("cancel() override invocations: \(FileHandleIOReader.cancelCount)")
    return 0
}

// MARK: - audio

/// Load a source through the engine's audio-only path and play it,
/// printing the synchronizer clock once a second. Confirms FFmpeg
/// decode -> AVSampleBufferAudioRenderer works end-to-end on macOS.
private func runAudio(url: URL, seconds playSeconds: Double) -> Int32 {
    print("aetherctl audio: \(url.absoluteString) (play \(playSeconds)s)")
    // AetherEngine is @MainActor, so it must be driven on the main thread
    // under a live run loop, NOT through the main-thread-blocking
    // `runBlocking` semaphore: that would deadlock the instant the engine
    // needs the main actor (the main thread would be parked on the
    // semaphore and could never service the MainActor executor). Running
    // CFRunLoopRun keeps the main actor executor AND the
    // Timer.publish(on: .main) clock mirror alive while the @MainActor
    // task drives playback, then the task stops the run loop when done.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await audioSmokeTest(url: url, seconds: playSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func audioSmokeTest(url: URL, seconds playSeconds: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }
    do {
        try await engine.load(url: url, options: LoadOptions(audioOnly: true))
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    let backend = engine.playbackBackend
    print("backend=\(backend.rawValue) decoder=\(engine.activeAudioDecoder ?? "?") duration=\(String(format: "%.1f", engine.duration))s")
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
    engine.stop()
    if finalTime <= 0.5 {
        print("FAIL: clock did not advance (t=\(finalTime)); decode or render path is silent")
        return 1
    }
    // If we stopped sampling well before the file's end, the engine MUST
    // still be playing. If it already reached .idle, the demuxer raced to
    // EOF and ended the track early (the missing-back-pressure regression).
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

// MARK: - live

/// Start a `LiveFixture` (endless MPEG-TS over loopback), load it into a
/// fresh engine with `LoadOptions(isLive: true)`, play for `playSeconds`,
/// and verdict on whether the live path advanced the clock.
///
/// `dvrWindow` (from `--dvr-window`) is threaded into
/// `LoadOptions.dvrWindowSeconds`. `nil` means live-only: the live window is
/// still bounded by `LiveWindowSizing.liveOnlyFloorSeconds`.
private func runLive(
    seconds playSeconds: Double,
    seed seedPath: String?,
    dvrWindow: Double?,
    serveOnly: Bool,
    measureRSS: Bool,
    reportCacheBytes: Bool
) -> Int32 {
    EngineLog.handler = { print($0) }

    // Resolve the seed relative to the repo root (CWD under `swift run`).
    let resolvedSeed = seedPath ?? "Fixtures/user/h264-ts-sample.ts"
    print("aetherctl live: seed=\(resolvedSeed) seconds=\(playSeconds)" +
          (dvrWindow.map { " dvr-window=\($0)" } ?? " dvr-window=none (live-only floor)") +
          (measureRSS ? " measure-rss=true" : "") +
          (reportCacheBytes ? " report-cache-bytes=true" : ""))

    let fixture: LiveFixture
    do {
        fixture = try LiveFixture(seedPath: resolvedSeed)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    let liveURL: URL
    do {
        liveURL = try fixture.start()
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    print("=== LIVE URL ===")
    print(liveURL.absoluteString)
    print("================")

    // Diagnostic: park the fixture so curl / ffprobe can inspect the
    // served endless stream directly, without the engine attached. Used
    // to validate the fixture's TS rewrite in isolation.
    //
    //   curl -s http://127.0.0.1:<port>/live.ts | head -c 3000000 > /tmp/x.ts
    //   ffprobe -v error -show_entries packet=pts -of csv /tmp/x.ts
    if serveOnly {
        print("Fixture parked (--serve-only). Ctrl-C to stop.")
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            fixture.stop()
            exit(0)
        }
        src.resume()
        RunLoop.main.run()
        return 0 // unreachable
    }

    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await liveSmokeTest(url: liveURL, seconds: playSeconds,
                                        dvrWindow: dvrWindow, measureRSS: measureRSS,
                                        reportCacheBytes: reportCacheBytes)
        fixture.stop()
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func liveSmokeTest(url: URL, seconds playSeconds: Double,
                           dvrWindow: Double? = nil,
                           measureRSS: Bool = false,
                           reportCacheBytes: Bool = false) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        // The native HLS path (H.264 / HEVC) currently requires a finite
        // duration to build its segment plan, so an unbounded live source
        // throws `zeroDuration` here. That unbounded-duration segment
        // producer is what the later plan tasks add; this harness reaching
        // a load failure on the fixture is the expected pre-feature state,
        // not a fixture defect (the fixture serves a valid, continuous TS,
        // verifiable with `aetherctl live --serve-only` + ffprobe).
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    print(String(format: "  post-load state=%@ isLive=%@ t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", engine.currentTime))

    if measureRSS {
        print("RSS_HEADER: elapsed_s  phys_footprint_mb  resident_mb")
    }
    if reportCacheBytes {
        print("CACHE_HEADER: elapsed_s  disk_bytes  disk_mb")
        // Emit an initial sample at t=0 so the plateau has a baseline.
        let b0 = engine.segmentCacheDiskBytes ?? 0
        print(String(format: "CACHE_BYTES: elapsed=0s  disk=%lld B  disk=%.2f MB",
                     b0, Double(b0) / 1_048_576.0))
    }

    let startTime = Date()
    var lastRSSTick: Double = 0
    var lastCacheTick: Double = 0

    let ticks = max(1, Int(playSeconds))
    for tick in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Date().timeIntervalSince(startTime)
        print(String(format: "  state=%@ isLive=%@ t=%.2fs",
                     "\(engine.state)", "\(engine.isLive)", engine.currentTime))
        // Print RSS sample every 30 s when --measure-rss is set.
        if measureRSS && (elapsed - lastRSSTick >= 30.0 || tick == ticks - 1) {
            let phys = physFootprintBytes()
            let res  = residentBytes()
            let physMB = phys >= 0 ? Double(phys) / 1_048_576.0 : -1
            let resMB  = res  >= 0 ? Double(res)  / 1_048_576.0 : -1
            print(String(format: "RSS_SAMPLE: elapsed=%.0fs  phys=%.1fMB  resident=%.1fMB",
                         elapsed, physMB, resMB))
            lastRSSTick = elapsed
        }
        // Print the cache disk footprint every 60 s when
        // --report-cache-bytes is set (plus a final sample at the end of
        // the run so a short run still shows the plateau).
        if reportCacheBytes && (elapsed - lastCacheTick >= 60.0 || tick == ticks - 1) {
            let bytes = engine.segmentCacheDiskBytes ?? 0
            print(String(format: "CACHE_BYTES: elapsed=%.0fs  disk=%lld B  disk=%.2f MB",
                         elapsed, bytes, Double(bytes) / 1_048_576.0))
            lastCacheTick = elapsed
        }
        _ = tick // suppress unused-var warning
    }

    let finalState = engine.state
    let finalIsLive = engine.isLive
    let finalTime = engine.currentTime
    engine.stop()

    // Scale the "advanced past 15s" bar to the play window: a 20 s run
    // should clear ~15 s, a shorter run scales proportionally (minus a
    // small warm-up allowance for first-segment latency).
    let advanceTarget = playSeconds >= 20 ? 15.0 : max(1.0, playSeconds * 0.6)

    let playing: Bool
    if case .playing = finalState { playing = true } else { playing = false }

    if finalIsLive, playing, finalTime >= advanceTarget {
        print(String(format: "VERDICT: live playing (isLive=%@, state=%@, t=%.2fs >= %.2fs)",
                     "\(finalIsLive)", "\(finalState)", finalTime, advanceTarget))
        return 0
    }
    print(String(format: "VERDICT: live FAIL (isLive=%@, state=%@, t=%.2fs, needed t>=%.2fs)",
                 "\(finalIsLive)", "\(finalState)", finalTime, advanceTarget))
    return 1
}

// MARK: - extract

/// Drive an async actor call to completion from the synchronous CLI.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T?>(nil)
    Task {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

private func runExtract(url: URL, at seconds: Double, mode: FrameMode, loops: Int, maxWidth: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl extract: \(url.absoluteString) at=\(seconds)s mode=\(mode) loops=\(loops)")
    print("")

    let extractor = FrameExtractor(url: url, httpHeaders: [:])

    var produced = 0
    let start = Date()
    let effectiveLoops = max(1, loops)
    for i in 0..<effectiveLoops {
        // Cycle positions within a bounded in-range window so every
        // iteration really decodes (and short clips do not run past
        // EOF). 8 distinct 1 s buckets is enough to defeat trivial
        // cache short-circuiting, especially in snapshot mode where the
        // cache holds only 2 entries.
        let pos = seconds + Double(i % 8) * 1.0
        let image: CGImage? = runBlocking {
            switch mode {
            case .thumbnail: return await extractor.thumbnail(at: pos, maxWidth: maxWidth)
            case .snapshot:  return await extractor.snapshot(at: pos, maxSize: nil)
            }
        }
        if let image {
            produced += 1
            if i == 0 {
                let out = "/tmp/aetherctl-extract-\(mode).png"
                if writePNG(image, to: out) {
                    print("Wrote \(image.width)x\(image.height) -> \(out)")
                } else {
                    print("ERROR: could not write \(out)")
                }
            }
        } else {
            print("Frame \(i) [\(mode)] at \(pos)s: (nil)")
        }
    }
    let elapsed = Date().timeIntervalSince(start)

    // Deterministic teardown so a `leaks --atExit` run sees a fully
    // released context (no lingering demuxer / connection / FFmpeg alloc).
    runBlocking { await extractor.shutdown() }

    print("")
    print("=== EXTRACT RESULT ===")
    print("Frames produced:  \(produced)/\(effectiveLoops)")
    print("Elapsed:          \(String(format: "%.2f", elapsed))s")
    print("Avg per frame:    \(String(format: "%.1f", elapsed / Double(effectiveLoops) * 1000))ms")
    print("======================")
    return produced > 0 ? 0 : 1
}

// MARK: - Dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(64)
}

let first = args[1]

if first == "--help" || first == "-h" || first == "help" {
    printUsage()
    exit(0)
}

/// Pluck a boolean flag out of the rest-args list, returning whether
/// it was present. Modifies `rest` in place. Unknown args stay in
/// `rest` so the URL positional ends up there.
private func takeFlag(_ name: String, from rest: inout [String]) -> Bool {
    guard let idx = rest.firstIndex(of: name) else { return false }
    rest.remove(at: idx)
    return true
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Int. Returns nil if absent or unparseable.
private func takeIntFlag(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count,
          let value = Int(rest[idx + 1]) else { return nil }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as String. Returns nil if absent or value-less.
private func takeStringFlag(_ name: String, from rest: inout [String]) -> String? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count else { return nil }
    let value = rest[idx + 1]
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Double. Returns nil if absent or unparseable.
private func takeDoubleFlag(_ name: String, from rest: inout [String]) -> Double? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count,
          let value = Double(rest[idx + 1]) else { return nil }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

// Live subcommand: no URL positional (the fixture supplies its own URL).
if first == "live" {
    var rest = Array(args.dropFirst(2))
    let seconds = takeDoubleFlag("--seconds", from: &rest) ?? 20.0
    let dvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let seed = takeStringFlag("--seed", from: &rest)
    let serveOnly = takeFlag("--serve-only", from: &rest)
    let measureRSS = takeFlag("--measure-rss", from: &rest)
    let reportCacheBytes = takeFlag("--report-cache-bytes", from: &rest)
    // --sliding is accepted-and-ignored for backward compat: sliding is now
    // the unconditional behaviour for a live session, so the flag is a no-op.
    _ = takeFlag("--sliding", from: &rest)
    exit(runLive(seconds: seconds, seed: seed, dvrWindow: dvrWindow,
                 serveOnly: serveOnly, measureRSS: measureRSS,
                 reportCacheBytes: reportCacheBytes))
}

// Subcommand path: explicit subcommand + flags + url.
if ["probe", "serve", "validate", "swdecode", "extract", "audio", "customio"].contains(first) {
    var rest = Array(args.dropFirst(2))
    let noDV = takeFlag("--no-dv", from: &rest)
    let framesOverride = takeIntFlag("--frames", from: &rest)
    let atSeconds = takeDoubleFlag("--at", from: &rest) ?? 60.0
    let extractLoops = takeIntFlag("--loops", from: &rest) ?? 1
    let extractWidth = takeIntFlag("--width", from: &rest) ?? 320
    let snapshotMode = takeFlag("--snapshot", from: &rest)
    let inMemory = takeFlag("--memory", from: &rest)
    let forwardOnly = takeFlag("--forward-only", from: &rest)
    let audioOnlyFlag = takeFlag("--audio-only", from: &rest)
    let reloadFlag = takeFlag("--reload", from: &rest)
    let switchAudioFlag = takeFlag("--switch-audio", from: &rest)
    let selectSubsFlag = takeFlag("--select-subs", from: &rest)
    let extractFlag = takeFlag("--extract", from: &rest)
    guard let urlArg = rest.first else {
        print("ERROR: \(first) requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    let url = parseSourceURL(urlArg)
    let dvModeAvailable = !noDV
    switch first {
    case "probe":
        exit(runProbe(url: url))
    case "serve":
        runServe(url: url, dvModeAvailable: dvModeAvailable)
    case "validate":
        exit(runValidate(url: url, dvModeAvailable: dvModeAvailable))
    case "swdecode":
        exit(runSWDecode(url: url, maxPackets: framesOverride ?? 100))
    case "extract":
        exit(runExtract(
            url: url,
            at: atSeconds,
            mode: snapshotMode ? .snapshot : .thumbnail,
            loops: extractLoops,
            maxWidth: extractWidth
        ))
    case "audio":
        exit(runAudio(url: url, seconds: 10))
    case "customio":
        // urlArg is a filesystem path, not a URL; use rest.first directly.
        exit(runCustomIO(path: urlArg, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnlyFlag, reload: reloadFlag, switchAudio: switchAudioFlag, selectSubs: selectSubsFlag, extract: extractFlag))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compatible `aetherctl <url>` == `aetherctl serve <url>`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
