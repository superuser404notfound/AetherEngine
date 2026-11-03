import AVFoundation
import Foundation
import AetherEngine

// MARK: - scrubpreview

/// Compositor scrub previews (Dolby Vision Profile 5 / 10.0) at a list of positions: for each one,
/// whether a picture came, how long it took, and the span it stands for. Positions inside the
/// resident window come from the segment cache, the rest from the source's own keyframe, so a run
/// against a throttled source exercises both. `--keep <dir>` copies the session's preview files
/// out before teardown, which is how the two kinds of file are compared byte for byte.
func runScrubPreview(url: URL, positions: [Double], warmSeconds: Double, keepDir: String?) -> Int32 {
    print(EngineLog.redacted("aetherctl scrubpreview: \(url.absoluteString)"))
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await scrubPreviewRun(url: url, positions: positions, warmSeconds: warmSeconds,
                                          keepDir: keepDir)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func scrubPreviewRun(url: URL, positions: [Double], warmSeconds: Double, keepDir: String?) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
        try await engine.load(url: url, options: LoadOptions())
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    engine.play()
    try? await Task.sleep(for: .seconds(warmSeconds))
    print("backend=\(engine.playbackBackend.rawValue) drawsInView=\(engine.scrubPreviewDrawsInView) "
          + String(format: "t=%.1fs duration=%.1fs", engine.currentTime, engine.duration))
    guard engine.scrubPreviewDrawsInView else {
        print("FAIL: this source does not draw its previews in a view")
        engine.stop()
        return 1
    }
    let view = AetherScrubPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    var shown = 0
    for target in positions {
        let resident = engine.residentRanges.contains { $0.contains(target) }
        let started = ContinuousClock.now
        let placement = await engine.showScrubPreview(atSeconds: target, in: view)
        let ms = Double((ContinuousClock.now - started).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - started).components.seconds) * 1000
        if placement != nil { shown += 1 }
        print(String(format: "  t=%7.2f resident=%@ -> %@ in %.0f ms", target, resident ? "yes" : "no ",
                     placement.map { String(format: "shown %.2f..%.2f", $0.validRange.lowerBound,
                                            $0.validRange.upperBound) } ?? "nil", ms))
    }
    if let keepDir {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aether-segments")
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = sessions.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        if let preview = newest?.appendingPathComponent("preview"),
           let files = try? FileManager.default.contentsOfDirectory(atPath: preview.path) {
            let out = URL(fileURLWithPath: keepDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for name in files where name.hasSuffix(".mp4") {
                try? FileManager.default.removeItem(at: out.appendingPathComponent(name))
                try? FileManager.default.copyItem(at: preview.appendingPathComponent(name),
                                                  to: out.appendingPathComponent(name))
            }
            print("kept \(files.filter { $0.hasSuffix(".mp4") }.count) preview files in \(keepDir)")
        }
    }
    view.clear()
    engine.stop()
    print("\(shown) of \(positions.count) positions showed a picture")
    return shown == positions.count ? 0 : 2
}

// MARK: - scrubpreview --stills

/// `scrubPreviewFrame` at a list of positions after `--warm S` seconds of play: where each still
/// came from (a resident segment or the keyframe still ladder) and the span it names. With
/// `--max-concurrent-requests 1` the origin is the one-connection shape the ladder exists for.
func runScrubStills(url: URL, positions: [Double], warmSeconds: Double,
                    maxConcurrentRequests: Int?, forwardBufferSegments: Int?) -> Int32 {
    print(EngineLog.redacted("aetherctl scrubpreview --stills: \(url.absoluteString)"))
    EngineLog.handler = { print($0) }
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await scrubStillsRun(url: url, positions: positions, warmSeconds: warmSeconds,
                                         maxConcurrentRequests: maxConcurrentRequests,
                                         forwardBufferSegments: forwardBufferSegments)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func scrubStillsRun(url: URL, positions: [Double], warmSeconds: Double,
                            maxConcurrentRequests: Int?, forwardBufferSegments: Int?) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
        try await engine.load(url: url, options: LoadOptions(
            maxConcurrentSourceRequests: maxConcurrentRequests,
            forwardBufferSegments: forwardBufferSegments))
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    engine.play()
    try? await Task.sleep(for: .seconds(warmSeconds))
    print("backend=\(engine.playbackBackend.rawValue) cacheBackedStills=\(engine.supportsCacheBackedStills) "
          + String(format: "t=%.1fs buffered=%.1fs duration=%.1fs",
                   engine.currentTime, engine.bufferedPosition, engine.duration))
    var shown = 0
    for target in positions {
        let resident = engine.residentRanges.contains { $0.contains(target) }
        let started = ContinuousClock.now
        let frame = await engine.scrubPreviewFrame(atSeconds: target, refined: false, isCancelled: { false })
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if frame != nil { shown += 1 }
        let detail = frame.map { f in
            String(format: "still at %.2f", f.actualSeconds)
                + (f.validRange.map { String(format: " span %.2f..%.2f", $0.lowerBound, $0.upperBound) } ?? "")
                + " \(f.image.width)x\(f.image.height)"
        } ?? "nil"
        print(String(format: "  t=%7.2f resident=%@ -> %@ in %.0f ms", target, resident ? "yes" : "no ", detail, ms))
    }
    engine.stop()
    print("\(shown) of \(positions.count) positions showed a picture")
    return shown == positions.count ? 0 : 2
}
