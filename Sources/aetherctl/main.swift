// aetherctl: standalone reproduction harness for HLSVideoEngine on macOS.
//
// Spins up the same engine the tvOS app uses, against any source URL
// (file:// or http(s)://), and parks the loopback HLS-fMP4 server in
// the foreground so curl / mediastreamvalidator / mp4dump / ffprobe
// can poke at the manifests + segments without an Apple TV in the
// loop. The build-122 spinner-and-back symptom on tvOS isn't
// reproducible from the device side without TestFlight cycles; this
// CLI lets us iterate locally.

import Foundation
import AetherEngine

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: aetherctl <url>")
    print("")
    print("  url: file:// or http(s):// to a video source the engine demuxes")
    print("       (typically a Dolby Vision MKV, same kind of source the")
    print("       tvOS app's `.native` route would feed to AVPlayer).")
    print("")
    print("Once the engine is running it prints the loopback URL it served.")
    print("Useful next steps from another terminal:")
    print("  curl -i  http://127.0.0.1:<port>/master.m3u8")
    print("  curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/init.mp4")
    print("  curl -o  /tmp/seg0.mp4   http://127.0.0.1:<port>/seg0.mp4")
    print("  mediastreamvalidator http://127.0.0.1:<port>/master.m3u8")
    print("  mp4dump --verbosity 1 /tmp/init.mp4")
    print("  ffprobe -v debug /tmp/seg0.mp4")
    print("  open 'http://127.0.0.1:<port>/master.m3u8'   # macOS QuickTime")
    print("")
    exit(64)
}

let raw = args[1]
let sourceURL: URL = {
    if let parsed = URL(string: raw), parsed.scheme != nil {
        return parsed
    }
    return URL(fileURLWithPath: raw)
}()

// Mirror what the tvOS app does: route every engine log to stdout
// instead of into a host overlay buffer, so the CLI session reads
// linearly.
EngineLog.handler = { line in
    let timestamp = ISO8601DateFormatter.string(from: Date(),
                                                timeZone: .current,
                                                formatOptions: [.withTime, .withFractionalSeconds])
    print("[\(timestamp)] \(line)")
}

print("aetherctl: opening \(sourceURL.absoluteString)")
print("")

let engine = HLSVideoEngine(url: sourceURL)
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
