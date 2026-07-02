import Foundation
import AetherEngine

// MARK: - pktdump (#93 post-recovery judder diagnosis)

/// Dumps raw video packet timing as delivered by the demuxer under a chosen open profile.
/// Differential use: run once with --profile playback and once with --profile restartReopen
/// at the same --at position; a NOPTS-dts explosion or a degraded dts-delta histogram under
/// restartReopen confirms the skipped find_stream_info pass as the judder source.
func runPktDump(url: URL, at seconds: Double, count: Int, profileName: String) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl pktdump: \(url.absoluteString)")
    print("  profile=\(profileName) at=\(seconds)s count=\(count)")
    print("")
    do {
        let report = try PacketTimingProbe.run(
            url: url,
            seekSeconds: seconds,
            packetCount: count,
            profileName: profileName
        )
        print(report)
        return 0
    } catch {
        print("ERROR: \(error)")
        return 1
    }
}
