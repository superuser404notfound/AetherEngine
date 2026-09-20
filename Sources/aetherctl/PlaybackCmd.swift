import Foundation
import Combine
import CoreGraphics
import CoreMedia
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import AetherEngine

/// #544: the still drill writes what it decoded, because a hit count says the call returned an image
/// and only the file says it is the right picture.
private func writeStillPNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - play

/// A host's post-play audio-track pick, replayed on the CLI (#337). The delay is the whole
/// point: a host that applies a viewer's preferred language milliseconds after `play()`
/// rebuilds the session at `resumeAt = 0`, which is the only shape where the rebuilt
/// session's renderer can fill before the newly selected stream's first packet arrives.
struct AudioSwitchRequest {
    let index: Int
    let delayMilliseconds: Int
}

/// A host changing the teletext caption page on a channel that is already playing (#364). nil page
/// means back to libzvbi auto-detect. The delay is what makes the run a test of the runtime path
/// rather than of the load option: it has to land after a teletext track is selected and showing.
struct TeletextPageSwitchRequest {
    let page: Int?
    let delayMilliseconds: Int
}

/// A host nudging the audio delay on a session that is already playing (AE#464). Milliseconds,
/// because that is the unit a lip-sync control is reasoned about in. The delay is what makes the run
/// a test of the runtime path, which is the interesting half: at load the offset is just a number
/// handed to a muxer or a decoder, while mid-session it has to reach media the session has already
/// committed to the previous value.
struct AudioDelaySwitchRequest {
    let milliseconds: Int
    let delayMilliseconds: Int
}

/// A host correcting a `LoadOption` on a session that is already playing (#460). The delay is what
/// makes the run a test of the runtime path rather than of the load option: it has to land on a
/// session that is playing, or the run proves nothing the load option did not already prove.
struct LoadOptionCorrectionRequest {
    let changes: [LoadOptionChange]
    let delayMilliseconds: Int
}

/// The corrections the harness can drive. Deliberately a short list of levers whose effect is
/// visible from a CLI run, plus two that exist to drive the two ways a correction can NOT happen:
/// `isLive`, a load-identity field, which has to be observably refused rather than observably
/// ignored, and `autoplay`, which is neither refused nor applied (the rebuild takes the session's
/// own transport, AE#464 round 2) and could until round 3 only be read off the code.
enum LoadOptionChange {
    case header(name: String, value: String)
    case audioBridgeMode(AudioBridgeMode)
    case preferredAudioLanguages([String])
    case decodePath(DecodePath)
    case dolbyVisionHandling(DolbyVisionHandling)
    case isLive(Bool)
    case autoplay(Bool)

    var label: String {
        switch self {
        case .header(let name, _): return "httpHeaders[\(name)]"
        case .audioBridgeMode(let mode): return "audioBridgeMode=\(mode.rawValue)"
        case .preferredAudioLanguages(let langs): return "preferredAudioLanguages=\(langs.joined(separator: ","))"
        case .decodePath(let path): return "preferredDecodePath=\(path.rawValue)"
        case .dolbyVisionHandling(let handling): return "dolbyVisionHandling=\(handling.rawValue)"
        case .isLive(let value): return "isLive=\(value)"
        case .autoplay(let value): return "autoplay=\(value)"
        }
    }

    func apply(to options: inout LoadOptions) {
        switch self {
        case .header(let name, let value): options.httpHeaders[name] = value
        case .audioBridgeMode(let mode): options.audioBridgeMode = mode
        case .preferredAudioLanguages(let langs): options.preferredAudioLanguages = langs
        case .decodePath(let path): options.preferredDecodePath = path
        case .dolbyVisionHandling(let handling): options.dolbyVisionHandling = handling
        case .isLive(let value): options.isLive = value
        case .autoplay(let value): options.autoplay = value
        }
    }
}

