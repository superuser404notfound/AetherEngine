import Foundation
import AetherEngine

// MARK: - audiotap (#95): decode the loopback audio track to a WAV, print continuity stats.

func runAudioTap(url: URL, duration: Double, outPath: String,
                 remote: Bool = false, software: Bool = false,
                 channels: AudioTapChannels = .downmix) -> Int32 {
    if software {
        return runSoftwareAudioTap(url: url, duration: duration, outPath: outPath, channels: channels)
    }
    EngineLog.handler = { print($0) }
    let mode = remote ? "remote-HLS" : "loopback"
    print(EngineLog.redacted("aetherctl audiotap (\(mode)): \(url.absoluteString) duration=\(duration)s channels=\(channels) out=\(outPath)"))
    do {
        let report = remote
            ? try AudioTapProbe.runRemote(url: url, durationSeconds: duration, outPath: outPath,
                                          channels: channels)
            : try AudioTapProbe.run(url: url, durationSeconds: duration, outPath: outPath,
                                    channels: channels)
        print(report)
        return 0
    } catch {
        print("ERROR: \(error)")
        return 1
    }
}

/// #400: the software sink runs inside a real session, so this mode needs the whole engine, not
/// a reader. CFRunLoopRun rather than a blocking wait: AetherEngine is @MainActor and parking the
/// main thread would deadlock its executor (same shape as `bgaudio`).
private func runSoftwareAudioTap(url: URL, duration: Double, outPath: String,
                                 channels: AudioTapChannels) -> Int32 {
    EngineLog.handler = { print($0) }
    print(EngineLog.redacted("aetherctl audiotap (software): \(url.absoluteString) duration=\(duration)s channels=\(channels) out=\(outPath)"))
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        do {
            let report = try await AudioTapProbe.runSoftware(
                url: url, durationSeconds: duration, outPath: outPath, channels: channels)
            print(report)
            // A tap that yields nothing, and one that yields silence, both look like a working
            // run in a report nobody reads to the end. Make them their own exit code.
            if !report.delivered {
                print("FAIL: the tap delivered no audible PCM "
                      + "(buffers=\(report.buffers), peak=\(report.peak))")
                box.value = 3
            } else {
                box.value = 0
            }
        } catch {
            print("ERROR: \(error)")
            box.value = 1
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
