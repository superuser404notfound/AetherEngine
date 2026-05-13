import Foundation
import CoreGraphics
import Compression
import Libavcodec
import Libavformat
import Libavutil

/// Packet-by-packet decoder for an embedded subtitle stream
/// (SubRip / ASS / SSA / WebVTT / mov_text / PGS / DVB / HDMV).
/// Owns one AVCodecContext for the lifetime of an active subtitle
/// track; the demux pump in HLSSegmentProducer feeds packets, this
/// decoder emits `SubtitleEvent` results back through its caller.
///
/// Lifted out of the pre-1.0 aether-path AetherEngine.swift, the
/// hard-won handling of PGS PES-header strip + zlib / gzip
/// Matroska compression wrappers + PGS clear-event semantics is
/// preserved verbatim.
///
/// Not MainActor: lives on the HLSSegmentProducer pump worker queue.
/// The caller bridges results back to MainActor via the callback
/// AetherEngine installs.
final class EmbeddedSubtitleDecoder {

    /// One emit from a single subtitle packet.
    struct SubtitleEvent: @unchecked Sendable {
        /// Cues produced. Empty for PGS clear events (each PGS event
        /// implicitly terminates whatever was previously on screen;
        /// AetherEngine applies the trim).
        let cues: [SubtitleCue]
        /// True when this packet was a PGS event (with or without
        /// rects). AetherEngine uses this to drive end-time fix-up of
        /// previously shown bitmap cues.
        let isPGS: Bool
        /// Time at which the previous PGS cue should be trimmed
        /// (matches the new event's startTime). nil for non-PGS or
        /// unknown.
        let pgsTrimAt: Double?
    }

    /// The codec ID for the active stream. Exposed for callers who
    /// want to gate behavior on text vs bitmap or check for PGS
    /// specifically.
    let codecID: AVCodecID

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var nextCueID: Int = 0
    private var seenKeys: Set<String> = []

    /// Canvas dimensions used to normalize bitmap subtitle position.
    /// Set from the source video dimensions at init; some bitmap
    /// codecs override them via their PCS so the decoder context's
    /// width/height may differ.
    private let sourceVideoWidth: Int32
    private let sourceVideoHeight: Int32

    /// Open the subtitle decoder for `stream`. Returns `nil` if the
    /// codec couldn't be opened (no decoder for codec_id, or
    /// avcodec_open2 fails).
    init?(stream: UnsafeMutablePointer<AVStream>, sourceVideoWidth: Int32, sourceVideoHeight: Int32) {
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        else { return nil }
        let id = codecpar.pointee.codec_id
        guard let codec = avcodec_find_decoder(id),
              let ctx = avcodec_alloc_context3(codec)
        else { return nil }

        if avcodec_parameters_to_context(ctx, codecpar) < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            return nil
        }

        // Bitmap codecs author their bitmaps against a known canvas
        // (the source video frame). The probe step often can't
        // determine those dimensions when the file is big and the
        // sub stream sparse; seed from the captured video frame size
        // as a fallback. The codec's PCS will overwrite once it
        // arrives.
        if Self.isBitmapCodec(id) {
            if ctx.pointee.width == 0 { ctx.pointee.width = sourceVideoWidth }
            if ctx.pointee.height == 0 { ctx.pointee.height = sourceVideoHeight }
        }

