import Foundation
import Libavformat
import Libavcodec
import Libavutil

enum SubtitleDecoderError: Error {
    case openFailed(code: Int32)
    case noSubtitleStream
    case noDecoder
    case codecOpenFailed(code: Int32)
}

/// Result of a sidecar decode: cue list plus, when preserveASSMarkup is set on an ASS/SSA file,
/// the script header ([Script Info] + [V4+ Styles] + [Events] Format line) from the stream's extradata.
struct SidecarDecodeResult {
    let cues: [SubtitleCue]
    let assHeader: String?
}

/// One-shot decoder for sidecar subtitle files (.srt/.ass/.vtt/.ssa).
/// Opens the URL as its own AVFormatContext; sidecars are separate files the main demuxer never sees.
enum SubtitleDecoder {

    /// Decode every cue from the subtitle file at `url`, cancellable via Task.cancel().
    /// When preserveASSMarkup is true, ASS/SSA cues carry the raw libavcodec event line
    /// (ReadOrder,Layer,Style,...,Text) so ASSScriptBuilder can restyle them; no effect on SRT/VTT.
    static func decodeFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        preserveASSMarkup: Bool = false
    ) async throws -> SidecarDecodeResult {
        // Task.cancel() does NOT propagate into detached tasks (isCancelled inside always false).
        // Bridge cancellation explicitly via CancelFlag so the decode loop + AVIO reader abort promptly.
        let token = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try decodeFileSync(
                    url: url, httpHeaders: httpHeaders,
                    preserveASSMarkup: preserveASSMarkup, cancel: token
                )
            }.value
        } onCancel: {
            token.cancel()
        }
    }

    /// Thread-safe cancellation token for the detached decode task; also aborts any registered AVIO reader.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var reader: AVIOReader?

        func cancel() {
            lock.lock()
            cancelled = true
            let r = reader
            lock.unlock()
            r?.markClosed()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        func register(_ r: AVIOReader) {
            lock.lock()
            let wasCancelled = cancelled
            reader = r
            lock.unlock()
            if wasCancelled { r.markClosed() }
        }
    }

    // MARK: - Synchronous core

    private static func decodeFileSync(
        url: URL, httpHeaders: [String: String],
        preserveASSMarkup: Bool, cancel: CancelFlag
    ) throws -> SidecarDecodeResult {
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        var avioReader: AVIOReader?

        if isHTTP {
            let reader = AVIOReader(url: url, extraHeaders: httpHeaders)
            // Register BEFORE open(): open does a synchronous network probe (up to ~60 s on stalled origins);
            // cancellation during the probe must abort via markClosed rather than waiting for timeout (#32).
            cancel.register(reader)
            try reader.open()
            avioReader = reader
            guard let ctx = avformat_alloc_context() else {
                reader.close()
                throw SubtitleDecoderError.openFailed(code: -1)
            }
            ctx.pointee.pb = reader.context
            // Assign formatContext only after a successful open: avformat_open_input frees the
            // supplied context and NULLs its pointer on failure, so an early assignment would
            // leave a dangling pointer for the defer to double-close (mirrors Demuxer.swift).
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

        // Probe defensively; sidecars usually have one stream at index 0 but containers can have extras.
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

        // ASS/SSA script header is in codec extradata (mirrors Demuxer.trackInfo for embedded tracks).
        // Only surfaced under preserveASSMarkup; the raw event-line path is the only consumer.
        let codecID = codecpar.pointee.codec_id
        let isASS = codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA
        let keepMarkup = preserveASSMarkup && isASS
        var assHeader: String? = nil
        if keepMarkup,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // Strip NUL bytes: extradata is often NUL-terminated; libass parses C-string-style and a NUL hides everything after it.
            assHeader = String(data: bytes, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
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
        var lastPktPTS: Double = 0  // PTS anchor for flush events that have no packet of their own

        // Under preserveASSMarkup: keep raw ASS event line (ASSScriptBuilder re-stamps timing); otherwise plain text.
        let lineForRect: (UnsafeMutablePointer<AVSubtitleRect>) -> String? = { rect in
            keepMarkup ? SubtitleRectText.rawASSLine(for: rect) : SubtitleRectText.plainText(for: rect)
        }

        while !cancel.isCancelled {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
            guard let pkt = pktPtr else { break }
            let readRet = av_read_frame(fmt, pkt)
            if readRet < 0 {
                trackedPacketFree(&pktPtr)
                break
            }

            if Int(pkt.pointee.stream_index) != subStreamIndex {
                av_packet_unref(pkt)
                trackedPacketFree(&pktPtr)
                continue
            }

            var sub = AVSubtitle()
            var gotSub: Int32 = 0
            let ret = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt)

            if ret >= 0 && gotSub != 0 {
                let pktPTS = pkt.pointee.pts == Int64.min
                    ? 0.0
                    : Double(pkt.pointee.pts) * tbSec
                lastPktPTS = pktPTS
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
                        if let text = lineForRect(rect) {
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
                        body: .text(merged)
                    ))
                    nextID += 1
                }
            }

            av_packet_unref(pkt)
            trackedPacketFree(&pktPtr)
        }

        // Flush ASS/SSA buffered events (old code decoded one event and discarded it, silently losing the last cue).
        // Flushed events have no packet; use lastPktPTS as the timing anchor.
        while !cancel.isCancelled {
            var flushPkt = AVPacket()
            flushPkt.data = nil
            flushPkt.size = 0
            var flushSub = AVSubtitle()
            var gotFlush: Int32 = 0
            let flushRet = avcodec_decode_subtitle2(codecCtx, &flushSub, &gotFlush, &flushPkt)
            guard flushRet >= 0, gotFlush != 0 else { break }

            let startOffset = Double(flushSub.start_display_time) / 1000.0
            let endOffset = flushSub.end_display_time > 0
                ? Double(flushSub.end_display_time) / 1000.0
                : startOffset + 5.0
            var lines: [String] = []
            if flushSub.num_rects > 0, let rects = flushSub.rects {
                for i in 0..<Int(flushSub.num_rects) {
                    guard let rect = rects[i] else { continue }
                    if let text = lineForRect(rect) {
                        lines.append(text)
                    }
                }
            }
            avsubtitle_free(&flushSub)

            let merged = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let startTime = lastPktPTS + startOffset
            let endTime = lastPktPTS + endOffset
            if !merged.isEmpty && endTime > startTime {
                cues.append(SubtitleCue(
                    id: nextID,
                    startTime: startTime,
                    endTime: endTime,
                    body: .text(merged)
                ))
                nextID += 1
            }
        }

        return SidecarDecodeResult(
            cues: cues.sorted { $0.startTime < $1.startTime },
            assHeader: assHeader
        )
    }

}
