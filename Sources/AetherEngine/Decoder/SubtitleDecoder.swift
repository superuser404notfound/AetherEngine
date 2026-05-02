import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// AVERROR_EOF — same value as in Demuxer.swift, redeclared here so the
/// subtitle path stays self-contained.
private let AVERROR_EOF_VALUE: Int32 = -541478725

/// Errors surfaced from `SubtitleDecoder.decodeAll`.
enum SubtitleDecoderError: Error {
    /// The container couldn't be opened (IO failure, format probe, etc).
    case openFailed(code: Int32)
    /// The given stream index didn't refer to a subtitle stream.
    case streamNotSubtitle
    /// FFmpeg has no decoder for this codec — typical for esoteric formats.
    case noDecoder
    /// avcodec_open2 / parameter copy failed.
    case codecOpenFailed(code: Int32)
}

/// One-shot decoder that walks an embedded subtitle stream end-to-end and
/// returns the full cue list. Runs against its **own** AVFormatContext —
/// completely independent of the main playback demuxer — so video/audio
/// flow is never disturbed.
///
/// Only text-based codecs land here (SubRip, ASS/SSA, WebVTT, mov_text).
/// Bitmap formats (PGS, DVB) decode to image rects without a `text` or
/// `ass` field; they produce zero cues, and the host is expected to
/// route those through its server-side extraction fallback instead.
///
/// The decode is cancellable through standard Swift Task cancellation —
/// rapid track switches won't pile up work.
enum SubtitleDecoder {

    /// Open `url`, find the subtitle stream at `streamIndex`, decode every
    /// packet, and return the collected `SubtitleCue` array sorted by
    /// start time. May be cancelled via `Task.cancel()`.
    static func decodeAll(url: URL, streamIndex: Int) async throws -> [SubtitleCue] {
        try await Task.detached(priority: .userInitiated) {
            try decodeAllSync(url: url, streamIndex: streamIndex)
        }.value
    }

    // MARK: - Synchronous core

    private static func decodeAllSync(url: URL, streamIndex: Int) throws -> [SubtitleCue] {
        let isHTTP = url.scheme == "http" || url.scheme == "https"
        print("[SubtitleDecoder] start streamIndex=\(streamIndex) isHTTP=\(isHTTP) url=\(url.absoluteString.prefix(120))")

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
            print("[SubtitleDecoder] probe failed code=\(probeRet)")
            throw SubtitleDecoderError.openFailed(code: probeRet)
        }
        print("[SubtitleDecoder] opened nb_streams=\(fmt.pointee.nb_streams)")

        // Validate that the requested stream is actually a subtitle stream.
        guard streamIndex >= 0,
              streamIndex < Int(fmt.pointee.nb_streams),
              let stream = fmt.pointee.streams[streamIndex],
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        else {
            print("[SubtitleDecoder] streamIndex=\(streamIndex) is not a subtitle stream")
            throw SubtitleDecoderError.streamNotSubtitle
        }

