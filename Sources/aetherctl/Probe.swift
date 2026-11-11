import Foundation
import AetherEngine

// MARK: - probe

func runProbe(url: URL, detecting: ProbeDetail = []) -> Int32 {
    EngineLog.handler = { print($0) }
    print(EngineLog.redacted("aetherctl probe: \(url.absoluteString)"))
    if !detecting.isEmpty {
        var passes: [String] = []
        if detecting.contains(.hdr10Plus) { passes.append("hdr10plus (packet scan)") }
        if detecting.contains(.hdrVivid) { passes.append("hdr-vivid (packet scan)") }
        if detecting.contains(.dolbyVisionEnhancementLayer) { passes.append("dv-el (packet scan)") }
        if detecting.contains(.atmos) { passes.append("atmos (bounded decode)") }
        print("detail passes: \(passes.joined(separator: ", "))")
    }
    print("")
    let probe: SourceProbe
    do {
        probe = try AetherEngine.probe(url: url, detecting: detecting)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    let duration = String(format: "%.3f", probe.durationSeconds)
    let res = probe.videoWidth > 0 ? "\(probe.videoWidth)x\(probe.videoHeight)" : "n/a"
    let rate = probe.videoFrameRate.map { String(format: "%.3f", $0) } ?? "n/a"
    let codec = probe.videoCodecName ?? "(unknown)"

    print("Container:   \(probe.containerFormat ?? "(unknown)")")
    print("Duration:    \(duration)s")
    print("Video:       codec=\(codec) resolution=\(res) fps=\(rate)")
    print("  format:    \(probe.videoFormat)")
    if let f = probe.videoStreamFormat {
        print("  pixels:    \(f.pixelFormat ?? "-") depth=\(f.bitDepth.map { "\($0)-bit" } ?? "-") profile=\(f.profile ?? "-")")
        print("  colour:    primaries=\(f.colorPrimariesLabel ?? "-") transfer=\(f.transferLabel ?? "-") "
              + "matrix=\(f.matrixLabel ?? "-") range=\(f.rangeLabel ?? "-")")
    }
    if probe.isDolbyVision {
        print("  HDR/DV:    Dolby Vision signaled"
              + (probe.dvProfile.map { " profile=\($0)" } ?? "")
              + (probe.dvBLCompatID.map { " blCompatID=\($0)" } ?? ""))
    }
    if detecting.contains(.hdr10Plus) {
        // A negative here means "not seen inside the scan budget", never "proven absent".
        print("  HDR10+:    \(probe.carriesHDR10PlusMetadata ? "ST 2094-40 metadata seen" : "not seen")")
    }
    if detecting.contains(.hdrVivid) {
        print("  HDR Vivid: \(probe.carriesHDRVividMetadata ? "CUVA metadata seen" : "not seen")")
    }
    if detecting.contains(.dolbyVisionEnhancementLayer) {
        let layer = probe.dolbyVisionEnhancementLayer?.rawValue
            ?? (probe.dvProfile == 7 ? "no RPU seen" : "not Profile 7")
        print("  DV EL:     \(layer)")
    }
    if !probe.discTitles.isEmpty {
        print("Disc titles:")
        for title in probe.discTitles {
            print("  [\(title.id)] \(title.name) " + String(format: "%.1fs", title.durationSeconds)
                  + " chapters=\(title.chapterCount)"
                  + (title.playlist.map { " playlist=\($0)" } ?? "")
                  + (title.titleSet.map { " titleSet=\($0)" } ?? ""))
        }
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
            let kind = (track.isVisualImpaired ? " (audio description)" : "") + (track.isCommentary ? " (commentary)" : "")
            print("  [\(track.id)] codec=\(track.codec) channels=\(track.channels) lang=\(lang)\(atmos)\(def)\(kind)")
            print("       rate=\(track.sampleRate) Hz bits=\(track.bitsPerSample) fmt=\(track.sampleFormat ?? "-") "
                  + "layout=\(track.channelLayout ?? "-") profile=\(track.profile ?? "-")"
                  + (track.trueHDAtmos.map { " truehd-atmos=\($0)" } ?? ""))
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
