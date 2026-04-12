import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// FFmpeg AVFormatContext wrapper. Opens a media URL, reads the stream
/// info, and produces demuxed `AVPacket`s for the decoder.
///
/// Thread safety: all calls must happen on the demux serial queue.
final class Demuxer {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// Open a media URL and probe its streams.
    func open(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let urlString = url.absoluteString

        let ret = avformat_open_input(&ctx, urlString, nil, nil)
        guard ret == 0, let ctx = ctx else {
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = ctx

        let findRet = avformat_find_stream_info(ctx, nil)
        guard findRet >= 0 else {
            throw DemuxerError.streamInfoFailed(code: findRet)
        }

        #if DEBUG
        print("[Demuxer] Opened: \(ctx.pointee.nb_streams) streams, duration=\(ctx.pointee.duration) µs")
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

    /// Access an AVStream by index.
    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else {
            return nil
        }
        return ctx.pointee.streams[Int(index)]
    }

    /// Read the next packet from the container.
    /// Returns the packet on success, nil at EOF.
    /// Throws on read errors (network failure, corrupt data, etc).
    func readPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        guard let ctx = formatContext else { return nil }
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if ret < 0 {
            av_packet_free(&packet)
            // AVERROR_EOF is negative; any other negative value is an error
            let isEOF = (ret == -541478725)  // AVERROR_EOF = FFERRTAG(0xF8,'E','O','F')
            if isEOF {
                return nil
            }
            throw DemuxerError.readFailed(code: ret)
        }
        return packet
    }

    /// Seek to a position in seconds.
    func seek(to seconds: Double) {
        guard let ctx = formatContext else { return }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = av_seek_frame(ctx, -1, timestamp, AVSEEK_FLAG_BACKWARD)
        if ret < 0 {
            #if DEBUG
            print("[Demuxer] Seek to \(seconds)s failed: \(ret)")
            #endif
        }
    }

    /// Close the format context and release resources.
    func close() {
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
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
