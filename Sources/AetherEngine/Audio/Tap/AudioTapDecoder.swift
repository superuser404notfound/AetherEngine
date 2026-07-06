import Foundation
import AVFAudio
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// One decoded PCM chunk in the tap's fixed format. `ptsSeconds` is on the axis of the packets
/// that were fed in (playlist axis when fed from loopback segments, source axis on the SW path).
struct AudioTapChunk {
    let buffer: AVAudioPCMBuffer
    let ptsSeconds: Double
}

/// FFmpeg decoder for the audio tap (#95): compressed packets to mono Float32 48 kHz
/// `AVAudioPCMBuffer`s. Mirrors `AudioDecoder`'s lazy-resampler + lock discipline but with a
/// fixed swr output and a running sample clock (anchor + emitted/48000) so chunks abut exactly.
final class AudioTapDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private let stateLock = NSLock()
    private var timeBase = AVRational(num: 1, den: 90_000)

    /// Running clock: PTS of the first decoded frame + samples emitted since. Re-anchored on
    /// a source PTS that diverges > 250 ms from the running position (seek within a session).
    private var anchorPTS: Double?
    private var samplesSinceAnchor: Int64 = 0

    private var pending: [Float] = []
    private var pendingStartPTS: Double = 0

    enum TapDecoderError: Error { case noCodecParameters, unsupportedCodec, allocFailed, openFailed }

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else { throw TapDecoderError.noCodecParameters }
        timeBase = stream.pointee.time_base
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw TapDecoderError.unsupportedCodec
        }
        guard let ctx = avcodec_alloc_context3(codec) else { throw TapDecoderError.allocFailed }
        codecContext = ctx
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0,
              avcodec_open2(ctx, codec, nil) >= 0 else {
            avcodec_free_context(&codecContext)
            throw TapDecoderError.openFailed
        }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [AudioTapChunk] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        guard avcodec_send_packet(ctx, packet) >= 0 else { return [] }
        return receiveAll(ctx)
    }

    /// EOF drain: flush delay frames, then force-emit the sub-threshold tail.
    func drain() -> [AudioTapChunk] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        avcodec_send_packet(ctx, nil)
        var chunks = receiveAll(ctx)
        if let tail = emitPending(force: true) { chunks.append(tail) }
        return chunks
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if codecContext != nil { avcodec_free_context(&codecContext) }
        if swrContext != nil { swr_free(&swrContext) }
        pending.removeAll()
        anchorPTS = nil
        samplesSinceAnchor = 0
    }

    deinit { close() }

    // MARK: - Internals (all called with stateLock held)

    private func receiveAll(_ ctx: UnsafeMutablePointer<AVCodecContext>) -> [AudioTapChunk] {
        var chunks: [AudioTapChunk] = []
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }
        while avcodec_receive_frame(ctx, f) >= 0 {
            if swrContext == nil, !initResampler(from: f) { continue }
            ingest(frame: f)
            if pending.count >= AudioTapDefaults.minSamplesPerChunk,
               let chunk = emitPending(force: false) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    private func initResampler(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 1)
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, 2)
        }
        // copy() allocates a channel map for custom-order layouts; uninit or that map leaks.
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }
        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout, AV_SAMPLE_FMT_FLT, Int32(AudioTapDefaults.sampleRate),
            &inLayout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate,
            0, nil
        )
        guard ret >= 0, swrContext != nil, swr_init(swrContext) >= 0 else {
            if swrContext != nil { swr_free(&swrContext) }
            return false
        }
        return true
    }

    private func ingest(frame f: UnsafeMutablePointer<AVFrame>) {
        guard let swr = swrContext, f.pointee.nb_samples > 0 else { return }

        let framePTS: Double? = f.pointee.pts != Int64.min && timeBase.den > 0
            ? Double(f.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
            : nil
        let runningPTS = anchorPTS.map { $0 + Double(samplesSinceAnchor) / AudioTapDefaults.sampleRate }
        if anchorPTS == nil || (framePTS != nil && runningPTS != nil && abs(framePTS! - runningPTS!) > 0.25) {
            // First frame, or a real discontinuity: drop the misplaced tail and re-anchor.
            pending.removeAll(keepingCapacity: true)
            anchorPTS = framePTS ?? 0
            samplesSinceAnchor = 0
        }
        if pending.isEmpty {
            pendingStartPTS = anchorPTS! + Double(samplesSinceAnchor) / AudioTapDefaults.sampleRate
        }

        let maxOut = Int(swr_get_out_samples(swr, f.pointee.nb_samples))
        guard maxOut > 0 else { return }
        var out = [Float](repeating: 0, count: maxOut)
        let converted: Int32 = out.withUnsafeMutableBytes { raw in
            var outPtr: UnsafeMutablePointer<UInt8>? =
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafeMutablePointer(to: &outPtr) { outBuf in
                let srcData = UnsafePointer<UnsafePointer<UInt8>?>(
                    OpaquePointer(f.pointee.extended_data)
                )
                return swr_convert(swr, outBuf, Int32(maxOut), srcData, f.pointee.nb_samples)
            }
        }
        guard converted > 0 else { return }
        pending.append(contentsOf: out.prefix(Int(converted)))
        samplesSinceAnchor += Int64(converted)
    }

    private func emitPending(force: Bool) -> AudioTapChunk? {
        guard !pending.isEmpty, force || pending.count >= AudioTapDefaults.minSamplesPerChunk else {
            return nil
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                         frameCapacity: AVAudioFrameCount(pending.count)) else {
            pending.removeAll(keepingCapacity: true)
            return nil
        }
        buf.frameLength = AVAudioFrameCount(pending.count)
        pending.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        let chunk = AudioTapChunk(buffer: buf, ptsSeconds: pendingStartPTS)
        pendingStartPTS += Double(pending.count) / AudioTapDefaults.sampleRate
        pending.removeAll(keepingCapacity: true)
        return chunk
    }
}

