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

    private var queue: LiveRecordingQueue!

    private let url: URL
    private let onFailure: @Sendable (RecordingFailure) -> Void

    var bytesWritten: Int64 { ctxLock.lock(); defer { ctxLock.unlock() }; return _bytesWritten }
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
            guard avformat_write_header(context, nil) >= 0 else {
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

        let rc = av_interleaved_write_frame(context, pkt)
        if rc < 0 {
            let failure: RecordingFailure = rc == -ENOSPC
                ? .diskFull(bytesWritten: bytesWritten)
                : .writeFailed("av_interleaved_write_frame: \(rc)")
            // This runs ON the drain queue, and `finish` waits for that queue, so calling it here
            // would deadlock against itself. Schedule it elsewhere.
            scheduleTeardown(failure: failure)
            return
        }
        ctxLock.lock()
        _bytesWritten += Int64(item.bytes.count)
        ctxLock.unlock()
    }

    // MARK: - Teardown

    func finish(reason: RecordingEndReason) {
        finish(reason: reason, failure: nil)
    }

    /// Tears the writer down from somewhere that must not block: the demux thread (a refused
    /// offer) or the drain queue itself (a write error). Runs at most once.
    private func scheduleTeardown(failure: RecordingFailure) {
        ctxLock.lock()
        guard !closed, !teardownScheduled else { ctxLock.unlock(); return }
        teardownScheduled = true
        ctxLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.finish(reason: .stoppedByHost, failure: failure)
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