        if avcodec_open2(ctx, codec, nil) < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            return nil
        }

        self.codecID = id
        self.codecContext = ctx
        self.sourceVideoWidth = sourceVideoWidth
        self.sourceVideoHeight = sourceVideoHeight

        // Some demuxers default subtitle streams to AVDISCARD_DEFAULT
        // which can swallow packets the parser thinks are useless.
        // Force NONE so every byte makes it to av_read_frame.
        stream.pointee.discard = AVDISCARD_NONE
    }

    deinit {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
    }

    /// Decode `packet` against the active codec. Returns `nil` if
    /// nothing usable; otherwise a `SubtitleEvent` with cues + PGS
    /// trim info.
    ///
    /// `streamStartTime` is the AVStream's `start_time` (in stream
    /// time_base units), subtracted from packet PTS so the resulting
    /// cue startTime is in absolute source seconds matching AVPlayer's
    /// clock. Pass `Int64.min` for streams without a defined
    /// start_time.
    func decode(
        packet: UnsafeMutablePointer<AVPacket>,
        streamTimeBase: AVRational,
        streamStartTime: Int64
    ) -> SubtitleEvent? {
        guard let ctx = codecContext else { return nil }

        var sub = AVSubtitle()
        var gotSub: Int32 = 0
        let ret = decodeWithFixups(ctx: ctx, pkt: packet, sub: &sub, gotSub: &gotSub)

        // Some MKV converters drop the trailing END segment (0x80) on
        // PGS; the decoder accumulates state but never gets the
        // signal to emit. If gotSub is still 0 after the real packet
        // and the codec is PGS, feed a synthetic END to flush.
        if gotSub == 0,
           ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE,
           packet.pointee.size > 30 {
            var endBytes: [UInt8] = [0x80, 0x00, 0x00,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0]
            endBytes.withUnsafeMutableBufferPointer { buf in
                var endPkt = AVPacket()
                endPkt.data = buf.baseAddress
                endPkt.size = 3
                endPkt.pts = packet.pointee.pts
                endPkt.dts = packet.pointee.dts
                endPkt.duration = packet.pointee.duration
                endPkt.stream_index = packet.pointee.stream_index
                _ = avcodec_decode_subtitle2(ctx, &sub, &gotSub, &endPkt)
            }
        }

        guard ret >= 0, gotSub != 0 else { return nil }

        let tbSec = Double(streamTimeBase.num) / Double(streamTimeBase.den)
        // Subtract stream->start_time so the resulting playback time
        // is in absolute source seconds. Some sources (especially
        // those re-muxed from broadcast or edited from longer files)
        // set a non-zero start_time on subtitle streams; without this
        // subtraction the cue's startTime ends up offset from AVPlayer's
        // clock by stream_start_time seconds. AV_NOPTS_VALUE (Int64.min)
        // means "no defined start", treat as zero offset.
        let startTimeOffset: Int64 = streamStartTime == Int64.min ? 0 : streamStartTime
        let rawPTS = packet.pointee.pts
        let adjustedPTS = (rawPTS == Int64.min) ? 0 : (rawPTS - startTimeOffset)
        let pktPTS = Double(adjustedPTS) * tbSec
        let startOffset = Double(sub.start_display_time) / 1000.0
        let endOffset: Double
        if sub.end_display_time > 0 {
            endOffset = Double(sub.end_display_time) / 1000.0
        } else if packet.pointee.duration > 0 {
            endOffset = Double(packet.pointee.duration) * tbSec
        } else {
            endOffset = 5.0
        }
        let startTime = pktPTS + startOffset
        let endTime = pktPTS + endOffset

        // Bitmap subtitles author rects against the canvas size in
        // the codec context (PCS-reported). Fall back to source video
        // dims if missing.
        let canvasW = ctx.pointee.width > 0 ? ctx.pointee.width : sourceVideoWidth
        let canvasH = ctx.pointee.height > 0 ? ctx.pointee.height : sourceVideoHeight

        var bodies: [SubtitleCue.Body] = []
        var textLines: [String] = []
        if sub.num_rects > 0, let rects = sub.rects {
            for i in 0..<Int(sub.num_rects) {
                guard let rect = rects[i] else { continue }
                if let text = Self.textForSubtitleRect(rect) {
                    textLines.append(text)
                } else if let image = Self.imageForSubtitleRect(
                    rect,
                    videoWidth: Int(canvasW),
                    videoHeight: Int(canvasH)
                ) {
                    bodies.append(.image(image))
                }
            }
        }
        avsubtitle_free(&sub)

        let merged = textLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !merged.isEmpty {
            bodies.append(.text(merged))
        }

        let isPGS = ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let isClearEvent = bodies.isEmpty

        guard endTime > startTime else { return nil }
        guard !isClearEvent || isPGS else { return nil }

        // Dedupe full duplicate non-empty events; keep clear events
        // distinct since each one trims a different previous cue.
        if !isClearEvent {
            let key = "\(startTime)|\(endTime)|\(bodies.count)"
            if seenKeys.contains(key) { return nil }
            seenKeys.insert(key)
        }

        let cueIDStart = nextCueID
        nextCueID += bodies.count

        let cues: [SubtitleCue] = bodies.enumerated().map { (offset, body) in
            SubtitleCue(
                id: cueIDStart + offset,
                startTime: startTime,
                endTime: endTime,
                body: body
            )
        }

        return SubtitleEvent(
            cues: cues,
            isPGS: isPGS,
            pgsTrimAt: isPGS ? startTime : nil
        )
    }

    /// Reset the dedupe set + cue counter when restarting at a new
    /// position (e.g. after a scrub). Called by HLSVideoEngine when
    /// the producer restarts.
    func resetState() {
        seenKeys.removeAll(keepingCapacity: true)
        nextCueID = 0
    }

    // MARK: - Codec checks

    static func isBitmapCodec(_ id: AVCodecID) -> Bool {
        return id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
            || id == AV_CODEC_ID_DVB_SUBTITLE
            || id == AV_CODEC_ID_DVD_SUBTITLE
            || id == AV_CODEC_ID_XSUB
    }

    // MARK: - Decode fixups

    private func decodeWithFixups(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        guard let data = pkt.pointee.data, pkt.pointee.size > 2 else {
            return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
        }

        // 1. zlib-wrapped (RFC 1950), `78 01/5E/9C/DA` magic.
        if data[0] == 0x78,
           data[1] == 0x01 || data[1] == 0x5E || data[1] == 0x9C || data[1] == 0xDA {
            if let decompressed = inflateZlibBlock(data, size: Int(pkt.pointee.size)) {
                return decodeWithReplacedPayload(
                    ctx: ctx, pkt: pkt, payload: decompressed,
                    sub: sub, gotSub: gotSub
                )
            }
        }

        // 1b. gzip-wrapped (RFC 1952), `1F 8B` magic.
        if pkt.pointee.size > 18,
           data[0] == 0x1F, data[1] == 0x8B {
            if let decompressed = inflateGzipBlock(data, size: Int(pkt.pointee.size)) {
                return decodeWithReplacedPayload(
                    ctx: ctx, pkt: pkt, payload: decompressed,
                    sub: sub, gotSub: gotSub
                )
            }
        }

        // 2. PGS PES-header strip.
        let isPGS = ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        if isPGS,
           pkt.pointee.size > 10,
           data[0] == 0x50, data[1] == 0x47 {
            return decodeWithStrippedPrefix(ctx: ctx, pkt: pkt, prefix: 10, sub: sub, gotSub: gotSub)
        }

        return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
    }

    private func inflateGzipBlock(_ src: UnsafePointer<UInt8>, size: Int) -> [UInt8]? {
        guard size > 18, src[0] == 0x1F, src[1] == 0x8B else { return nil }
        let flg = src[3]
        var off = 10
        if flg & 0x04 != 0 {
            guard off + 2 <= size else { return nil }
            let xlen = Int(src[off]) | (Int(src[off + 1]) << 8)
            off += 2 + xlen
            if off > size { return nil }
        }
        if flg & 0x08 != 0 {
            while off < size && src[off] != 0 { off += 1 }
            off += 1
            if off > size { return nil }
        }
        if flg & 0x10 != 0 {
            while off < size && src[off] != 0 { off += 1 }
            off += 1
            if off > size { return nil }
        }
        if flg & 0x02 != 0 {
            off += 2
            if off > size { return nil }
        }
        let trailerSize = 8
        guard off < size - trailerSize else { return nil }
        return inflateDeflateStream(
            src.advanced(by: off),
            size: size - off - trailerSize,
            originalSize: size
        )
    }

    private func inflateZlibBlock(_ src: UnsafePointer<UInt8>, size: Int) -> [UInt8]? {
        guard size > 6 else { return nil }
        return inflateDeflateStream(
            src.advanced(by: 2),
            size: size - 2 - 4,
            originalSize: size
        )
    }

    private func inflateDeflateStream(
        _ src: UnsafePointer<UInt8>,
        size: Int,
        originalSize: Int
    ) -> [UInt8]? {
        guard size > 0 else { return nil }
        var dstCapacity = max(originalSize * 8, 4096)
        let maxCapacity = 8 * 1024 * 1024
        while dstCapacity <= maxCapacity {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(
                dst, dstCapacity,
                src, size,
                nil, COMPRESSION_ZLIB
            )
            if written > 0 && written < dstCapacity {
                return Array(UnsafeBufferPointer(start: dst, count: written))
            }
            if written == 0 { return nil }
            dstCapacity *= 2
        }
        return nil
    }

    private func decodeWithReplacedPayload(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        payload: [UInt8],
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        let paddingSize = 64
        var buffer = payload
        buffer.append(contentsOf: repeatElement(0, count: paddingSize))
        return buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            var temp = AVPacket()
            temp.data = bufPtr.baseAddress
            temp.size = Int32(payload.count)
            temp.pts = pkt.pointee.pts
            temp.dts = pkt.pointee.dts
            temp.duration = pkt.pointee.duration
            temp.stream_index = pkt.pointee.stream_index
            temp.flags = pkt.pointee.flags
            return avcodec_decode_subtitle2(ctx, sub, gotSub, &temp)
        }
    }

    private func decodeWithStrippedPrefix(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        prefix: Int,
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        let originalSize = Int(pkt.pointee.size)
        guard originalSize > prefix, let srcData = pkt.pointee.data else {
            return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
        }
        let payloadSize = originalSize - prefix
        let paddingSize = 64
        var buffer = [UInt8](repeating: 0, count: payloadSize + paddingSize)
        memcpy(&buffer, srcData.advanced(by: prefix), payloadSize)

        return buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            var temp = AVPacket()
            temp.data = bufPtr.baseAddress
            temp.size = Int32(payloadSize)
            temp.pts = pkt.pointee.pts
            temp.dts = pkt.pointee.dts
            temp.duration = pkt.pointee.duration
            temp.stream_index = pkt.pointee.stream_index
            temp.flags = pkt.pointee.flags
            return avcodec_decode_subtitle2(ctx, sub, gotSub, &temp)
        }
    }

    // MARK: - Rect → text / image

    private static func textForSubtitleRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
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
            // ASS dialogue layout: 9 comma-separated fields; the body
            // is the 9th and may contain commas.
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

    /// Render a bitmap subtitle rect (PGS / DVB / HDMV) into a
    /// CGImage with normalised position. Walks the indexed-pixel
    /// plane (`data[0]`) through the palette (`data[1]`) into a
    /// packed RGBA buffer and wraps that as a CGImage.
    ///
    /// The palette is delivered by libavcodec as 32-bit values laid
    /// out with alpha in the high byte and BGR below, i.e. on a
    /// little-endian platform the bytes in memory read `[B, G, R, A]`.
    /// We rewrite to RGBA byte order for CGImage's
    /// `premultipliedLast` consumer.
    private static func imageForSubtitleRect(
        _ rect: UnsafeMutablePointer<AVSubtitleRect>,
        videoWidth: Int,
        videoHeight: Int
    ) -> SubtitleImage? {
        let r = rect.pointee
        guard r.type == SUBTITLE_BITMAP,
              r.w > 0, r.h > 0,
              let pixelsPtr = r.data.0,
              let palettePtr = r.data.1
        else { return nil }

        let width = Int(r.w)
        let height = Int(r.h)
        let stride = Int(r.linesize.0)

        // Walk once to find the bounding box of non-zero-alpha pixels.
        // Some Blu-ray-to-MKV conversions emit PGS events as full
        // 1920x1080 ODS bitmaps with cropping parameters that FFmpeg's
        // pgssubdec discards. Re-crop ourselves so the overlay
        // positions correctly and doesn't carry ~8 MB of transparent
        // pixels per cue.
        let alphaThreshold: UInt8 = 8
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowOff = y * stride
            for x in 0..<width {
                let palIdx = Int(pixelsPtr[rowOff + x])
                let alpha = palettePtr[palIdx * 4 + 3]
                if alpha >= alphaThreshold {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1
        let absX = Int(r.x) + minX
        let absY = Int(r.y) + minY

        var rgba = [UInt8](repeating: 0, count: cropW * cropH * 4)
        for cy in 0..<cropH {
            let srcRow = (minY + cy) * stride
            let dstRow = cy * cropW * 4
            for cx in 0..<cropW {
                let palIdx = Int(pixelsPtr[srcRow + minX + cx])
                let palOff = palIdx * 4
                let b = palettePtr[palOff + 0]
                let g = palettePtr[palOff + 1]
                let red = palettePtr[palOff + 2]
                let a = palettePtr[palOff + 3]
                // Premultiply against alpha so CGImage's
                // premultipliedLast renders correctly without the
                // black-fringe edges that straight alpha produces.
                let outOff = dstRow + cx * 4
                rgba[outOff + 0] = UInt8((Int(red) * Int(a) + 127) / 255)
                rgba[outOff + 1] = UInt8((Int(g) * Int(a) + 127) / 255)
                rgba[outOff + 2] = UInt8((Int(b) * Int(a) + 127) / 255)
                rgba[outOff + 3] = a
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: cropW,
            height: cropH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cropW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let position: CGRect
        if videoWidth > 0, videoHeight > 0 {
            position = CGRect(
                x: Double(absX) / Double(videoWidth),
                y: Double(absY) / Double(videoHeight),
                width: Double(cropW) / Double(videoWidth),
                height: Double(cropH) / Double(videoHeight)
            )
        } else {
            position = CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.15)
        }

        return SubtitleImage(cgImage: cgImage, position: position)
    }
}
