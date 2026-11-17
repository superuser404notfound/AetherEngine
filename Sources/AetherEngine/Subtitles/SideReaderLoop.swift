import Foundation
import AetherLibavcodec

/// The two side readers (the #151 prefetcher and the native subtitle readers) used to carry their
/// own copy of the read step and of the link-yield valve, and the copies drifted: only the
/// prefetcher told a transport error from EOF (#231), so the native readers served a truncated
/// whole-program .vtt as complete (audit SUB-201, SUB-R201). The parts both loops need live here.
enum SideReaderLoop {

    /// What one `readPacket` call means. `Demuxer.readPacket` returns nil at EOF and throws on a
    /// transport failure; flattening both into "no packet" is the defect this type exists to prevent.
    enum ReadStep {
        case packet(UnsafeMutablePointer<AVPacket>)
        case endOfFile
        case failed(Error)
    }

    static func readNext(_ demuxer: Demuxer) -> ReadStep {
        do {
            guard let pkt = try demuxer.readPacket() else { return .endOfFile }
            return .packet(pkt)
        } catch {
            return .failed(error)
        }
    }

    /// The result of waiting for the video path to release the link.
    struct LinkYield {
        /// Seconds spent waiting, 0 when the arbiter let the reader straight through.
        var seconds: Double
        /// The wait hit the cap, so the reader takes the link for `valveGrantSeconds`.
        var tookValve: Bool
        /// The last playhead read while waiting, nil when no wait happened.
        var playhead: Double?
    }

    /// #240: leave the link to the video path while it needs it. Asked before the read because
    /// `readPacket` is what pulls bytes, and on Matroska it pulls the video and audio bytes too.
    /// Returns nil when the task was cancelled or the playhead source is gone (the caller leaves its
    /// loop). `valveGrantedUntil` is the grant window: while it runs the arbiter is not asked.
    static func yieldLink(
        _ link: SideReaderLinkArbiter,
        valveGrantedUntil: inout DispatchTime?,
        inAnchorGrace: () -> Bool,
        playhead: () async -> Double?,
        onWaitStart: () -> Void = {}
    ) async -> LinkYield? {
        if let until = valveGrantedUntil, DispatchTime.now() <= until {
            return LinkYield(seconds: 0, tookValve: false, playhead: nil)
        }
        var yielded: Double = 0
        var latest: Double?
        while !Task.isCancelled,
              link.shouldYield(inAnchorGrace: inAnchorGrace(), yieldedSeconds: yielded) {
            if yielded == 0 { onWaitStart() }
            guard let fresh = await playhead() else { return nil }
            latest = fresh
            do { try await Task.sleep(nanoseconds: link.pollNanoseconds) } catch { return nil }
            yielded += link.pollSeconds
        }
        let tookValve = yielded >= link.maxYieldSeconds
        if tookValve { valveGrantedUntil = DispatchTime.now() + link.valveGrantSeconds }
        return LinkYield(seconds: yielded, tookValve: tookValve, playhead: latest)
    }
}
