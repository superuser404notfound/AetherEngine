import Foundation
import AetherEngine

/// `aetherctl segverify <url> [--from N] [--count K]` — deterministic, headless #92 verifier.
///
/// Starts the engine, then fetches `init.mp4` plus each media segment SEQUENTIALLY from the loopback
/// server (sequential on purpose: jumping straight to a deep segment triggers a producer restart whose
/// keyframe gate re-anchors a clean IRAP, masking the defect). Each tested segment is SW-decoded IN
/// ISOLATION (`init.mp4` + that one segment, fresh decoder, no predecessor). `framesDecoded == 0` means
/// the segment carries no usable IRAP to start from, i.e. it is not independently decodable, which is
/// exactly what AVPlayer hits on a fresh decode at a mid-stream open-GOP boundary (#92).
func runSegVerify(url: URL, from: Int, count: Int, dvModeAvailable: Bool, dumpDir: String? = nil) -> Int32 {
    setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: progressive output survives a long-running run
    print("segverify: starting engine for \(url.absoluteString)")
    let engine = HLSVideoEngine(url: url, dvModeAvailable: dvModeAvailable)
    let playbackURL: URL
    do {
        playbackURL = try engine.start()
    } catch {
        print("ERROR: engine.start failed: \(error)")
        return 1
    }
    print("segverify: engine started, playlist=\(playbackURL.absoluteString)")
    defer { engine.stop() }

    guard var comps = URLComponents(url: playbackURL, resolvingAgainstBaseURL: false) else {
        print("ERROR: cannot parse playback URL \(playbackURL)")
        return 1
    }
    comps.path = ""
    comps.query = nil
    guard let base = comps.url else {
        print("ERROR: cannot derive loopback base from \(playbackURL)")
        return 1
    }

    let initData: Data
    do {
        initData = try Data(contentsOf: base.appendingPathComponent("init.mp4"))
    } catch {
        print("ERROR: fetch init.mp4 failed: \(error)")
        return 1
    }
    print("init.mp4: \(initData.count) B  (loopback \(base.absoluteString))")

    let last = from + count
    var independent = 0
    var tested = 0
    for n in 0..<last {
        let segData: Data
        do {
            // Sequential fetch advances the producer's consumer target; without it the producer parks.
            segData = try Data(contentsOf: base.appendingPathComponent("seg\(n).mp4"))
        } catch {
            print("seg\(n): FETCH FAILED \(error)")
            if n >= from { tested += 1 }
            continue
        }
        guard n >= from else { continue }   // fetched only to keep production sequential; not decoded
        tested += 1

        var blob = initData
        blob.append(segData)
        if let dumpDir {
            let p = "\(dumpDir)/segverify_seg\(n).mp4"
            try? blob.write(to: URL(fileURLWithPath: p))
            print("seg\(n): dumped \(blob.count) B -> \(p)")
        }
        do {
            let r = try AetherEngine.swDecodeProbe(data: blob, formatHint: "mp4", maxPackets: 400)
            let ok = r.framesDecoded > 0
            if ok { independent += 1 }
            var line = "seg\(n): \(segData.count) B  fed=\(r.packetsFedToDecoder) decoded=\(r.framesDecoded)"
            line += "  -> \(ok ? "INDEPENDENT" : "NOT-INDEPENDENT")"
            if !r.openSucceeded { line += "  (decoder open failed: \(r.openError ?? "?"))" }
            print(line)
        } catch {
            print("seg\(n): PROBE ERROR \(error)")
        }
    }

    print("---")
    print("segverify: \(independent)/\(tested) segments independently decodable  [\(from)..<\(last)]")
    if tested == 0 { return 1 }
    return independent == tested ? 0 : 2
}
