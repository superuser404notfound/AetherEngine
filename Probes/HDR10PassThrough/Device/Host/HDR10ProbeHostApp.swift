import AetherEngine
import AVFoundation
import AVKit
import SwiftUI
import UIKit

// Device harness for the HDR10 pass-through check (see ../../README.md). It plays the pattern clip arm by
// arm, so the television's HDR info screen can be read for each one: whose metadata arrived, the clip's
// own (1000 nit, MaxCLL 1000 / MaxFALL 400) or the engine probe's (777 nit, 345 / 123).
//
// Arms come from the environment variable `HDR10_ARMS`, which `devicectl device process launch
// --environment-variables` delivers to an app process:
//
//   HDR10_ARMS="label|mode|url[|secs=45],label|mode|url,..."
//
// Modes:
// - `avplayer`: plain AVPlayer + AVPlayerLayer, Apple's own path (the reference).
// - `native`: AetherEngine as a host uses it, default routing (the native AVPlayer route for this clip).
// - `software`, `meta`, `chain`, `chainmeta`: AetherEngine on the software path
//   (`preferredDecodePath: .software`) with `AETHER_HDR10_PROBE` set to `log`, `meta`, `chain` and
//   `chain+meta`. The engine reads the variable at each load, so the harness sets it before each arm.

@main
struct HDR10ProbeHostApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