/// Full playback-session smoke test: load a URL exactly like a host app (VOD by
/// default, `--live` for the live path), autoplay, print 1 Hz transport telemetry,
/// and optionally activate an embedded subtitle track (`--subs <codec-or-lang>`)
/// and log every overlay cue that arrives. Repro harness for "loads but never
/// plays" reports and for live teletext end-to-end validation (#107).
func runPlay(url: URL, seconds: Double, live: Bool, nativeHLS: Bool = false, liveIngest: Bool = false, fastZap: Bool = false, liveStartImmediately: Bool = true, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool = false, seekEvery: Double? = nil, seekPattern: [Double] = [], seekCount: Int? = nil, startPosition: Double? = nil, mallocCensus: Bool = false, forceSoftware: Bool = false,
                    censusThresholdMB: Int? = nil, censusHz: Double? = nil, frameTimes: Bool = false, presentTimes: Bool = false, pictureProbe: Bool = false,
                    sidecars: [ExternalSubtitleTrack] = [], audioSwitch: AudioSwitchRequest? = nil,
                    teletextPage: Int? = nil, teletextSwitch: TeletextPageSwitchRequest? = nil,
                    audioDelayMs: Int = 0, audioDelaySwitches: [AudioDelaySwitchRequest] = [],
                    pausedMount: Bool = false,
                    optionCorrection: LoadOptionCorrectionRequest? = nil,
                    sequentialOrigin: Bool = false, maxConcurrentRequests: Int? = nil, heldConnection: Bool = false, declaredDuration: Double? = nil,
                    httpHeaders: [String: String] = [:],
                    deinterlaceFieldRate: DeinterlaceFieldRate = .field,
                    assertDolbyVision: Bool = false,
                    dolbyVisionHandling: DolbyVisionHandling = .automatic, record: URL? = nil) -> Int32 {
    EngineLog.handler = { print($0) }
    if mallocCensus {
        AetherEngine.setLargeAllocationCensusEnabled(
            true,
            triggerThresholdMB: censusThresholdMB ?? 32,
            triggerPollHz: censusHz ?? 8)
    }
    // AE#461: `play --sw` drives `LoadOptions.preferredDecodePath`, the shipping per-session lever,
    // rather than the process-global test hook it used before. The hook forces every session on the
    // engine, so it could never exercise the thing a host actually calls.
    if forceSoftware { print("[aetherctl] decode path: preferredDecodePath=.software (#461)") }
    if let audioSwitch {
        print("[aetherctl] audio switch: selectAudioTrack(index: \(audioSwitch.index)) "
              + "\(audioSwitch.delayMilliseconds) ms after the load returns")
    }
    print("aetherctl play: \(url.absoluteString) (seconds=\(seconds) live=\(live) nativeHLS=\(nativeHLS) liveIngest=\(liveIngest) dvrWindow=\(dvrWindow.map { String($0) } ?? "nil") subs=\(subsPick ?? "off") hostCalls=\(hostCalls.isEmpty ? "none" : hostCalls.joined(separator: "+")) audioStats=\(audioStats) seekEvery=\(seekEvery.map { String($0) } ?? "off") seekCount=\(seekCount.map { String($0) } ?? "unbounded") seekPattern=\(seekPattern.isEmpty ? "off" : seekPattern.map { String($0) }.joined(separator: "/")) startPosition=\(startPosition.map { String($0) } ?? "0"))")
    print("")
    // CFRunLoopRun, not a blocking semaphore: AetherEngine is @MainActor, so parking the main thread would deadlock the executor.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await playSmokeTest(url: url, seconds: seconds, live: live, forceSoftware: forceSoftware, nativeHLS: nativeHLS, liveIngest: liveIngest, fastZap: fastZap, liveStartImmediately: liveStartImmediately, dvrWindow: dvrWindow, subsPick: subsPick, hostCalls: hostCalls, audioStats: audioStats, seekEvery: seekEvery, seekPattern: seekPattern, seekCount: seekCount, startPosition: startPosition, frameTimes: frameTimes, presentTimes: presentTimes, pictureProbe: pictureProbe, sidecars: sidecars, audioSwitch: audioSwitch, teletextPage: teletextPage, teletextSwitch: teletextSwitch, audioDelayMs: audioDelayMs, audioDelaySwitches: audioDelaySwitches, pausedMount: pausedMount, optionCorrection: optionCorrection, sequentialOrigin: sequentialOrigin, maxConcurrentRequests: maxConcurrentRequests, heldConnection: heldConnection, declaredDuration: declaredDuration, httpHeaders: httpHeaders, deinterlaceFieldRate: deinterlaceFieldRate, assertDolbyVision: assertDolbyVision, dolbyVisionHandling: dolbyVisionHandling, record: record)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

/// #306: the network half of the 1 Hz snapshot, appended to the transport line. Every field is
/// omitted where the snapshot has none, so the software path's numbers can be read off a run instead
/// of inferred from a memprobe half a minute wide. `ahead` is the fetched part the demuxer has not
/// consumed, and `cushion` the decoded video queued past the clock.
///
/// AE#443: `rx` and `origin` are two different links, and the run that made that worth spelling out was
/// a reporter reading a fall in `rx` as an origin socket event. `origin` is the session's pull from the
/// SOURCE, which is the one an origin question is about; `rx` is what the playback consumer pulled over
/// its own link, which on the native path is the loopback server and therefore says nothing about the
/// origin at all. Both are session totals now.
@MainActor
private func networkTelemetryFragment(_ telemetry: LiveTelemetry?) -> String {
    guard let telemetry else { return "" }
    var out = ""
    if let mbps = telemetry.networkThroughputMbps { out += String(format: " net=%.2fMbps", mbps) }
    if let rx = telemetry.networkTransferredBytes { out += String(format: " rx=%.1fMB", Double(rx) / 1_048_576) }
    out += String(format: " origin=%.1fMB", Double(telemetry.demuxerBytesFetched) / 1_048_576)
    if let ahead = telemetry.readerWindowAheadBytes { out += String(format: " ahead=%.1fMB", Double(ahead) / 1_048_576) }
    if let cushion = telemetry.displayCushionSeconds { out += String(format: " cushion=%.2fs", cushion) }
    if let fwd = telemetry.forwardBufferSeconds { out += String(format: " fwd=%.1fs", fwd) }
    if let dropped = telemetry.droppedFrameCount { out += " drop=\(dropped)" }
    if let delay = telemetry.accumulatedFrameDelaySeconds { out += String(format: " delay=%.2fs", delay) }
    return out
}

/// AE#510: what reached the screen on the NATIVE path, which had no frame observable at all.
///
/// `--frame-times` reads the software renderer's own reports, so every judder report on the AVPlayer
/// route could only be argued about from `AVPlayerItemTrack.currentVideoFrameRate`, an estimate that
/// is explicitly not a frame count. This attaches an `AVPlayerItemVideoOutput` to the engine's own
/// item and counts DISTINCT presentation times, and it reports the largest gap between two of them,
/// which is the observable that separates "the picture is late" from "only the random access points
/// survive": a 29.97 fps session that presents nothing but its container keys shows a gap of one GOP.
///
/// Attaching an output gives AVPlayer a pixel-buffer consumer it would not otherwise have, so a run
/// with this flag is not byte-for-byte the run without it. It is still the same decode path.
final class PresentedFrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var attachedID: ObjectIdentifier?
    private var harvest: DispatchSourceTimer?
    private var total = 0
    private var sinceTick = 0
    private var perTick: [Int] = []
    private var last = Double.nan
    private var largestGap = 0.0
    private var largestGapAt = 0.0
    private var suspended = false

    /// The engine builds the item and can replace it, so attach to whichever one is current.
    @MainActor
    func attachIfNeeded(_ item: AVPlayerItem?) {
        guard let item else { return }
        let id = ObjectIdentifier(item)
        lock.lock()
        let already = attachedID == id
        lock.unlock()
        guard !already else { return }
        let fresh = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        if let output, let attachedItem { attachedItem.remove(output) }
        item.add(fresh)
        lock.lock()
        output = fresh
        attachedItem = item
        attachedID = id
        last = .nan
        lock.unlock()
        startHarvest()
    }

    private func startHarvest() {
        lock.lock()
        defer { lock.unlock() }
        guard harvest == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "aetherctl.presented"))
        // Poll well above the content rate: a missed poll is a frame this probe under-counts.
        timer.schedule(deadline: .now(), repeating: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        harvest = timer
    }

    private func poll() {
        lock.lock()
        let current = output
        lock.unlock()
        guard let current else { return }
        let itemTime = current.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, current.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var display = CMTime.zero
        guard current.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &display) != nil,
              display.isValid else { return }
        let seconds = display.seconds
        lock.lock()
        defer { lock.unlock() }
        guard last.isNaN || seconds > last else { return }
        if !suspended, !last.isNaN, seconds - last > largestGap {
            largestGap = seconds - last
            largestGapAt = last
        }
        last = seconds
        total += 1
        sinceTick += 1
    }

    /// A seek moves the presentation axis, so neither the jump across it nor anything presented while
    /// it is in flight is a gap in delivery. Suspending has to bracket the call, not follow it: the
    /// landing frame arrives before `seek(to:)` returns, and the first version of this recorded that
    /// jump as the session's largest gap on every run.
    func beginDiscontinuity() {
        lock.lock()
        suspended = true
        last = .nan
        lock.unlock()
    }

    func endDiscontinuity() {
        lock.lock()
        suspended = false
        last = .nan
        lock.unlock()
    }

    func drainTick() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let frames = sinceTick
        sinceTick = 0
        perTick.append(frames)
        return frames
    }

    /// Ticks before the first presented frame are the load, not a stall: they would drag every
    /// summary down and say nothing about the session that ran.
    func summary() -> (total: Int, min: Int, median: Int, max: Int, largestGap: Double, gapAt: Double) {
        lock.lock()
        defer { lock.unlock() }
        let live = Array(perTick.drop(while: { $0 == 0 }))
        let sorted = live.sorted()
        return (total,
                sorted.first ?? 0,
                sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                sorted.last ?? 0,
                largestGap,
                largestGapAt)
    }

    func stop() {
        lock.lock()
        let timer = harvest
        harvest = nil
        lock.unlock()
        timer?.cancel()
    }
}

/// #311: records the software path's per-frame reports, from the decode thread. Also checks the
/// API's own claim while it is at it: these arrive past the reorder buffer, so `ooo` (a report whose
/// presentation time precedes its predecessor within one generation) must stay 0 on real media.
final class FrameTimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var sinceTick = 0
    private var last: CMTime?
    private var lastInGeneration: CMTime?
    private var generation: UInt64 = 0
    private var generations: Set<UInt64> = []
    private var outOfOrder = 0

    func record(_ frame: SoftwareVideoFrameTime) {
        lock.lock()
        defer { lock.unlock() }
        total += 1
        sinceTick += 1
        generations.insert(frame.generation)
        if frame.generation != generation {
            generation = frame.generation
            lastInGeneration = nil
        }
        if let previous = lastInGeneration, CMTimeCompare(frame.presentation, previous) < 0 {
            outOfOrder += 1
        }
        lastInGeneration = frame.presentation
        last = frame.presentation
    }

    /// Frames since the previous call, and the state at this instant.
    func drainTick() -> (frames: Int, last: CMTime?, generation: UInt64, outOfOrder: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = sinceTick
        sinceTick = 0
        return (n, last, generation, outOfOrder)
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "frames=\(total) outOfOrder=\(outOfOrder) generations=\(generations.sorted())"
    }
}

/// Decoded-PCM continuity monitor fed by the engine audio tap (#95 infrastructure).
/// Tracks per-buffer source-PTS abutment (gap = next.start - prev.end) and the running
/// end-of-enqueued-audio position, so the telemetry loop can print the audio lead
/// (decoded-ahead-of-clock). A chopping report shows up as AGAP lines (decode-side holes)
/// or as the lead collapsing to ~0 (feeder starvation); a clean run shows neither.
@MainActor
private final class AudioContinuityMonitor {
    private(set) var bufferCount = 0
    private(set) var gapCount = 0
    private(set) var discontinuityCount = 0
    private(set) var maxGapMs = 0.0
    private(set) var lastEndPTS: Double?
    private var totalFrames = 0

    func consume(_ buf: AudioTapBuffer) {
        let start = buf.sourceTime
        let frames = Int(buf.buffer.frameLength)
        if let prevEnd = lastEndPTS {
            let gapMs = (start - prevEnd) * 1000
            if buf.discontinuity { discontinuityCount += 1 }
            if abs(gapMs) > 2.0 {
                gapCount += 1
                maxGapMs = max(maxGapMs, abs(gapMs))
                print(String(format: "  AGAP #%d at src=%.3f gap=%+.1fms frames=%d%@",
                             gapCount, start, gapMs, frames, buf.discontinuity ? " (disc)" : ""))
            }
        }
        lastEndPTS = start + Double(frames) / buf.buffer.format.sampleRate
        bufferCount += 1
        totalFrames += frames
    }

    var summary: String {
        String(format: "buffers=%d frames=%d gaps>2ms=%d maxGap=%.1fms discFlags=%d",
               bufferCount, totalFrames, gapCount, maxGapMs, discontinuityCount)
    }
}

