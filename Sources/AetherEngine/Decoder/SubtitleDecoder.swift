import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

enum SubtitleDecoderError: Error, CustomStringConvertible, LocalizedError {
    case openFailed(code: Int32)
    case noSubtitleStream
    /// #266: a requested absolute stream index is out of range or not a subtitle stream. Reported
    /// rather than falling back to the first subtitle stream, since a silent fallback is
    /// indistinguishable from the pre-#266 behaviour the index exists to escape.
    case streamIndexNotSubtitle(index: Int32)
    case noDecoder
    case textLimitExceeded
    case unsupportedTextCodec
    case codecOpenFailed(code: Int32)

    var description: String {
        switch self {
        case .openFailed(let code): "SubtitleDecoder: open failed (\(FFmpegErr.text(for: code)))"
        case .noSubtitleStream: "SubtitleDecoder: file has no subtitle stream"
        case .streamIndexNotSubtitle(let index): "SubtitleDecoder: stream \(index) is out of range or not a subtitle stream"
        case .noDecoder: "SubtitleDecoder: no decoder for the subtitle codec"
        case .textLimitExceeded: "SubtitleDecoder: text resource limit"
        case .unsupportedTextCodec: "SubtitleDecoder: unsupported text codec"
        case .codecOpenFailed(let code): "SubtitleDecoder: decoder open failed (\(FFmpegErr.text(for: code)))"
        }
    }

    var errorDescription: String? { description }
}

/// Result of a sidecar decode: cue list plus, when preserveASSMarkup is set on an ASS/SSA file,
/// the script header ([Script Info] + [V4+ Styles] + [Events] Format line) from the stream's extradata.
struct SidecarDecodeResult {
    let cues: [SubtitleCue]
    let assHeader: String?
    /// #921: set instead of `cues` when the caller asked for a bitmap stream's packets.
    var bitmapSource: SidecarBitmapSource? = nil
}

/// One-shot decoder for sidecar subtitle files (.srt/.ass/.vtt/.ssa).
/// Opens the URL as its own AVFormatContext; sidecars are separate files the main demuxer never sees.
enum SubtitleDecoder {
    #if DEBUG
    private final class ValidationProbe: @unchecked Sendable {
        let lock = NSLock()
        var observer: (@Sendable (URL) -> Void)?
    }
    private static let validationProbe = ValidationProbe()
    static var preparedFileValidationObserverForTesting: (@Sendable (URL) -> Void)? {
        get { validationProbe.lock.withLock { validationProbe.observer } }
        set { validationProbe.lock.withLock { validationProbe.observer = newValue } }
    }
    #endif


