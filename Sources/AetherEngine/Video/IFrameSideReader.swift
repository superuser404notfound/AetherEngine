// Sources/AetherEngine/Video/IFrameSideReader.swift
import Foundation
import AetherLibavcodec

/// AE#682: reads the keyframe that opens a plan segment, on a demuxer of its own. Only the bytes
/// are used; the fragment is stamped from the plan, so this demuxer's timestamp ladder (DTS on mp4,
/// PTS on Matroska, the #409 shift) never has to agree with the session's.
final class IFrameSideReader: @unchecked Sendable {
    private let open: (Demuxer) throws -> Void
    private let cleanup: () -> Void
    private let convertP7ToProfile81: Bool
    private let felDeliveryClamp: DoviFELDeliveryClamp?
    private let nalFraming: VideoNALFraming
    private let readDeadlineSeconds: TimeInterval
    private let now: () -> Date

    private let lock = NSLock()
    private var demuxer: Demuxer?
    private var isOpen = false
    private var videoIndex: Int32 = -1
    private var interrupted = false
    private var cleanedUp = false
    private var consecutiveFailures = 0
    private var blockedUntil = Date.distantPast

    /// A keyframe sits at the seek target or right behind it; this bounds a source that claims an
    /// index entry no keyframe backs.
    private static let maxPacketsPerRead = 256

    /// How long the reader refuses to touch the source after a failed open or read. Requests are
    /// served one at a time and AVKit sends five at once, so without this a stalled connection
    /// answers them a full read deadline apart; with it they fall through to a cached neighbour.
    static func coolDownSeconds(afterConsecutiveFailures failures: Int) -> TimeInterval {
        failures <= 1 ? 5 : 30
    }

    /// `open` receives a demuxer that `interrupt()` can already reach, so a slow open is abortable.
    /// `cleanup` runs once, from `close()`, whether or not the demuxer was ever opened.
    init(open: @escaping (Demuxer) throws -> Void,
         cleanup: @escaping () -> Void = {},
         convertP7ToProfile81: Bool = false,
         felDeliveryClamp: DoviFELDeliveryClamp? = nil,
         nalFraming: VideoNALFraming = .lengthPrefixed(size: 4),
         readDeadlineSeconds: TimeInterval = 8,
         now: @escaping () -> Date = Date.init) {
        self.open = open
        self.cleanup = cleanup
        self.convertP7ToProfile81 = convertP7ToProfile81
        self.felDeliveryClamp = felDeliveryClamp
        self.nalFraming = nalFraming
        self.readDeadlineSeconds = readDeadlineSeconds
        self.now = now
    }

    private var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    private func drop(_ dem: Demuxer) {
        lock.lock()
        if demuxer === dem {
            demuxer = nil
            isOpen = false
        }
        lock.unlock()
        dem.markClosed()
        dem.close()
    }

    private func noteFailure(_ what: String) {
        lock.lock()
        guard !interrupted else { lock.unlock(); return }
        consecutiveFailures += 1
        let coolDown = Self.coolDownSeconds(afterConsecutiveFailures: consecutiveFailures)
        blockedUntil = now().addingTimeInterval(coolDown)
        let failures = consecutiveFailures
        lock.unlock()
        EngineLog.emit("[IFrameSideReader] \(what); leaving the source alone for "
                       + "\(Int(coolDown))s (consecutive failures: \(failures))", category: .session)
    }

    private func readyDemuxer() -> Demuxer? {
        lock.lock()
        if interrupted { lock.unlock(); return nil }
        if let demuxer, isOpen { lock.unlock(); return demuxer }
        let dem = Demuxer()
        demuxer = dem
        lock.unlock()

        let started = DispatchTime.now()
        do {
            try open(dem)
        } catch {
            drop(dem)
            noteFailure("open failed: \(error)")
            return nil
        }
        let index = dem.videoStreamIndex
        guard index >= 0 else {
            drop(dem)
            noteFailure("open failed: no video stream")
            return nil
        }
        dem.discardAllStreamsExcept([index])
        lock.lock()
        if interrupted {
            lock.unlock()
            drop(dem)
            return nil
        }
        isOpen = true
        videoIndex = index
        lock.unlock()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[IFrameSideReader] opened in \(String(format: "%.0f", ms))ms", category: .session)
        return dem
    }

    func payload(startPts: Int64) -> Data? {
        lock.lock()
        let held = interrupted || now() < blockedUntil
        lock.unlock()
        if held { return nil }
        guard let dem = readyDemuxer() else { return nil }
        if let data = read(dem, startPts: startPts) {
            lock.lock(); consecutiveFailures = 0; lock.unlock()
            return data
        }
        guard !isInterrupted else { return nil }
        // The session treats a demuxer whose read failed as suspect-dead and reopens; so does this.
        drop(dem)
        noteFailure("read failed at pts=\(startPts)")
        return nil
    }

    private func read(_ dem: Demuxer, startPts: Int64) -> Data? {
        dem.beginReadDeadline(secondsFromNow: readDeadlineSeconds)
        defer { dem.endReadDeadline() }
        if dem.isDiscSource || !dem.seek(to: startPts, streamIndex: videoIndex) {
            guard let stream = dem.stream(at: videoIndex) else { return nil }
            let tb = stream.pointee.time_base
            guard tb.den > 0, dem.seek(to: Double(startPts) * Double(tb.num) / Double(tb.den)) else {
                return nil
            }
        }
        for _ in 0..<Self.maxPacketsPerRead {
            if isInterrupted { return nil }
            guard let packet = try? dem.readPacket() else { return nil }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            guard packet.pointee.stream_index == videoIndex,
                  (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 else { continue }
            if convertP7ToProfile81 {
                _ = DoviRpuConverter.convertPacketToProfile81(packet, framing: nalFraming, deliveryClamp: felDeliveryClamp)
            }
            guard let bytes = packet.pointee.data, packet.pointee.size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(packet.pointee.size))
        }
        return nil
    }

    /// Any thread. Aborts an open or a read in flight and makes every later call answer nil.
    func interrupt() {
        lock.lock()
        interrupted = true
        let dem = demuxer
        lock.unlock()
        dem?.markClosed()
    }

    /// The reading thread, after `interrupt()`.
    func close() {
        lock.lock()
        let dem = demuxer
        demuxer = nil
        isOpen = false
        let runCleanup = !cleanedUp
        cleanedUp = true
        lock.unlock()
        dem?.close()
        if runCleanup { cleanup() }
    }
}