/// #292 drill: issue a seek and make a transport call while its reposition is still in flight, then
/// report what the landing did with that intent.
///
/// The software and audio hosts park their loops for the duration of a seek by clearing `isPlaying`,
/// and since #254 the reposition that follows is awaited off the main actor, so a transport call
/// (another seek, `pause()`, `play()`) can land inside that window. `seektest` cannot reach any of
/// this: it awaits every seek, so its bursts are strictly serial.
///
/// `inWindow` is the precondition. Without it the call arrived after the landing and the run proves
/// nothing, so it reports INCONCLUSIVE rather than a green PASS.
///
/// Every drill opens by healing the session with the report's own manual workaround (pause + play)
/// and then settling into `startPlaying`, so a defect one drill provokes cannot be inherited by the
/// next: before the fix each of these leaves the session wedged, and drills run back to back on a
/// wedged session are unattributable.
@MainActor
private func seekIntentDrill(
    engine: AetherEngine,
    label: String,
    target: Double,
    startPlaying: Bool,
    expectPlaying: Bool,
    extraPrecondition: @MainActor () -> Bool = { true },
    duringReposition: @MainActor @escaping () async -> Void
) async -> String {
    engine.pause()
    engine.play()
    let healClock = engine.currentTime
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let healAdvance = engine.currentTime - healClock
    if healAdvance < 0.5 {
        return String(format: "INCONCLUSIVE %@: session did not play at drill start (%+.2fs in 1.5s)",
                      label, healAdvance)
    }
    if !startPlaying {
        engine.pause()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    print(String(format: "  #292 DRILL %@: from %@, seek(to: %.2f), transport call mid-reposition",
                 label, startPlaying ? "playing" : "paused", target))
    let seekTask = Task { @MainActor in await engine.seek(to: target) }
    await Task.yield()                                   // let the seek reach its off-main await
    try? await Task.sleep(nanoseconds: 2_000_000)
    let inWindow = engine.isSeeking
    await duringReposition()
    _ = await seekTask.value
    let stateAtLanding = engine.state
    let clockAtLanding = engine.currentTime
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let advanced = engine.currentTime - clockAtLanding
    let playing = advanced >= 1.0
    print(String(format: "    inWindow=%@ landed state=%@ clock=%.2f -> %.2f (%+.2fs in 3s)",
                 inWindow ? "yes" : "NO", String(describing: stateAtLanding),
                 clockAtLanding, engine.currentTime, advanced))
    guard inWindow, extraPrecondition() else {
        return "INCONCLUSIVE \(label): the transport call did not land inside the reposition window"
    }
    guard playing == expectPlaying else {
        return String(format: "FAIL %@: expected the landing to be %@, clock advanced %+.2fs",
                      label, expectPlaying ? "playing" : "paused", advanced)
    }
    guard (stateAtLanding == .playing) == expectPlaying else {
        return "FAIL \(label): engine reported \(stateAtLanding) over a host that landed "
            + (playing ? "playing" : "paused")
    }
    return "PASS \(label)"
}

@MainActor
private func playSmokeTest(url: URL, seconds: Double, live: Bool, forceSoftware: Bool = false, nativeHLS: Bool = false, liveIngest: Bool = false, fastZap: Bool = false, liveStartImmediately: Bool = true, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool, seekEvery: Double? = nil, seekPattern: [Double] = [], seekCount: Int? = nil, startPosition: Double? = nil, frameTimes: Bool = false, presentTimes: Bool = false, pictureProbe: Bool = false, sidecars: [ExternalSubtitleTrack] = [], audioSwitch: AudioSwitchRequest? = nil, teletextPage: Int? = nil, teletextSwitch: TeletextPageSwitchRequest? = nil, audioDelayMs: Int = 0, audioDelaySwitches: [AudioDelaySwitchRequest] = [], pausedMount: Bool = false, optionCorrection: LoadOptionCorrectionRequest? = nil, sequentialOrigin: Bool = false, maxConcurrentRequests: Int? = nil, heldConnection: Bool = false, declaredDuration: Double? = nil, httpHeaders: [String: String] = [:], deinterlaceFieldRate: DeinterlaceFieldRate = .field, assertDolbyVision: Bool = false, dolbyVisionHandling: DolbyVisionHandling = .automatic, record: URL? = nil) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }

    var cancellables = Set<AnyCancellable>()
    var seenCueEnds: [Int: Double] = [:]
    var cueCount = 0
    // #362 round 2: CUE and TRIM report arrivals and end changes, and a cue that LEAVES the window
    // was reported by neither, so a wrong end that was later replaced read exactly like one the
    // host still carries. `DROP` and the closing `WINDOW` dump are what make a claim about what the
    // host holds measurable, which is the shape every report of this kind arrives in.
    var presentCueIDs: Set<Int> = []
    var lastCues: [SubtitleCue] = []
    engine.$subtitleCues.sink { cues in
        let ids = Set(cues.map(\.id))
        for gone in presentCueIDs.subtracting(ids).sorted() {
            print(String(format: "  DROP #%d", gone))
        }
        presentCueIDs = ids
        // The LAST NON-EMPTY window, not the last one: teardown publishes an empty array, so a
        // closing dump of `cues` reports nothing carried and hides the whole session.
        if !cues.isEmpty { lastCues = cues }
        for cue in cues {
            if let prevEnd = seenCueEnds[cue.id] {
                if prevEnd != cue.endTime {
                    seenCueEnds[cue.id] = cue.endTime
                    print(String(format: "  TRIM #%d -> end=%.2f", cue.id, cue.endTime))
                }
                continue
            }
            seenCueEnds[cue.id] = cue.endTime
            cueCount += 1
            let body: String
            switch cue.body {
            case .text(let text): body = "'\(text.replacingOccurrences(of: "\n", with: " | "))'"
            case .richText(let runs):
                let flat = runs.map(\.text).joined().replacingOccurrences(of: "\n", with: " | ")
                let colours = runs.filter { $0.color != nil }.count
                body = "'\(flat)' [\(colours) colour run(s)]"
            case .image: body = "[bitmap]"
            }
            print(String(format: "  CUE #%d %.2f-%.2f %@", cue.id, cue.startTime, cue.endTime, body))
        }
    }.store(in: &cancellables)

    // #315: the cover-lift edge, stamped from the load call. Both transitions are printed: the
    // false is the load un-latching it, the true is the running path reporting a first frame ready
    // for display. Nothing here binds a render surface, so a true means the pipeline is ready, not
    // that anything is on screen (that distinction is the property's own documentation).
    let loadStart = DispatchTime.now()
    engine.$hasFirstFrameReadyForDisplay
        .dropFirst()
        .sink { ready in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1e9
            print(String(format: "  FIRSTFRAME hasFirstFrameReadyForDisplay=%@ t+%.2fs",
                         ready ? "true" : "false", elapsed))
        }
        .store(in: &cancellables)

    // AE#440: the 1 Hz tick samples `phase`, which is too coarse to tell a start signal from the
    // moment the rate actually rolls. Every edge, stamped from the same load clock as FIRSTFRAME,
    // so the two can be read against each other and against the host's timeControlStatus lines.
    engine.$playbackPhase
        .removeDuplicates()
        .dropFirst()
        .sink { phase in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1e9
            print(String(format: "  PHASE %@ t+%.2fs", String(describing: phase), elapsed))
        }
        .store(in: &cancellables)

    let options = LoadOptions(
        suppressDisplayCriteria: true,
        httpHeaders: httpHeaders,
        // AE#493: the Dolby Vision claim a macOS host has to make itself, because there is no per-mode
        // capability API to read there. Without the flag a Mac run cannot exercise the DV route at all,
        // which is how the reporter ended up A/B-ing a local patch instead of a session option.
        // The base layer of a Dolby Vision source, the Dolby Vision left out of the container: the
        // harness for a record the bitstream contradicts.
        dolbyVisionHandling: dolbyVisionHandling,
        panelPresentsDolbyVision: assertDolbyVision,
        isLive: live,
        dvrWindowSeconds: dvrWindow,
        liveJoinProfile: fastZap ? .fastZap : .standard,
        liveJoinStartsImmediately: liveStartImmediately,
        nativeRemoteHLS: nativeHLS,
        // Sodalite#156: the native WebVTT renditions, i.e. the path a host uses whenever the picture
        // leaves its own layer (PiP, AirPlay, a wired display). `serve --native-subs` could stand the
        // renditions UP and `live --force-master` could route a channel behind them, but no VOD
        // session here had ever loaded with them, so the half that matters, AVPlayer actually holding
        // a legible selection and the engine feeding it, had no harness at all. AE#359 was found the
        // day live got one; this is the same gap on the other side.
        prepareNativeSubtitles: hostCalls.contains("nativesubs"),
        sequentialOrigin: sequentialOrigin,
        maxConcurrentSourceRequests: maxConcurrentRequests,
        heldSourceConnection: heldConnection,
        declaredDurationSeconds: declaredDuration,
        externalSubtitles: sidecars,
        // AE#464 round 2: the reporter's mount. A host that drives transport itself loads with
        // autoplay off and calls play() next to its own load; a rebuild the ENGINE raises has no
        // such caller, which is what made a mid-play nudge settle paused and stay there.
        autoplay: !pausedMount,
        teletextPage: teletextPage,
        audioDelaySeconds: Double(audioDelayMs) / 1000.0,   // AE#464
        // AE#492: the field-rate lever was reachable from no harness at all, so the one A/B that
        // separates "the deinterlaced path loses frames" from "it emits 2.5x as many of them" could
        // only be asked of a reporter. send_frame halves the output rate and changes nothing else.
        deinterlaceFieldRate: deinterlaceFieldRate,
        preferredDecodePath: forceSoftware ? .software : .automatic
    )
    // #311: installed BEFORE the load on purpose. The engine holds it and arms the host it builds,
    // which is the documented usage and the part a host would otherwise have to re-do per load.
    let frameProbe = frameTimes ? FrameTimeProbe() : nil
    let presentProbe = presentTimes ? PresentedFrameProbe() : nil
    let picture = pictureProbe ? PictureProbe() : nil
    if let frameProbe {
        engine.setSoftwareVideoFrameTimeObserver { [weak frameProbe] frame in
            frameProbe?.record(frame)
        }
    }

    do {
        let probe: SourceProbe?
        if liveIngest {
            // The shape a host uses for a live channel it ingests itself (Sodalite's direct path):
            // HLSLiveIngestReader over the upstream playlist, handed in as a custom source. Without
            // this the CLI cannot reach the ingest at all, since `--live` sends an m3u8 to the raw
            // live path by design and `hlslive` only serves local .ts files.
            probe = try await engine.load(source: .custom(HLSLiveIngestReader(playlistURL: url,
                                                                              httpHeaders: httpHeaders),
                                                          formatHint: "mpegts"),
                                          options: options)
        } else {
            probe = try await engine.load(url: url, startPosition: startPosition, options: options)
        }
        // Mirror AetherPlayer's Open URL flow: a probe-flagged live source is reloaded
        // back-to-back on the live path (same engine instance, stopInternal in between).
        if hostCalls.contains("reloadlive"), let probe, probe.isLive, !engine.isLive {
            print("  HOSTCALL reload as live (probe.isLive)")
            var liveOptions = options
            liveOptions.isLive = true
            liveOptions.dvrWindowSeconds = 1800
            try await engine.load(url: url, options: liveOptions)
        }
    } catch {
        print("LOAD FAILED: \(error)")
        return 1
    }
    if !sidecars.isEmpty {
        // #316: what the declaration actually became. On the bypass an id in the external range means
        // the track survived the branch at all; whether it is ALSO a rendition is in the engine's own
        // "serving N external subtitle rendition(s)" line above.
        print("  SIDECARS declared=\(sidecars.count) -> tracks: "
              + engine.subtitleTracks.map { "#\($0.id) \($0.name)(\($0.language ?? "?"))" }
                .joined(separator: ", "))
    }
    // The source identity a host stats panel reads, in one line. Printed from the session (not from a
    // separate probe) because that is the state the panel binds to, and the two can disagree: the
    // remote-HLS bypass runs no probe and fills these from the item's sample type instead.
    print("  SOURCE codec=\(engine.sourceVideoCodecName ?? "nil") "
          + "container=\(engine.sourceContainerFormat ?? "nil") "
          + "\(engine.sourceVideoWidth)x\(engine.sourceVideoHeight) "
          + "fps=\(engine.sourceVideoFrameRate.map { String(format: "%.3f", $0) } ?? "nil") "
          + "bitrate=\(engine.sourceVideoBitrate) "
          + "fmt=\(engine.sourceVideoFormat)"
          + (engine.sourceDVProfile.map { " dvProfile=\($0)" } ?? "")
          + (engine.dolbyVisionConversion.map { " dvConversion=\($0)" } ?? ""))

    // AE#560: record the live source to a file, from the connection this session already holds.
    // A requested recording that produces nothing is a machine-checkable failure (exit 3), not a
    // silent pass, which is the whole reason the flag exists.
    var recordingRefused = false
    if let record {
        do {
            try await engine.startRecording(to: record)
            print("  RECORD started -> \(record.path)")
        } catch {
            print("  RECORD refused: \(error)")
            recordingRefused = true
        }
    }

    // Mimic host-app post-load calls (AetherPlayer openInternal order) to reproduce
    // host-triggered transport races the bare harness would miss.
    var frameExtractor: FrameExtractor?
    for call in hostCalls {
        switch call {
        case "play":
            print("  HOSTCALL play()")
            engine.play()
        case "extractor":
            frameExtractor = engine.makeFrameExtractor()
            print("  HOSTCALL makeFrameExtractor() -> \(frameExtractor == nil ? "nil" : "instance")")
        case "setrate":
            print("  HOSTCALL setRate(1.0)")
            engine.setRate(1.0)
        case "ratehold":
            // #436: the speed a host set has to survive the transport's own resume. Set here, paused
            // at tick 3 and resumed at tick 5 in the telemetry loop; the verdict reads the rate back
            // off the transport itself, not off anything the engine remembers.
            print("  HOSTCALL setRate(\(Issue436RateHold.rate)) (held across a pause/resume)")
            engine.setRate(Issue436RateHold.rate)
        case "pausestart":
            // Sodalite#104 round 4: a host that pauses the instant load returns, before any frame
            // exists (the foreground retune's hold-paused policy). Resumed at tick 8.
            print("  HOSTCALL pause() right after load")
            engine.pause()
        case "reloadlive", "seekback", "overlapseek", "ratehold-tail", "pauseseek", "pausehold", "still", "stallclock":
            break  // reloadlive handled at load time, seekback/overlapseek/pauseseek in the telemetry loop
        case "nativesubs":
            break  // Sodalite#156, read at load time into LoadOptions.prepareNativeSubtitles
        case let call where call.hasPrefix("seekfar") || call.hasPrefix("subsoff")
            || call.hasPrefix("subson") || call.hasPrefix("nativerender"):
            break  // #433 / Sodalite#156, all in the telemetry loop; `@N` picks the tick
        default:
            print("  HOSTCALL unknown '\(call)' (use play,extractor,setrate,ratehold,pausestart,reloadlive,seekback,seekfar,overlapseek,pauseseek,pausehold,still,stallclock,nativesubs,nativerender,subsoff,subson)")
        }
    }
    defer { if let frameExtractor { Task { await frameExtractor.shutdown() } } }

    var rateHoldAfterResume: Float?
    var rateHoldAtEnd: Float?
    // AE#549: the clock at the stall, just before the resume, and at the last tick.
    var stallClockStalled = false
    var stallClockAtStall: Double?
    var stallClockBeforeResume: Double?
    var stallClockAtEnd: Double?
    var monitor: AudioContinuityMonitor?
    var tapTask: Task<Void, Never>?
    if audioStats {
        let mon = AudioContinuityMonitor()
        monitor = mon
        let stream = engine.installAudioTap()
        print("  AUDIOTAP installed (deliverySource=\(engine.audioTapHasDeliverySource))")
        tapTask = Task { @MainActor in
            for await buf in stream { mon.consume(buf) }
            // A finished stream and a stream that stopped yielding look identical from the
            // buffer counter, and they are different defects (#356).
            print("  AUDIOTAP stream finished (buffers=\(mon.bufferCount))")
        }
    }

    // #364: the host changing the caption page on a channel that is already playing. Same detached
    // shape as the audio switch below, for the same reason: the delay has to be elapsed time next to
    // a running session, and here it also has to outlast the subtitle selection, or the run measures
    // the load option it was already able to measure before.
    // AE#464 round 2: repeatable, because a stepper press is repeatable. Three of them inside
    // one runloop turn is the leg that stacked three reloads and lost the playhead.
    //
    // Round 3: presses that share a delay are delivered by ONE task, in argument order, with no
    // await between them, which is what "inside one runloop turn" means. A task per press does not
    // reproduce that: three of them three milliseconds apart arrive in whatever order the scheduler
    // picks, measured as a 50/100/150 series landing 100, 150, 50, so the engine delivered 50 and
    // the arm read as a defect that was the harness. The suffix still groups them, so presses at
    // different times stay ordered by time.
    for (delay, group) in Dictionary(grouping: audioDelaySwitches, by: \.delayMilliseconds)
        .sorted(by: { $0.key < $1.key }) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
            for audioDelaySwitch in group {
                print("  HOSTCALL setAudioDelay(\(audioDelaySwitch.milliseconds) ms) at "
                      + "+\(delay) ms "
                      + "(was \(Int((engine.audioDelaySeconds * 1000).rounded())) ms, "
                      + "route=\(engine.videoRoute.rawValue), t=\(String(format: "%.2f", engine.currentTime))s)")
                engine.setAudioDelay(Double(audioDelaySwitch.milliseconds) / 1000.0)
            }
        }
    }

    if let teletextSwitch {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, teletextSwitch.delayMilliseconds)) * 1_000_000)
            let target = teletextSwitch.page.map(String.init) ?? "auto"
            print("  HOSTCALL setTeletextPage(\(target)) at +\(teletextSwitch.delayMilliseconds) ms "
                  + "(was \(engine.teletextPage.map(String.init) ?? "auto"))")
            engine.setTeletextPage(teletextSwitch.page)
        }
    }

    // #460: the host correcting an option on a session that is already playing, through the
    // session-preserving reload rather than a fresh load. Same detached shape as the switches
    // above. Both outcomes are printed: a correction that was applied and one that was refused are
    // exactly the pair a host's recovery ladder has to tell apart.
    if let optionCorrection {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, optionCorrection.delayMilliseconds)) * 1_000_000)
            let labels = optionCorrection.changes.map(\.label).joined(separator: ", ")
            let before = engine.currentTime
            print("  HOSTCALL reloadAtCurrentPosition(applying: \(labels)) at +\(optionCorrection.delayMilliseconds) ms "
                  + "(t=\(String(format: "%.2f", before))s)")
            do {
                let outcome = try await engine.reloadAtCurrentPosition { options in
                    for change in optionCorrection.changes { change.apply(to: &options) }
                }
                // AE#464 round 4: the returned partition, printed as it comes back. A run that
                // asked for a field the session owns used to print the same `applied` line as one
                // that rebuilt, which is exactly the confusion the return value ends.
                print("  #460 outcome applied=[\(outcome.applied.joined(separator: ", "))] "
                      + "sessionOwned=[\(outcome.sessionOwned.joined(separator: ", "))] "
                      + "rebuilt=\(outcome.rebuilt)")
                guard outcome.rebuilt else {
                    print("  #460 correction complete without a rebuild, the session owns every "
                          + "field it named (t=\(String(format: "%.2f", engine.currentTime))s, "
                          + "state=\(engine.state))")
                    return
                }
                // The clock republishes on the tick after the load returns, so reading it here
                // prints 0 and reads like a restart the session never took. Let one tick land.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                print("  #460 correction applied, session resumed at "
                      + "\(String(format: "%.2f", engine.currentTime))s from \(String(format: "%.2f", before))s "
                      + "(state=\(engine.state))")
            } catch {
                print("  #460 correction refused: \(error.localizedDescription)")
            }
        }
    }

    // #337: the host's language preference, applied while the session is still coming up. Fired
    // from a detached task so the delay is real elapsed time next to the running session, not a
    // gap the harness sleeps through before the engine ever starts.
    if let audioSwitch {
        let mon = monitor
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, audioSwitch.delayMilliseconds)) * 1_000_000)
            print("  HOSTCALL selectAudioTrack(index: \(audioSwitch.index)) "
                  + "at +\(audioSwitch.delayMilliseconds) ms (was \(engine.activeAudioTrackIndex.map(String.init) ?? "none"))")
            engine.selectAudioTrack(index: audioSwitch.index)
            // The tap is bound to the software host that was live when it was installed, and the
            // switch rebuilds that host, so a run that does not re-install reports silence for the
            // whole session and cannot tell a wedge from working audio.
            if let mon {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let restream = engine.installAudioTap()
                print("  AUDIOTAP re-installed after the switch "
                      + "(deliverySource=\(engine.audioTapHasDeliverySource))")
                Task { @MainActor in
                    for await buf in restream { mon.consume(buf) }
                }
            }
        }
    }

    print("")
    // #321: route, not just backend. `.native` covers both the loopback and the remote bypass, and an
    // internal reroute can have moved this run off the route the flags asked for.
    print("backend=\(engine.playbackBackend.rawValue) route=\(engine.videoRoute.rawValue) "
          + "duration=\(String(format: "%.1f", engine.duration))s isLive=\(engine.isLive)")
    // AE#462: the typed delivery next to the human label, because they answer different questions:
    // the label names the pipeline, the delivery says whether there is one at all.
    print("audio delivery=\(engine.audioDelivery.rawValue) "
          + "pipeline=\(engine.activeAudioDecoder ?? "none") tracks=\(engine.audioTracks.count)")
    if frameTimes {
        if let timebase = engine.softwarePresentationTimebase {
            print(String(format: "  timebase: present, time=%.3fs rate=%.2f", timebase.time.seconds, timebase.rate))
        } else {
            print("  timebase: nil (not the software path)")
        }
    }
    for track in engine.audioTracks {
        print("  audio    id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?") ch=\(track.channels)\(track.isDefault ? " default" : "")")
    }
    for track in engine.subtitleTracks {
        print("  subtitle id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?")\(track.isDefault ? " default" : "")")
    }
    print("")

    var subsSelected = false
    var seekPatternIndex = 0
    var seekLandings: [Double] = []

    // #292 drill state. `supersededSeeks` is the PRECONDITION: without an observed supersede the two
    // seeks never interleaved and the run proves nothing, so it reports INCONCLUSIVE rather than PASS.
    let supersededSeeks = UncheckedBox<Int>(0)
    var seekEventSub: AnyCancellable?
    if hostCalls.contains("overlapseek") {
        seekEventSub = engine.seekEvents.sink { event in
            if event.outcome == .superseded { supersededSeeks.value += 1 }
        }
    }
    defer { seekEventSub?.cancel() }
    var overlapVerdicts: [String] = []

    // #353: sampled during the session, because the engine clears the size with the session and the
    // summary below prints after teardown. Paired with the coded dimensions read at the same moment.
    var observedDisplaySize: CGSize?
    var observedCodedSize: (Int32, Int32) = (0, 0)

    // #433: `seekfar` (optionally `seekfar@N`) picks the second the far seek is issued in, so a run can
    // put the restart on top of a reader that is deep enough into its ladder to still be parked.
    let seekFarTick: Int? = hostCalls.first(where: { $0.hasPrefix("seekfar") }).map { call in
        let parts = call.split(separator: "@")
        return parts.count == 2 ? (Int(parts[1]) ?? 15) : 15
    }

    // Sodalite#156: a host turning subtitles OFF and back ON mid-session, which is the transition the
    // native rendition path had no way to drive from here at all. `subsoff@N` / `subson@N` pick the
    // second each one fires in. Selecting a track and clearing it are two different engine calls with
    // two different async tails, and only running them against each other shows whether the legible
    // selection ends up where the host asked for it. Defaults sit far enough apart for the pre-fill
    // that gates a select to finish in between.
    let nativeRenderTick: Int? = hostCalls.first(where: { $0.hasPrefix("nativerender") }).map { call in
        let parts = call.split(separator: "@")
        return parts.count == 2 ? (Int(parts[1]) ?? 8) : 8
    }
    let subsOffTick: Int? = hostCalls.first(where: { $0.hasPrefix("subsoff") }).map { call in
        let parts = call.split(separator: "@")
        return parts.count == 2 ? (Int(parts[1]) ?? 12) : 12
    }
    // `subson@N` re-picks the `--subs` track; `subson@N:lang` picks a DIFFERENT one, which is the
    // track-switch case. It read as working before this was fixable, for the same reason the off case
    // read as broken: with a selection standing and nothing ever moving it, a pick that never reached
    // the rendition still left the right language on screen.
    let subsOnSpec = hostCalls.first(where: { $0.hasPrefix("subson") })
        .map { $0.split(separator: "@").dropFirst().joined().split(separator: ":") }
    let subsOnTick: Int? = subsOnSpec.map { Int($0.first ?? "") ?? 18 }
    let subsOnLang: String? = subsOnSpec.flatMap { $0.count > 1 ? String($0[1]) : nil }

    // #544: scrub stills on the software live path, decoded out of the DVR packet ring. Three aims
    // per run (deep in the window, just behind the playhead, and at the edge), because the edge is the
    // one a live viewer sits on and the one a clamp has to cover.
    var stillAttempts = 0
    var stillHits = 0

    let ticks = max(1, Int(seconds))
    // Sodalite#104: where the playhead stood when the pause-and-hold drill parked it, so the run can
    // say whether it moved.
    var pauseHoldPlayhead: Double?
    for tick in 1...ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var line = String(format: "  t=%02d state=%@ phase=%@ cur=%.2f src=%.2f buf=%.2f dur=%.1f",
                          tick,
                          String(describing: engine.state),
                          String(describing: engine.playbackPhase),
                          engine.currentTime,
                          engine.sourceTime,
                          engine.bufferedPosition,
                          engine.duration)
        line += " rfd=\(engine.hasFirstFrameReadyForDisplay ? "y" : "n")"
        if let presentProbe {
            presentProbe.attachIfNeeded(engine.currentAVPlayerItem)
            line += " pres=\(presentProbe.drainTick())"
        }
        // AE#441: the live rewind surfaces a host actually scales its strip on. Sampling them needed a
        // patched copy of this CLI before, which is how an over-promising lower bound stayed unseen.
        if engine.isLive {
            // Sodalite#104: `atEdge` is the flag a host draws its LIVE badge and its return-to-live
            // affordance from, and it is not readable from `behind` alone, because the tolerance it
            // is judged against follows the segment cadence. Printing the distance without the
            // verdict is what let a flag that toggles twice per cut go unnoticed here.
            line += String(format: " edge=%.2f behind=%.2f atEdge=%@",
                           engine.liveEdgeTime, engine.behindLiveSeconds,
                           engine.isAtLiveEdge ? "y" : "n")
            line += " range=" + (engine.seekableLiveRange.map {
                String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) } ?? "nil")
        }
        if let monitor, let end = monitor.lastEndPTS {
            // Decoded-audio lead over the master clock (source axis). Near-zero = renderer starving.
            line += String(format: " alead=%.2f abufs=%d", end - engine.sourceTime, monitor.bufferCount)
        }
        line += networkTelemetryFragment(engine.liveTelemetry)
        // AE#418: the picture states its own source time, so `axisErr` is what AVPlayer did with the
        // segment rather than what the producer wrote, and `capErr` is the same error as a host
        // placing a cue at `sourceTime` would make it.
        //
        // The two errors do not have the same resolution, and only one of them says so without help.
        // `axisErr` differences two frame-grid values read out of one `copyPixelBuffer` call, so it is
        // a whole number of frames and every digit of it is a reading. `capErr` differences the same
        // frame-grid value against the engine's continuous clock, so a magnitude below one frame is
        // the sub-frame phase of the sampling instant, not an error: two sessions whose `capErr`
        // differs by less than `capFr = 1.0` made the SAME reading. Round 11 of #418 is exactly that
        // mistake made on a host-side metric (two clocks sampled at different points, differenced,
        // and a 0.050 s instrument constant reported as accuracy), so this line prints the quantum
        // next to the value rather than leaving it to be rediscovered per reader.
        if let picture {
            picture.attachIfNeeded(engine.currentAVPlayerItem)
            if let sample = picture.sample() {
                let capErr = sample.pictureSourceTime - engine.sourceTime
                line += String(format: " pic=%.3f picItem=%.3f axisErr=%+.3f capErr=%+.3f capFr=%+.2f",
                               sample.pictureSourceTime, sample.itemTime, sample.axisError,
                               capErr, capErr / picture.frameQuantum)
            } else {
                line += " pic=none"
            }
        }
        if let frameProbe {
            let tick = frameProbe.drainTick()
            line += " ft=\(tick.frames)"
            if let last = tick.last { line += String(format: " ftLast=%.3fs", last.seconds) }
            line += " ftGen=\(tick.generation) ooo=\(tick.outOfOrder)"
            // The clock the frames are presented against, read through the public property. Its
            // proximity to ftLast is the point: one axis, no conversion between them.
            if let timebase = engine.softwarePresentationTimebase {
                line += String(format: " tb=%.3fs", timebase.time.seconds)
            }
            // #353: the rectangle the frames land in. Read next to the coded dimensions on purpose:
            // on anamorphic content the two differ, and that difference IS the defect being watched.
            if let size = engine.softwareDisplaySize {
                line += " disp=\(Int(size.width))x\(Int(size.height))"
                observedDisplaySize = size
                observedCodedSize = (engine.sourceVideoWidth, engine.sourceVideoHeight)
            }
        }
        print(line)
        // DVR-seek smoke: rewind 20 s mid-session, then live-edge return 15 s later, so the
        // telemetry shows whether the clock and the audio look-ahead recover from both.
        if hostCalls.contains("ratehold") {
            if tick == 3 {
                print(String(format: "  HOSTCALL pause() at rate %.2f", Issue436RateHold.observedRate(engine)))
                engine.pause()
            }
            if tick == 5 {
                print("  HOSTCALL play() (no rate written by the client, which is the point)")
                engine.play()
            }
            if tick >= 6, rateHoldAfterResume == nil {
                rateHoldAfterResume = Issue436RateHold.observedRate(engine)
            }
            // Read again every tick after that: a rebuild the session runs later (an audio-track
            // switch, a live reload) builds a fresh host, and whether the speed crosses that seam is
            // the other half of the report.
            if tick >= 6 { rateHoldAtEnd = Issue436RateHold.observedRate(engine) }
        }
        if hostCalls.contains("still"), [15, 20, 25].contains(tick) {
            // The third aim is the live EDGE itself, not the playhead: a target a fraction past the
            // newest packet is the clamp case, and it is where a live viewer sits most.
            let target: Double
            let label: String
            switch tick {
            case 15:
                target = max(0, engine.currentTime - 20)
                label = "playhead-20"
            case 20:
                target = max(0, engine.currentTime - 5)
                label = "playhead-5"
            default:
                target = engine.seekableLiveRange?.upperBound ?? engine.currentTime
                label = "edge"
            }
            let started = Date()
            let image = await engine.liveScrubThumbnail(atSessionSeconds: target, maxWidth: 320)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            stillAttempts += 1
            if let image {
                stillHits += 1
                let path = "/tmp/aetherctl-still-\(tick).png"
                let written = writeStillPNG(image, to: path)
                print(String(format: "  HOSTCALL still(at: %.2f, %@) -> %dx%d in %d ms  %@",
                             target, label, image.width, image.height, ms,
                             written ? path : "(png write failed)"))
            } else {
                print(String(format: "  HOSTCALL still(at: %.2f, %@) -> MISS in %d ms", target, label, ms))
            }
        }
        if hostCalls.contains("seekback"), tick == 15 {
            let target = max(0, engine.currentTime - 20)
            print(String(format: "  HOSTCALL seek(to: %.2f) (currentTime - 20)", target))
            await engine.seek(to: target)
        }
        // #433: a seek PAST the produced window, so the landing needs a producer restart rather than
        // cached output. Paired with an origin outage, this is the reported discriminator: the restart
        // finds the old pump parked in its reconnect ladder, aborts it, and serves the rest of the
        // session from a reader the phase axis has never heard from.
        if tick == seekFarTick {
            // Past `bufferedPosition`, not merely ahead of the playhead: the producer runs tens of
            // seconds ahead, and a seek INTO its cache lands without restarting anything.
            let target = max(engine.bufferedPosition + 60, engine.duration * 0.85)
            print(String(format: "  HOSTCALL seek(to: %.2f) (past bufferedPosition %.2f, so the landing needs a producer restart)",
                         target, engine.bufferedPosition))
            await engine.seek(to: target)
        }
        if hostCalls.contains("seekback"), tick == 30 {
            print("  HOSTCALL seekToLiveEdge()")
            await engine.seekToLiveEdge()
        }
        // AE#479: a scrub that lands PAUSED. The SW pump parks in its pause wait and hears of the seek
        // only at play(), so whatever the 1 Hz `[SWDiag]` line reports for the five paused ticks after
        // the landing comes from state the seek path itself had to keep honest. `--seek-pattern`'s
        // first entry picks the target, else 20 s ahead.
        // Sodalite#104: what a live session does while it is PAUSED for longer than its DVR window.
        //
        // The question a host has to answer is whether pausing keeps recording, and what happens when
        // the recording reaches the depth the session asked for: a producer that parks stops draining
        // the origin, and a window that slides instead walks past the position the viewer is parked
        // on. Neither is reachable from a device in less than the buffer depth, which is ninety
        // minutes on a real session; with `--dvr-window 30` it is a ninety second run.
        //
        // Pauses at t=10 and resumes ten seconds before the end, so the run covers the fill, whatever
        // the engine does at the cap, and the return.
        if hostCalls.contains("pausehold") {
            if tick == 10 {
                print("  HOSTCALL pause() and HOLD (resumes at t=\(max(11, ticks - 10)))")
                engine.pause()
                pauseHoldPlayhead = engine.currentTime
            }
            if tick > 10, tick < max(11, ticks - 10) {
                let range = engine.clock.seekableLiveRange
                print(String(format:
                    "    PAUSEHOLD t=%02d playhead=%.2f (moved %+.2f) edge=%.2f window=%@ resident=%.1fs",
                    tick, engine.currentTime, engine.currentTime - (pauseHoldPlayhead ?? 0),
                    engine.clock.liveEdgeTime,
                    range.map { String(format: "%.1f...%.1f", $0.lowerBound, $0.upperBound) } ?? "none",
                    range.map { $0.upperBound - $0.lowerBound } ?? 0))
            }
            if tick == max(11, ticks - 10) {
                let held = engine.currentTime
                print(String(format: "  HOSTCALL play() after the hold (playhead %.2f, moved %+.2f while paused)",
                             held, held - (pauseHoldPlayhead ?? 0)))
                engine.play()
            }
        }
        // AE#549: stop the master clock behind the host's back at tick 4, the way an interrupted audio
        // session does, then let a plain play() try to bring it back. The interruption itself cannot be
        // staged on macOS; its outcome can.
        if hostCalls.contains("stallclock") {
            if tick == 4 {
                stallClockStalled = engine.stallRendererClockForTesting()
                stallClockAtStall = engine.currentTime
                print(String(format: "  HOSTCALL AE#549 stopped the master clock behind the host's back at %.2f%@",
                             engine.currentTime,
                             stallClockStalled ? "" : " -- NO renderer clock on this backend"))
            }
            if tick == 6 { stallClockBeforeResume = engine.currentTime }
            if tick == 7 {
                print(String(format: "  HOSTCALL play() on the stalled clock (playhead %.2f, rate %.2f)",
                             engine.currentTime, engine.rendererClockRateForTesting ?? -1))
                engine.play()
            }
            if tick >= 9 { stallClockAtEnd = engine.currentTime }
        }
        if hostCalls.contains("pausestart"), tick == 8 {
            print(String(format: "  HOSTCALL play() after the start pause (playhead %.2f)", engine.currentTime))
            engine.play()
        }
        if hostCalls.contains("pauseseek") {
            if tick == 12 {
                print("  HOSTCALL pause()")
                engine.pause()
            }
            if tick == 15 {
                let target = seekPattern.first ?? min(engine.currentTime + 20, engine.duration * 0.9)
                print(String(format: "  HOSTCALL seek(to: %.2f) while paused (stays paused until tick 20)", target))
                await engine.seek(to: target)
                print(String(format: "  SEEKLANDED target=%.2f (clock=%.2f, state=%@)",
                             target, engine.currentTime, String(describing: engine.state)))
            }
            if tick == 20 {
                print("  HOSTCALL play()")
                engine.play()
            }
        }
        // #292: three transport calls that can land inside a seek's reposition window. A is the
        // reported case (a scrub arriving as two same-target seeks, the second superseding the first);
        // B and C are its siblings, a pause and a play issued while the reposition is still running.
        if hostCalls.contains("overlapseek"), tick == 8 {
            let targetA = engine.duration * 0.25
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "A superseded scrub while playing", target: targetA,
                startPlaying: true, expectPlaying: true,
                extraPrecondition: { supersededSeeks.value > 0 },
                duringReposition: { await engine.seek(to: targetA) }))

            let targetB = engine.duration * 0.45
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "B pause during the reposition", target: targetB,
                startPlaying: true, expectPlaying: false,
                duringReposition: { engine.pause() }))
            // The report's manual workaround: play() after the landing must resume from the target.
            let clockBeforeResume = engine.currentTime
            engine.play()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let resumed = engine.currentTime - clockBeforeResume
            print(String(format: "    B resume: play() advanced the clock %+.2fs in 2s", resumed))
            if resumed < 0.5 { overlapVerdicts.append("FAIL B resume: play() did not restart the clock") }

            let targetC = engine.duration * 0.65
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "C play during the reposition", target: targetC,
                startPlaying: false, expectPlaying: true,
                duringReposition: { engine.play() }))
        }
        // #220 repro affordance: a periodic short backward seek drives the subtitle drain
        // through .resetAndDecode and re-anchors the #151 forward prefetcher, the churn a
        // rebuffering remote source produces on its own. Steady-state runs cannot reach it.
        if let seekEvery, seekEvery > 0, tick > 10, Double(tick).truncatingRemainder(dividingBy: seekEvery) == 0,
           seekLandings.count < (seekCount ?? .max) {
            // #240: `--seek-pattern` walks a list of absolute targets instead of the short
            // backward hop, because the two exercise different machinery. A 6 s rewind lands in
            // the segment cache and never restarts the producer; a far seek restarts it, and the
            // landing budget it then runs against is what the #240 report is about. The elapsed
            // time is printed per seek, which is the number under test.
            let target: Double
            if !seekPattern.isEmpty {
                target = seekPattern[seekPatternIndex % seekPattern.count]
                seekPatternIndex += 1
            } else {
                target = max(0, engine.currentTime - 6)
            }
            print(String(format: "  SEEKCHURN seek(to: %.2f)", target))
            presentProbe?.beginDiscontinuity()
            let began = DispatchTime.now()
            await engine.seek(to: target)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e6
            seekLandings.append(ms)
            presentProbe?.endDiscontinuity()
            print(String(format: "  SEEKLANDED target=%.2f in %.0fms (clock=%.2f)",
                         target, ms, engine.currentTime))
        }
        // Give the session a few seconds to settle before activating subtitles,
        // mirroring a user picking a track from the menu.
        if let subsPick, !subsSelected, tick >= 5 {
            let match: TrackInfo?
            if let wanted = Int(subsPick) {
                match = engine.subtitleTracks.first { $0.id == wanted }
            } else {
                match = engine.subtitleTracks.first {
                    $0.codec.localizedCaseInsensitiveContains(subsPick)
                        || ($0.language?.localizedCaseInsensitiveContains(subsPick) ?? false)
                }
            }
            if let match {
                print("  SELECT subtitle id=\(match.id) codec=\(match.codec) lang=\(match.language ?? "?")")
                engine.selectSubtitleTrack(index: match.id)
                subsSelected = true
            } else if tick == 5 {
                print("  SELECT subtitle: no track matching '\(subsPick)' (have: \(engine.subtitleTracks.map(\.codec).joined(separator: ", ")))")
            }
        }

        // Sodalite#156. The readout is taken a tick AFTER each transition, not inside it: both calls
        // finish their work on a detached MainActor task (the select waits on a cue pre-fill first),
        // so reading immediately would report the state the host asked for rather than the one the
        // item ended up in, which is the whole distinction this harness exists to make.
        // Sodalite#156: what the host does when the picture leaves its own layer. Without this the
        // renditions are merely SERVED and nothing ever holds a legible selection, which is the state
        // the first version of this harness measured and mistook for a result.
        if let t = nativeRenderTick, tick == t {
            print("  HOSTCALL setNativeSubtitleRendering(true)")
            engine.setNativeSubtitleRendering(true)
        }
        if let t = nativeRenderTick, tick == t + 2 { await reportLegibleSelection(engine, "after render on") }
        if let subsOffTick, tick == subsOffTick {
            print("  HOSTCALL subtitles off")
            engine.clearSubtitle()
        }
        if let subsOnTick, tick == subsOnTick, let wanted = subsOnLang ?? subsPick,
           let match = engine.subtitleTracks.first(where: {
               $0.codec.localizedCaseInsensitiveContains(wanted)
                   || ($0.language?.localizedCaseInsensitiveContains(wanted) ?? false)
           }) {
            print("  HOSTCALL subtitles on id=\(match.id)")
            engine.selectSubtitleTrack(index: match.id)
        }
        // Four ticks, not one. A deselect is one hop, but a SELECT waits on the cue pre-fill that
        // exists so AVPlayer fetches a populated rendition instead of racing the reader, and that is
        // seconds rather than a runloop turn. Reading at +1 caught the off correctly and reported
        // every on as a failure, which is the harness lying in the more expensive direction.
        if let t = subsOffTick, tick == t + 1 { await reportLegibleSelection(engine, "after off") }
        if let t = subsOnTick, tick == t + 4 { await reportLegibleSelection(engine, "after on") }
    }

    let finalTime = engine.currentTime
    let endState = engine.state
    // #316: the settled list, after any late rendition discovery. Read it rather than the load-time
    // one when the question is what a host's picker ends up showing.
    let finalSubtitleTracks = engine.subtitleTracks
    let finalActiveSubtitle = engine.activeSubtitleTrackIndex
    if record != nil {
        await engine.stopRecording()
        print("  RECORD final state: \(engine.recordingState)")
    }
    let recordingState = engine.recordingState
    engine.stop()
    tapTask?.cancel()
    print("")
    print("=== PLAY RESULT ===")
    if !seekLandings.isEmpty {
        let sorted = seekLandings.sorted()
        print(String(format: "seek landings: n=%d min=%.0fms median=%.0fms max=%.0fms (%@)",
                     sorted.count, sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1],
                     sorted.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
    }
    if let monitor {
        print("audio continuity: \(monitor.summary)")
    }
    if let presentProbe {
        presentProbe.stop()
        let p = presentProbe.summary()
        print(String(format: "presented frames: total=%d perSecond min/median/max=%d/%d/%d largestGap=%.3fs at %.3fs",
                     p.total, p.min, p.median, p.max, p.largestGap, p.gapAt))
    }
    if let frameProbe {
        print("frame times: \(frameProbe.summary())")
        // #353: coded next to settled. Equal on square-pixel sources, and on anamorphic content the
        // gap is exactly what a host laying out against `sourceVideoWidth` would have got wrong.
        if let size = observedDisplaySize {
            print("display size: \(Int(size.width))x\(Int(size.height)) "
                  + "(coded \(observedCodedSize.0)x\(observedCodedSize.1))")
        } else {
            print("display size: never published (not the software path, or no frame built)")
        }
    }
    if !finalSubtitleTracks.isEmpty {
        let listed = finalSubtitleTracks
            .map { "#\($0.id) \($0.name)(\($0.language ?? "?"))\($0.isExternal ? "*" : "")" }
            .joined(separator: ", ")
        print("subtitle tracks (* = external): \(listed)")
        print("active subtitle: \(finalActiveSubtitle.map(String.init) ?? "none")")
    }
    print("final t=\(String(format: "%.2f", finalTime))s state=\(String(describing: endState)) cues=\(cueCount)")
    let closingWindow = await MainActor.run { lastCues }
    print("WINDOW \(closingWindow.count) cues in the last published window")
    for cue in closingWindow {
        print(String(format: "  HELD #%d %.2f-%.2f", cue.id, cue.startTime, cue.endTime))
    }
    if case .error(let message) = endState {
        print("VERDICT: session ended in error: \(message)")
        return 2
    }
    if hostCalls.contains("still") {
        print("#544 scrub stills: \(stillHits) of \(stillAttempts) hit")
        if stillAttempts == 0 {
            print("VERDICT: #544 drill inconclusive (session ended before the first still tick)")
            return 5
        }
        if stillHits == 0 {
            print("VERDICT: #544 reproduced (the live scrub preview has no frame to show)")
            return 6
        }
    }
    if hostCalls.contains("ratehold") {
        let observed = rateHoldAfterResume
        print(String(format: "#436 rate hold: requested %.2f, transport reported %.2f after the resume",
                     Issue436RateHold.rate, observed ?? -1))
        guard let observed else {
            print("VERDICT: #436 drill inconclusive (session ended before the resume tick)")
            return 5
        }
        if abs(observed - Issue436RateHold.rate) > 0.01 {
            print("VERDICT: #436 reproduced (the resume discarded the rate)")
            return 4
        }
        if let atEnd = rateHoldAtEnd, abs(atEnd - Issue436RateHold.rate) > 0.01 {
            print(String(format: "VERDICT: #436 held across the resume but lost later (%.2f at the last tick); "
                         + "a rebuild in between dropped it", atEnd))
            return 4
        }
    }
    if hostCalls.contains("stallclock") {
        guard stallClockStalled, let atStall = stallClockAtStall,
              let beforeResume = stallClockBeforeResume, let atEnd = stallClockAtEnd else {
            print("VERDICT: AE#549 drill inconclusive (no renderer clock to stall, "
                  + "or the session ended before the resume)")
            return 5
        }
        print(String(format: "AE#549 stalled clock: %.2f at the stall, %.2f before the resume, %.2f at the last tick",
                     atStall, beforeResume, atEnd))
        if beforeResume > atStall + 0.25 {
            print("VERDICT: AE#549 drill inconclusive (the clock kept running through the stall)")
            return 5
        }
        if atEnd <= beforeResume + 0.25 {
            print("VERDICT: AE#549 reproduced (play() could not restart a clock the host did not stop)")
            return 4
        }
    }
    if hostCalls.contains("overlapseek") {
        print("#292 seek-window drills:")
        for verdict in overlapVerdicts { print("  \(verdict)") }
        if overlapVerdicts.isEmpty { print("  not run (session ended before tick 8)") }
        if overlapVerdicts.contains(where: { $0.hasPrefix("FAIL") }) {
            print("VERDICT: #292 reproduced (the seek window swallowed a transport call)")
            return 4
        }
        if overlapVerdicts.isEmpty || overlapVerdicts.contains(where: { $0.hasPrefix("INCONCLUSIVE") }) {
            print("VERDICT: #292 drill inconclusive; widen the reposition window (--throttle-kbps, remote source)")
            return 5
        }
    }
    if finalTime <= 3.0 {
        if let audioSwitch {
            // #337: the wedge signature. state stays .playing with a first frame on screen, so the
            // only thing that separates it from a healthy session is this clock.
            print("VERDICT: clock never left \(String(format: "%.2f", finalTime))s after "
                  + "selectAudioTrack(index: \(audioSwitch.index)) at +\(audioSwitch.delayMilliseconds) ms "
                  + "(state=\(String(describing: endState))); the rebuilt session never armed its clock")
            return 2
        }
        print("VERDICT: clock did not advance (t=\(String(format: "%.2f", finalTime))s); transport stalled after load")
        return 2
    }
    if let audioSwitch {
        print("audio switch: index=\(audioSwitch.index) at +\(audioSwitch.delayMilliseconds) ms, "
              + "clock reached \(String(format: "%.2f", finalTime))s")
    }
    if subsPick != nil && !subsSelected {
        print("VERDICT: playback OK but requested subtitle track was never found")
        return 3
    }
    if subsPick != nil && cueCount == 0 {
        print("VERDICT: playback OK, subtitle track selected, but no cues arrived")
        return 3
    }
    // AE#560: same shape as the subtitle verdicts above. A requested capability that produces
    // nothing is a failure the harness can check, not a green run someone has to read the log for.
    if recordingRefused {
        print("VERDICT: playback OK but the requested recording was refused")
        return 3
    }
    if let record {
        switch recordingState {
        case .failed(let failure):
            print("VERDICT: playback OK but the recording failed: \(failure)")
            return 3
        case .ended, .recording, .idle:
            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: record.path)[.size] as? Int64) ?? nil
            guard let bytes, bytes > 0 else {
                print("VERDICT: playback OK but the recording produced no bytes")
                return 3
            }
            print("recording: \(bytes) B at \(record.path)")
        }
    }
    print("VERDICT: OK")
    return 0
}