    /// Decode every cue from the subtitle file at `url`, cancellable via Task.cancel().
    /// When preserveASSMarkup is true, ASS/SSA cues carry the raw libavcodec event line
    /// (ReadOrder,Layer,Style,...,Text) so ASSScriptBuilder can restyle them; no effect on SRT/VTT.
    /// `sourceStreamIndex` (#266) is an ABSOLUTE AVStream index inside the container at `url`, for
    /// URLs that are containers holding several subtitle streams; nil decodes the container's first
    /// subtitle stream (the pre-#266 behaviour). An index that is out of range or names a
    /// non-subtitle stream throws `streamIndexNotSubtitle`.
    /// `keepsBitmapPackets` (#921): a bitmap stream is read into a `SidecarBitmapSource` and not
    /// decoded at all; the result carries no cues. Text streams decode as before either way.
    static func decodeFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        preserveASSMarkup: Bool = false,
        sourceStreamIndex: Int32? = nil,
        preparationPolicy: ExternalSubtitlePreparationPolicy? = nil,
        keepsBitmapPackets: Bool = false
    ) async throws -> SidecarDecodeResult {
        let results = try await decode(
            url: url, httpHeaders: httpHeaders, preserveASSMarkup: preserveASSMarkup,
            requested: sourceStreamIndex.map { [$0] }, preparationPolicy: preparationPolicy,
            keepsBitmapPackets: keepsBitmapPackets
        )
        guard let only = results.first else { throw SubtitleDecoderError.noSubtitleStream }
        return only
    }

    /// #266: decode several subtitle streams from ONE pass over the container, so a host that
    /// registered one external track per embedded stream pays a single fetch instead of one per
    /// track. The result is POSITIONAL: element i holds the cues for `sourceStreamIndices[i]`, so a
    /// caller maps it straight back onto its own targets without resolving what a nil entry became.
    /// A repeated index is decoded once and returned at each of its positions.
    static func decodeFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        preserveASSMarkup: Bool = false,
        sourceStreamIndices: [Int32?]
    ) async throws -> [SidecarDecodeResult] {
        guard !sourceStreamIndices.isEmpty else { return [] }
        return try await decode(
            url: url, httpHeaders: httpHeaders, preserveASSMarkup: preserveASSMarkup,
            requested: sourceStreamIndices
        )
    }

    /// `requested` nil means "the container's first subtitle stream", the pre-#266 single-stream path.
    private static func decode(
        url: URL,
        httpHeaders: [String: String],
        preserveASSMarkup: Bool,
        requested: [Int32?]?, preparationPolicy: ExternalSubtitlePreparationPolicy? = nil,
        keepsBitmapPackets: Bool = false
    ) async throws -> [SidecarDecodeResult] {
        // Task.cancel() does NOT propagate into detached tasks (isCancelled inside always false).
        // Bridge cancellation explicitly via CancelFlag so the decode loop + AVIO reader abort promptly.
        let token = CancelFlag()
        return try await withTaskCancellationHandler {
            try await BlockingWork.detached(priority: .userInitiated) {
                try decodeFileSync(
                    url: url, httpHeaders: httpHeaders,
                    preserveASSMarkup: preserveASSMarkup, requested: requested, cancel: token, preparationPolicy: preparationPolicy,
                    keepsBitmapPackets: keepsBitmapPackets
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

    // MARK: - Per-stream decode state

    /// One decoder plus its accumulated cues, so #266 can run several streams off a single read
    /// loop. Every field here used to be a local in `decodeFileSync`; the timing anchor, the ASS
    /// PlayRes and the open-image bookkeeping are all per-stream and must not be shared.
    private final class StreamDecode {
        let streamIndex: Int32
        let codecCtx: UnsafeMutablePointer<AVCodecContext>
        let tbSec: Double
        let keepMarkup: Bool
        let assPlayRes: CGSize
        let assHeader: String?
        let codedWidth: Int
        let codedHeight: Int

        let preparationPolicy: ExternalSubtitlePreparationPolicy?
        var textBytes = 0
        var limitExceeded = false
        var decodeFailed = false
        var cues: [SubtitleCue] = []
        var nextID = 0
        /// Indices of image cues still "open" (PGS-style: ended by the next composition event).
        var pendingImageCueIndices: [Int] = []
        var lastPktPTS: Double = 0  // PTS anchor for flush events that have no packet of their own

        init(streamIndex: Int32, stream: UnsafeMutablePointer<AVStream>, preserveASSMarkup: Bool, preparationPolicy: ExternalSubtitlePreparationPolicy? = nil) throws {
            guard let codecpar = stream.pointee.codecpar else {
                throw SubtitleDecoderError.streamIndexNotSubtitle(index: streamIndex)
            }

            // ASS/SSA script header is in codec extradata (mirrors Demuxer.trackInfo for embedded tracks).
            // Only surfaced under preserveASSMarkup; the raw event-line path is the only consumer.
            self.preparationPolicy = preparationPolicy
            let codecID = codecpar.pointee.codec_id
            if preparationPolicy != nil && ![AV_CODEC_ID_SUBRIP, AV_CODEC_ID_WEBVTT, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA].contains(codecID) {
                throw SubtitleDecoderError.unsupportedTextCodec
            }
            let isASS = codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA
            let keepMarkup = preserveASSMarkup && isASS
            var assHeader: String? = nil
            var assPlayRes = SubtitleRectText.defaultASSPlayRes
            if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
                let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
                // Strip NUL bytes: extradata is often NUL-terminated; libass parses C-string-style and a NUL hides everything after it.
                let header = String(data: bytes, encoding: .utf8)?
                    .replacingOccurrences(of: "\0", with: "")
                if keepMarkup { assHeader = header }
                // #233: a real ASS script declares the space its \pos coordinates live in; without one
                // the line came from libavcodec's own conversion and uses the 384x288 default.
                if let header, let declared = SubtitleRectText.playRes(fromASSHeader: header) {
                    assPlayRes = declared
                }
            }

            guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
                throw SubtitleDecoderError.noDecoder
            }
            guard let ctx = avcodec_alloc_context3(codec) else {
                throw SubtitleDecoderError.codecOpenFailed(code: -1)
            }
            // Throwing before `codecCtx` is assigned skips deinit, so unwind the context by hand.
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            let paramsRet = avcodec_parameters_to_context(ctx, codecpar)
            guard paramsRet >= 0 else {
                avcodec_free_context(&local)
                throw SubtitleDecoderError.codecOpenFailed(code: paramsRet)
            }
            let openRet = avcodec_open2(ctx, codec, nil)
            guard openRet >= 0 else {
                avcodec_free_context(&local)
                throw SubtitleDecoderError.codecOpenFailed(code: openRet)
            }

            self.streamIndex = streamIndex
            self.codecCtx = ctx
            let timeBase = stream.pointee.time_base
            self.tbSec = Double(timeBase.num) / Double(timeBase.den)
            self.keepMarkup = keepMarkup
            self.assPlayRes = assPlayRes
            self.assHeader = assHeader
            self.codedWidth = Int(codecpar.pointee.width)
            self.codedHeight = Int(codecpar.pointee.height)
        }

        deinit {
            var local: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&local)
        }

        // Under preserveASSMarkup: keep raw ASS event line (ASSScriptBuilder re-stamps timing); otherwise plain text.
        private func line(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
            keepMarkup ? SubtitleRectText.rawASSLine(for: rect) : SubtitleRectText.plainText(for: rect)
        }

        func decode(packet pkt: UnsafeMutablePointer<AVPacket>) {
            var sub = AVSubtitle()
            var gotSub: Int32 = 0
            let ret = avcodec_decode_subtitle2(codecCtx, &sub, &gotSub, pkt)
            if preparationPolicy != nil && ret < 0 { decodeFailed = true; return }
            guard ret >= 0, gotSub != 0 else { return }

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

            // Bitmap subtitles (external .sup / PGS sidecars, FFmpegBuild >= 2.1.3 sup demuxer):
            // a composition usually carries end_display_time == 0 and is ended by the NEXT
            // composition event (a new set or a clear packet), so clamp any still-open image
            // cues to this packet's PTS before appending the new ones. The 5 s fallback above
            // only survives for a final composition with no successor.
            for idx in pendingImageCueIndices where cues[idx].startTime < pktPTS && cues[idx].endTime > pktPTS {
                let open = cues[idx]
                cues[idx] = open.with(endTime: pktPTS)
            }
            pendingImageCueIndices.removeAll()

            var lines: [String] = []
            var images: [SubtitleImage] = []
            var styledBodies: [SubtitleCue.Body] = []
            var placement: SubtitleTextPlacement?
            if sub.num_rects > 0, let rects = sub.rects {
                for i in 0..<Int(sub.num_rects) {
                    guard let rect = rects[i] else { continue }
                    if rect.pointee.type == SUBTITLE_BITMAP {
                        // The composition canvas is the codec's coded size (PGS: from the PCS).
                        if let image = EmbeddedSubtitleDecoder.imageForSubtitleRect(
                            rect, videoWidth: codedWidth, videoHeight: codedHeight
                        ) {
                            images.append(image)
                        }
                    } else if keepMarkup {
                        if let raw = line(for: rect) { lines.append(raw) }
                    } else if let assLine = SubtitleRectText.rawASSLine(for: rect),
                              let parsed = SubtitleRectText.styledBody(fromASSEventLine: assLine,
                                                                      playRes: assPlayRes) {
                        // #233: SRT and WebVTT sidecars reach libavcodec's ASS conversion too,
                        // so their markup survives here. Unstyled cues stay .text and merge
                        // with their siblings below, exactly as the plain path did.
                        placement = placement ?? parsed.placement
                        if case .text(let t) = parsed.body {
                            lines.append(t)
                        } else {
                            styledBodies.append(parsed.body)
                        }
                    } else if let text = line(for: rect) {
                        lines.append(text)
                    }
                }
            }
            avsubtitle_free(&sub)

            // #233: WebVTT cue settings never reach the ASS event line (the decoder drops
            // them), but the demuxer keeps them on the packet. An ASS `\an` / `\pos` still
            // wins, since that came from the payload itself.
            placement = placement ?? WebVTTCueSettings.placement(onPacket: pkt)

            let merged = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !merged.isEmpty && endTime > startTime {
                append(startTime: startTime, endTime: endTime, body: .text(merged), placement: placement)
            }
            if endTime > startTime {
                for body in styledBodies {
                    append(startTime: startTime, endTime: endTime, body: body, placement: placement)
                }
            }
            if endTime > startTime {
                for image in images {
                    pendingImageCueIndices.append(cues.count)
                    append(startTime: startTime, endTime: endTime, body: .image(image), placement: nil)
                }
            }
        }

        /// Flush ASS/SSA buffered events (old code decoded one event and discarded it, silently losing the last cue).
        /// Flushed events have no packet; use lastPktPTS as the timing anchor.
        func flush(cancel: CancelFlag) {
            while !cancel.isCancelled && !limitExceeded {
                var flushPkt = AVPacket()
                flushPkt.data = nil
                flushPkt.size = 0
                var flushSub = AVSubtitle()
                var gotFlush: Int32 = 0
                let flushRet = avcodec_decode_subtitle2(codecCtx, &flushSub, &gotFlush, &flushPkt)
                if preparationPolicy != nil && flushRet < 0 && flushRet != FFmpegErr.eof { decodeFailed = true; break }
                guard flushRet >= 0, gotFlush != 0 else { break }

                let startOffset = Double(flushSub.start_display_time) / 1000.0
                let endOffset = flushSub.end_display_time > 0
                    ? Double(flushSub.end_display_time) / 1000.0
                    : startOffset + 5.0
                var lines: [String] = []
                if flushSub.num_rects > 0, let rects = flushSub.rects {
                    for i in 0..<Int(flushSub.num_rects) {
                        guard let rect = rects[i] else { continue }
                        if let text = line(for: rect) {
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
                    append(startTime: startTime, endTime: endTime, body: .text(merged), placement: nil)
                }
            }
        }

        private func append(startTime: Double, endTime: Double,
                            body: SubtitleCue.Body, placement: SubtitleTextPlacement?) {
            if let preparationPolicy {
                let count: Int
                switch body {
                case .text(let value): count = value.utf8.count
                case .richText(let runs): count = runs.reduce(0) { $0 + $1.text.utf8.count }
                case .image: limitExceeded = true; return
                }
                guard !limitExceeded, cues.count < preparationPolicy.maximumCueCount, count <= preparationPolicy.maximumCueBytes,
                      count <= preparationPolicy.maximumTextBytes - textBytes,
                      startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
                    limitExceeded = true; return
                }
                textBytes += count
            }
            cues.append(SubtitleCue(id: nextID, startTime: startTime, endTime: endTime,
                                    body: body, placement: placement))
            nextID += 1
        }

        var result: SidecarDecodeResult {
            SidecarDecodeResult(cues: cues.sorted { $0.startTime < $1.startTime }, assHeader: assHeader)
        }
    }

    // MARK: - Synchronous core

    private static func decodeFileSync(
        url: URL, httpHeaders: [String: String],
        preserveASSMarkup: Bool, requested: [Int32?]?, cancel: CancelFlag, preparationPolicy: ExternalSubtitlePreparationPolicy?,
        keepsBitmapPackets: Bool = false
    ) throws -> [SidecarDecodeResult] {
        if let preparationPolicy {
            #if DEBUG
            preparedFileValidationObserverForTesting?(url)
            #endif
            try preparationPolicy.validateFile(url)
        }
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
            var options: OpaquePointer?
            defer { av_dict_free(&options) }
            var inputFormat: UnsafePointer<AVInputFormat>?
            if preparationPolicy != nil {
                guard url.isFileURL else { throw SubtitleDecoderError.unsupportedTextCodec }
                let name: String
                switch url.pathExtension.lowercased() {
                case "srt": name = "srt"
                case "vtt": name = "webvtt"
                case "ass", "ssa": name = "ass"
                default: throw SubtitleDecoderError.unsupportedTextCodec
                }
                inputFormat = av_find_input_format(name)
                guard inputFormat != nil else { throw SubtitleDecoderError.unsupportedTextCodec }
                av_dict_set(&options, "protocol_whitelist", "file", 0)
            }
            let ret = avformat_open_input(&ctx, urlString, inputFormat, &options)
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
        let firstSubtitleStream = firstSubtitleStreamIndex(in: fmt)
        // #266: resolve each request to an absolute stream index. Keep the positional mapping so
        // the caller gets one result per request even when several requests share a stream.
        let resolved: [Int32] = try (requested ?? [nil]).map { request in
            guard let request else {
                guard let first = firstSubtitleStream else { throw SubtitleDecoderError.noSubtitleStream }
                return first
            }
            guard request >= 0, request < Int32(fmt.pointee.nb_streams),
                  let stream = fmt.pointee.streams[Int(request)],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
            else { throw SubtitleDecoderError.streamIndexNotSubtitle(index: request) }
            return request
        }

        var decodersByStream: [Int32: StreamDecode] = [:]
        // #921: bitmap streams read into packets instead, never decoded here.
        var bitmapSources: [Int32: SidecarBitmapSource] = [:]
        // Registered after the avformat_close_input defer, so LIFO runs it FIRST: the codec
        // contexts go before the format context, matching the pre-#266 defer order. Covers the
        // throwing paths below too.
        defer { decodersByStream.removeAll() }
        for index in resolved where decodersByStream[index] == nil && bitmapSources[index] == nil {
            guard let stream = fmt.pointee.streams[Int(index)] else {
                throw SubtitleDecoderError.streamIndexNotSubtitle(index: index)
            }
            if keepsBitmapPackets, preparationPolicy == nil,
               let source = SidecarBitmapSource(stream: stream) {
                bitmapSources[index] = source
                continue
            }
            decodersByStream[index] = try StreamDecode(
                streamIndex: index, stream: stream, preserveASSMarkup: preserveASSMarkup, preparationPolicy: preparationPolicy)
        }

        var reachedEOF = false
        while !cancel.isCancelled {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
            guard let pkt = pktPtr else { break }
            let readRet = av_read_frame(fmt, pkt)
            if readRet < 0 {
                trackedPacketFree(&pktPtr)
                if preparationPolicy != nil && readRet != FFmpegErr.eof { throw SubtitleDecoderError.openFailed(code: readRet) }
                reachedEOF = readRet == FFmpegErr.eof
                break
            }

            let decoder = decodersByStream[pkt.pointee.stream_index]
            let bitmapSource = bitmapSources[pkt.pointee.stream_index]
            if decoder != nil || bitmapSource != nil,
               let stream = fmt.pointee.streams[Int(pkt.pointee.stream_index)] {
                // Audit FEA-101 / SUB-105: this loop reads libavformat directly, past Demuxer's bound.
                SourceTimestampBounds.sanitize(pkt, timeBase: stream.pointee.time_base)
                decoder?.decode(packet: pkt)
                bitmapSource?.harvest(packet: pkt, timeBase: stream.pointee.time_base)
            }

            av_packet_unref(pkt)
            trackedPacketFree(&pktPtr)
            if preparationPolicy != nil && decodersByStream.values.contains(where: { $0.decodeFailed }) {
                throw SubtitleDecoderError.openFailed(code: -1)
            }
            if decodersByStream.values.contains(where: { $0.limitExceeded }) {
                throw SubtitleDecoderError.textLimitExceeded
            }
        }

        for decoder in decodersByStream.values {
            decoder.flush(cancel: cancel)
            if decoder.limitExceeded { throw SubtitleDecoderError.textLimitExceeded }
            if preparationPolicy != nil && decoder.decodeFailed { throw SubtitleDecoderError.openFailed(code: -1) }
        }
        if preparationPolicy != nil && cancel.isCancelled { throw CancellationError() }
        if reachedEOF { bitmapSources.values.forEach { $0.finishReading() } }

        return resolved.compactMap { index in
            decodersByStream[index]?.result
                ?? bitmapSources[index].map { SidecarDecodeResult(cues: [], assHeader: nil, bitmapSource: $0) }
        }
    }

    private static func firstSubtitleStreamIndex(in fmt: UnsafeMutablePointer<AVFormatContext>) -> Int32? {
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar
            else { continue }
            if codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                return Int32(i)
            }
        }
        return nil
    }

}
