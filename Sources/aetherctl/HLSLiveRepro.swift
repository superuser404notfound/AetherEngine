import Foundation
import AetherEngine

// hlslive: faithful SSAI repro. Serves a list of REAL .ts segment files
// (content, ad, content, ...) as a sliding live HLS window WITHOUT any
// timestamp rewriting (unlike LiveFixture), marks the content↔ad seams
// with EXT-X-DISCONTINUITY, then drives the actual HLSLiveIngestReader →
// engine.load(source: .custom, isLive) path — exactly Sodalite's direct
// live path. Prints the engine's segment-finalize activity so a wedged
// cutter (SSAI PID switch) is visible as "no new seg-N for a while".
//
//   aetherctl hlslive --segments content.ts,ad.ts,content.ts \
//                     [--disc 1,2] [--seconds 40] [--segment-seconds 5]
//
// --disc lists which segment indices (into --segments) carry a leading
// EXT-X-DISCONTINUITY. Default: every segment whose file differs from the
// previous one.

func runHLSLiveRepro(args: [String]) -> Int32 {
    var rest = args
    guard let segList = takeStringFlag("--segments", from: &rest) else {
        print("ERROR: hlslive requires --segments a.ts,b.ts,c.ts")
        return 64
    }
    let paths = segList.split(separator: ",").map(String.init)
    let seconds = takeIntFlag("--seconds", from: &rest) ?? 40
    let segSeconds = takeIntFlag("--segment-seconds", from: &rest) ?? 5
    let discFlag = takeStringFlag("--disc", from: &rest)

    var slices: [[UInt8]] = []
    for p in paths {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            print("ERROR: cannot read \(p)"); return 1
        }
        let aligned = (raw.count / 188) * 188
        guard aligned > 0 else { print("ERROR: \(p) too small / not TS"); return 1 }
        slices.append([UInt8](raw.prefix(aligned)))
    }

    // Discontinuity indices: explicit --disc, else auto-detect on file change.
    var discSet: Set<Int> = []
    if let discFlag {
        for s in discFlag.split(separator: ",") { if let i = Int(s) { discSet.insert(i) } }
    } else {
        for i in 1..<paths.count where paths[i] != paths[i - 1] { discSet.insert(i) }
    }
    print("[hlslive] segments=\(paths.count) discontinuities=\(discSet.sorted()) "
          + "segSeconds=\(segSeconds) seconds=\(seconds)")

    let config = HLSFixtureConfig(
        slices: slices, segmentSeconds: segSeconds, withMaster: false,
        discontinuityAt: nil, slowRefresh: false, dropSegment: nil,
        encrypted: false, fmp4: false, discontinuityIndices: discSet
    )
    let server = HLSFixtureServer(config: config)
    let listenPort: UInt16
    do { listenPort = try server.start(preferredPort: 8091) }
    catch { print("ERROR: server start: \(error)"); return 1 }
    let entryURL = "http://127.0.0.1:\(listenPort)/media.m3u8"
    print("[hlslive] serving \(entryURL)")

    EngineLog.handler = { print($0) }
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await hlsLiveRun(entryURL: entryURL, seconds: seconds, server: server)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func hlsLiveRun(entryURL: String, seconds: Int, server: HLSFixtureServer) async -> Int32 {
    guard let url = URL(string: entryURL) else { return 1 }
    let reader = HLSLiveIngestReader(playlistURL: url)
    let engine: AetherEngine
    do { engine = try AetherEngine() } catch {
        print("VERDICT: engine init failed: \(error)"); server.stop(); return 1
    }
    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    do {
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
    } catch {
        print("VERDICT: load failed: \(error)"); engine.stop(); server.stop(); return 1
    }
    print(String(format: "  post-load state=%@ isLive=%@", "\(engine.state)", "\(engine.isLive)"))

    for tick in 0..<seconds {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if case .error(let m) = engine.state {
            print("VERDICT: engine error at t=\(tick)s: \(m)"); engine.stop(); server.stop(); return 1
        }
        _ = tick
    }
    print("VERDICT: ran \(seconds)s, see seg-N finalize log above for cut continuity")
    engine.stop()
    server.stop()
    try? await Task.sleep(nanoseconds: 500_000_000)
    return 0
}
