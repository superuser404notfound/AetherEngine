// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import CoreVideo
import Foundation
import VideoToolbox

/// What the output route does with one base-layer buffer from the player's video output.
enum BaseLayerFormatDecision: Equatable, Sendable {
    /// The buffer is what the composer reads (`x420`, IOSurface-backed): it goes on untouched.
    case passThrough
    /// Anything else goes through a pixel transfer into a buffer that is.
    case convert
}

/// The outcome of `BaseLayerConverting.prepare`. There is no case that carries a buffer in a format the
/// composer cannot read: a conversion that did not happen hands nothing on.
enum BaseLayerPreparation {
    /// A buffer in the composer's format: the player's own, or a converted one from the pool.
    case ready(CVPixelBuffer)
    /// The conversion pool is at its limit: every buffer in it is held downstream. Backpressure, not a
    /// fault of the conversion; it heals when the compositions in flight finish.
    case refused
    /// The conversion itself failed (no session, no pool, a transfer that returned an error).
    case failed(String)
}

struct BaseLayerConversionStatistics: Equatable, Sendable {
    var passedThrough = 0
    var converted = 0
    var refused = 0
    var failed = 0
    /// The most pool buffers alive at once (rented and not yet released by the compositions in flight and the
    /// display layer).
    var peakLive = 0
}

/// What the route needs from the step that makes the player's buffers readable for the composer.
protocol BaseLayerConverting: AnyObject, Sendable {
    func prepare(_ buffer: CVPixelBuffer) -> BaseLayerPreparation
    /// Called from the pull tick: releases the pool's idle buffers once nothing has been converted for a while.
    func trimIfIdle()
    /// Ends the converter: the session is invalidated and the pool released. Runs on the route's teardown
    /// queue, after the pull ticks have ended or the bounded wait for them ran out; a `prepare` that comes
    /// later fails the frame and touches neither the session nor the pool.
    func tearDown()
    var statistics: BaseLayerConversionStatistics { get }
}

/// The output route asks its `AVPlayerItemVideoOutput` for the player's own buffer format (`nil` pixel buffer
/// attributes), because naming `x420` there makes the system's decoder service keep a second, much larger
/// set of buffers (see `docs/dolby-vision-fel.md` for the figures and the build they come from). The composer reads `x420`. A player that hands out `x420` directly costs
/// nothing here; any other format is transferred into a small pool of `x420` buffers with
/// `VTPixelTransferSession` (public API), on the thread that pulled the frame.
///
/// The pool limit is sized from the frame rate and the buffers that can be alive at once (`poolLimit(frameRate:)`),
/// not from one clip. It gives its idle buffers back when no frame was converted for a second (with the
/// composition in place, the frames the display layer still holds stay out of the pool), and the converter is torn down with the route on its off-main stop path.
///
/// Two locks, so a reader of the counters never waits on a transfer: `lock` guards the session and the pool
/// and is held across the pixel transfer and the bounded wait for a buffer (up to about 36 ms); `statsLock`
/// guards only the counters and is held for the length of an increment. `statistics`, which the route's
/// `summary` reads on the main thread from `stop()`, takes only `statsLock`.
final class BaseLayerFormatConverter: BaseLayerConverting, @unchecked Sendable {

    /// The format the composer reads.
    static let outputFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    /// Buffers held by the display side once a converted frame has been composed in place: the one on screen
    /// and the one the layer retains while it replaces it.
    static let displayHeldFrames = 2
    /// One more, so a refusal is not the normal state at the exact count.
    static let spareBuffers = 1

    /// The most pool buffers alive at once for a stream at `frameRate`. With the composition in place the
    /// converted buffer is the one that reaches the display layer, so it stays out of the pool until the layer
    /// lets it go. The holders: the frames taken `pullAheadSeconds` ahead of the clock (a whole number of
    /// them, rounded up), the frames the display holds (`displayHeldFrames`), the compositions in flight
    /// (`DoviFelComposer.maxFramesInFlight`) and a spare. 9 at 23.976 and 24 fps, 10 at 30, 14 at 60. A stream
    /// whose rate is unknown gets the 60 fps figure. It is a ceiling, not an allocation: the pool grows only
    /// as far as the holders need.
    static func poolLimit(frameRate: Double) -> Int {
        let rate = frameRate.isFinite && frameRate > 0 ? frameRate : 60
        let lead = Int((DualLayerOutputRoute.pullAheadSeconds * rate - 1e-9).rounded(.up))
        return lead + displayHeldFrames + DoviFelComposer.maxFramesInFlight + spareBuffers
    }
    /// Seconds with no conversion after which the idle buffers are released. The same age the composer's
    /// output pool uses (`kCVPixelBufferPoolMaximumBufferAgeKey`).
    static let idleTrimSeconds = 1.0

    /// The format decision, without a buffer: IOSurface backing is part of "readable by the composer",
    /// since its Metal textures are made from the surface.
    static func decision(format: OSType, hasIOSurface: Bool) -> BaseLayerFormatDecision {
        format == outputFormat && hasIOSurface ? .passThrough : .convert
    }

    static func decision(for buffer: CVPixelBuffer) -> BaseLayerFormatDecision {
        decision(format: CVPixelBufferGetPixelFormatType(buffer), hasIOSurface: CVPixelBufferGetIOSurface(buffer) != nil)
    }

