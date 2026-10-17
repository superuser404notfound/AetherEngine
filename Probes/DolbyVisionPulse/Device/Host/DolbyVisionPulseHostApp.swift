import AetherEngine
import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

// Device harness for the Dolby Vision pulse test (see ../../README.md). Every arm plays a clip whose
// pixels are constant while only the RPU (or, for the EL clip, only the residual) switches, so a
// camera pointed at the television can tell whether the metadata reached the panel.
//
// Arms come from the environment variable `PULSE_ARMS`, which `devicectl device process launch
// --environment-variables` does deliver to an app process:
//
//   PULSE_ARMS="label|mode|url[|k=v;k=v],label|mode|url,..."
//
// Arms play back to back with a 5 s slate naming the arm in between, so one phone recording covers
// the whole sequence. Modes:
//
// - `avplayer`: plain AVPlayer + AVPlayerLayer on the file (Apple's own path, the positive control).
// - `vt`: AVAssetReader (VideoToolbox) output straight into AVSampleBufferDisplayLayer, with the
//   attachments VideoToolbox set.
// - `vtcopy`: as `vt`, but every frame copied into a buffer from our own IOSurface pool, with all of
//   VideoToolbox's propagated attachments (Dolby Vision RPU included) copied across byte for byte.
// - `vtstrip`: as `vtcopy`, without `DolbyVisionRPUData` / `DolbyCompatibilityID`.
// - `engine`: AetherEngine with `preferDualLayerDolbyVision: true` (a Profile 7 FEL clip takes the
//   dual-layer route).
// - `enginenofel`: as `engine` with `preferDualLayerDolbyVision: false` (native 8.1 route, EL dropped).
// - `soak`: `engine` for `minutes=` with a `seeks=at@to,...` schedule, sampled once a second, ending in
//   one `soak summary` line.
//
// The VT modes request Dolby Vision display criteria from the track's own format description, as an
// app on this path would.

@main
struct DolbyVisionPulseHostApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    // About eleven minutes of playback, partly not AVPlayer: keep the screensaver away.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