/// #436: reading the rate back off the transport, whichever one is serving. The native paths run an
/// AVPlayer; the software paths run their own synchronizer, and its timebase is the only place their
/// effective rate exists. Neither is a value the engine caches, which is what makes the drill's
/// answer worth having.
enum Issue436RateHold {
    static let rate: Float = 1.5

    @MainActor
    static func observedRate(_ engine: AetherEngine) -> Float {
        if let player = engine.currentAVPlayer { return player.rate }
        if let timebase = engine.softwarePresentationTimebase {
            return Float(CMTimebaseGetRate(timebase))
        }
        return -1
    }
}

/// Sodalite#156: what the item's legible media selection actually holds right now.
///
/// This is the observable the native rendition path never had from the CLI. `nativeSubtitleTracks`
/// and `activeSubtitleTrackIndex` say what the ENGINE thinks; the legible selection is what an
/// AVPlayer, and therefore an AirPlay receiver, renders. Those two came apart in the field report:
/// the readers had been cancelled while the receiver was still fetching the rendition it had been
/// handed, which is a caption box with nothing in it.
@MainActor
private func reportLegibleSelection(_ engine: AetherEngine, _ label: String) async {
    guard let item = engine.currentAVPlayer?.currentItem else {
        print("  LEGIBLE \(label): no item")
        return
    }
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
        print("  LEGIBLE \(label): no legible group")
        return
    }
    let selection = item.currentMediaSelection.selectedMediaOption(in: group)
    let name = selection.map { $0.displayName } ?? "none"
    print("  LEGIBLE \(label): selected=\(name) options=\(group.options.count) "
          + "engineActive=\(engine.activeSubtitleTrackIndex.map(String.init) ?? "nil")")
}
