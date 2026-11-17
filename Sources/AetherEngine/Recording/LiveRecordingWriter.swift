import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Stream-copies live source packets into an MPEG-TS file (AE#560).
///
/// MPEG-TS rather than fragmented MP4 because the stated requirement is that a file cut short by a
/// crash or a kill is still playable: TS is a continuous run of 188 byte packets with periodic
/// PAT/PMT, so a truncated file plays up to the truncation with no repair. It also carries the
/// source codecs without a mapping step.
///
/// The writer never decodes and never encodes. Packets arrive already demuxed, from a tap that sits
/// before the audio bridge, so the file keeps the source's own video and audio codecs even while
/// playback is listening to a bridged FLAC rendition.
final class LiveRecordingWriter: LiveRecordingSink, @unchecked Sendable {

    /// source stream index -> output stream index plus the two time bases the rescale needs.
    private struct StreamMapping {
        let out: Int32
        let inTb: AVRational
        var outTb: AVRational
    }

    private let ctxLock = NSLock()
    private var ctx: UnsafeMutablePointer<AVFormatContext>?
    private var mapping: [Int32: StreamMapping] = [:]
    private var _bytesWritten: Int64 = 0
    private var closed = false
    private var sawFirstKeyframe = false
    /// The source stream index the arming keyframe must come from, or nil for an audio-only source.
    private var videoSourceStreamIndex: Int32?
    private var reportedFailure = false
    private var teardownScheduled = false
    /// The failure a scheduled teardown is ending the recording with, kept so whoever else ends the
    /// recording meanwhile (a stop, a zap) can report it instead of calling the file cleanly ended.
    private var pendingFailure: RecordingFailure?
    /// Entered when a teardown is scheduled, left when it has run: `finish(reason:)` joins it.
    private let teardownGroup = DispatchGroup()

    private var queue: LiveRecordingQueue!

    /// SUB-202: the mpegts muxer is not AVFMT_TS_NONSTRICT, so a packet whose dts does not rise
    /// past the stream's last one returns EINVAL. Touched only by `write`, which runs on the drain
    /// queue, so it needs no lock.
    private var lastOutDts: [Int32: Int64] = [:]
    private var repairedDtsCount = 0
    private var droppedPacketCount = 0
    private var consecutiveRejections = 0
    /// A run of rejected packets this long is a broken muxer, not a bad timestamp.
    private static let maxConsecutiveRejections = 64

    private let url: URL
    private let onFailure: @Sendable (RecordingFailure) -> Void

    var bytesWritten: Int64 { ctxLock.lock(); defer { ctxLock.unlock() }; return _bytesWritten }
    var isClosed: Bool { ctxLock.lock(); defer { ctxLock.unlock() }; return closed }

    #if DEBUG
    /// Test-only: runs on the drain queue before each write, so a test can hold the drain and make a
    /// teardown take as long as a slow disk would.
    nonisolated(unsafe) var beforeWriteForTesting: (@Sendable () -> Void)?
    #endif
    var droppedBytes: Int64 { queue.droppedBytes }

    init(url: URL,
         streams: [RecordingStreamDescriptor],
         ceilingBytes: Int,
         onFailure: @escaping @Sendable (RecordingFailure) -> Void) throws {
        self.url = url
        self.onFailure = onFailure

        let copyable = streams.filter { $0.codecParameters != nil }
        guard !copyable.isEmpty else { throw RecordingFailure.noStreamsToCopy }

        var allocated: UnsafeMutablePointer<AVFormatContext>?
        let path = url.path
        guard avformat_alloc_output_context2(&allocated, nil, "mpegts", path) >= 0,
              let context = allocated else {
            throw RecordingFailure.cannotCreateFile("could not allocate an mpegts output context")
        }

        // Every failure past this point must free the context, so the whole build runs inside one
        // do/catch with a single cleanup rather than a free at each return.
        do {
            for descriptor in copyable {
                guard let outStream = avformat_new_stream(context, nil) else {
                    throw RecordingFailure.cannotCreateFile("could not allocate an output stream")
                }
                guard avcodec_parameters_copy(outStream.pointee.codecpar,
                                              descriptor.codecParameters) >= 0 else {
                    throw RecordingFailure.cannotCreateFile("could not copy codec parameters")
                }
                // Let the TS muxer pick the tag for the codec. A source container's tag means
                // nothing here, and a stale one makes the muxer refuse the stream.
                outStream.pointee.codecpar.pointee.codec_tag = 0
                if descriptor.isVideo { videoSourceStreamIndex = descriptor.sourceStreamIndex }
                mapping[descriptor.sourceStreamIndex] = StreamMapping(
                    out: outStream.pointee.index,
                    inTb: AVRational(num: descriptor.timeBaseNum, den: descriptor.timeBaseDen),
                    outTb: outStream.pointee.time_base
                )
            }

            guard avio_open(&context.pointee.pb, path, AVIO_FLAG_WRITE) >= 0 else {
                throw RecordingFailure.cannotCreateFile("could not open \(path) for writing")
            }
            // The file starts at zero, not where the broadcast happened to be.
            //
            // A live source's timestamps are whatever its clock had reached, six or seven hours in
            // on a channel that has been up since morning, and copying them verbatim produces a
            // file whose first presentation timestamp lies hours past its own beginning: a
            // duration probe then reports the offset rather than the length (#560, #574).
            //
            // `make_zero` is the muxer's own rebase, and it is the reason this is an option
            // rather than arithmetic on every packet. It peeks into the interleaving queue for
            // the LOWEST timestamp across every stream, latches one offset from it and applies
            // that same offset to all streams for the rest of the file.
            //
            // Taking the origin here instead would take it from the first packet WRITTEN, which
            // is the arming video keyframe, and a TS interleaves the audio that belongs with that
            // picture ahead of it. Those frames are then earlier than the origin, and a negative
            // timestamp has to be clamped: measured on a source whose audio led by 100 ms, four
            // AC-3 frames came out stamped at instant zero while the picture also sat at zero, so
            // the head of the recording lost the very offset this is supposed to preserve.
            var options: OpaquePointer?
            av_dict_set(&options, "avoid_negative_ts", "make_zero", 0)
            defer { av_dict_free(&options) }
            guard avformat_write_header(context, &options) >= 0 else {
                avio_closep(&context.pointee.pb)
                throw RecordingFailure.cannotCreateFile("could not write the mpegts header")
            }
        } catch {
            avformat_free_context(context)
            throw error
        }

        // The muxer may have adjusted the output time bases while writing the header, so the
        // rescale has to read them back rather than trust what the stream carried before.
        for (source, existing) in mapping {
            guard let stream = context.pointee.streams[Int(existing.out)] else { continue }
            mapping[source] = StreamMapping(out: existing.out,
                                            inTb: existing.inTb,
                                            outTb: stream.pointee.time_base)
        }

        self.ctx = context
        self.queue = LiveRecordingQueue(ceilingBytes: ceilingBytes) { [weak self] item in
            self?.write(item)
        }
    }

    // MARK: - LiveRecordingSink (demux thread, must not block)

    func accept(packetBytes: UnsafeRawBufferPointer,
                sourceStreamIndex: Int32,
                pts: Int64, dts: Int64, duration: Int64,
                isKeyframe: Bool) {
        ctxLock.lock()
        let known = mapping[sourceStreamIndex] != nil
        let isClosed = closed
        // Open the file on a decodable picture: everything before the first VIDEO keyframe is
        // dropped so the recording does not start mid-GOP. The stream matters, it is not enough to
        // take a keyframe from anywhere: every AAC packet is flagged as one, so an any-stream gate
        // is armed by the first audio packet and the head of the file then references parameter
        // sets that were never written.
        //
        // An audio-only live source has no video keyframe to wait for and arms immediately.
        if isKeyframe, videoSourceStreamIndex == nil || sourceStreamIndex == videoSourceStreamIndex {
            sawFirstKeyframe = true
        }
        let armed = sawFirstKeyframe
        ctxLock.unlock()

        guard known, !isClosed, armed, packetBytes.count > 0 else { return }

        let item = LiveRecordingQueue.QueuedPacket(
            bytes: Data(packetBytes),
            sourceStreamIndex: sourceStreamIndex,
            pts: pts, dts: dts, duration: duration, isKeyframe: isKeyframe
        )
        if !queue.offer(item) {
            // Refused: the drain cannot keep up. Dropping the recording is the deliberate trade;
            // parking this thread would stall the picture, which is the one outcome this whole
            // design exists to prevent. So the teardown is SCHEDULED, never run here: `finish`
            // blocks on the drain, and this is the demux thread.
            scheduleTeardown(failure: .writeTooSlow(bytesWritten: bytesWritten,
                                                    queuedBytesDropped: queue.droppedBytes))
        }
    }

    // MARK: - Writer queue

    private func write(_ item: LiveRecordingQueue.QueuedPacket) {
        #if DEBUG
        beforeWriteForTesting?()
        #endif
        ctxLock.lock()
        // Deliberately NOT gated on `closed`. `finish` stops ACCEPTING first and drains second, so
        // gating the write here would discard everything still queued at the moment of a stop, up
        // to the full ceiling. The context staying alive until after the drain is what makes the
        // tail of a recording survive.
        guard let context = ctx, let map = mapping[item.sourceStreamIndex] else {
            ctxLock.unlock()
            return
        }
        ctxLock.unlock()

        guard let pkt = av_packet_alloc() else { return }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }

        guard av_new_packet(pkt, Int32(item.bytes.count)) >= 0 else { return }
        item.bytes.withUnsafeBytes { source in
            if let base = source.baseAddress, let destination = pkt.pointee.data {
                destination.update(from: base.assumingMemoryBound(to: UInt8.self),
                                   count: item.bytes.count)
            }
        }
        pkt.pointee.stream_index = map.out
        pkt.pointee.pts = item.pts
        pkt.pointee.dts = item.dts
        pkt.pointee.duration = item.duration
        if item.isKeyframe { pkt.pointee.flags |= AV_PKT_FLAG_KEY }
        av_packet_rescale_ts(pkt, map.inTb, map.outTb)
        repairNonMonotonicDts(pkt, outStream: map.out)

        let rc = av_interleaved_write_frame(context, pkt)
        if rc == -EINVAL, consecutiveRejections < Self.maxConsecutiveRejections {
            // The muxer refused this one packet and is not corrupted by it. Losing a frame beats
            // ending a multi-hour recording.
            consecutiveRejections += 1
            droppedPacketCount += 1
            if droppedPacketCount == 1 {
                EngineLog.emit("[Recording] muxer rejected a packet (EINVAL), dropped; the recording "
                               + "continues (logged once, url=\(url.lastPathComponent))",
                               category: .session)
            }
            return
        }
        if rc < 0 {
            let failure: RecordingFailure = rc == -ENOSPC
                ? .diskFull(bytesWritten: bytesWritten)
                : .writeFailed("av_interleaved_write_frame: \(rc)")
            // This runs ON the drain queue, and `finish` waits for that queue, so calling it here
            // would deadlock against itself. Schedule it elsewhere.
            scheduleTeardown(failure: failure)
            return
        }
        consecutiveRejections = 0
        ctxLock.lock()
        _bytesWritten += Int64(item.bytes.count)
        ctxLock.unlock()
    }

    /// Lifts a dts that does not rise past the stream's previous one to `previous + 1`, and keeps
    /// pts at or above dts. The first repair is logged, the rest are counted.
    private func repairNonMonotonicDts(_ pkt: UnsafeMutablePointer<AVPacket>, outStream: Int32) {
        let dts = pkt.pointee.dts
        guard dts != Int64.min else { return }
        if let last = lastOutDts[outStream], dts <= last {
            pkt.pointee.dts = last + 1
            if pkt.pointee.pts != Int64.min, pkt.pointee.pts < pkt.pointee.dts {
                pkt.pointee.pts = pkt.pointee.dts
            }
            repairedDtsCount += 1
            if repairedDtsCount == 1 {
                EngineLog.emit("[Recording] non-increasing dts on output stream \(outStream) "
                               + "(\(dts) after \(last)), repaired; later ones are not logged "
                               + "(url=\(url.lastPathComponent))",
                               category: .session)
            }
        }
        lastOutDts[outStream] = pkt.pointee.dts
    }

    // MARK: - Teardown

    /// Closes the recording and returns the failure it ended with, if any (audit FEA-105). A stop that
    /// lands while a scheduled teardown is already draining used to see `closed`, return at once, and let
    /// the caller publish `.ended` for a file that was still being written; it now joins that teardown
    /// and hands back the failure the teardown recorded, which its own report can no longer deliver
    /// because the recording has been released by then.
    @discardableResult
    func finish(reason: RecordingEndReason) -> RecordingFailure? {
        finish(reason: reason, failure: nil)
        teardownGroup.wait()
        ctxLock.lock()
        defer { ctxLock.unlock() }
        return pendingFailure
    }

    /// Tears the writer down from somewhere that must not block: the demux thread (a refused
    /// offer) or the drain queue itself (a write error). Runs at most once.
    private func scheduleTeardown(failure: RecordingFailure) {
        ctxLock.lock()
        guard !closed, !teardownScheduled else { ctxLock.unlock(); return }
        teardownScheduled = true
        pendingFailure = failure
        teardownGroup.enter()
        ctxLock.unlock()

        // Strong self: the group is entered, and a group released while entered is a libdispatch trap.
        DispatchQueue.global(qos: .utility).async {
            self.finish(reason: .stoppedByHost, failure: failure)
            self.teardownGroup.leave()
        }
    }

    private func finish(reason: RecordingEndReason, failure: RecordingFailure?) {
        ctxLock.lock()
        guard !closed else { ctxLock.unlock(); return }
        closed = true
        ctxLock.unlock()

        queue.finish()

        ctxLock.lock()
        if let context = ctx {
            av_write_trailer(context)
            avio_closep(&context.pointee.pb)
            avformat_free_context(context)
            ctx = nil
        }
        let written = _bytesWritten
        let shouldReport = failure != nil && !reportedFailure
        if shouldReport { reportedFailure = true }
        ctxLock.unlock()

        EngineLog.emit(
            "[Recording] finished reason=\(reason) bytes=\(written) "
            + "dropped=\(queue.droppedBytes) url=\(url.lastPathComponent)",
            category: .session
        )
        if shouldReport, let failure { onFailure(failure) }
    }
}