    typealias Transfer = (VTPixelTransferSession, CVPixelBuffer, CVPixelBuffer) -> OSStatus
    typealias Flush = (CVPixelBufferPool) -> Void

    /// Buffers the pool hands out at once.
    let poolLimit: Int
    private let idleTrimSeconds: Double
    private let now: @Sendable () -> Double
    private let retryAttempts: Int
    private let retryInterval: TimeInterval
    private let transfer: Transfer
    private let flush: Flush

    /// Guards the session, the pool and the vended list. Held across the transfer and the bounded buffer wait.
    private let lock = NSLock()
    /// Guards `stats` only. Never held across a transfer or a sleep, and nothing else is taken under it.
    private let statsLock = NSLock()
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private struct WeakBuffer { weak var value: CVPixelBuffer? }
    /// The pool buffers handed out and not yet released, for the peak count. Weak: it must not keep one alive.
    private var vended: [WeakBuffer] = []
    private var lastUse: Double?
    private var lastTrim: Double = 0
    private var closed = false
    private var stats = BaseLayerConversionStatistics()

    /// `retryAttempts` and `retryInterval` default to the composer's own bounded wait for its output pool
    /// (at most about 36 ms on the pull thread, and only while every pool buffer is held downstream).
    init(poolLimit: Int = BaseLayerFormatConverter.poolLimit(frameRate: 0),
         idleTrimSeconds: Double = BaseLayerFormatConverter.idleTrimSeconds,
         retryAttempts: Int = DoviFelComposer.outputPoolAttempts,
         retryInterval: TimeInterval = DoviFelComposer.outputPoolRetryInterval,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         transfer: @escaping Transfer = { VTPixelTransferSessionTransferImage($0, from: $1, to: $2) },
         flush: @escaping Flush = { CVPixelBufferPoolFlush($0, .excessBuffers) }) {
        self.poolLimit = poolLimit
        self.idleTrimSeconds = idleTrimSeconds
        self.retryAttempts = max(1, retryAttempts)
        self.retryInterval = retryInterval
        self.now = now
        self.transfer = transfer
        self.flush = flush
    }

    var statistics: BaseLayerConversionStatistics {
        statsLock.lock(); defer { statsLock.unlock() }
        return stats
    }

    private func count(_ update: (inout BaseLayerConversionStatistics) -> Void) {
        statsLock.lock(); update(&stats); statsLock.unlock()
    }

    func prepare(_ buffer: CVPixelBuffer) -> BaseLayerPreparation {
        if Self.decision(for: buffer) == .passThrough {
            count { $0.passedThrough += 1 }
            return .ready(buffer)
        }
        lock.lock(); defer { lock.unlock() }
        if closed { count { $0.failed += 1 }; return .failed("the converter is closed") }
        if session == nil {
            var created: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created)
            guard status == noErr, let created else {
                count { $0.failed += 1 }
                return .failed("no pixel transfer session (status \(status))")
            }
            session = created
        }
        guard let session else { count { $0.failed += 1 }; return .failed("no pixel transfer session") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let pool = ensurePool(width: width, height: height) else {
            count { $0.failed += 1 }
            return .failed("no buffer pool for \(width)x\(height)")
        }
        var destination: CVPixelBuffer?
        var status = kCVReturnError
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: poolLimit] as CFDictionary
        for attempt in 0..<retryAttempts {
            status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &destination)
            if status != kCVReturnWouldExceedAllocationThreshold { break }
            if attempt < retryAttempts - 1 { Thread.sleep(forTimeInterval: retryInterval) }
        }
        if status == kCVReturnWouldExceedAllocationThreshold {
            count { $0.refused += 1 }
            return .refused
        }
        guard status == kCVReturnSuccess, let destination else {
            count { $0.failed += 1 }
            return .failed("buffer pool status \(status)")
        }
        vended.removeAll { $0.value == nil }
        vended.append(WeakBuffer(value: destination))
        let live = vended.count
        count { $0.peakLive = max($0.peakLive, live) }
        let transferred = transfer(session, buffer, destination)
        guard transferred == noErr else {
            count { $0.failed += 1 }
            return .failed("pixel transfer status \(transferred)")
        }
        // The pixel transfer carries the buffer's attachments (colour tags, display metadata) to the
        // destination; `attachmentsFollowThePicture` holds that.
        count { $0.converted += 1 }
        lastUse = now()
        return .ready(destination)
    }

    func trimIfIdle() {
        lock.lock(); defer { lock.unlock() }
        guard let pool, let lastUse else { return }
        let current = now()
        // Repeats every idle period while the player stays idle: a buffer still held downstream when the
        // first trim ran is released by a later one.
        guard current - lastUse >= idleTrimSeconds, current - lastTrim >= idleTrimSeconds else { return }
        lastTrim = current
        flush(pool)
    }

    func tearDown() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if let session { VTPixelTransferSessionInvalidate(session) }
        session = nil
        if let pool { flush(pool) }
        pool = nil
        lastUse = nil
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height { return pool }
        // A new picture size starts a new pool; the old one is released with the buffers still out.
        pool = nil
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 0,
            kCVPixelBufferPoolAllocationThresholdKey: poolLimit,
            kCVPixelBufferPoolMaximumBufferAgeKey: Self.idleTrimSeconds,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Self.outputFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary,
                                      &created) == kCVReturnSuccess, let created else { return nil }
        pool = created
        poolWidth = width
        poolHeight = height
        return created
    }
}
#endif
