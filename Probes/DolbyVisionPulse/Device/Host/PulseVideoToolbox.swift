import AVFoundation
import AVKit
import CoreMedia
import UIKit

// The AVPlayer and VideoToolbox arms of the pulse harness: the hosts the engine's own route is
// compared against. None of this touches AetherEngine.

final class PulseHostView: UIView {

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }

    @MainActor
    func playAVPlayer(_ url: URL, log: @escaping @Sendable (String) -> Void) async {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // AVPlayerLayer has no automatic criteria (that is AVPlayerViewController's); request them from the
        // track's own format description exactly as the VT arms do.
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let fd = try? await track.load(.formatDescriptions).first,
           let fps = try? await track.load(.nominalFrameRate) {
            await requestCriteria(fd: fd, fps: fps, log: log)
        }
        let pl = AVPlayerLayer(player: player)
        pl.frame = bounds
        pl.videoGravity = .resizeAspect
        layer.addSublayer(pl)
        player.play()
        let deadline = Date().addingTimeInterval(80)
        let duration = (try? await item.asset.load(.duration).seconds) ?? 66
        while Date() < deadline, item.status != .failed, player.currentTime().seconds < duration - 0.2 {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("avplayer status=\(item.status.rawValue) error=\(String(describing: item.error)) t=\(player.currentTime().seconds)")
        player.pause()
        pl.removeFromSuperlayer()
    }

    @MainActor
    func playVT(_ url: URL, mode: String, log: @escaping @Sendable (String) -> Void) async {
        do {
            // AVAssetReader only reads local files: fetch the clip into the app's temp dir first.
            var localURL = url
            if !url.isFileURL {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                localURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: localURL)
                try FileManager.default.moveItem(at: tmp, to: localURL)
                log("downloaded \(url.lastPathComponent) to temp")
            }
            // Each arm fetches its own copy; drop it when the arm ends so repeated runs do not fill the app's temp dir.
            defer { if !url.isFileURL { try? FileManager.default.removeItem(at: localURL) } }
            let asset = AVURLAsset(url: localURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let fd = try await track.load(.formatDescriptions).first else { log("no video track"); return }
            let fps = try await track.load(.nominalFrameRate)
            await requestCriteria(fd: fd, fps: fps, log: log)

            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { log("reader failed: \(String(describing: reader.error))"); return }

            let dl = AVSampleBufferDisplayLayer()
            dl.frame = bounds
            dl.videoGravity = .resizeAspect
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
            guard let tb else { log("timebase failed"); return }
            dl.controlTimebase = tb
            layer.addSublayer(dl)

            let renderer = dl.sampleBufferRenderer
            let queue = DispatchQueue(label: "dv-pulse.feed")
            let state = FeedState()
            let copier = PulseFrameCopier()
            nonisolated(unsafe) let output = out
            nonisolated(unsafe) let r = renderer
            renderer.requestMediaDataWhenReady(on: queue) {
                while r.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else {
                        r.stopRequestingMediaData()
                        state.finish()
                        return
                    }
                    let n = state.count
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if n == 0 {
                        CMTimebaseSetTime(tb, time: CMTimeSubtract(pts, CMTime(value: 1, timescale: 4)))
                        CMTimebaseSetRate(tb, rate: 1)
                    }
                    guard let enq = copier.transform(sb, mode: mode) else { state.fail(); continue }
                    if n < 2 || n == 150 {
                        let pb = CMSampleBufferGetImageBuffer(enq)!
                        let atts = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
                        let rpu = (atts["DolbyVisionRPUData"] as? Data)?.count ?? 0
                        log("frame \(n) pts=\(String(format: "%.3f", pts.seconds)) rpu=\(rpu)B compat=\(atts["DolbyCompatibilityID"] ?? "nil") keys=\(atts.keys.sorted())")
                    }
                    r.enqueue(enq)
                    state.advance(lastPTS: pts)
                }
            }
            let deadline = Date().addingTimeInterval(80)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if state.done, CMTimebaseGetTime(tb) > state.lastPTS { break }
                if dl.sampleBufferRenderer.status == .failed {
                    log("renderer failed: \(String(describing: dl.sampleBufferRenderer.error))")
                    break
                }
            }
            log("vt \(mode): enqueued=\(state.count) copyFailures=\(state.failures) reader=\(reader.status.rawValue)")
            renderer.stopRequestingMediaData()
            reader.cancelReading()
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            dl.removeFromSuperlayer()
        } catch {
            log("vt error: \(error)")
        }
    }

    @MainActor
    private func requestCriteria(fd: CMFormatDescription, fps: Float, log: @Sendable (String) -> Void) async {
        window?.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: fps, formatDescription: fd)
        log("criteria requested codec=\(fourCC(CMFormatDescriptionGetMediaSubType(fd))) fps=\(fps)")
        let switchDeadline = Date().addingTimeInterval(10)
        try? await Task.sleep(nanoseconds: 300_000_000)
        while window?.avDisplayManager.isDisplayModeSwitchInProgress == true, Date() < switchDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        log("mode switch settled")
    }

    private func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)"
    }
}


/// Frame copy for the `vtcopy` / `vtstrip` arms, used on the feed queue.
nonisolated private final class PulseFrameCopier: @unchecked Sendable {
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType)?

    /// `vt`: unchanged. `vtcopy` / `vtstrip`: pixels copied into our own pool buffer, propagated
    /// attachments copied across (minus the two Dolby Vision keys for `vtstrip`), new sample buffer
    /// built from the image buffer the way AetherEngine's renderer builds its own.
    func transform(_ sb: CMSampleBuffer, mode: String) -> CMSampleBuffer? {
        if mode == "vt" { return sb }
        guard let src = CMSampleBufferGetImageBuffer(sb), let dst = copyPixels(src) else { return nil }
        var atts = CVBufferCopyAttachments(src, .shouldPropagate) as? [String: Any] ?? [:]
        CVBufferRemoveAllAttachments(dst)
        if mode == "vtstrip" {
            atts["DolbyVisionRPUData"] = nil
            atts["DolbyCompatibilityID"] = nil
        }
        CVBufferSetAttachments(dst, atts as CFDictionary, .shouldPropagate)
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: dst, formatDescriptionOut: &fd) == noErr,
              let fd else { return nil }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: dst, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    private func copyPixels(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let fmt = CVPixelBufferGetPixelFormatType(src)
        if pool == nil || poolKey.map({ $0 != (w, h, fmt) }) ?? true {
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferPixelFormatTypeKey as String: fmt,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 12] as CFDictionary,
                                    attrs as CFDictionary, &pool)
            poolKey = (w, h, fmt)
        }
        guard let pool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        for p in 0..<CVPixelBufferGetPlaneCount(src) {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return nil }
            let sr = CVPixelBufferGetBytesPerRowOfPlane(src, p), dr = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let rows = CVPixelBufferGetHeightOfPlane(src, p)
            let n = min(sr, dr)
            for r in 0..<rows { memcpy(d + r * dr, s + r * sr, n) }
        }
        return dst
    }

}

nonisolated private final class FeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0, _failures = 0, _done = false
    private var _last = CMTime.zero
    var count: Int { lock.withLock { _count } }
    var failures: Int { lock.withLock { _failures } }
    var done: Bool { lock.withLock { _done } }
    var lastPTS: CMTime { lock.withLock { _last } }
    func advance(lastPTS: CMTime) { lock.withLock { _count += 1; _last = lastPTS } }
    func fail() { lock.withLock { _failures += 1 } }
    func finish() { lock.withLock { _done = true } }
}
