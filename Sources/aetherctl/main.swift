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
      aetherctl live [--seconds N] [--seed <path>] [--dvr-window N] [--measure-rss] [--report-cache-bytes] [--rewind-test] [--sw] [--drop-after N] [--discontinuity-at N] [--realtime] [--gen-highbitrate-seed]
      aetherctl dvr [--path native|sw|both] [--seconds N] [--dvr-window N]
      aetherctl hlsfixture <input.ts> [--port N] [--segment-seconds N]
                           [--master] [--discontinuity-at N] [--slow-refresh]
                           [--drop-segment N] [--encrypted] [--fmp4] [--self-test]
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

    // Read the combined output BEFORE waiting for exit: the validator can
    // emit more than the kernel pipe buffer (~64 KB), and waiting first
    // deadlocks (child blocked on write, parent blocked in waitUntilExit).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
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
            engine.stop(); return 6
        }
        engine.selectAudioTrack(index: target)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if case .playing = engine.state {
            print("VERDICT: audio switch OK to id=\(target), still playing (was \(String(describing: current)))")
        } else {
            print("VERDICT: audio switch left state \(engine.state)"); engine.stop(); return 6
        }
    }
    if selectSubs {
        guard let subID = engine.subtitleTracks.first?.id else {
            print("VERDICT: select-subs: no subtitle tracks in source"); engine.stop(); return 7
        }
        engine.selectSubtitleTrack(index: subID)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let cueCount = engine.subtitleCues.count
        print("VERDICT: subtitle select id=\(subID), cues=\(cueCount) active=\(engine.isSubtitleActive)")
        if cueCount == 0 { print("VERDICT: select-subs FAILED: no cues produced"); engine.stop(); return 7 }
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

// MARK: - high-bitrate seed generation

/// Ensure a high-bitrate (~22 Mbps) 1080p H.264 MPEG-TS seed exists at
/// `path`, generating it with ffmpeg if absent. A realistic ~20+ Mbps video
/// bitrate is what makes AVPlayer's retain-everything memory behaviour show
/// up clearly in resident_size over a multi-minute run; the prior ~0.5 MB/s
/// synthetic seed was far too small to reproduce it. H.264 routes through the
/// NATIVE AVPlayer path, which is exactly what we want to stress for the
/// B4-gating retention question. Returns true if the seed exists (or was
/// generated) and looks like a non-trivial TS file; false on any failure.
private func ensureHighBitrateSeed(path: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        // A real ~22 Mbps x 10 s clip is ~25 MB; anything tiny is suspect.
        if size > 5_000_000 {
            print("high-bitrate seed present: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB)")
            return true
        }
        print("high-bitrate seed at \(path) is only \(size) bytes; regenerating")
    }

    // Resolve an ffmpeg binary. Homebrew install path first, then PATH.
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpeg = ffmpegCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        print("ERROR: ffmpeg not found on \(ffmpegCandidates). Install it (brew install ffmpeg) to generate the high-bitrate seed.")
        return false
    }

    // Ensure the parent directory exists.
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    print("generating high-bitrate seed via ffmpeg (\(ffmpeg)) -> \(path) ...")

    // The seed is a CHEAP intro spliced in front of a HIGH-BITRATE body, both
    // 1080p H.264 with a matching 5 s closed GOP (-g 150 at 30 fps). Why the
    // two-stage shape:
    //
    //  - The live producer cuts a segment at the first keyframe >= its ~4 s
    //    target, so a 5 s GOP yields clean 5 s segments and the served playlist
    //    advertises an EXT-X-TARGETDURATION that matches them.
    //  - At startup the producer's FIRST segment must be demuxed + remuxed +
    //    published before AVPlayer's initial-buffering stall timer fires (the
    //    manifest is empty / target=1 until then; AVPlayer demands an update
    //    within 1.5 * target = ~1.5 s). A high-bitrate first segment is ~12-14 MB
    //    and its remux exceeds that window on the loopback path, so AVPlayer
    //    dies with CoreMedia -12888 ("Playlist File unchanged...") at the very
    //    first frame, every time. A ~1.5 Mbps, 6 s intro makes seg-0 small
    //    enough to publish well within the window, AVPlayer starts, and the
    //    producer then races into the 22 Mbps body (it reads far faster than 1x
    //    once AVPlayer is healthy and pulling).
    //  - The 22 Mbps, 24 s body is the part that stresses AVPlayer retention:
    //    firmly high-bitrate (~44x the old ~0.5 MB/s synthetic seed), so a
    //    93%-retain leak over a multi-minute unpaced run is unmistakable in
    //    resident_size. H.264 routes through the NATIVE AVPlayer path.
    //
    // The two TS files are byte-concatenated (raw MPEG-TS is concatenable; the
    // demuxer absorbs the splice). LiveFixture loops the whole seed, so the
    // cheap intro recurs once per ~30 s loop, which is harmless.
    let tmp = NSTemporaryDirectory()
    let introPath = (tmp as NSString).appendingPathComponent("aetherctl-seed-intro.ts")
    let bodyPath  = (tmp as NSString).appendingPathComponent("aetherctl-seed-body.ts")

    func runFFmpeg(_ args: [String], label: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            print("ERROR: failed to launch ffmpeg (\(label)): \(error.localizedDescription)")
            return false
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            print("ERROR: ffmpeg (\(label)) exited \(proc.terminationStatus). Output tail:")
            if let text = String(data: out, encoding: .utf8) { print(String(text.suffix(2000))) }
            return false
        }
        return true
    }

    let introArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=6",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
        "-c:v", "libx264", "-b:v", "1500k", "-maxrate", "1500k", "-bufsize", "3M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "2M", "-f", "mpegts", introPath, "-y"
    ]
    let bodyArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=24",
        "-c:v", "libx264", "-b:v", "22M", "-maxrate", "22M", "-bufsize", "44M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "24M", "-f", "mpegts", bodyPath, "-y"
    ]
    guard runFFmpeg(introArgs, label: "intro"), runFFmpeg(bodyArgs, label: "body") else {
        return false
    }

    // Byte-concatenate intro + body into the seed.
    guard let introData = try? Data(contentsOf: URL(fileURLWithPath: introPath)),
          let bodyData  = try? Data(contentsOf: URL(fileURLWithPath: bodyPath)) else {
        print("ERROR: could not read generated intro/body TS files")
        return false
    }
    var combined = introData
    combined.append(bodyData)
    do {
        try combined.write(to: URL(fileURLWithPath: path))
    } catch {
        print("ERROR: could not write combined seed to \(path): \(error.localizedDescription)")
        return false
    }
    try? fm.removeItem(atPath: introPath)
    try? fm.removeItem(atPath: bodyPath)

    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    guard size > 5_000_000 else {
        print("ERROR: generated seed at \(path) is only \(size) bytes; ffmpeg may have failed silently.")
        return false
    }
    print("generated high-bitrate seed: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB; ~1.5 Mbps 6 s intro + 22 Mbps 24 s body)")
    return true
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
    reportCacheBytes: Bool,
    rewindTest: Bool = false,
    forceSoftware: Bool = false,
    dropAfter: Double? = nil,
    discontinuityAt: Double? = nil,
    realtime: Bool = false
) -> Int32 {
    EngineLog.handler = { print($0) }

    // TEST-ONLY: force the live source through SoftwarePlaybackHost so the
    // H.264 fixture exercises the SW live + DVR path. Cleared on the way
    // out so it never bleeds into a subsequent invocation in-process.
    AetherEngine.setForceSoftwarePathForTesting(forceSoftware)
    if forceSoftware {
        print("aetherctl live: --sw set, forcing SoftwarePlaybackHost routing")
    }
    defer { AetherEngine.setForceSoftwarePathForTesting(false) }

    // Resolve the seed relative to the repo root (CWD under `swift run`).
    let resolvedSeed = seedPath ?? "Fixtures/user/h264-ts-sample.ts"
    print("aetherctl live: seed=\(resolvedSeed) seconds=\(playSeconds)" +
          (dvrWindow.map { " dvr-window=\($0)" } ?? " dvr-window=none (live-only floor)") +
          (dropAfter.map { " drop-after=\($0)s" } ?? "") +
          (discontinuityAt.map { " discontinuity-at=\($0)s" } ?? "") +
          (measureRSS ? " measure-rss=true" : "") +
          (reportCacheBytes ? " report-cache-bytes=true" : ""))

    let fixture: LiveFixture
    do {
        fixture = try LiveFixture(seedPath: resolvedSeed)
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    fixture.dropAfterSeconds = dropAfter
    fixture.discontinuityAfterSeconds = discontinuityAt
    fixture.paced = realtime
    if realtime {
        print("aetherctl live: --realtime set, pacing fixture output at ~1x")
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
        if rewindTest {
            box.value = await liveRewindTest(url: liveURL, seconds: playSeconds,
                                             dvrWindow: dvrWindow ?? 60)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        box.value = await liveSmokeTest(url: liveURL, seconds: playSeconds,
                                        dvrWindow: dvrWindow, measureRSS: measureRSS,
                                        reportCacheBytes: reportCacheBytes,
                                        checkMonotonic: discontinuityAt != nil)
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
                           reportCacheBytes: Bool = false,
                           checkMonotonic: Bool = false) async -> Int32 {
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

    // Monotonicity tracking for the discontinuity test. The session
    // timeline (currentTime on SW, and the live edge on both paths) must
    // never jump backward and must never leap forward by the raw PTS delta
    // (1000 s). We watch both per-tick maxima and the largest single-tick
    // forward step; a leap >> the playhead-vs-realtime over-run would be the
    // failure signature of an unhandled discontinuity.
    var monotonicViolation = false
    var maxForwardStep: Double = 0
    var prevCurrentTime = engine.currentTime
    var prevEdgeTime = engine.liveEdgeTime
    // The fixture races well ahead of wall clock, so a single 1 s tick can
    // legitimately advance the timeline by several seconds. A genuine
    // unhandled +1000 s discontinuity dwarfs that; 100 s is a safe ceiling
    // that no normal over-run reaches but any raw-PTS leap exceeds.
    let leapCeiling: Double = 100.0

    let ticks = max(1, Int(playSeconds))
    for tick in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Date().timeIntervalSince(startTime)
        if checkMonotonic {
            let ct = engine.currentTime
            let et = engine.liveEdgeTime
            // Backward jump on either axis is a hard violation.
            if ct + 0.5 < prevCurrentTime || et + 0.5 < prevEdgeTime {
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (backward): "
                             + "currentTime %.2f->%.2f edge %.2f->%.2f",
                             prevCurrentTime, ct, prevEdgeTime, et))
            }
            // Forward leap by ~the raw PTS delta is the unhandled-jump
            // signature.
            let ctStep = ct - prevCurrentTime
            let etStep = et - prevEdgeTime
            maxForwardStep = max(maxForwardStep, max(ctStep, etStep))
            if ctStep > leapCeiling || etStep > leapCeiling {
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (raw-PTS leap): "
                             + "currentTime step=%.2f edge step=%.2f",
                             ctStep, etStep))
            }
            prevCurrentTime = ct
            prevEdgeTime = et
        }
        print(String(format: "  state=%@ isLive=%@ t=%.2fs edge=%.2fs",
                     "\(engine.state)", "\(engine.isLive)", engine.currentTime, engine.liveEdgeTime))
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
    let finalEdge = engine.liveEdgeTime
    engine.stop()

    // Scale the "advanced past 15s" bar to the play window: a 20 s run
    // should clear ~15 s, a shorter run scales proportionally (minus a
    // small warm-up allowance for first-segment latency).
    let advanceTarget = playSeconds >= 20 ? 15.0 : max(1.0, playSeconds * 0.6)

    let playing: Bool
    if case .playing = finalState { playing = true } else { playing = false }

    // "Has the session advanced" is judged on currentTime when it ticks
    // (native AVPlayer, and the SW path once its audio clock runs), else on
    // the live edge (the SW video-only fixture advances the edge from video
    // PTS while the audio-driven currentTime stays at 0). Either crossing the
    // bar proves continued playback past the discontinuity point.
    let advanced = max(finalTime, finalEdge)

    if checkMonotonic && monotonicViolation {
        print(String(format: "VERDICT: live FAIL (monotonic violation across "
                     + "discontinuity; maxForwardStep=%.2fs, t=%.2fs, edge=%.2fs)",
                     maxForwardStep, finalTime, finalEdge))
        return 1
    }

    if finalIsLive, playing, advanced >= advanceTarget {
        let mono = checkMonotonic
            ? String(format: " monotonic OK maxStep=%.2fs", maxForwardStep)
            : ""
        print(String(format: "VERDICT: live playing (isLive=%@, state=%@, t=%.2fs, edge=%.2fs >= %.2fs)%@",
                     "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget, mono))
        return 0
    }
    print(String(format: "VERDICT: live FAIL (isLive=%@, state=%@, t=%.2fs, edge=%.2fs, needed >=%.2fs)",
                 "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget))
    return 1
}

/// DVR rewind test: play ~40s with a DVR window, rewind 20s off the live edge,
/// assert the playhead moved back and `behindLiveSeconds` is roughly 20, then
/// return to the live edge and assert `isAtLiveEdge`. Prints PASS/FAIL per
/// step and `VERDICT: native DVR rewind+return OK` only when both pass.
@MainActor
private func liveRewindTest(url: URL, seconds playSeconds: Double,
                            dvrWindow: Double) async -> Int32 {
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
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }
    print(String(format: "  post-load state=%@ isLive=%@ dvrWindow=%.0fs t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", dvrWindow, engine.currentTime))

    // Warm up for ~40s so the DVR window has enough history to rewind into.
    // Sample behindLiveSeconds every ~4s during this NORMAL playback phase and
    // collect the series: on a 1x (--realtime) feed it should stay roughly
    // stable and small, not the continuously-growing ~30-40s racing-ahead
    // artifact a fast (unpaced) fixture produces.
    let warmup = max(playSeconds, 40.0)
    var normalBehindSamples: [Double] = []
    print("  NORMAL_PLAYBACK behindLiveSeconds series (every ~4s, 1x feed):")
    for i in 0..<Int(warmup) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if i % 4 == 0 || i == Int(warmup) - 1 {
            let b = engine.behindLiveSeconds
            normalBehindSamples.append(b)
            print(String(format: "    +%2ds  t=%.2f  edge=%.2f  behind=%.2f",
                         i + 1, engine.currentTime, engine.liveEdgeTime, b))
        }
    }
    // Stability of the normal-playback behind series: max - min over the
    // samples taken after a short settle (skip the first sample, which can be
    // mid warm-up). A 1x feed holds behind in a narrow band; a racing feed
    // ramps it monotonically.
    let settled = normalBehindSamples.count > 1 ? Array(normalBehindSamples.dropFirst()) : normalBehindSamples
    let normalMin = settled.min() ?? 0
    let normalMax = settled.max() ?? 0
    let normalSpread = normalMax - normalMin
    print(String(format: "  NORMAL_PLAYBACK behind: min=%.2f max=%.2f spread=%.2f (stable if spread small and max not ~30-40)",
                 normalMin, normalMax, normalSpread))
    print(String(format: "  pre-rewind edge=%.2fs t=%.2fs behind=%.2fs range=%@",
                 engine.liveEdgeTime, engine.currentTime, engine.behindLiveSeconds,
                 engine.seekableLiveRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"))

    // --- Rewind 20s off the live edge ---
    // Note: comparing absolute currentTime before vs after the seek is the
    // wrong invariant for a live stream (the playhead keeps advancing and the
    // edge lurches forward in discrete steps as new segments publish). The
    // correct post-seek invariant is: the playhead sits ~20s behind the edge,
    // i.e. behindLiveSeconds settles near 20, and the playhead is below where
    // it would be at the edge. Sample on each of the next ~5s and take the
    // settled minimum behind, which is robust against an edge lurch landing on
    // the final sample.
    let edgeBefore = engine.liveEdgeTime
    let timeBefore = engine.currentTime
    await engine.seek(to: edgeBefore - 20)
    var behindSamples: [Double] = []
    var timeAfter = engine.currentTime
    for i in 0..<5 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        timeAfter = engine.currentTime
        let b = engine.behindLiveSeconds
        behindSamples.append(b)
        print(String(format: "    +%ds t=%.2f edge=%.2f behind=%.2f", i + 1,
                     timeAfter, engine.liveEdgeTime, b))
    }
    // The settled behind right after the seek (before any edge lurch) is the
    // minimum of the early samples; that is the true rewind depth.
    let behindAfter = behindSamples.min() ?? engine.behindLiveSeconds
    // Playhead moved back relative to the live edge it was rewound from.
    let movedBack = timeAfter < edgeBefore
    let behindOK = abs(behindAfter - 20) <= 5
    let rewindPass = movedBack && behindOK
    print(String(format: "  REWIND: edgeBefore=%.2f tBefore=%.2f -> tAfter=%.2f settledBehind=%.2f (belowEdge=%@, behind~20=%@)",
                 edgeBefore, timeBefore, timeAfter, behindAfter,
                 "\(movedBack)", "\(behindOK)"))
    print("  REWIND: \(rewindPass ? "PASS" : "FAIL")")

    // --- Return to the live edge ---
    await engine.seekToLiveEdge()
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let atEdge = engine.isAtLiveEdge
    print(String(format: "  RETURN: behind=%.2fs isAtLiveEdge=%@",
                 engine.behindLiveSeconds, "\(atEdge)"))
    print("  RETURN: \(atEdge ? "PASS" : "FAIL")")

    engine.stop()

    // Normal-playback stability gate: on a 1x feed the behind series should sit
    // in a narrow band well below the racing-ahead ~30-40s artifact. Generous
    // bound: spread <= 15s and max < 30s. Informational, but folded into the
    // PASS/FAIL so the "behind is stable at 1x" claim is checked, not asserted.
    let normalStable = normalSpread <= 15.0 && normalMax < 30.0
    print(String(format: "  NORMAL_STABLE: %@ (spread=%.2f max=%.2f)",
                 normalStable ? "PASS" : "FAIL", normalSpread, normalMax))

    if rewindPass && atEdge && normalStable {
        print("VERDICT: native DVR rewind+return OK; behind stable at 1x")
        return 0
    }
    print(String(format: "VERDICT: native DVR rewind+return FAIL (rewind=%@ return=%@ normalStable=%@)",
                 "\(rewindPass)", "\(atEdge)", "\(normalStable)"))
    return 1
}

// MARK: - dvr matrix harness

/// Run the full DVR matrix on one playback path (native or SW).
/// Returns 0 if all hard invariants pass, 1 otherwise.
@MainActor
private func dvrMatrixRun(
    label: String,
    url: URL,
    seconds playSeconds: Double,
    dvrWindow: Double
) async -> Int32 {
    print("")
    print("=== DVR MATRIX: \(label) path ===")
    print("  dvrWindow=\(dvrWindow)s  playSeconds=\(playSeconds)s")

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: dvr \(label) FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }
    defer { engine.stop() }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: dvr \(label) FAIL: load error: \(error.localizedDescription)")
        return 1
    }

    print(String(format: "  post-load state=%@ isLive=%@ t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", engine.currentTime))

    // ---- Sampling loop ----
    // Sample every ~12s. Two-thirds through the run we inject a rewind+return.
    let sampleInterval = 12
    let totalTicks = max(sampleInterval * 2 + sampleInterval, Int(playSeconds))
    let rewindTick = (totalTicks * 2) / 3
    let rewindOffset = 20.0   // seconds to rewind behind live edge

    var rewindDone = false
    var rewindEdgeBefore: Double = 0
    var seekTargetTime: Double = 0
    var postSeekTimeSamples: [Double] = []
    var postReturnEdgeSamples: [Double] = []; var postReturnBehindSamples: [Double] = []
    var atEdgeAfterReturn: Bool = false
    var seekToEdgeDone = false

    // Disk byte samples for plateau check.
    var diskSamples: [Int64] = []
    // Playback continuity tracking.
    var anyStall = false
    var prevTime = engine.currentTime

    print("  SAMPLE_HEADER: tick  state  t  edge  behind  atEdge  diskMB")

    for tick in 1...totalTicks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let ct = engine.currentTime
        let edge = engine.liveEdgeTime
        let behind = engine.behindLiveSeconds
        let atEdge = engine.isAtLiveEdge
        let stateNow = engine.state
        let disk = engine.segmentCacheDiskBytes ?? 0
        diskSamples.append(disk)

        // Stall detection: time must advance over consecutive ticks at
        // wall-clock 1x. The synthetic fixture runs faster than 1x so
        // currentTime may jump ahead; the hard failure is it staying put.
        if case .playing = stateNow {
            if ct <= prevTime && tick > 5 {
                anyStall = true
                print(String(format: "  WARNING: time did not advance tick=%d ct=%.2f", tick, ct))
            }
        } else {
            anyStall = true
            print(String(format: "  WARNING: state not .playing at tick=%d state=%@", tick, "\(stateNow)"))
        }
        prevTime = ct

        if tick % sampleInterval == 0 || tick == rewindTick || tick == totalTicks {
            print(String(format: "  SAMPLE: tick=%d state=%@ t=%.2f edge=%.2f behind=%.2f atEdge=%@ disk=%.2fMB",
                         tick, "\(stateNow)", ct, edge, behind, "\(atEdge)",
                         Double(disk) / 1_048_576.0))
        }

        // Mid-run: rewind then return to edge.
        if tick == rewindTick && !rewindDone {
            rewindEdgeBefore = engine.liveEdgeTime
            seekTargetTime = rewindEdgeBefore - rewindOffset
            print(String(format: "  REWIND: seeking to %.2f (edge=%.2f minus %.0fs)",
                         seekTargetTime, rewindEdgeBefore, rewindOffset))
            await engine.seek(to: seekTargetTime)
            rewindDone = true

            // Collect 5 post-seek samples (1s each).
            for si in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let pt = engine.currentTime
                let pb = engine.behindLiveSeconds
                postSeekTimeSamples.append(pt)
                print(String(format: "    post-seek +%ds t=%.2f behind=%.2f", si+1, pt, pb))
                // Update prevTime to the post-seek cursor so stall check
                // doesn't false-positive on the next iteration.
                prevTime = pt
            }

            // Now return to live edge.
            print("  RETURN: seeking to live edge")
            await engine.seekToLiveEdge()
            seekToEdgeDone = true

            // Collect 5 post-return samples.
            for ri in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let pt = engine.currentTime
                let pb = engine.behindLiveSeconds
                let ae = engine.isAtLiveEdge
                let re = engine.liveEdgeTime
                postReturnEdgeSamples.append(re)
                postReturnBehindSamples.append(pb)
                if ae { atEdgeAfterReturn = true }
                print(String(format: "    post-return +%ds t=%.2f edge=%.2f behind=%.2f atEdge=%@",
                             ri+1, pt, re, pb, "\(ae)"))
                prevTime = pt
            }
        }
    }

    let finalState = engine.state
    let finalTime = engine.currentTime
    let finalEdge = engine.liveEdgeTime
    let finalRange = engine.seekableLiveRange
    let finalBehind = engine.behindLiveSeconds

    print("")
    print("=== HARD INVARIANT CHECKS (\(label)) ===")

    // Check 1: no stall (state stayed .playing, time advanced).
    let check1 = !anyStall
    print("  [1] Sustained .playing with advancing time: \(check1 ? "PASS" : "FAIL")")

    // Check 2: seekableLiveRange non-nil and has positive span.
    let check2 = finalRange != nil && (finalRange!.upperBound - finalRange!.lowerBound) > 0
    let rangeStr = finalRange.map { String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) } ?? "nil"
    print("  [2] seekableLiveRange non-nil and advancing: \(check2 ? "PASS" : "FAIL")  (\(rangeStr))")

    // Check 3: after rewind, the playhead moved backward vs. the edge before.
    // Use the earliest post-seek sample as the "where we landed" value.
    var check3 = false
    var check3detail = "no rewind performed"
    if rewindDone, let firstPostSeek = postSeekTimeSamples.first {
        // Playhead must have moved back relative to the pre-rewind edge.
        // Tolerance: one full DVR window (keyframe granularity varies
        // between 1 s and 5 s on the fixture so we allow generous slack).
        let movedBack = firstPostSeek < rewindEdgeBefore
        let landedNearTarget = abs(firstPostSeek - seekTargetTime) <= dvrWindow
        check3 = movedBack && landedNearTarget
        check3detail = String(format: "edgeBefore=%.2f target=%.2f landed=%.2f movedBack=%@ landedNear=%@",
                              rewindEdgeBefore, seekTargetTime, firstPostSeek,
                              "\(movedBack)", "\(landedNearTarget)")
    }
    print("  [3] After rewind, playhead moved back to near target: \(check3 ? "PASS" : "FAIL")  (\(check3detail))")

    // Check 4: after seekToLiveEdge, isAtLiveEdge became true OR
    // behindLiveSeconds dropped sharply (< 10s) since it may not flip
    // the boolean instantly on the synthetic fixture.
    var check4 = false
    var check4detail = "no seekToLiveEdge performed"
    if seekToEdgeDone {
        let minBehindAfterReturn = postReturnBehindSamples.min() ?? finalBehind
        let behindDropped = minBehindAfterReturn < 10.0
        check4 = atEdgeAfterReturn || behindDropped
        check4detail = String(format: "atEdge=%@ minBehind=%.2f behindDropped=%@",
                              "\(atEdgeAfterReturn)", minBehindAfterReturn, "\(behindDropped)")
    }
    print("  [4] After seekToLiveEdge, isAtLiveEdge or behind < 10s: \(check4 ? "PASS" : "FAIL")  (\(check4detail))")

    // Check 5: disk bytes do not grow unbounded (plateau).
    // "Not growing unbounded" = the last third of samples is not strictly
    // larger than the first third, or the total growth is < 50 MB.
    var check5 = true
    var check5detail = "no samples"
    if diskSamples.count >= 3 {
        let firstThird = diskSamples.prefix(diskSamples.count / 3)
        let lastThird  = diskSamples.suffix(diskSamples.count / 3)
        let firstMax = firstThird.max() ?? 0
        let lastMax  = lastThird.max()  ?? 0
        let growthMB = Double(max(0, lastMax - firstMax)) / 1_048_576.0
        // Allow up to 100 MB growth (the first-segment warm-up can spike
        // before the sliding window prunes old segments).
        check5 = growthMB < 100.0
        check5detail = String(format: "firstMax=%.2fMB lastMax=%.2fMB growth=%.2fMB",
                              Double(firstMax) / 1_048_576.0,
                              Double(lastMax)  / 1_048_576.0,
                              growthMB)
    }
    print("  [5] Disk bytes not unbounded (plateau): \(check5 ? "PASS" : "FAIL")  (\(check5detail))")

    // Informational (device-verify) metrics -- do NOT fail on these.
    print("")
    print("=== INFO (device-verify) metrics (\(label)) ===")

    // RSS / phys footprint slope (unreliable off-device on macOS).
    let phys = physFootprintBytes()
    let res  = residentBytes()
    print(String(format: "  INFO (device-verify): phys_footprint=%.1fMB  resident=%.1fMB",
                 phys >= 0 ? Double(phys) / 1_048_576.0 : -1,
                 res  >= 0 ? Double(res)  / 1_048_576.0 : -1))
    print("  INFO (device-verify): macOS phys_footprint ~7-8GB VM does NOT map to tvOS jetsam; verify on device.")

    // behindLiveSeconds stability during the rewind window.
    if !postSeekTimeSamples.isEmpty {
        let minBehind = postReturnBehindSamples.min().map { String(format: "%.2f", $0) } ?? "n/a"
        print("  INFO (device-verify): behindLiveSeconds post-seek min=\(minBehind)s (unreliable on synthetic fixture; verify on device.)")
    }

    let hardPassed = check1 && check2 && check3 && check4 && check5
    print("")
    print("=== SUMMARY (\(label)) ===")
    print(String(format: "  finalState=%@  t=%.2fs  edge=%.2fs  behind=%.2fs  range=%@",
                 "\(finalState)", finalTime, finalEdge, finalBehind, rangeStr))
    if hardPassed {
        print("VERDICT: dvr \(label) OK")
    } else {
        var failed: [String] = []
        if !check1 { failed.append("[1] sustained play") }
        if !check2 { failed.append("[2] seekableLiveRange") }
        if !check3 { failed.append("[3] rewind landed near target") }
        if !check4 { failed.append("[4] seekToLiveEdge") }
        if !check5 { failed.append("[5] disk plateau") }
        print("VERDICT: dvr \(label) FAIL -- failed hard checks: \(failed.joined(separator: ", "))")
    }
    return hardPassed ? 0 : 1
}