/// Decodes one loopback fMP4 fragment (#95): composes init + segment in memory (the
/// scrub-thumbnail precedent, see `DataIOReader`), demuxes, decodes the single audio track.
/// A fresh demux + codec context per segment keeps it robust across producer restarts and
/// track switches; the cost is negligible against 4-6 s of audio per segment.
final class AudioTapSegmentDecoder: @unchecked Sendable {
    func decode(initData: Data, segment: Data) -> [AudioTapChunk] {
        var composed = Data(capacity: initData.count + segment.count)
        composed.append(initData)
        composed.append(segment)
        let demuxer = Demuxer()
        do {
            try demuxer.open(reader: DataIOReader(data: composed))
        } catch {
            return []
        }
        defer { demuxer.close() }
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else { return [] }
        let decoder = AudioTapDecoder()
        do {
            try decoder.open(stream: stream)
        } catch {
            return []
        }
        defer { decoder.close() }

        var chunks: [AudioTapChunk] = []
        while let packet = (try? demuxer.readPacket()) ?? nil {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&p) }
            guard packet.pointee.stream_index == audioIdx else { continue }
            chunks.append(contentsOf: decoder.decode(packet: packet))
        }
        chunks.append(contentsOf: decoder.drain())
        return chunks
    }

    /// Decode a self-describing HLS segment (MPEG-TS or fMP4-with-inline-moof) whose container
    /// FFmpeg detects unaided. Used by the remote-HLS tap, where segments carry no separate init
    /// blob (unlike the loopback fMP4 fragments). Same fresh-demux-per-segment discipline.
    func decode(selfContainedSegment segment: Data) -> [AudioTapChunk] {
        let demuxer = Demuxer()
        do {
            try demuxer.open(reader: DataIOReader(data: segment))
        } catch {
            return []
        }
        defer { demuxer.close() }
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else { return [] }
        let decoder = AudioTapDecoder()
        do {
            try decoder.open(stream: stream)
        } catch {
            return []
        }
        defer { decoder.close() }

        var chunks: [AudioTapChunk] = []
        while let packet = (try? demuxer.readPacket()) ?? nil {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&p) }
            guard packet.pointee.stream_index == audioIdx else { continue }
            chunks.append(contentsOf: decoder.decode(packet: packet))
        }
        chunks.append(contentsOf: decoder.drain())
        return chunks
    }
}
