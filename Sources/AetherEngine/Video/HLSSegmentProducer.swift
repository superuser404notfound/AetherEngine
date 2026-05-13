import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Drives libavformat's `hls` muxer for the duration of one rendition
/// (one elementary stream: video XOR one audio track). Replaces the
/// previous design where a single producer multiplexed video + an
/// optional audio side-band into one fMP4 stream.
///
/// One producer = one stream = one fMP4 output = one `HLSSegmentCache`.
/// Pump loop reads from the producer's own `Demuxer`, filters packets
/// on `sourceStreamIndex`, and writes them as muxer output stream 0.
/// Caller (HLSVideoEngine) constructs one of these per HLS rendition
/// it publishes through `HLSLocalServer`: one video producer for the
/// video rendition, one audio producer per audio rendition.
///
/// The multi-rendition split is what enables AVMediaSelection-based
/// seamless audio switching in AVPlayer: each rendition is a self-
/// contained EXT-X-MEDIA TYPE=AUDIO entry the player can switch into
/// at PTS-alignment time, without tearing the video render surface
/// down.
final class HLSSegmentProducer: @unchecked Sendable {

    // MARK: - Errors

    enum ProducerError: Error, CustomStringConvertible {
        case muxerAllocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case writeHeaderFailed(code: Int32)

        var description: String {
            switch self {
            case .muxerAllocFailed(let c):     return "HLSSegmentProducer: avformat_alloc_output_context2 for hls failed (\(c))"
            case .streamCreationFailed:        return "HLSSegmentProducer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "HLSSegmentProducer: avcodec_parameters_copy failed (\(c))"
            case .writeHeaderFailed(let c):    return "HLSSegmentProducer: avformat_write_header failed (\(c))"
            }
        }
    }

