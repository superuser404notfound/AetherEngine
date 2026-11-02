import Foundation

/// Runs an `APACEncoder` on its own serial queue, so the bridge decodes and renders the next chunk
/// while the previous one encodes.
///
/// The two halves cost about the same: on Dolby's Unfold demo (27 s, M1, release build) the TrueHD
/// decode took 1.36 s, the APAC encode 1.26 s and everything else 0.06 s, each on one core. Run in
/// series that is 9.5x real time, which is what a seek past the cache waits for before the first
/// segment is served; overlapped it is set by the slower half alone.
///
/// Rendered chunks travel in `PlaneBuffer`s from a fixed pool. `submit` hands one over and takes a
/// free one back, waiting when none is free, which is the backpressure: the producer never runs
/// more than the pool ahead of the encoder, so the audio a segment lacks at its cut stays a few
/// chunks long. The queue carries no QoS of its own, so each job runs at the QoS of the producer
/// that submitted it and follows the pump's retuning (AE#286).
///
/// Packets are stamped on the worker by absolute position: each chunk says where its first frame
/// sits, and a run of the encoder (from one reset to the next) stamps packet k at the run's first
/// position plus k·1024. A failed encode resets the encoder and drops the chunk, so the next run
/// starts on the next chunk's own position and nothing after the failure moves.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class APACEncodePipeline: SpatialBedSink, @unchecked Sendable {

    typealias StampedPacket = SpatialBedPacket
    typealias PlaneBuffer = SpatialBedBuffer

    let leadingFrames: Int
    let magicCookie: Data

    private let encoder: APACEncoder
    private let queue = DispatchQueue(label: "AetherEngine.SpatialAudioBridge.encode")

    /// Guards everything below it.
    private let cond = NSCondition()
    private var freeBuffers: [PlaneBuffer]
    private var ready: [StampedPacket] = []
    private var errors: [Error] = []
    /// Bumped by `reset`; a job submitted before it is skipped, and its output is never collected.
    private var generation = 0
    private var pendingJobs = 0

    /// Worker only.
    private var runStart: Int64?
    private var packetsInRun: Int64 = 0

    /// `bufferCount` buffers in all: one the caller renders into, the rest queued or encoding.
    init(encoder: APACEncoder, channels: Int, bufferFrames: Int, bufferCount: Int = 3) {
        precondition(bufferCount >= 2, "one buffer to render into and one to encode")
        self.encoder = encoder
        leadingFrames = encoder.leadingFrames
        magicCookie = encoder.magicCookie
        freeBuffers = (0..<bufferCount).map { _ in PlaneBuffer(channels: channels, capacity: bufferFrames) }
    }

    /// A buffer to render into. Call once, before the first `submit`.
    func takeInitialBuffer() -> PlaneBuffer { acquire() }

    /// Queue `frames` frames of `buffer` for encoding, its first frame at `position`, and return a
    /// free buffer to render the next chunk into.
    func submit(_ buffer: PlaneBuffer, frames: Int, position: Int64) -> PlaneBuffer {
        enqueue { [self] in
            encode(buffer, frames: frames, position: position)
        } release: { [self] in
            release(buffer)
        }
        return acquire()
    }

    /// End the encoder's current run: its tail is stamped on the run, and the next chunk starts a
    /// new one on its own position.
    func restart() {
        enqueue { [self] in
            stamp(encoder.flushIgnoringErrors())
            encoder.reset()
            runStart = nil
        }
    }

    /// Move every packet stamped from now on by `frames`.
    func shift(by frames: Int64) {
        enqueue { [self] in
            runStart = runStart.map { $0 + frames }
        }
    }

    /// Drain the encoder at end of stream and wait for it. Returns everything not yet collected.
    func finish() -> (packets: [StampedPacket], errors: [Error]) {
        enqueue { [self] in
            stamp(encoder.flushIgnoringErrors())
        }
        cond.lock()
        while pendingJobs > 0 { cond.wait() }
        cond.unlock()
        return collect()
    }

    /// Drop everything queued and encoded but not yet collected, and start the encoder over.
    func reset() {
        cond.lock()
        generation += 1
        ready.removeAll()
        errors.removeAll()
        cond.unlock()
        enqueue { [self] in
            encoder.reset()
            runStart = nil
            packetsInRun = 0
        }
    }

    /// The packets encoded so far, in order, and the encode errors since the last call.
    func collect() -> (packets: [StampedPacket], errors: [Error]) {
        cond.lock()
        defer { cond.unlock() }
        let out = (ready, errors)
        ready.removeAll(keepingCapacity: true)
        errors.removeAll()
        return out
    }

    /// Wait for every queued job, then collect.
    func settle() -> (packets: [StampedPacket], errors: [Error]) {
        close()
        return collect()
    }

    /// Wait for every queued job.
    func close() {
        cond.lock()
        while pendingJobs > 0 { cond.wait() }
        cond.unlock()
    }

    // MARK: - Worker

    /// `release` runs whether the job ran or was skipped, after any output it made is collectable.
    private func enqueue(_ job: @escaping @Sendable () -> Void, release: (@Sendable () -> Void)? = nil) {
        cond.lock()
        let submitted = generation
        pendingJobs += 1
        cond.unlock()
        queue.async { [self] in
            cond.lock()
            let current = submitted == generation
            if current { workerGeneration = submitted }
            cond.unlock()
            if current { job() }
            release?()
            cond.lock()
            pendingJobs -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private func encode(_ buffer: PlaneBuffer, frames: Int, position: Int64) {
        if runStart == nil {
            runStart = position
            packetsInRun = 0
        }
        do {
            let planes = buffer.planes.map { UnsafePointer($0) }
            stamp(try encoder.encode(planes: planes, frameCount: frames))
        } catch {
            // Packet k of a run is stamped by its index, so a call that swallowed packets would
            // leave every later one early. The chunk becomes a gap instead.
            encoder.reset()
            runStart = nil
            cond.lock()
            if generationMatches() { errors.append(error) }
            cond.unlock()
        }
    }

    private func stamp(_ packets: [APACEncoder.Packet]) {
        guard !packets.isEmpty, let start = runStart else { return }
        var stamped: [StampedPacket] = []
        stamped.reserveCapacity(packets.count)
        for packet in packets {
            stamped.append(StampedPacket(
                data: packet.data, isSync: packet.isSync,
                pts: start + packetsInRun * Int64(APACEncoder.framesPerPacket),
                frames: APACEncoder.framesPerPacket))
            packetsInRun += 1
        }
        cond.lock()
        if generationMatches() { ready.append(contentsOf: stamped) }
        cond.unlock()
    }

    /// The generation of the job running on the worker.
    private var workerGeneration = 0

    /// Caller holds `cond`. False when a `reset` overtook the running job, whose output nobody wants.
    private func generationMatches() -> Bool { workerGeneration == generation }

    private func release(_ buffer: PlaneBuffer) {
        cond.lock()
        freeBuffers.append(buffer)
        cond.broadcast()
        cond.unlock()
    }

    private func acquire() -> PlaneBuffer {
        cond.lock()
        defer { cond.unlock() }
        while freeBuffers.isEmpty { cond.wait() }
        return freeBuffers.removeLast()
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
private extension APACEncoder {
    func flushIgnoringErrors() -> [Packet] { (try? flush()) ?? [] }
}