private struct RootView: View {
    var body: some View {
        if let arms = ProbeArm.fromEnvironment() {
            ProbeHarnessView(arms: arms)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Text("HDR10 pass-through host").font(.title2)
                Text("No HDR10_ARMS in the environment.").font(.title3)
                Text("Launch it with Scripts/run_tv.sh, or set HDR10_ARMS in the Xcode scheme.")
                    .foregroundStyle(.secondary)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct ProbeArm {
    let label: String
    let mode: String
    let url: URL
    let seconds: Double

    /// The probe mode each engine arm sets, nil for an arm that leaves the variable unset.
    var probeMode: String? {
        switch mode {
        case "software": "log"
        case "meta": "meta"
        case "chain": "chain"
        case "chainmeta": "chain+meta"
        default: nil
        }
    }

    /// What the television's HDR info screen should show if the metadata on this arm reaches it.
    var expectation: String {
        switch mode {
        case "meta", "chainmeta": "expect 777 nit, MaxCLL 345, MaxFALL 123 (the probe's)"
        default: "expect 1000 nit, MaxCLL 1000, MaxFALL 400 (the clip's)"
        }
    }

    static func fromEnvironment() -> [ProbeArm]? {
        guard let raw = ProcessInfo.processInfo.environment["HDR10_ARMS"] else { return nil }
        let arms = raw.split(separator: ",").compactMap { item -> ProbeArm? in
            let parts = item.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 3, let url = URL(string: parts[2]) else { return nil }
            var seconds = 45.0
            if parts.count == 4, parts[3].hasPrefix("secs="), let s = Double(parts[3].dropFirst(5)) { seconds = s }
            return ProbeArm(label: parts[0], mode: parts[1], url: url, seconds: seconds)
        }
        return arms.isEmpty ? nil : arms
    }
}

struct ProbeHarnessView: View {
    let arms: [ProbeArm]
    @State private var engine: AetherEngine?
    @State private var slate: [String] = []
    @State private var corner = ""
    @State private var host = ProbeHostView()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ProbeHostRepresentable(host: host).ignoresSafeArea()
            if let engine {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
            }
            if !corner.isEmpty {
                Text(corner).font(.system(size: 28, weight: .semibold)).foregroundColor(.gray).padding(40)
            }
            if !slate.isEmpty {
                VStack(spacing: 30) {
                    ForEach(Array(slate.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: i == 0 ? 140 : 48, weight: i == 0 ? .heavy : .regular))
                            .foregroundColor(i == 0 ? .white : .gray)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        .task { await run() }
    }

    @MainActor
    private func run() async {
        let started = Date()
        let say: @Sendable (String) -> Void = { s in
            let line = String(format: "[HDR10Host] t=%.1f %@", Date().timeIntervalSince(started), s)
            print(line)
            fflush(stdout)
            ProbeLog.shared.note(line)
        }
        EngineLog.handler = { line in
            ProbeLog.shared.note(line)
            print(line)
            fflush(stdout)
        }
        say("sequence: " + arms.map { "\($0.label)(\($0.mode))" }.joined(separator: " "))
        for (n, arm) in arms.enumerated() {
            slate = ["\(n + 1)/\(arms.count)  \(arm.label)", arm.mode, arm.expectation]
            host.window?.avDisplayManager.preferredDisplayCriteria = nil
            say("slate \(arm.label)")
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            slate = []
            corner = "\(arm.label) \(arm.mode)"
            say("arm \(arm.label) start mode=\(arm.mode) url=\(arm.url.lastPathComponent) secs=\(Int(arm.seconds))")
            switch arm.mode {
            case "avplayer":
                await host.playAVPlayer(arm.url, seconds: arm.seconds, log: say)
            case "native", "software", "meta", "chain", "chainmeta":
                await playEngine(arm, log: say)
            default:
                say("unknown mode \(arm.mode), skipped")
            }
            corner = ""
            say("arm \(arm.label) end")
        }
        unsetenv("AETHER_HDR10_PROBE")
        slate = ["done"]
        host.window?.avDisplayManager.preferredDisplayCriteria = nil
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        say("sequence done")
        exit(0)
    }

    @MainActor
    private func playEngine(_ arm: ProbeArm, log: @Sendable (String) -> Void) async {
        if let probe = arm.probeMode {
            setenv("AETHER_HDR10_PROBE", probe, 1)
        } else {
            unsetenv("AETHER_HDR10_PROBE")
        }
        guard let e = try? AetherEngine() else { log("engine init failed"); return }
        engine = e
        var options = LoadOptions()
        if arm.mode != "native" { options.preferredDecodePath = .software }
        do {
            try await e.load(url: arm.url, startPosition: nil, options: options, audioSourceStreamIndex: nil)
            e.play()
        } catch {
            log("engine load failed: \(error)")
            engine = nil
            return
        }
        let deadline = Date().addingTimeInterval(arm.seconds)
        while Date() < deadline, e.state != .ended {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let dropped = e.liveTelemetry?.droppedFrameCount ?? -1
        log(String(format: "summary %@: route=%@ state=%@ played=%.1fs droppedFrames=%d",
                   arm.label, e.videoRoute.rawValue, "\(e.state)", e.currentTime, dropped))
        e.stop()
        engine = nil
        unsetenv("AETHER_HDR10_PROBE")
    }
}

/// The AVPlayer arm: Apple's own path, with display criteria requested from the track the way
/// AVPlayerViewController would.
final class ProbeHostView: UIView {

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }

    @MainActor
    func playAVPlayer(_ url: URL, seconds: Double, log: @escaping @Sendable (String) -> Void) async {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        window?.avDisplayManager.preferredDisplayCriteria = item.asset.preferredDisplayCriteria
        let pl = AVPlayerLayer(player: player)
        pl.frame = bounds
        pl.videoGravity = .resizeAspect
        layer.addSublayer(pl)
        player.play()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, item.status != .failed {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log(String(format: "summary avplayer: status=%d error=%@ played=%.1fs", item.status.rawValue,
                   String(describing: item.error), player.currentTime().seconds))
        player.pause()
        pl.removeFromSuperlayer()
    }
}

private struct ProbeHostRepresentable: UIViewRepresentable {
    let host: ProbeHostView
    func makeUIView(context: Context) -> ProbeHostView { host }
    func updateUIView(_ uiView: ProbeHostView, context: Context) {}
}

/// Every line the harness and the engine print also lands in `Library/Caches/hdr10-log.txt`, which
/// `devicectl device copy from` pulls after a run. Truncated at launch.
final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()

    private let queue = DispatchQueue(label: "hdr10.log")
    private let handle: FileHandle?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("hdr10-log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func note(_ line: String) {
        queue.async { [handle] in
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }
}