        // Open the codec.
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            print("[SubtitleDecoder] no decoder for codec_id=\(codecpar.pointee.codec_id.rawValue)")
            throw SubtitleDecoderError.noDecoder
        }
        print("[SubtitleDecoder] codec=\(String(cString: codec.pointee.name)) timeBase=\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den)")
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

        // Seek to the very start so we don't miss packets that live before
        // the demuxer's current cursor (the secondary context starts at 0
        // by default but seek is cheap insurance against probe state).
        avformat_seek_file(fmt, -1, Int64.min, 0, Int64.max, 0)
        avformat_flush(fmt)

        // Time base for converting packet PTS to seconds.
        let timeBase = stream.pointee.time_base
        let tbSec = Double(timeBase.num) / Double(timeBase.den)

        var cues: [SubtitleCue] = []
        var nextID = 0
        var totalPackets = 0
        var matchedPackets = 0
        var decodedSubs = 0
        var firstAssSample: String?
        var firstTextSample: String?
        var lastReadErr: Int32 = 0

        // Read until EOF or task cancel.
        while !Task.isCancelled {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let pkt = pktPtr else { break }
            let readRet = av_read_frame(fmt, pkt)
            if readRet < 0 {
                av_packet_free(&pktPtr)
                if readRet == AVERROR_EOF_VALUE { break }
                // Transient read failure — bail rather than spin.
                lastReadErr = readRet
                break
            }
            totalPackets += 1

            // Only decode packets from the chosen subtitle stream.
            if Int(pkt.pointee.stream_index) != streamIndex {
                av_packet_unref(pkt)
                av_packet_free(&pktPtr)
                continue
            }
            matchedPackets += 1

            var sub = AVSubtitle()
            var gotSub: Int32 = 0
            let decodeRet = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt)

            if decodeRet >= 0 && gotSub != 0 {
                decodedSubs += 1
                if firstAssSample == nil, sub.num_rects > 0,
                   let rect = sub.rects?[0] {
                    if let assPtr = rect.pointee.ass {
                        firstAssSample = String(cString: assPtr)
                    }
                    if let textPtr = rect.pointee.text {
                        firstTextSample = String(cString: textPtr)
                    }
                }
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
                    // Last-resort fallback for streams that don't carry
                    // duration (rare) — five seconds is a sensible
                    // average display time for a dialogue line.
                    endOffset = 5.0
                }

                let startTime = pktPTS + startOffset
                let endTime = pktPTS + endOffset

                // Each AVSubtitle may contain multiple rects (e.g. one per
                // simultaneous text overlay); merge them all into a single
                // cue body separated by newlines so the host renders them
                // together.
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
            } else if gotSub == 0 {
                // No subtitle in this packet (possible for streams that
                // emit empty events). Drop and continue.
            }

            av_packet_unref(pkt)
            av_packet_free(&pktPtr)
        }

        // Flush any remaining buffered subtitles by feeding a NULL packet.
        // Most text decoders never buffer, but ASS/SSA can.
        var flushPkt = AVPacket()
        flushPkt.data = nil
        flushPkt.size = 0
        var flushSub = AVSubtitle()
        var gotSub: Int32 = 0
        if avcodec_decode_subtitle2(codecCtx, &flushSub, &gotSub, &flushPkt) >= 0 && gotSub != 0 {
            avsubtitle_free(&flushSub)
        }

        let assPreview = firstAssSample.map { $0.prefix(80) } ?? "nil"
        let textPreview = firstTextSample.map { $0.prefix(80) } ?? "nil"
        print("[SubtitleDecoder] done totalPackets=\(totalPackets) matched=\(matchedPackets) decoded=\(decodedSubs) cues=\(cues.count) lastReadErr=\(lastReadErr) firstAss=\(assPreview) firstText=\(textPreview)")

        return cues.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Rect → text

    /// Pull the displayable text out of an `AVSubtitleRect`. Prefers
    /// `rect.text` (raw plain text) when available and non-empty,
    /// otherwise parses `rect.ass` as an ASS/SSA dialogue line and
    /// strips override blocks. Returns nil for graphic rects with
    /// neither field set.
    private static func textForRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        // Plain UTF-8 text — set by some text decoders directly.
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        // ASS dialogue line — the universal output of FFmpeg's text
        // subtitle decoders. Format produced by libavcodec is:
        //   ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
        // (8 commas before the body). Some versions also prefix
        // "Dialogue: ".
        if let assPtr = rect.pointee.ass {
            var line = String(cString: assPtr)
            if line.hasPrefix("Dialogue: ") {
                line.removeFirst("Dialogue: ".count)
            }
            // Split on the first 8 commas — the 9th field is the text
            // and may itself contain commas.
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let raw = parts.count == 9 ? String(parts[8]) : line
            return cleanASSBody(raw)
        }
        return nil
    }

    /// Strip ASS override blocks, expand newline escapes, collapse
    /// whitespace, and trim. Conservative — we don't try to render
    /// formatting (italic, bold, colour) since the host overlay is
    /// plain text.
    private static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        // Hard line break tokens.
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        // Hard space.
        s = s.replacingOccurrences(of: "\\h", with: " ")
        // Override blocks: `{\an8}`, `{\fad(...)}`, etc.
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
