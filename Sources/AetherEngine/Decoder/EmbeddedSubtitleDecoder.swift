import Foundation
import CoreGraphics
import Compression
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Packet-by-packet decoder for an embedded subtitle stream (SubRip/ASS/SSA/WebVTT/mov_text/PGS/DVB/HDMV).
/// Owns one AVCodecContext per active track; HLSSegmentProducer feeds packets and bridges results to MainActor.
/// Handles PGS PES-header strip, zlib/gzip Matroska compression wrappers, and PGS clear-event semantics.
/// Not MainActor: lives on the HLSSegmentProducer pump worker queue.
final class EmbeddedSubtitleDecoder {

    struct SubtitleEvent: @unchecked Sendable {
        /// Empty for PGS clear events (each PGS event implicitly terminates the previous bitmap; AetherEngine applies the trim).
        let cues: [SubtitleCue]
        let isPGS: Bool
        /// PTS at which the previous PGS cue should be trimmed. nil for non-PGS.
        let pgsTrimAt: Double?
        /// #107: PTS at which earlier open text cues of this track should be trimmed. Set for
        /// every teletext event (content and page-erase): a teletext page is full state, each
        /// transmission replaces the previous one, and libzvbi emits content open-ended
        /// ("until replaced"). nil for all other codecs.
        var textTrimAt: Double? = nil
        /// #112: the emitting display set was an Acquisition Point / Epoch Start - a self-contained restatement of
        /// the line. A reconstruction pass publishes such a composition immediately (it IS the current line) rather
        /// than holding it for successor resolution. False for Normal deltas and all non-PGS events.
        var isSelfContainedPGS: Bool = false
    }

    /// Exposed so callers can gate on text-vs-bitmap or check for PGS specifically.
    let codecID: AVCodecID

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var nextCueID: Int = 0
    private var seenKeys: Set<String> = []

    /// #112: composition_state of the most recent PCS seen, carried until the display set's END emits the cue. In a
    /// split M2TS the PCS and the emitting END arrive in different packets, so the state must be remembered across
    /// packets rather than read off the packet that triggers `gotSub`.
    private var pendingPGSCompositionState: PGSCompositionState?

    /// Fallback canvas for bitmap subtitle positioning; some codecs (PGS) override via PCS once it arrives.
    private let sourceVideoWidth: Int32
    private let sourceVideoHeight: Int32

    /// `LoadOptions.preserveASSMarkup` ALREADY GATED on this stream's codec: true only for ASS/SSA,
    /// where cues then carry the raw libavcodec event line (AetherEngine#30 styled rendering).
    ///
    /// AE#587: named for the answer rather than the option because the gate is set in `init` and read
    /// a hundred lines below, and a property carrying the option's own name reads at the emit site as
    /// if no gate existed at all. libavcodec normalises SubRip, WebVTT and mov_text through
    /// `ff_ass_add_rect` too, so every text codec has an ASS payload to emit and only the codec tells
    /// them apart.
    private let emitsRawASSLines: Bool

    /// #107: explicit teletext page override (nil = libzvbi `subtitle` auto-detect).
    private let teletextPage: Int?

    /// #233: coordinate space `\pos` is expressed in. A real ASS track declares its own PlayResX/Y
    /// in the header libavcodec hands over as extradata; every event line libavcodec synthesises
    /// for SRT, WebVTT or teletext uses the default 384x288 instead.
    private let assPlayRes: CGSize

    /// Open the subtitle decoder for `stream`. Returns `nil` if the codec couldn't be opened.
    convenience init?(stream: UnsafeMutablePointer<AVStream>, sourceVideoWidth: Int32, sourceVideoHeight: Int32, preserveASSMarkup: Bool = false, teletextPage: Int? = nil) {
        guard let codecpar = stream.pointee.codecpar else { return nil }
        self.init(codecpar: codecpar, sourceVideoWidth: sourceVideoWidth,
                  sourceVideoHeight: sourceVideoHeight, preserveASSMarkup: preserveASSMarkup,
                  teletextPage: teletextPage)
        // Some demuxers default to AVDISCARD_DEFAULT and swallow packets; force NONE so everything reaches av_read_frame.
        stream.pointee.discard = AVDISCARD_NONE
    }

