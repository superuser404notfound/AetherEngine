// avplayer-open-check.swift  (AetherEngine #15, E8)
//
// Standalone AVFoundation harness that proves AVPlayer can OPEN the loopback HLS master that carries the
// native WebVTT SUBTITLES rendition, reaches `.readyToPlay`, and EXPOSES at least one legible
// (subtitle/closed-caption) media-selection option. This is the open-time guard that #55 lacked: muxing
// timed text into the A/V fMP4 silently failed the AVPlayer open, so we need an explicit "does it open and
// expose the option" check against the conformant separate-rendition shape.
//
// It deliberately imports ONLY Foundation + AVFoundation (never AetherEngine): it talks to the engine the
// same way a real client does, over the loopback HTTP server, so it validates the served bytes end to end.
//
// It cannot run as a normal `swift test`: it needs `aetherctl serve` already serving a media file with at
// least one embedded TEXT subtitle track. See Tests/Integration/README.md for the exact commands.
//
// Run:
//   swift Tests/Integration/avplayer-open-check.swift <master.m3u8 url> [timeoutSeconds]
//
// Exit codes: 0 = readyToPlay AND >= 1 legible option; 1 = failed/timeout/no option; 2 = bad usage.

import AVFoundation
import Foundation

func dumpErrorLog(_ item: AVPlayerItem) {
    guard let log = item.errorLog() else {
        print("[harness] no errorLog() events")
        return
    }
    if log.events.isEmpty {
        print("[harness] errorLog() present but empty")
        return
    }
    for (i, ev) in log.events.enumerated() {
        print("[harness] errorLog[\(i)]: statusCode=\(ev.errorStatusCode) domain=\(ev.errorDomain) "
            + "comment=\(ev.errorComment ?? "nil") uri=\(ev.uri ?? "nil")")
    }
}

func loadLegibleGroup(_ asset: AVURLAsset) async -> AVMediaSelectionGroup? {
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
        return try? await asset.loadMediaSelectionGroup(for: .legible)
    } else {
        return asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
    }
}

func run() async -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 2, let url = URL(string: args[1]) else {
        FileHandle.standardError.write(Data(
            "usage: swift avplayer-open-check.swift <master.m3u8 url> [timeoutSeconds]\n".utf8))
        return 2
    }
    let timeout = args.count >= 3 ? (Double(args[2]) ?? 30) : 30

    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    _ = player  // retain the player for the lifetime of the check

    print("[harness] opening \(url.absoluteString)  (timeout \(Int(timeout))s)")

    let deadline = Date().addingTimeInterval(timeout)
    var ready = false
    while Date() < deadline {
        switch item.status {
        case .readyToPlay:
            ready = true
        case .failed:
            print("[harness] AVPlayerItem.status = .failed")
            if let e = item.error { print("[harness] item.error = \(e)") }
            dumpErrorLog(item)
            return 1
        case .unknown:
            break
        @unknown default:
            break
        }
        if ready { break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    guard ready else {
        print("[harness] TIMEOUT after \(Int(timeout))s; AVPlayerItem.status still .unknown")
        dumpErrorLog(item)
        return 1
    }
    print("[harness] AVPlayerItem.status = .readyToPlay")

    let group = await loadLegibleGroup(asset)
    let options = group?.options ?? []
    print("[harness] legible media-selection options: \(options.count)")
    for (i, o) in options.enumerated() {
        print("[harness]   [\(i)] displayName=\"\(o.displayName)\" "
            + "lang=\(o.extendedLanguageTag ?? "nil") mediaType=\(o.mediaType.rawValue)")
    }

    if options.isEmpty {
        print("[harness] FAIL: AVPlayer opened but exposed no legible option (rendition not advertised/accepted)")
        return 1
    }
    print("[harness] PASS: readyToPlay + \(options.count) legible option(s) against the loopback master")
    return 0
}

let code = await run()
exit(code)