    /// Per-stream codec config for the video kind.
    struct StreamConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Override the codec_tag emitted by the mp4 sub-muxer. Used to
        /// force `dvh1` / `hvc1` / `avc1` / `vp09` / `av01` instead of
        /// FFmpeg's defaults of `hev1` / `h264`, which AVPlayer rejects.
        let codecTagOverride: String?
        /// Source-container stream index. Pump filters packets on this
        /// index; everything else is discarded.
        let sourceStreamIndex: Int32
    }

    /// Per-stream codec config for the audio kind. Supports both
    /// stream-copy passthrough (e.g. EAC3-JOC Atmos) and FLAC re-encode
    /// via `AudioBridge` for codecs that aren't legal in fMP4.
    struct AudioConfig {
        /// codecpar installed on the muxer's audio output stream. For
        /// stream-copy this is the source's codecpar; for FLAC bridge
        /// this is `AudioBridge.encoderCodecpar`.
        let codecpar: UnsafePointer<AVCodecParameters>
        /// time_base set on the muxer stream. The muxer rewrites this
        /// to its own auto-picked timescale at write_header time, but
        /// we still need to set the input value so libavformat knows
        /// the requested base.
        let timeBase: AVRational
        /// Source stream index to filter packets from in the demuxer.
        let sourceStreamIndex: Int32
        /// Time base of packets handed to `av_write_frame`. For
        /// stream-copy this is the source's time_base. For FLAC bridge
        /// this is `AudioBridge.encoderTimeBase` (the bridge re-stamps
        /// the FLAC packets it emits into its encoder's time_base).
        let inputTimeBase: AVRational
        /// Optional decode-then-FLAC-encode bridge. Non-nil routes each
        /// source audio packet through `bridge.feed` and muxes the
        /// returned FLAC packets; nil means stream-copy.
        let bridge: AudioBridge?
    }

    /// Discriminated kind: a producer pumps either video XOR one audio
    /// track, never both. The single-stream invariant is what makes
    /// the pump loop trivial and the muxer's segment-cut decisions
    /// per-rendition independent.
    enum Kind {
        case video(StreamConfig)
        case audio(AudioConfig)
    }

    // MARK: - State

    private let demuxer: Demuxer
    private let kind: Kind
    private let cache: SegmentCache
    /// Absolute index offset for segments produced by this instance.
    /// Initial bring-up uses 0; the restart machinery passes the
    /// scrub-target index here.
    private let baseIndex: Int

    /// Source stream's time_base. Carried into pump so packet pts/dts
    /// can be rescaled from source units to the muxer's chosen output
    /// time_base before each `av_write_frame`.
    private let sourceTimeBase: AVRational
    /// Muxer's chosen time_base for the output stream, latched after
    /// `avformat_write_header`. Used as the destination time_base for
    /// `av_packet_rescale_ts`. The hls muxer (via its mov sub-muxer)
    /// rewrites the output stream's time_base to its own auto-picked
    /// timescale (e.g. 1/16000 for 30 fps video, 1/<sampleRate> for
    /// audio); source packets still carry source-time-base pts/dts so
    /// we must rescale every packet before writing it.
    private var muxerTimeBase: AVRational = AVRational(num: 1, den: 1)

    /// Source-container stream index the pump filters on. Cached out
    /// of the Kind so the hot loop doesn't have to switch each packet.
    private let sourceStreamIndex: Int32

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// How many segments the pump is allowed to race ahead of the
    /// highest segment AVPlayer has actually fetched. With the cache's
    /// default `forwardWindow = 20` this leaves headroom behind the
    /// playhead for cheap short-range backward scrubs without
    /// triggering a producer restart.
    private static let bufferAheadSegments = 20

    /// Worker queue running the read → write_frame pump. One per
    /// producer instance; serial, no concurrent writes to the format
    /// context. Closed when `stop()` is called.
    private let pumpQueue: DispatchQueue

    private let stateLock = NSLock()
    private var pumpStarted = false
    private var shouldStop = false

    /// Set once the pump exits (EOF, error, or `stop()`). Read by
    /// `waitForFinish(timeout:)` so the host can synchronously tear
    /// this producer down before constructing a successor at a
    /// different `baseIndex` (the scrub-restart path).
    private let finishCondition = NSCondition()
    private var didFinishFlag = false
    var didFinish: Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return didFinishFlag
    }

    // MARK: - Init

    init(
        demuxer: Demuxer,
        kind: Kind,
        cache: SegmentCache,
        baseIndex: Int = 0,
        targetSegmentDurationSeconds: Double = 6.0
    ) throws {
        self.demuxer = demuxer
        self.kind = kind
        self.cache = cache
        self.baseIndex = baseIndex

        switch kind {
        case .video(let cfg):
            self.sourceStreamIndex = cfg.sourceStreamIndex
            self.sourceTimeBase = cfg.timeBase
            self.pumpQueue = DispatchQueue(
                label: "AetherEngine.HLSSegmentProducer.video.pump",
                qos: .userInitiated
            )
        case .audio(let cfg):
            self.sourceStreamIndex = cfg.sourceStreamIndex
            self.sourceTimeBase = cfg.inputTimeBase
            self.pumpQueue = DispatchQueue(
                label: "AetherEngine.HLSSegmentProducer.audio.pump",
                qos: .userInitiated
            )
        }

        // 1. Allocate hls output context. Output url "playlist.m3u8" is
        //    a placeholder: hlsenc derives segment filenames from it
        //    when `hls_segment_filename` isn't set; we override it
        //    explicitly below.
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "hls", "playlist.m3u8")
        guard allocRet == 0, let ctx = ctxOut else {
            throw ProducerError.muxerAllocFailed(code: allocRet)
        }
        formatContext = ctx

        // 2. Allow non-standard extensions so the inner mp4 sub-muxer
        //    writes `dvcC` / `dvvC` atoms (DV-spec, not ISOBMFF base).
        ctx.pointee.strict_std_compliance = -2

        // 3. Wire the IO trampolines. The opaque we stash here is also
        //    propagated to the nested mp4 sub-muxer (hls_mux_init copies
        //    `s->opaque` and the io callbacks onto `oc`), so the
        //    trampolines below receive the same producer pointer
        //    regardless of which AVFormatContext invoked them.
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.io_open = hlsProducerIOOpen
        ctx.pointee.io_close2 = hlsProducerIOClose2

        // 4. Add the single output stream. Per-kind codec parameter and
        //    time-base; the mp4 sub-muxer rescales to its own track
        //    timescale automatically at write_header.
        guard let outStream = avformat_new_stream(ctx, nil) else {
            cleanup()
            throw ProducerError.streamCreationFailed
        }
        switch kind {
        case .video(let cfg):
            let copyRet = avcodec_parameters_copy(outStream.pointee.codecpar, cfg.codecpar)
            guard copyRet >= 0 else {
                cleanup()
                throw ProducerError.copyParametersFailed(code: copyRet)
            }
            outStream.pointee.time_base = cfg.timeBase
            if let override = cfg.codecTagOverride,
               let tag = Self.mkTag(fromFourCC: override) {
                outStream.pointee.codecpar.pointee.codec_tag = tag
            }
        case .audio(let cfg):
            let copyRet = avcodec_parameters_copy(outStream.pointee.codecpar, cfg.codecpar)
            guard copyRet >= 0 else {
                cleanup()
                throw ProducerError.copyParametersFailed(code: copyRet)
            }
            outStream.pointee.time_base = cfg.timeBase
        }

        // 5. Configure hls muxer options. The mp4 sub-muxer's movflags
        //    are set inside hls_mux_init at libavformat/hlsenc.c:867
        //    (`+frag_custom+dash+delay_moov`); we do not override them.
        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "hls_segment_type", "fmp4", 0)
        av_dict_set(&opts, "hls_fmp4_init_filename", "init.mp4", 0)
        av_dict_set(&opts, "hls_segment_filename", "seg-%d.m4s", 0)
        let hlsTimeStr = String(format: "%.3f", targetSegmentDurationSeconds)
        av_dict_set(&opts, "hls_time", hlsTimeStr, 0)
        av_dict_set(&opts, "hls_playlist_type", "vod", 0)
        av_dict_set(&opts, "hls_list_size", "0", 0)
        av_dict_set(&opts, "hls_flags", "independent_segments", 0)
        if baseIndex > 0 {
            av_dict_set(&opts, "start_number", String(baseIndex), 0)
        }

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            cleanup()
            throw ProducerError.writeHeaderFailed(code: ret)
        }

        muxerTimeBase = ctx.pointee.streams.advanced(by: 0).pointee!.pointee.time_base

        let kindDesc: String
        switch kind {
        case .video:
            kindDesc = "video stream=\(sourceStreamIndex)"
        case .audio(let cfg):
            let mode = cfg.bridge != nil ? "bridge" : "stream-copy"
            kindDesc = "audio stream=\(sourceStreamIndex) mode=\(mode)"
        }
        EngineLog.emit(
            "[HLSSegmentProducer] muxer init OK (\(kindDesc), baseIndex=\(baseIndex), targetDur=\(hlsTimeStr)s, "
            + "srcTb=\(sourceTimeBase.num)/\(sourceTimeBase.den) "
            + "muxerTb=\(muxerTimeBase.num)/\(muxerTimeBase.den))",
            category: .session
        )
    }

    deinit {
        cleanup()
    }

    // MARK: - Public API

    /// Start the read → write_frame pump on the worker queue.
    func start() {
        stateLock.lock()
        guard !pumpStarted else { stateLock.unlock(); return }
        pumpStarted = true
        stateLock.unlock()

        pumpQueue.async { [weak self] in
            self?.runPumpLoop()
        }
    }

    /// Signal the pump to stop at the next loop iteration. Async — the
    /// pump may be blocked inside `demuxer.readPacket` waiting on an
    /// HTTP byte-range read, which can take up to its own network
    /// timeout to return. Use `waitForFinish(timeout:)` if you need
    /// the pump to actually be gone before proceeding (the restart
    /// path does). Also wakes any pump currently parked in
    /// `cache.awaitFetchHighWater` so the restart path doesn't pay up
    /// to a second of latency waiting for the backpressure poll to
    /// time out on its own.
    func stop() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
        cache.wakeWaiters()
    }

    /// Thread-safe read of `shouldStop`. Used by the dispatchSinkOutput
    /// backpressure loop to poll for cancellation between short cache
    /// waits.
    fileprivate func checkShouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    /// Block until the pump has exited or `timeout` elapses. Returns
    /// `true` if the pump finished, `false` on timeout (in which case
    /// the caller can choose to leak this instance and proceed with a
    /// fresh producer; the lingering pump will finish on its own once
    /// the demuxer read returns).
    func waitForFinish(timeout: TimeInterval) -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        if didFinishFlag { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !didFinishFlag {
            if !finishCondition.wait(until: deadline) { return false }
        }
        return true
    }

    // MARK: - Pump

    private func runPumpLoop() {
        guard let ctx = formatContext else { return }

        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var packetsWritten = 0
        var lastError: Int32 = 0

        do {
            readLoop: while true {
                stateLock.lock()
                let stopRequested = shouldStop
                stateLock.unlock()
                if stopRequested { break readLoop }

                guard let packet = try demuxer.readPacket() else {
                    // EOF
                    break readLoop
                }
                packetsRead += 1
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pktPtr) }

                if packet.pointee.stream_index != sourceStreamIndex {
                    // Not our stream (other tracks, attachments, etc).
                    // Each rendition owns its own demuxer cursor, so
                    // other streams are still demuxed but discarded
                    // here.
                    continue
                }

                switch kind {
                case .video:
                    packet.pointee.stream_index = 0
                    av_packet_rescale_ts(packet, sourceTimeBase, muxerTimeBase)
                    let ret = av_write_frame(ctx, packet)
                    if ret < 0 {
                        lastError = ret
                        EngineLog.emit(
                            "[HLSSegmentProducer] video av_write_frame failed at packet \(packetsRead): \(ret)",
                            category: .session
                        )
                        break readLoop
                    }
                    packetsWritten += 1

                case .audio(let cfg):
                    if let bridge = cfg.bridge {
                        // Decode + resample + FLAC-encode. Each call
                        // returns 0..N encoded FLAC packets stamped in
                        // `bridge.encoderTimeBase`; caller takes
                        // ownership and frees after muxing.
                        let flacPackets: [UnsafeMutablePointer<AVPacket>]
                        do {
                            flacPackets = try bridge.feed(packet: packet)
                        } catch {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio bridge.feed failed at pkt#\(packetsRead): \(error)",
                                category: .session
                            )
                            continue
                        }
                        for fp in flacPackets {
                            fp.pointee.stream_index = 0
                            av_packet_rescale_ts(fp, cfg.inputTimeBase, muxerTimeBase)
                            _ = av_write_frame(ctx, fp)
                            var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                            av_packet_free(&fpVar)
                        }
                        packetsWritten += 1
                    } else {
                        packet.pointee.stream_index = 0
                        av_packet_rescale_ts(packet, cfg.inputTimeBase, muxerTimeBase)
                        let ret = av_write_frame(ctx, packet)
                        if ret < 0 {
                            lastError = ret
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio av_write_frame failed at packet \(packetsRead): \(ret)",
                                category: .session
                            )
                            break readLoop
                        }
                        packetsWritten += 1
                    }
                }
            }
        } catch {
            EngineLog.emit(
                "[HLSSegmentProducer] demuxer.readPacket threw: \(error)",
                category: .session
            )
        }

        // Trailer flushes the final segment and writes the playlist;
        // our io_open trampoline still catches whatever bytes that
        // produces. Safe to call on partial / error exit too.
        let trailerRet = av_write_trailer(ctx)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWritten) trailer=\(trailerRet) lastError=\(lastError) "
            + "elapsed=\(String(format: "%.0f", elapsedMs))ms cacheCount=\(cache.count)",
            category: .session
        )

        finishCondition.lock()
        didFinishFlag = true
        finishCondition.broadcast()
        finishCondition.unlock()
    }

    // MARK: - IO trampoline plumbing (called from the C callbacks below)

    fileprivate func openSink(url: String) -> UnsafeMutablePointer<AVIOContext>? {
        let sink = SegmentSink(url: url)
        let opaque = Unmanaged.passRetained(sink).toOpaque()
        let bufSize: Int32 = 65536
        guard let raw = av_malloc(Int(bufSize)) else {
            Unmanaged<SegmentSink>.fromOpaque(opaque).release()
            return nil
        }
        let buf = raw.assumingMemoryBound(to: UInt8.self)
        guard let pb = avio_alloc_context(
            buf,
            bufSize,
            /* write_flag */ 1,
            opaque,
            nil,
            hlsProducerSinkWrite,
            nil
        ) else {
            av_free(raw)
            Unmanaged<SegmentSink>.fromOpaque(opaque).release()
            return nil
        }
        pb.pointee.seekable = 0
        return pb
    }

    fileprivate func closeSink(pb: UnsafeMutablePointer<AVIOContext>) {
        avio_flush(pb)
        let opaqueRaw = pb.pointee.opaque
        var data = Data()
        var url = ""
        if let opaque = opaqueRaw {
            let sink = Unmanaged<SegmentSink>.fromOpaque(opaque).takeRetainedValue()
            data = sink.buffer
            url = sink.url
        }
        // Free the buffer libavformat currently has on the context. It
        // may have been reallocated since openSink (avio grows it on
        // demand when callers write more than `bufSize` between flushes).
        if pb.pointee.buffer != nil {
            withUnsafeMutablePointer(to: &pb.pointee.buffer) { bufRef in
                bufRef.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                    av_freep(UnsafeMutableRawPointer(raw))
                }
            }
        }
        var pbVar: UnsafeMutablePointer<AVIOContext>? = pb
        avio_context_free(&pbVar)

        dispatchSinkOutput(url: url, data: data)
    }

    private func dispatchSinkOutput(url: String, data: Data) {

        if url == "init.mp4" {
            EngineLog.emit(
                "[HLSSegmentProducer] init.mp4 captured (\(data.count) B)",
                category: .session
            )
            cache.setInit(data)
            return
        }
        // "seg-N.m4s" — N is the hlsenc sequence number, which equals
        // (baseIndex + local segment count) when we set `start_number`.
        // Re-deriving from the filename keeps the cache key authoritative
        // even if hlsenc renumbers internally.
        if url.hasPrefix("seg-"), url.hasSuffix(".m4s") {
            let inner = url.dropFirst("seg-".count).dropLast(".m4s".count)
            if let absIdx = Int(inner) {
                // Backpressure FIRST, store SECOND. Doing the store
                // before the wait lets `pruneOutsideWindow` evict the
                // just-written segment whenever the cache window
                // hasn't slid to include `absIdx` yet (race window:
                // AVPlayer fetch latency greater than muxer cut
                // interval). Waiting first keeps the window centred
                // such that every stored segment fits.
                //
                // Poll with short 1 s waits so `stop()` can shut us
                // down promptly during a restart instead of stranding
                // the pump in a 60 s sleep.
                let target = absIdx - Self.bufferAheadSegments
                while !checkShouldStop() {
                    if cache.awaitFetchHighWater(reaching: target, timeout: 1.0) { break }
                }
                if checkShouldStop() { return }

                EngineLog.emit(
                    "[HLSSegmentProducer] seg-\(absIdx).m4s captured (\(data.count) B)",
                    category: .session
                )
                cache.store(index: absIdx, data: data)
                return
            }
        }
        // playlist.m3u8 (or any other path) — we generate our own
        // playlist from the pre-planned segment list, so any bytes
        // hlsenc writes here are discarded.
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let ctx = formatContext {
            // Clear opaque first so any late io_open from the muxer's
            // own teardown path doesn't dereference a self that's about
            // to disappear. (avformat_free_context shouldn't trigger
            // io_open at this point, but defensive.)
            ctx.pointee.opaque = nil
            avformat_free_context(ctx)
            formatContext = nil
        }
    }

    // MARK: - Helpers

    /// Equivalent of FFmpeg's `MKTAG(a, b, c, d)`. Encodes a four-character
    /// code as a little-endian `UInt32` (byte 0 = a, byte 3 = d).
    private static func mkTag(fromFourCC fourCC: String) -> UInt32? {
        let chars = Array(fourCC)
        guard chars.count == 4 else { return nil }
        var tag: UInt32 = 0
        for (i, ch) in chars.enumerated() {
            guard let ascii = ch.asciiValue else { return nil }
            tag |= UInt32(ascii) << (i * 8)
        }
        return tag
    }
}

