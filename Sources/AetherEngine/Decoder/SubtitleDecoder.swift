import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// AVERROR_EOF — FFmpeg's end-of-file sentinel.
private let AVERROR_EOF_VALUE: Int32 = -541478725

enum SubtitleDecoderError: Error {
    case openFailed(code: Int32)
    case noSubtitleStream
    case noDecoder
    case codecOpenFailed(code: Int32)
}

/// One-shot decoder for sidecar subtitle files (.srt / .ass / .vtt /
/// .ssa next to the media). Opens the URL as its own AVFormatContext,
/// finds the single subtitle stream, walks every packet, and returns
/// the decoded cue list.
///
/// Distinct from the main demux loop's streaming decoder which routes
/// subtitle packets that are *already* flowing for an embedded track —
/// sidecars are separate small files that the main demuxer never sees,
/// so they need their own context. Bandwidth-wise this is cheap: a
/// typical SRT/ASS file is ~50–200 KB, served straight from the host
/// (Jellyfin) with no extraction work.
enum SubtitleDecoder {

    /// Decode every cue out of the subtitle file at `url`. Cancellable
    /// via `Task.cancel()`; throws on open / codec failure. Returns
    /// cues sorted by `startTime`.
    static func decodeFile(url: URL) async throws -> [SubtitleCue] {
        try await Task.detached(priority: .userInitiated) {
            try decodeFileSync(url: url)
        }.value
    }

    // MARK: - Synchronous core

    private static func decodeFileSync(url: URL) throws -> [SubtitleCue] {
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        var avioReader: AVIOReader?

        if isHTTP {
            let reader = AVIOReader(url: url)
            try reader.open()
            avioReader = reader
            guard let ctx = avformat_alloc_context() else {
                reader.close()
                throw SubtitleDecoderError.openFailed(code: -1)
            }
            ctx.pointee.pb = reader.context
            formatContext = ctx
            var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
            let ret = avformat_open_input(&ctxPtr, nil, nil, nil)
            guard ret == 0 else {
                reader.close()
                throw SubtitleDecoderError.openFailed(code: ret)
            }
            formatContext = ctxPtr
        } else {
            var ctx: UnsafeMutablePointer<AVFormatContext>?
            let urlString = url.isFileURL ? url.path : url.absoluteString
            let ret = avformat_open_input(&ctx, urlString, nil, nil)
            guard ret == 0, ctx != nil else {
                throw SubtitleDecoderError.openFailed(code: ret)
            }
            formatContext = ctx
        }

        defer {
            if formatContext != nil {
                avformat_close_input(&formatContext)
            }
            avioReader?.close()
        }

        guard let fmt = formatContext else {
            throw SubtitleDecoderError.openFailed(code: -1)
        }

        let probeRet = avformat_find_stream_info(fmt, nil)
        guard probeRet >= 0 else {
            throw SubtitleDecoderError.openFailed(code: probeRet)
        }

        // Sidecar containers usually expose exactly one subtitle stream
        // at index 0, but probe defensively in case a container wraps
        // multiple sub tracks or an unrelated stream sneaks in.
        var subStreamIndex: Int = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar
            else { continue }
            if codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                subStreamIndex = i
                break
            }
        }
        guard subStreamIndex >= 0,
              let stream = fmt.pointee.streams[subStreamIndex],
              let codecpar = stream.pointee.codecpar
        else {
            throw SubtitleDecoderError.noSubtitleStream
        }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw SubtitleDecoderError.noDecoder
        }
        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw SubtitleDecoderError.codecOpenFailed(code: -1)
        }
        var localCodecCtx: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        defer { avcodec_free_context(&localCodecCtx) }

        let paramsRet = avcodec_parameters_to_context(codecCtx, codecpar)
        guard paramsRet >= 0 else {
            throw SubtitleDecoderError.codecOpenFailed(code: paramsRet)
        }
        let openRet = avcodec_open2(codecCtx, codec, nil)
        guard openRet >= 0 else {
            throw SubtitleDecoderError.codecOpenFailed(code: openRet)
        }

        let timeBase = stream.pointee.time_base
        let tbSec = Double(timeBase.num) / Double(timeBase.den)

        var cues: [SubtitleCue] = []
        var nextID = 0

        while !Task.isCancelled {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let pkt = pktPtr else { break }
            let readRet = av_read_frame(fmt, pkt)
            if readRet < 0 {
                av_packet_free(&pktPtr)
                break
            }

            if Int(pkt.pointee.stream_index) != subStreamIndex {
                av_packet_unref(pkt)
                av_packet_free(&pktPtr)
                continue
            }

            var sub = AVSubtitle()
            var gotSub: Int32 = 0
            let ret = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt)

            if ret >= 0 && gotSub != 0 {
                let pktPTS = pkt.pointee.pts == Int64.min
                    ? 0.0
                    : Double(pkt.pointee.pts) * tbSec
                let startOffset = Double(sub.start_display_time) / 1000.0
                let endOffset: Double
                if sub.end_display_time > 0 {
                    endOffset = Double(sub.end_display_time) / 1000.0
                } else if pkt.pointee.duration > 0 {
                    endOffset = Double(pkt.pointee.duration) * tbSec
                } else {
                    endOffset = 5.0
                }
                let startTime = pktPTS + startOffset
                let endTime = pktPTS + endOffset

                var lines: [String] = []
                if sub.num_rects > 0, let rects = sub.rects {
                    for i in 0..<Int(sub.num_rects) {
                        guard let rect = rects[i] else { continue }
                        if let text = textForRect(rect) {
                            lines.append(text)
                        }
                    }
                }
                avsubtitle_free(&sub)

                let merged = lines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !merged.isEmpty && endTime > startTime {
                    cues.append(SubtitleCue(
                        id: nextID,
                        startTime: startTime,
                        endTime: endTime,
                        text: merged
                    ))
                    nextID += 1
                }
            }

            av_packet_unref(pkt)
            av_packet_free(&pktPtr)
        }

        // Flush — ASS/SSA decoders sometimes buffer events.
        var flushPkt = AVPacket()
        flushPkt.data = nil
        flushPkt.size = 0
        var flushSub = AVSubtitle()
        var gotSub: Int32 = 0
        if avcodec_decode_subtitle2(codecCtx, &flushSub, &gotSub, &flushPkt) >= 0 && gotSub != 0 {
            avsubtitle_free(&flushSub)
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Rect → text

    private static func textForRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            var line = String(cString: assPtr)
            if line.hasPrefix("Dialogue: ") {
                line.removeFirst("Dialogue: ".count)
            }
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let raw = parts.count == 9 ? String(parts[8]) : line
            return cleanASSBody(raw)
        }
        return nil
    }

    private static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