/// Entry point for the `dvr` subcommand.
/// Runs the DVR matrix on one or both playback paths.
private func runDVR(path: String, seconds: Double, dvrWindow: Double) -> Int32 {
    EngineLog.handler = { print($0) }

    let nativeSeed = "Fixtures/user/h264-ts-sample.ts"
    let swSeed     = "Fixtures/user/h264-aac-ts-sample.ts"
    let fm = FileManager.default

    print("aetherctl dvr: path=\(path) seconds=\(seconds) dvrWindow=\(dvrWindow)s")

    let runNative = path == "native" || path == "both"
    var runSW     = path == "sw"     || path == "both"

    // Validate that the SW seed exists before committing to the SW leg.
    if runSW && !fm.fileExists(atPath: swSeed) {
        let genCmd = "ffmpeg -i \(nativeSeed) -f lavfi -t 5 "
            + "-i \"sine=frequency=440:sample_rate=48000\" "
            + "-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 96k "
            + "-muxrate 2M -f mpegts \(swSeed) -y"
        if path == "sw" {
            print("SW leg skipped: no a/v seed at \(swSeed); generate with:")
            print("  \(genCmd)")
            return 1
        } else { // both
            print("SW leg skipped: no a/v seed at \(swSeed); generate with:")
            print("  \(genCmd)")
            runSW = false
        }
    }

    var overallRC: Int32 = 0

    if runNative {
        guard fm.fileExists(atPath: nativeSeed) else {
            print("ERROR: native seed not found at \(nativeSeed)")
            return 1
        }

        // Start a LiveFixture for the native leg.
        let fixture: LiveFixture
        do {
            fixture = try LiveFixture(seedPath: nativeSeed)
        } catch {
            print("ERROR: LiveFixture (native) init: \(error)")
            return 1
        }
        let liveURL: URL
        do {
            liveURL = try fixture.start()
        } catch {
            print("ERROR: LiveFixture (native) start: \(error)")
            return 1
        }
        print("[native] live URL: \(liveURL.absoluteString)")

        let box = UncheckedBox<Int32?>(nil)
        Task { @MainActor in
            box.value = await dvrMatrixRun(
                label: "native",
                url: liveURL,
                seconds: seconds,
                dvrWindow: dvrWindow
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        fixture.stop()
        if (box.value ?? 1) != 0 { overallRC = 1 }
    }

    if runSW {
        // Force SW routing for the SW leg.
        AetherEngine.setForceSoftwarePathForTesting(true)
        defer { AetherEngine.setForceSoftwarePathForTesting(false) }

        let fixture: LiveFixture
        do {
            fixture = try LiveFixture(seedPath: swSeed)
        } catch {
            print("ERROR: LiveFixture (sw) init: \(error)")
            return 1
        }
        let liveURL: URL
        do {
            liveURL = try fixture.start()
        } catch {
            print("ERROR: LiveFixture (sw) start: \(error)")
            return 1
        }
        print("[sw] live URL: \(liveURL.absoluteString)")

        let box = UncheckedBox<Int32?>(nil)
        Task { @MainActor in
            box.value = await dvrMatrixRun(
                label: "sw",
                url: liveURL,
                seconds: seconds,
                dvrWindow: dvrWindow
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        fixture.stop()
        if (box.value ?? 1) != 0 { overallRC = 1 }
    }

    return overallRC
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
/// the value as Int. Returns nil if absent; exits 64 on a present but
/// missing/unparseable value (silently falling back to the default AND
/// leaving the flag token in `rest` used to corrupt the URL positional).
private func takeIntFlag(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Int(rest[idx + 1]) else {
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects an integer value, got \(got)")
        exit(64)
    }
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
/// the value as Double. Returns nil if absent; exits 64 on a present
/// but missing/unparseable value (see `takeIntFlag`).
private func takeDoubleFlag(_ name: String, from rest: inout [String]) -> Double? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Double(rest[idx + 1]) else {
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects a numeric value, got \(got)")
        exit(64)
    }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Reject leftover `--flags` after a subcommand's known flags were
/// plucked: a typo'd flag otherwise either vanished silently or, worse,
/// became the URL positional and produced a misleading open error.
private func rejectStrayFlags(_ rest: [String], subcommand: String) {
    if let stray = rest.first(where: { $0.hasPrefix("--") }) {
        print("ERROR: unknown flag '\(stray)' for subcommand '\(subcommand)'")
        print("")
        printUsage()
        exit(64)
    }
}

// DVR matrix subcommand.
if first == "dvr" {
    var rest = Array(args.dropFirst(2))
    let path    = takeStringFlag("--path",       from: &rest) ?? "both"
    let seconds = takeDoubleFlag("--seconds",    from: &rest) ?? 120.0
    let dvrWin  = takeDoubleFlag("--dvr-window", from: &rest) ?? 60.0
    guard ["native", "sw", "both"].contains(path) else {
        print("ERROR: --path must be native, sw, or both (got '\(path)')")
        exit(64)
    }
    rejectStrayFlags(rest, subcommand: "dvr")
    exit(runDVR(path: path, seconds: seconds, dvrWindow: dvrWin))
}

// HLS live fixture subcommand.
if first == "hlsfixture" {
    let rest = Array(args.dropFirst(2))
    exit(runHLSFixture(args: rest))
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
    let rewindTest = takeFlag("--rewind-test", from: &rest)
    // --sw forces the live source through SoftwarePlaybackHost regardless
    // of codec (TEST-ONLY routing override). Lets the H.264 fixture
    // exercise the SW live + DVR path end-to-end.
    let forceSW = takeFlag("--sw", from: &rest)
    // --drop-after N: instruct LiveFixture to close the first client
    // connection after N seconds, simulating a single recoverable mid-stream
    // drop. AVIOReader should reconnect and playback should resume.
    let dropAfter = takeDoubleFlag("--drop-after", from: &rest)
    // --discontinuity-at N: after ~N seconds of serving, the fixture jumps
    // its rewritten PTS / PCR forward by a large delta ONCE, then continues
    // monotonically (simulating a program boundary). The engine must keep
    // playing and keep the session timeline monotonic.
    let discontinuityAt = takeDoubleFlag("--discontinuity-at", from: &rest)
    // --realtime paces the fixture output at ~1x wall-clock so the producer /
    // AVPlayer cannot race ahead of real time, matching a genuine live feed.
    // Default (absent): serve as fast as the socket drains (today's behaviour).
    let realtime = takeFlag("--realtime", from: &rest)
    // --gen-highbitrate-seed: ensure a ~22 Mbps 1080p H.264 MPEG-TS seed exists
    // in Fixtures/user/ (generating it with ffmpeg if absent) and exit. Used to
    // prep the RSS-retention measurement seed. Honours --seed for the path.
    if takeFlag("--gen-highbitrate-seed", from: &rest) {
        let path = seed ?? "Fixtures/user/highbitrate-1080p.ts"
        exit(ensureHighBitrateSeed(path: path) ? 0 : 1)
    }
    // --sliding is accepted-and-ignored for backward compat: sliding is now
    // the unconditional behaviour for a live session, so the flag is a no-op.
    _ = takeFlag("--sliding", from: &rest)
    rejectStrayFlags(rest, subcommand: "live")
    exit(runLive(seconds: seconds, seed: seed, dvrWindow: dvrWindow,
                 serveOnly: serveOnly, measureRSS: measureRSS,
                 reportCacheBytes: reportCacheBytes, rewindTest: rewindTest,
                 forceSoftware: forceSW, dropAfter: dropAfter,
                 discontinuityAt: discontinuityAt, realtime: realtime))
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
    rejectStrayFlags(rest, subcommand: first)
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