// MARK: - Sink storage

private final class SegmentSink {
    let url: String
    var buffer = Data()
    init(url: String) { self.url = url }
}

// MARK: - C callback bridges

/// `s->io_open` trampoline. Routed back into the `HLSSegmentProducer`
/// via the `s->opaque` pointer set at construction. Returns a custom
/// `AVIOContext` whose write callback appends to a per-sink `Data`
/// buffer; the closeSink path drains that buffer into the `SegmentCache`.
private func hlsProducerIOOpen(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
    url: UnsafePointer<CChar>?,
    flags: Int32,
    options: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32 {
    guard let s = s, let pb = pb, let url = url, let opaque = s.pointee.opaque else {
        return -1
    }
    let producer = Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue()
    let urlStr = String(cString: url)
    guard let ctx = producer.openSink(url: urlStr) else { return -1 }
    pb.pointee = ctx
    return 0
}

/// `s->io_close2` trampoline. Drains the sink's accumulated buffer
/// into the producer's dispatch path and frees the `AVIOContext`.
private func hlsProducerIOClose2(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<AVIOContext>?
) -> Int32 {
    guard let s = s, let pb = pb, let opaque = s.pointee.opaque else { return 0 }
    let producer = Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue()
    producer.closeSink(pb: pb)
    return 0
}

/// `avio_alloc_context` write callback. `opaque` is the retained
/// `SegmentSink` pointer set in `openSink`.
private func hlsProducerSinkWrite(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf, size > 0 else { return -1 }
    let sink = Unmanaged<SegmentSink>.fromOpaque(opaque).takeUnretainedValue()
    sink.buffer.append(buf, count: Int(size))
    return size
}
