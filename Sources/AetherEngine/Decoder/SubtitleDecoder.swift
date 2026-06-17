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

/// Result of a sidecar decode: the cue list plus, for ASS/SSA files
/// loaded under `preserveASSMarkup`, the script header (`[Script Info]`
/// + `[V4+ Styles]` + `[Events]` Format line) extracted from the
/// subtitle stream's extradata. `assHeader` is nil for non-ASS files
/// and whenever markup preservation is off.
struct SidecarDecodeResult {
    let cues: [SubtitleCue]
    let assHeader: String?
}

/// One-shot decoder for sidecar subtitle files (.srt / .ass / .vtt /
/// .ssa next to the media). Opens the URL as its own AVFormatContext,
/// finds the single subtitle stream, walks every packet, and returns
/// the decoded cue list.
///
/// Distinct from the main demux loop's streaming decoder which routes
/// subtitle packets that are *already* flowing for an embedded track,
/// sidecars are separate small files that the main demuxer never sees,
/// so they need their own context. Bandwidth-wise this is cheap: a
/// typical SRT/ASS file is ~50–200 KB, served straight from the host
/// (Jellyfin) with no extraction work.
enum SubtitleDecoder {

    /// Decode every cue out of the subtitle file at `url`. Cancellable
    /// via `Task.cancel()`; throws on open / codec failure. Returns
    /// cues sorted by `startTime`, plus the ASS header when
    /// `preserveASSMarkup` is set and the file is ASS/SSA.
    ///
    /// `preserveASSMarkup`: when true, ASS/SSA cues carry the raw
    /// libavcodec event line (`ReadOrder,Layer,Style,...,Text`) as
    /// their text body instead of stripped plain text, mirroring the
    /// embedded `EmbeddedSubtitleDecoder` path so a whole-script
    /// renderer (swift-ass-renderer via `ASSScriptBuilder`) can style
    /// them. No effect on non-ASS files (SRT / VTT carry no ASS
    /// payload, so the path falls back to plain text).
    static func decodeFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        preserveASSMarkup: Bool = false
    ) async throws -> SidecarDecodeResult {
        // Task.cancel() does NOT propagate into a detached task (and
        // `Task.isCancelled` inside it refers to the detached task, so it
        // was always false): a superseded sidecar load used to decode the
        // whole file to the end, HTTP traffic included. Bridge the
        // caller's cancellation explicitly: the handler trips a shared
        // flag the decode loop polls, and aborts the AVIO reader so a
        // read blocked on a stalled source unwinds promptly.
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

    /// Thread-safe cancellation token bridged into the detached decode
    /// task (cf. `FrameExtractor.CancelToken`). Also aborts a registered
    /// AVIO reader so cancellation isn't stuck behind a blocked read.
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
            // Auth headers (WebDAV-hosted sidecars and friends, #32)
            // ride the same AVIO reader path as the media source.
            let reader = AVIOReader(url: url, extraHeaders: httpHeaders)
            // Register BEFORE open(): open does a synchronous network
            // probe (up to ~60 s against a stalled origin), and a
            // superseded load cancelled during it must be able to abort
            // via markClosed instead of holding the connection + the
            // detached task until the probe times out.
            cancel.register(reader)
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

        // ASS / SSA sidecars carry their script header ([Script Info] +
        // [V4+ Styles] + the [Events] Format line) as codec extradata,
        // exactly like embedded tracks (mirrors Demuxer.trackInfo). Hosts
        // that opt into raw ASS event lines need it to resolve style
        // references. Only surfaced under preserveASSMarkup; the raw
        // event-line path below is the only consumer.
        let codecID = codecpar.pointee.codec_id
        let isASS = codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA
        let keepMarkup = preserveASSMarkup && isASS
        var assHeader: String? = nil
        if keepMarkup,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // Strip NUL bytes: extradata is frequently NUL-terminated and
            // libass parses C-string-style, so a single embedded NUL would
            // hide every line a host appends after the header.
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
        // PTS anchor for events surfaced by the post-loop flush, which
        // have no packet of their own.
        var lastPktPTS: Double = 0

        // Body extraction honours preserveASSMarkup: under it keep the
        // raw ASS event line (so the host can rebuild a styled script
        // via ASSScriptBuilder), otherwise strip to plain text. The
        // raw line carries its own timing in the cue's start/end, which
        // ASSScriptBuilder re-stamps, so the merged join below is safe.
        let lineForRect: (UnsafeMutablePointer<AVSubtitleRect>) -> String? = { rect in
            keepMarkup ? SubtitleRectText.rawASSLine(for: rect) : textForRect(rect)
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

        // Flush: ASS/SSA decoders can buffer events. Loop until the
        // decoder reports nothing more and run the SAME cue extraction
        // as the main loop. The old code decoded exactly one buffered
        // event and threw it away unextracted, so whenever the decoder
        // really did buffer, the file's last cue silently vanished.
        // Timing anchor: a flushed event has no packet of its own, the
        // last packet's PTS is the only plausible base.
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

    // MARK: - Rect → text

    private static func textForRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        SubtitleRectText.plainText(for: rect)
    }

}