private struct RootView: View {
    var body: some View {
        if let arms = PulseArm.fromEnvironment() {
            PulseHarnessView(arms: arms)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dolby Vision pulse host").font(.title2)
                Text("No PULSE_ARMS in the environment.").font(.title3)
                Text("""
                    Launch with devicectl device process launch --environment-variables \
                    '{"PULSE_ARMS":"label|mode|url,..."}'. Scripts/run_tv.sh does it.
                    """)
                    .foregroundStyle(.secondary)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct PulseArm {
    let label: String
    let mode: String
    let url: URL
    /// Optional 4th field, `key=value;key=value` (soak: `minutes=5;seeks=60@1800,150@600`).
    let params: [String: String]

    static func fromEnvironment() -> [PulseArm]? {
        guard let raw = ProcessInfo.processInfo.environment["PULSE_ARMS"] else { return nil }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [PulseArm]? {
        // Arms are comma separated, but a soak's `seeks=` list contains commas too: a new arm starts
        // only at a piece shaped `label|mode|...`, anything else belongs to the previous arm's params.
        var items: [String] = []
        for piece in raw.split(separator: ",", omittingEmptySubsequences: true).map(String.init) {
            if piece.contains("|") || items.isEmpty { items.append(piece) } else { items[items.count - 1] += "," + piece }
        }
        let arms = items.compactMap { item -> PulseArm? in
            let parts = item.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 3, let url = URL(string: parts[2]) else { return nil }
            var params: [String: String] = [:]
            if parts.count == 4 {
                for kv in parts[3].split(separator: ";") {
                    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    if p.count == 2 { params[p[0]] = p[1] }
                }
            }
            return PulseArm(label: parts[0], mode: parts[1], url: url, params: params)
        }
        return arms.isEmpty ? nil : arms
    }
}

struct PulseHarnessView: View {
    let arms: [PulseArm]
    @State private var engine: AetherEngine?
    @State private var slate: String = ""
    @State private var host = PulseHostView()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PulseHostRepresentable(host: host).ignoresSafeArea()
            if let engine {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
            }
            if !slate.isEmpty {
                VStack(spacing: 30) {
                    Text(slate).font(.system(size: 160, weight: .heavy)).foregroundColor(.white)
                    // Live UTC clock: one readable slate frame pins the video time to wall time.
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        Text(Self.clock(ctx.date))
                            .font(.system(size: 96, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    Text("dv-pulse").font(.system(size: 48)).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        .task { await run() }
    }

    private static func clock(_ d: Date) -> String {
        let s = d.timeIntervalSince1970
        let day = s.truncatingRemainder(dividingBy: 86400)
        return String(format: "%02d:%02d:%04.1f UTC", Int(day / 3600), Int(day / 60) % 60,
                      day.truncatingRemainder(dividingBy: 60))
    }

    @MainActor
    private func run() async {
        EngineLog.handler = { line in
            PulseLog.shared.note(line)
            print(line)
            fflush(stdout)
        }
        let started = Date()
        // Wall-clock epoch seconds on every line, so the phone video (whose creation date and the
        // slate clock give its own wall-clock start) can be cut per arm afterwards.
        let say: @Sendable (String) -> Void = { s in
            let now = Date()
            let line = String(format: "[Pulse] wall=%.3f t=%.1f %@", now.timeIntervalSince1970,
                              now.timeIntervalSince(started), s)
            print(line)
            fflush(stdout)
            PulseLog.shared.note(line)
        }
        say("sequence: " + arms.map { "\($0.label)(\($0.mode))" }.joined(separator: " "))
        // Without the trait the engine accepts preferDualLayerDolbyVision and plays the native route, so
        // every `engine` and `soak` arm would film the wrong thing. Refuse the whole sequence instead.
        if arms.contains(where: { $0.mode == "engine" || $0.mode == "soak" }),
           !AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn {
            slate = "AetherEngine was built without the DualLayerDolbyVision trait"
            say("ERROR: the engine and soak arms need AetherEngine's DualLayerDolbyVision trait, which this "
                + "build lacks (PulseEngine/Package.swift sets it); refusing the sequence")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            exit(70)
        }
        for (n, arm) in arms.enumerated() {
            slate = "\(n + 1)/\(arms.count)  \(arm.label)"
            host.window?.avDisplayManager.preferredDisplayCriteria = nil
            say("slate \(arm.label)")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            slate = ""
            say("arm \(arm.label) start mode=\(arm.mode) url=\(arm.url.lastPathComponent)")
            switch arm.mode {
            case "avplayer":
                await host.playAVPlayer(arm.url, log: say)
            case "vt", "vtcopy", "vtstrip":
                await host.playVT(arm.url, mode: arm.mode, log: say)
            case "engine":
                await playEngine(arm.url, fel: true, log: say)
            case "enginenofel":
                await playEngine(arm.url, fel: false, log: say)
            case "soak":
                await playSoak(arm, log: say)
            default:
                say("unknown mode \(arm.mode), skipped")
            }
            say("arm \(arm.label) end")
        }
        slate = "done"
        host.window?.avDisplayManager.preferredDisplayCriteria = nil
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        say("sequence done")
        exit(0)
    }

    @MainActor
    private func playEngine(_ url: URL, fel: Bool, log: @Sendable (String) -> Void) async {
        guard let e = try? AetherEngine() else { log("engine init failed"); return }
        engine = e
        do {
            try await e.load(url: url, startPosition: nil,
                             options: LoadOptions(dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: fel,
                                                  audioBridgeMode: .surroundCompat),
                             audioSourceStreamIndex: nil)
            e.play()
        } catch {
            log("engine load failed: \(error)")
            engine = nil
            return
        }
        let deadline = Date().addingTimeInterval(80)
        while Date() < deadline, e.state != .ended {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("engine state=\(e.state) t=\(e.currentTime)")
        e.stop()
        engine = nil
    }

    /// Long-run FEL playback with a seek schedule. Measures only what the engine exposes publicly:
    /// - droppedFrames: `liveTelemetry.droppedFrameCount` (render synchronizer's dropped frames on the
    ///   software path, session total; nil reads as -1).
    /// - composeFailures: sum of `composeFailures=` over the engine's `[DualLayerVideoDecoder] summary`
    ///   lines (seen through EngineLog.handler; the counter itself is internal). The engine writes that
    ///   line every second at `.verbose`, which never reaches the handler, and at the default level only
    ///   for a second that counted a failure, so the sum is exact. Stays 0 if the FEL route never ran,
    ///   so `route=` is the thing to check first.
    /// - footprint: task_vm_info phys_footprint, sampled each second.
    @MainActor
    private func playSoak(_ arm: PulseArm, log: @Sendable (String) -> Void) async {
        let minutes = arm.params["minutes"].flatMap(Double.init) ?? 5
        var seeks: [(at: Double, to: Double)] = []
        for item in (arm.params["seeks"] ?? "").split(separator: ",") {
            let p = item.split(separator: "@")
            if p.count == 2, let at = Double(p[0]), let to = Double(p[1]) { seeks.append((at, to)) }
        }
        seeks.sort { $0.at < $1.at }
        let tally = SoakTally()
        let previous = EngineLog.handler
        EngineLog.handler = { line in
            previous?(line)
            tally.ingest(line)
        }
        defer { EngineLog.handler = previous }
        guard let e = try? AetherEngine() else { log("engine init failed"); return }
        engine = e
        do {
            try await e.load(url: arm.url, startPosition: nil,
                             options: LoadOptions(dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: true,
                                                  audioBridgeMode: .surroundCompat),
                             audioSourceStreamIndex: nil)
            e.play()
        } catch {
            log("engine load failed: \(error)")
            engine = nil
            return
        }
        log("soak start minutes=\(minutes) seeks=\(seeks.count)")
        let started = Date()
        let deadline = started.addingTimeInterval(minutes * 60)
        var peak = Self.footprintMB()
        var played = 0.0
        var nSeeks = 0
        var lastTick = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = Date()
            if e.state == .playing { played += now.timeIntervalSince(lastTick) }
            lastTick = now
            peak = max(peak, Self.footprintMB())
            if let next = seeks.first, now.timeIntervalSince(started) >= next.at {
                seeks.removeFirst()
                nSeeks += 1
                await e.seek(to: next.to)
                log(String(format: "seek to=%.1f landed=%.1f", next.to, e.currentTime))
                lastTick = Date()
            }
            if e.state == .ended { log("soak ended early"); break }
        }
        let dropped = e.liveTelemetry?.droppedFrameCount ?? -1
        let route = tally.sawDualLayer ? "FEL" : "\(e.videoRoute.rawValue)-noDualLayerSummary"
        log(String(format: "soak summary: played=%.0fs seeks=%d droppedFrames=%d composeFailures=%d peakFootprintMB=%d endFootprintMB=%d route=%@",
                   played, nSeeks, dropped, tally.composeFailures, peak, Self.footprintMB(), route))
        e.stop()
        engine = nil
    }

    /// `phys_footprint` (what jetsam judges), MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1024 / 1024) : -1
    }
}

/// Accumulates the engine's `[DualLayerVideoDecoder] summary: ... composeFailures=N ...` lines (per-second
/// deltas; only the seconds with a failure reach the handler). The FEL route is recognised by its
/// open-time line, since a healthy summary does not reach the handler.
private final class SoakTally: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var seen = false
    var composeFailures: Int { lock.lock(); defer { lock.unlock() }; return failures }
    var sawDualLayer: Bool { lock.lock(); defer { lock.unlock() }; return seen }
    func ingest(_ line: String) {
        if line.contains("[DualLayerVideoDecoder] FEL stream detected") {
            lock.lock(); seen = true; lock.unlock()
            return
        }
        guard line.contains("[DualLayerVideoDecoder] summary:") else { return }
        lock.lock(); defer { lock.unlock() }
        seen = true
        if let r = line.range(of: "composeFailures="),
           let n = Int(line[r.upperBound...].prefix { $0.isNumber }) { failures += n }
    }
}

private struct PulseHostRepresentable: UIViewRepresentable {
    let host: PulseHostView
    func makeUIView(context: Context) -> PulseHostView { host }
    func updateUIView(_ uiView: PulseHostView, context: Context) {}
}
