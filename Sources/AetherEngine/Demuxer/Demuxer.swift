import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// AVERROR_EOF, FFmpeg's end-of-file sentinel. The C macro can't be
/// imported into Swift, so we define it inline: FFERRTAG(0xF8,'E','O','F').
private let AVERROR_EOF_VALUE: Int32 = -541478725

/// FFmpeg AVFormatContext wrapper. Opens a media URL, reads the stream
/// info, and produces demuxed `AVPacket`s for the decoder.
///
/// For HTTP(S) URLs, uses a custom AVIO context backed by URLSession
/// (since FFmpegBuild has no built-in network stack). File URLs are
/// handled directly by FFmpeg's file protocol.
///
/// Thread safety: `readPacket()` and `seek()` are serialized via an
/// internal lock, so `seek()` can safely be called from any thread
/// (e.g. main actor) while the demux loop reads on a background queue.
final class Demuxer {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// Serializes access to formatContext between readPacket() (demux queue)
    /// and seek() (main actor), prevents concurrent AVFormatContext access
    /// that triggers assertion failures in matroskadec.c.
    private let accessLock = NSLock()

    /// Retained while the format context is open for HTTP streams.
    private var avioReader: AVIOReader?

    /// Open a media URL and probe its streams.
    func open(url: URL) throws {
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        if isHTTP {
            try openHTTP(url: url)
        } else {
            try openLocal(url: url)
        }
    }

    // MARK: - Open Strategies