    /// Open the subtitle decoder for a stream's parameters alone. #921: a bitmap sidecar keeps a
    /// copy of its parameters after its container is closed, and builds its drain decoders from it.
    init?(codecpar: UnsafePointer<AVCodecParameters>, sourceVideoWidth: Int32, sourceVideoHeight: Int32, preserveASSMarkup: Bool = false, teletextPage: Int? = nil) {
        guard codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { return nil }
        let id = codecpar.pointee.codec_id
        guard let codec = avcodec_find_decoder(id),
              let ctx = avcodec_alloc_context3(codec)
        else { return nil }

        if avcodec_parameters_to_context(ctx, codecpar) < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            return nil
        }

        // Seed bitmap canvas from video dims; PCS overwrites once it arrives (probe can't always determine them upfront).
        if Self.isBitmapCodec(id) {
            if ctx.pointee.width == 0 { ctx.pointee.width = sourceVideoWidth }
            if ctx.pointee.height == 0 { ctx.pointee.height = sourceVideoHeight }
        }

        var opts: OpaquePointer?
        for (key, value) in Self.decoderOptions(for: id, teletextPage: teletextPage) {
            av_dict_set(&opts, key, value, 0)
        }
        let openResult = avcodec_open2(ctx, codec, &opts)
        av_dict_free(&opts)
        if openResult < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            return nil
        }

        self.codecID = id
        self.codecContext = ctx
        self.sourceVideoWidth = sourceVideoWidth
        self.sourceVideoHeight = sourceVideoHeight
        // The documented "only affects ASS / SSA codecs" gate, matching SubtitleDecoder's sidecar path.
        self.emitsRawASSLines = preserveASSMarkup
            && (id == AV_CODEC_ID_ASS || id == AV_CODEC_ID_SSA)
        self.teletextPage = teletextPage

        var playRes = SubtitleRectText.defaultASSPlayRes
        if let extra = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
            let header = String(decoding: UnsafeBufferPointer(
                start: extra, count: Int(codecpar.pointee.extradata_size)), as: UTF8.self)
            if let declared = SubtitleRectText.playRes(fromASSHeader: header) { playRes = declared }
        }
        self.assPlayRes = playRes
    }

    deinit {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
    }

    /// Decode `packet`. Returns nil if nothing usable; otherwise a SubtitleEvent with cues + PGS trim info.
    /// cue.startTime/endTime are absolute source PTS seconds (same axis as engine.sourceTime).
    /// Do NOT subtract stream.start_time: for MKV that equals the first cue's PTS, which would shift all cues back
    /// and fire the first PGS cue immediately (confirmed with Harry Potter, first cue at source PTS=19.186 s).
    func decode(
        packet: UnsafeMutablePointer<AVPacket>,
        streamTimeBase: AVRational
    ) -> SubtitleEvent? {
        guard let ctx = codecContext else { return nil }

        var sub = AVSubtitle()
        var gotSub: Int32 = 0
        var fixedPayload: [UInt8]? = nil
        let ret = decodeWithFixups(ctx: ctx, pkt: packet, sub: &sub, gotSub: &gotSub, capturedPayload: &fixedPayload)

        // #112: remember this packet's PGS composition state (a PCS-only packet carries it; the later END emits the
        // cue). Only overwrite when a PCS is actually present so the state survives the intervening ODS/END packets.
        if ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE,
           let state = Self.pgsCompositionState(for: packet, fixedPayload: fixedPayload) {
            pendingPGSCompositionState = state
        }

        // Some MKV converters drop the PGS trailing END (0x80); feed a synthetic one to flush accumulated
        // state. Gate it (#112): only when the decoded payload already carries a complete object and no END
        // of its own. A split-M2TS intermediate packet (PCS/PDS ahead of the ODS) would otherwise force a
        // compose against an object that is not defined yet ("Invalid object id", once per display set).
        if gotSub == 0,
           ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE,
           packet.pointee.size > 30,
           Self.pgsPayloadWarrantsSyntheticEnd(for: packet, fixedPayload: fixedPayload) {
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

        guard ret >= 0, gotSub != 0 else {
            // Synthetic PGS END flush can set gotSub even when ret < 0; free to avoid a leak.
            if gotSub != 0 { avsubtitle_free(&sub) }
            return nil
        }

        let isTeletext = ctx.pointee.codec_id == AV_CODEC_ID_DVB_TELETEXT
        let tbSec = Double(streamTimeBase.num) / Double(streamTimeBase.den)
        let rawPTS = packet.pointee.pts
        let pktPTS = (rawPTS == Int64.min) ? 0 : Double(rawPTS) * tbSec
        let startOffset = Double(sub.start_display_time) / 1000.0
        var endOffset: Double
        if sub.end_display_time > 0 {
            endOffset = Double(sub.end_display_time) / 1000.0
        } else if packet.pointee.duration > 0 {
            endOffset = Double(packet.pointee.duration) * tbSec
        } else {
            endOffset = 5.0
        }
        // #107: libzvbi emits page content open-ended (end_display_time = u32 max, "until
        // replaced"); textTrimAt closes the window at the next page event or erase. The cap
        // only bounds a ghost line if transmission stops without either; teletext re-transmits
        // held pages every few seconds, so a real caption never hits it.
        if isTeletext, endOffset > 120 { endOffset = 120 }
        let startTime = pktPTS + startOffset
        let endTime = pktPTS + endOffset

        // PCS-reported canvas; fall back to source video dims if missing.
        let canvasW = ctx.pointee.width > 0 ? ctx.pointee.width : sourceVideoWidth
        let canvasH = ctx.pointee.height > 0 ? ctx.pointee.height : sourceVideoHeight

        var bodies: [SubtitleCue.Body] = []
        var textLines: [String] = []
        var placement: SubtitleTextPlacement?
        if sub.num_rects > 0, let rects = sub.rects {
            for i in 0..<Int(sub.num_rects) {
                guard let rect = rects[i] else { continue }
                if isTeletext, let assLine = SubtitleRectText.rawASSLine(for: rect) {
                    // Teletext decodes as ASS (txt_format=ass); parse styled runs (#107 colour,
                    // #233 the rest). Falls back to plain text inside teletextBody when the page
                    // carries no styling.
                    if let parsed = SubtitleRectText.teletextBody(fromASSEventLine: assLine,
                                                                 playRes: assPlayRes) {
                        bodies.append(parsed.body)
                        placement = placement ?? parsed.placement
                    }
                } else if emitsRawASSLines, let raw = SubtitleRectText.rawASSLine(for: rect) {
                    // ASS/SSA only; every other text codec falls through to the extraction below
                    // (AE#587, gate in init).
                    textLines.append(raw)
                } else if let assLine = SubtitleRectText.rawASSLine(for: rect),
                          let parsed = SubtitleRectText.styledBody(fromASSEventLine: assLine,
                                                                  playRes: assPlayRes) {
                    // #233: libavcodec converts every text format to an ASS event line, so SRT,
                    // WebVTT and ASS all keep their styling here. An unstyled cue still comes back
                    // as .text and merges with its siblings below, exactly as the plain path did.
                    placement = placement ?? parsed.placement
                    if case .text(let t) = parsed.body {
                        textLines.append(t)
                    } else {
                        bodies.append(parsed.body)
                    }
                } else if let text = SubtitleRectText.plainText(for: rect) {
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

        // #233: WebVTT cue settings never reach the ASS event line (the decoder drops them), but
        // the demuxer keeps them on the packet, and the #112 store carries them through a rebuild.
        // An ASS `\an` / `\pos` still wins, since that came from the payload itself.
        placement = placement ?? WebVTTCueSettings.placement(onPacket: packet)

        let merged = textLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !merged.isEmpty {
            bodies.append(.text(merged))
        }

        let isPGS = ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let isClearEvent = bodies.isEmpty

        // A teletext page erase carries no rects but must still trim the open page cue (#107).
        guard endTime > startTime || (isClearEvent && isTeletext) else { return nil }
        guard !isClearEvent || isPGS || isTeletext else { return nil }

        // Bound the dedupe set to prevent unbounded growth on long live sessions (DVB/PGS).
        // Reset only weakens dedupe (a re-emitted duplicate renders as an identical overlay), never correctness.
        if seenKeys.count > 4096 {
            seenKeys.removeAll(keepingCapacity: true)
        }

        // Dedupe duplicate non-empty events; key includes CONTENT not just times+count:
        // two simultaneous speaker lines (classic anime ASS, identical pts/duration, one body each)
        // are distinct and must both survive.
        if !isClearEvent {
            let contentKey = bodies.map { body -> String in
                switch body {
                case .text(let t):
                    return "t:\(t)"
                case .richText(let runs):
                    return "t:" + runs.map { run in
                        let c = run.color.map { "\($0.r),\($0.g),\($0.b)" } ?? "-"
                        // #233: two cues differing only in styling are distinct events.
                        let s = "\(run.isBold)\(run.isItalic)\(run.isUnderlined)"
                            + "\(run.isStruckThrough)\(run.fontName ?? "-")\(run.fontSize ?? -1)"
                        return "\(run.text)#\(c)#\(s)"
                    }.joined(separator: "\u{1E}")
                case .image(let img):
                    // Dimensions + position discriminate cheaply; identical-rect repeats are the target case.
                    return "i:\(img.cgImage.width)x\(img.cgImage.height)@\(img.position)"
                }
            }.joined(separator: "\u{1F}")
            let key = "\(startTime)|\(endTime)|\(contentKey)"
            if seenKeys.contains(key) { return nil }
            seenKeys.insert(key)
        }

        let cueIDStart = nextCueID
        nextCueID += bodies.count

        let cues: [SubtitleCue] = bodies.enumerated().map { (offset, body) in
            // Placement is the text equivalent of a bitmap rect's geometry, so an image body keeps
            // carrying its own and never takes the cue-level one.
            var cuePlacement = placement
            if case .image = body { cuePlacement = nil }
            return SubtitleCue(
                id: cueIDStart + offset,
                startTime: startTime,
                endTime: endTime,
                body: body,
                placement: cuePlacement
            )
        }

        // #112: consume the remembered PGS composition state for this display set.
        let selfContained = isPGS && (pendingPGSCompositionState?.isSelfContained ?? false)
        pendingPGSCompositionState = nil

        return SubtitleEvent(
            cues: cues,
            isPGS: isPGS,
            pgsTrimAt: isPGS ? startTime : nil,
            textTrimAt: isTeletext ? startTime : nil,
            isSelfContainedPGS: selfContained
        )
    }

    // MARK: - Codec checks

    static func isBitmapCodec(_ id: AVCodecID) -> Bool {
        return id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
            || id == AV_CODEC_ID_DVB_SUBTITLE
            || id == AV_CODEC_ID_DVD_SUBTITLE
            || id == AV_CODEC_ID_XSUB
    }

    /// Decoder options for a subtitle codec. DVB teletext (libzvbi_teletextdec) emits ASS so colour
    /// override tags survive to the overlay (#107 colour); `txt_page` selects the caption page
    /// (`subtitle` = libzvbi auto-detect; an explicit page targets channels libzvbi does not flag,
    /// e.g. AU 801). Every other codec opens with no options.
    static func decoderOptions(for id: AVCodecID, teletextPage: Int?) -> [String: String] {
        guard id == AV_CODEC_ID_DVB_TELETEXT else { return [:] }
        return ["txt_format": "ass", "txt_page": teletextPage.map(String.init) ?? "subtitle"]
    }

    /// Issue #112: decide whether a PGS payload that decoded with gotSub==0 warrants the synthetic
    /// END flush. True ONLY when the payload already carries a complete object (an ODS whose
    /// last-in-sequence flag is set) and no END segment of its own: the MKV-converter case the flush
    /// targets (a full display set missing its trailing 0x80). It excludes the split-M2TS intermediate
    /// packet (PCS/PDS before the ODS), where forcing a compose references an object that is not
    /// defined yet and logs "Invalid object id".
    ///
    /// Payload layout: a run of `[type:1][length:2 BE][body:length]` segments (0x14 PDS, 0x15 ODS,
    /// 0x16 PCS, 0x17 WDS, 0x80 END). Walked defensively; any malformed length ends the scan without a
    /// read past `count`.
    static func pgsPayloadWarrantsSyntheticEnd(_ base: UnsafePointer<UInt8>?, count: Int) -> Bool {
        guard let base, count >= 3 else { return false }
        var i = 0
        var sawCompleteObject = false
        while i + 3 <= count {
            let type = base[i]
            let len = (Int(base[i + 1]) << 8) | Int(base[i + 2])
            let bodyStart = i + 3
            if type == 0x80 { return false }   // real END present: the decoder emits on its own.
            if type == 0x15,                   // ODS: complete only when the last-in-sequence bit is set.
               len >= 4,
               bodyStart + 3 < count {
                // ODS body = object_id[2] + version[1] + sequence_flag[1]; 0x40 = last, 0xC0 = only.
                if (base[bodyStart + 3] & 0x40) != 0 { sawCompleteObject = true }
            }
            let next = bodyStart + len
            if next <= i { break }             // zero/negative advance guard.
            i = next
        }
        return sawCompleteObject
    }

    /// #112 full umbau: PGS composition state (the PCS `composition_state` field). An acquisition point or epoch
    /// start is a self-contained restatement of the current on-screen line - the disc's own random-access anchor -
    /// so a reconstruction pass that decodes one can publish the line immediately instead of holding it as a stale
    /// replay.
    enum PGSCompositionState: Sendable, Equatable {
        case normal            // 0x00: delta update; prior objects/palettes still required.
        case acquisitionPoint  // 0x40: mid-epoch restatement; safe to begin decoding here.
        case epochStart        // 0x80: fresh epoch; fully self-contained.

        /// True when the composition re-establishes the visible line without any earlier segment.
        var isSelfContained: Bool { self != .normal }
    }

    /// #112 full umbau: read the composition_state of the first PCS (0x16) segment in a PGS segment run. Payload
    /// layout mirrors `pgsPayloadWarrantsSyntheticEnd`: a run of `[type:1][length:2 BE][body:length]`. The PCS body
    /// is `width[2] height[2] frame_rate[1] composition_number[2] composition_state[1] ...`, so composition_state
    /// is at body offset 7; its top two bits carry the state (0x00 Normal / 0x40 Acquisition Point / 0x80 Epoch
    /// Start), the low bits are the palette-update flag + palette id. Returns nil when no PCS is present or its body
    /// is too short to hold the field. Walked defensively; a malformed length ends the scan.
    static func pgsCompositionState(_ base: UnsafePointer<UInt8>?, count: Int) -> PGSCompositionState? {
        guard let base, count >= 3 else { return nil }
        var i = 0
        while i + 3 <= count {
            let type = base[i]
            let len = (Int(base[i + 1]) << 8) | Int(base[i + 2])
            let bodyStart = i + 3
            if type == 0x16 {                       // PCS: the composition segment carries the state.
                let stateOffset = bodyStart + 7
                guard len >= 8, stateOffset < count else { return nil }
                switch base[stateOffset] & 0xC0 {
                case 0x40: return .acquisitionPoint
                case 0x80: return .epochStart
                default:   return .normal           // 0x00 Normal; 0xC0 Epoch-Continue is not self-contained.
                }
            }
            let next = bodyStart + len
            if next <= i { break }                  // zero/negative advance guard.
            i = next
        }
        return nil
    }

    /// #112: pick the bytes actually decoded (`fixedPayload` for stripped/inflated paths, else the raw packet) and
    /// read the PGS composition state over them, mirroring the synthetic-END payload selection.
    private static func pgsCompositionState(
        for packet: UnsafeMutablePointer<AVPacket>,
        fixedPayload: [UInt8]?
    ) -> PGSCompositionState? {
        if let fixedPayload {
            return fixedPayload.withUnsafeBufferPointer {
                pgsCompositionState($0.baseAddress, count: $0.count)
            }
        }
        return pgsCompositionState(packet.pointee.data, count: Int(packet.pointee.size))
    }

    /// Pick the bytes actually decoded (`fixedPayload` for stripped/inflated paths, else the raw
    /// packet) and run the #112 synthetic-END gate over them.
    private static func pgsPayloadWarrantsSyntheticEnd(
        for packet: UnsafeMutablePointer<AVPacket>,
        fixedPayload: [UInt8]?
    ) -> Bool {
        if let fixedPayload {
            return fixedPayload.withUnsafeBufferPointer {
                pgsPayloadWarrantsSyntheticEnd($0.baseAddress, count: $0.count)
            }
        }
        return pgsPayloadWarrantsSyntheticEnd(packet.pointee.data, count: Int(packet.pointee.size))
    }

    // MARK: - Decode fixups

    private func decodeWithFixups(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>,
        capturedPayload: inout [UInt8]?
    ) -> Int32 {
        guard let data = pkt.pointee.data, pkt.pointee.size > 2 else {
            return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
        }

        // 1. zlib-wrapped (RFC 1950), `78 01/5E/9C/DA` magic.
        if data[0] == 0x78,
           data[1] == 0x01 || data[1] == 0x5E || data[1] == 0x9C || data[1] == 0xDA {
            if let decompressed = inflateZlibBlock(data, size: Int(pkt.pointee.size)) {
                capturedPayload = decompressed
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
                capturedPayload = decompressed
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
            capturedPayload = Array(UnsafeBufferPointer(start: data.advanced(by: 10),
                                                        count: Int(pkt.pointee.size) - 10))
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

    /// Render a PGS/DVB/HDMV bitmap rect into a CGImage with normalised position.
    /// Palette from libavcodec is 32-bit with alpha in the high byte and BGR below ([B,G,R,A] on little-endian);
    /// rewritten to RGBA for CGImage's premultipliedLast. Internal for unit tests (#146).
    static func imageForSubtitleRect(
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
        // Malformed rect guard: stride < width would read past the plane allocation.
        guard stride >= width else { return nil }

        // AE#628: resolve the palette once. Every pixel below is then one table read instead of a
        // palette walk plus a premultiply; on a full-canvas plane that is the difference between 5 ms
        // and 1.3 ms per display set in release, and 211 ms and 52 ms in a debug build.
        // Premultiplied: straight alpha produces black-fringe edges in CGImage premultipliedLast.
        // Packed so a little-endian store lays the bytes out as R, G, B, A.
        let alphaThreshold: UInt8 = 8
        var visible = [Bool](repeating: false, count: 256)
        var premultiplied = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            let b = UInt32(palettePtr[i * 4 + 0])
            let g = UInt32(palettePtr[i * 4 + 1])
            let red = UInt32(palettePtr[i * 4 + 2])
            let a = UInt32(palettePtr[i * 4 + 3])
            visible[i] = palettePtr[i * 4 + 3] >= alphaThreshold
            premultiplied[i] = ((red * a + 127) / 255)
                | (((g * a + 127) / 255) << 8)
                | (((b * a + 127) / 255) << 16)
                | (a << 24)
        }

        // Re-crop to non-zero-alpha bounding box: some Blu-ray-to-MKV conversions emit full 1920x1080 ODS bitmaps
        // with cropping params that FFmpeg's pgssubdec discards, carrying ~8 MB of transparent pixels per cue.
        var minX = width, minY = height, maxX = -1, maxY = -1
        visible.withUnsafeBufferPointer { visible in
            for y in 0..<height {
                let row = UnsafeBufferPointer(start: pixelsPtr + y * stride, count: width)
                guard let first = row.firstIndex(where: { visible[Int($0)] }),
                      let last = row.lastIndex(where: { visible[Int($0)] }) else { continue }
                minX = min(minX, first)
                maxX = max(maxX, last)
                if minY == height { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1
        let absX = Int(r.x) + minX
        let absY = Int(r.y) + minY

        var data = Data(count: cropW * cropH * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt32.self)
            premultiplied.withUnsafeBufferPointer { lut in
                for cy in 0..<cropH {
                    let src = pixelsPtr + (minY + cy) * stride + minX
                    let dst = cy * cropW
                    for cx in 0..<cropW { out[dst + cx] = lut[Int(src[cx])].littleEndian }
                }
            }
        }
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

        return SubtitleImage(cgImage: cgImage, position: position,
                             canvasSize: CGSize(width: Int(videoWidth), height: Int(videoHeight)),
                             isForced: (r.flags & AV_SUBTITLE_FLAG_FORCED) != 0)
    }
}