    /// Open a local file URL via FFmpeg's built-in file protocol.
    private func openLocal(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else {
            throw DemuxerError.openFailed(code: -1)
        }
        applyProbeBudget(allocated)

        let urlString = url.isFileURL ? url.path : url.absoluteString
        let ret = avformat_open_input(&ctx, urlString, nil, nil)
        guard ret == 0, let openedCtx = ctx else {
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = openedCtx

        try probeStreams(openedCtx)
    }

    /// Open an HTTP(S) URL via custom AVIO context + URLSession.
    private func openHTTP(url: URL) throws {
        // 1. Create and open the AVIO reader (performs HEAD request)
        let reader = AVIOReader(url: url)
        try reader.open()
        avioReader = reader

        // 2. Allocate an empty AVFormatContext and attach our AVIO
        guard let ctx = avformat_alloc_context() else {
            throw DemuxerError.openFailed(code: -1)
        }
        ctx.pointee.pb = reader.context
        applyProbeBudget(ctx)
        formatContext = ctx

        // 3. Open input, pass nil for URL since pb is already set
        var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
        let ret = avformat_open_input(&ctxPtr, nil, nil, nil)
        guard ret == 0 else {
            formatContext = nil
            avioReader?.close()
            avioReader = nil
            throw DemuxerError.openFailed(code: ret)
        }
        // avformat_open_input may reallocate, update our reference
        formatContext = ctxPtr

        try probeStreams(ctxPtr!)
    }

    /// Default probe budgets are tuned for live network streams, 5 MB
    /// of bytes and ~5 seconds of analysed content. For big container
    /// files (10–20 GB Blu-ray rips) with sparse subtitle streams that
    /// budget runs out before libavformat sees a single PGS / DVB
    /// presentation segment, leaving those tracks with no codec
    /// parameters and the decoder unable to assemble cues. Bumping
    /// to 50 MB / 60 s gives the probe enough material without
    /// noticeably slowing playback start (LAN can move 50 MB in
    /// well under a second).
    private func applyProbeBudget(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.probesize = 50 * 1024 * 1024
        ctx.pointee.max_analyze_duration = 60 * 1_000_000
    }

    /// Common stream probing after open.
    private func probeStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) throws {
        let findRet = avformat_find_stream_info(ctx, nil)
        guard findRet >= 0 else {
            throw DemuxerError.streamInfoFailed(code: findRet)
        }

        #if DEBUG
        print("[Demuxer] Opened: \(ctx.pointee.nb_streams) streams, duration=\(ctx.pointee.duration) us")
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }
            let codecType = codecpar.pointee.codec_type
            let typeName: String
            switch codecType {
            case AVMEDIA_TYPE_VIDEO: typeName = "video"
            case AVMEDIA_TYPE_AUDIO: typeName = "audio"
            case AVMEDIA_TYPE_SUBTITLE: typeName = "subtitle"
            default: typeName = "other"
            }
            print("[Demuxer]   stream[\(i)] type=\(typeName) \(codecpar.pointee.width)x\(codecpar.pointee.height)")
        }
        #endif
    }

    /// Duration in seconds (or 0 if unknown).
    var duration: Double {
        guard let ctx = formatContext else { return 0 }
        let dur = ctx.pointee.duration
        return dur > 0 ? Double(dur) / Double(AV_TIME_BASE) : 0
    }

    /// Index of the best video stream, or -1 if none.
    var videoStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
    }

    /// Index of the best audio stream, or -1 if none.
    var audioStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
    }

    /// Extract metadata for all audio streams.
    func audioTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    /// Extract metadata for all subtitle streams.
    func subtitleTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    /// Build TrackInfo from an AVStream's metadata.
    private func trackInfo(from stream: UnsafeMutablePointer<AVStream>, index: Int) -> TrackInfo {
        let codecpar = stream.pointee.codecpar!

        // Codec name
        let codecName: String
        if let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
            codecName = String(cString: codec.pointee.name)
        } else {
            codecName = "unknown"
        }

        // Language and title from stream metadata
        let language = metadataValue(stream.pointee.metadata, key: "language")
        let title = metadataValue(stream.pointee.metadata, key: "title")

        // Build display name
        let name: String
        if let title = title, !title.isEmpty {
            name = title
        } else if let lang = language {
            name = "\(lang.uppercased()) (\(codecName))"
        } else {
            name = "Track \(index) (\(codecName))"
        }

        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
        let channels = Int(codecpar.pointee.ch_layout.nb_channels)

        // Atmos detection mirrors the gate used by the audio engine
        // selectAudioTrack path: EAC3 with profile 30 = JOC, which is
        // what every Dolby-Atmos-on-streaming elementary stream is in
        // practice. Lets the UI label the row "Atmos" instead of just
        // its bed channel count.
        let isAtmos = (codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            && codecpar.pointee.profile == 30

        return TrackInfo(
            id: index,
            name: name,
            codec: codecName,
            language: language,
            channels: channels,
            isDefault: isDefault,
            isAtmos: isAtmos
        )
    }

    /// Read a metadata value from an AVDictionary.
    private func metadataValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let dict = dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }

    /// Access an AVStream by index.
    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else {
            return nil
        }
        return ctx.pointee.streams[Int(index)]
    }

    /// Enumerate the source's keyframe positions for the given stream
    /// from libavformat's index, returning each entry's `timestamp`
    /// field in the stream's native timebase.
    ///
    /// MKV / Matroska sources populate their index from the `Cues`
    /// element, which is parsed lazily on the first seek. To get a
    /// useful answer from this method on those sources, the caller
    /// must have already issued a seek (the cue-prewarm in
    /// `HLSVideoEngine.start()` does this). Sources that ship a
    /// keyframe index in their header (MP4 `stss`, MPEG-TS pcr-based,
    /// etc.) populate it during `avformat_find_stream_info` and are
    /// ready immediately.
    ///
    /// Returns an empty array when the index is empty or the stream
    /// index is invalid — callers should treat that as "no usable
    /// index, fall back to a uniform-stride plan".
    ///
    /// FFmpeg's index entries are all keyframe seek points by
    /// definition; the `AVINDEX_KEYFRAME` bit is checked defensively
    /// in case a future libavformat version starts mixing
    /// non-keyframe seek targets in.
    func indexedKeyframes(streamIndex: Int32) -> [Int64] {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext,
              streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(streamIndex)] else {
            return []
        }
        let count = avformat_index_get_entries_count(stream)
        guard count > 0 else { return [] }
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            // AVINDEX_KEYFRAME = 0x0001
            if entry.pointee.flags & 0x0001 != 0,
               entry.pointee.timestamp != Int64.min {
                result.append(entry.pointee.timestamp)
            }
        }
        return result
    }

    /// Read the next packet from the container.
    /// Returns the packet on success, nil at EOF.
    /// Throws on read errors (network failure, corrupt data, etc).
    func readPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return nil }
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if ret < 0 {
            av_packet_free(&packet)
            let isEOF = (ret == AVERROR_EOF_VALUE)
            if isEOF {
                return nil
            }
            throw DemuxerError.readFailed(code: ret)
        }
        return packet
    }

    /// Seek to a position in seconds.
    /// Uses avformat_seek_file instead of av_seek_frame, more robust
    /// for MKV containers (av_seek_frame triggers assertion failures
    /// in matroskadec.c with nested elements).
    func seek(to seconds: Double) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        if ret < 0 {
            #if DEBUG
            print("[Demuxer] Seek to \(seconds)s failed: \(ret)")
            #endif
        }
        // Flush internal parser state after seek, prevents assertion
        // failures in matroskadec.c when reading the next packet.
        avformat_flush(ctx)
    }

    /// Close the format context and release resources.
    /// Thread-safe: waits for any in-progress readPacket() to finish
    /// before freeing the format context. The AVIO reader is marked
    /// closed first so its callback returns -1 immediately, unblocking
    /// any suspended av_read_frame call.
    func close() {
        // 1. Mark AVIO as closed, read callback returns -1 immediately.
        //    This unblocks av_read_frame if the demux thread is suspended
        //    inside a read (tvOS suspends threads in background).
        avioReader?.markClosed()

        // 2. Wait for readPacket() to release the lock, then tear down.
        accessLock.lock()
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
        accessLock.unlock()

        avioReader?.close()
        avioReader = nil
    }

    deinit {
        close()
    }
}

enum DemuxerError: Error {
    case openFailed(code: Int32)
    case streamInfoFailed(code: Int32)
    case readFailed(code: Int32)
}
