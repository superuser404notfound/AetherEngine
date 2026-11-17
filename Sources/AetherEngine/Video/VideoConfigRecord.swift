import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// The video config record (`hvcC` / `avcC`) and the framing question that hangs off it (#365).
///
/// movenc decides whether to convert a packet from Annex B to length-prefixed by looking at the
/// **extradata**, not at the packet: `mov_write_packet_internal` runs `ff_hevc_annexb2mp4` for every
/// sample as soon as the config record starts with a start code ("extradata is Annex B, assume the
/// bitstream is too and convert it", movenc.c), and for H.264 it reformats on anything that is not an
/// `avcC` at all. A source that carries Annex-B parameter sets while muxing length-prefixed NALs (a
/// Matroska remux whose CodecPrivate is Annex B, or one with no CodecPrivate at all, where
/// libavformat synthesises Annex-B extradata from the first in-band parameter sets) therefore has
/// every video sample rewritten by a converter that finds no start codes: the samples come out empty
/// except where a 4-byte NAL length happens to read as `00 00 01`. The init.mp4 is perfectly valid
/// throughout, which is why the failure looks like a decoder problem.
enum VideoConfigRecord {

    /// One array of an `hvcC` record: its three header bytes and the NAL units behind them.
    struct HVCCArray {
        let header: Range<Int>
        /// `NAL_unit_type` of the array (the header's low six bits).
        let type: UInt8
        let nals: [Range<Int>]
    }

    /// The arrays of an `hvcC` record (22-byte header, array count at byte 22), the one walk every
    /// consumer shares (audit BIT-R203). `isComplete` is false when the record ends inside an array
    /// header or a NAL, or holds a zero-length NAL; `arrays` then holds what was read before that.
    /// `end` is where the walk stopped, so a caller can also refuse trailing bytes.
    static func hvccArrays(_ record: UnsafeBufferPointer<UInt8>) -> (arrays: [HVCCArray], isComplete: Bool, end: Int) {
        guard record.count > 23 else { return ([], false, 0) }
        var arrays: [HVCCArray] = []
        var cursor = 23
        for _ in 0..<Int(record[22]) {
            guard cursor + 3 <= record.count else { return (arrays, false, cursor) }
            let header = cursor..<cursor + 3
            let type = record[cursor] & 0x3F
            let count = Int(record[cursor + 1]) << 8 | Int(record[cursor + 2])
            cursor += 3
            var nals: [Range<Int>] = []
            for _ in 0..<count {
                guard cursor + 2 <= record.count else { arrays.append(HVCCArray(header: header, type: type, nals: nals)); return (arrays, false, cursor) }
                let length = Int(record[cursor]) << 8 | Int(record[cursor + 1])
                cursor += 2
                guard length > 0, cursor + length <= record.count else {
                    arrays.append(HVCCArray(header: header, type: type, nals: nals))
                    return (arrays, false, cursor)
                }
                nals.append(cursor..<cursor + length)
                cursor += length
            }
            arrays.append(HVCCArray(header: header, type: type, nals: nals))
        }
        return (arrays, true, cursor)
    }

    /// Will the mp4 muxer reformat every sample of this track? Mirrors movenc's own two tests rather
    /// than an equivalent-looking predicate: predicting this decision wrong is the whole defect.
    static func muxerWillReformatPackets(
        codecID: AVCodecID, extradata: UnsafePointer<UInt8>?, size: Int
    ) -> Bool {
        guard let data = extradata, size > 0 else { return false }
        switch codecID {
        case AV_CODEC_ID_H264:
            return data[0] != 1
        case AV_CODEC_ID_HEVC:
            return isAnnexB(data, size: size)
        default:
            return false
        }
    }

    /// Mirrors movenc's HEVC test byte for byte.
    static func isAnnexB(_ data: UnsafePointer<UInt8>, size: Int) -> Bool {
        guard size > 6 else { return false }
        let rb24 = (UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2])
        let rb32 = (rb24 << 8) | UInt32(data[3])
        return rb24 == 1 || rb32 == 1
    }

    static func isAnnexB(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return isAnnexB(base, size: buf.count)
        }
    }

    /// Convert Annex-B parameter sets into an `hvcC` / `avcC`, by having movenc build it.
    ///
    /// Hand-rolling the record would mean parsing `profile_tier_level` out of the SPS and getting
    /// chroma format, bit depths and the sub-layer flags right; movenc already does exactly that in
    /// `ff_isom_write_hvcc`, and its answer is by definition the one the real muxer would have
    /// written. A throwaway mp4 header goes to an in-memory AVIO sink and the record box is read back
    /// out of it. Handing that record to the session muxer is idempotent: the record path in
    /// `ff_isom_write_hvcc` re-parses the arrays and writes the same bytes.
    ///
    /// Returns nil when the buffer is not Annex B or movenc cannot make a record of it; the caller
    /// then leaves the source extradata alone.
    static func fromAnnexB(
        _ extradata: [UInt8], codecID: AVCodecID, width: Int32, height: Int32
    ) -> [UInt8]? {
        guard isAnnexB(extradata) else { return nil }
        let isHEVC = codecID == AV_CODEC_ID_HEVC
        guard isHEVC || codecID == AV_CODEC_ID_H264 else { return nil }
        let boxFourCC: [UInt8] = isHEVC
            ? [0x68, 0x76, 0x63, 0x43]   // hvcC
            : [0x61, 0x76, 0x63, 0x43]   // avcC
        let sampleEntryTag: UInt32 = isHEVC ? mkTagHVC1 : mkTagAVC1

        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "config-probe.mp4") == 0,
              let ctx = ctxOut
        else { return nil }
        defer { avformat_free_context(ctx) }
        // Dolby Vision atoms need the relaxed compliance level the session muxer also runs at; the
        // hvcC itself does not, but a rejected header would produce no record at all.
        ctx.pointee.strict_std_compliance = -2

        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let pbCtx = pb else { return nil }
        ctx.pointee.pb = pbCtx

        guard let stream = avformat_new_stream(ctx, nil) else {
            discardDynBuf(pbCtx, ctx: ctx)
            return nil
        }
        stream.pointee.time_base = AVRational(num: 1, den: 90_000)
        guard let par = stream.pointee.codecpar else {
            discardDynBuf(pbCtx, ctx: ctx)
            return nil
        }
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = codecID
        par.pointee.codec_tag = sampleEntryTag
        par.pointee.width = width > 0 ? width : 1920
        par.pointee.height = height > 0 ? height : 1080
        guard setExtradata(par, extradata) else {
            discardDynBuf(pbCtx, ctx: ctx)
            return nil
        }

        var opts: OpaquePointer?
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "movflags", "+frag_keyframe+empty_moov", 0)
        guard avformat_write_header(ctx, &opts) >= 0 else {
            discardDynBuf(pbCtx, ctx: ctx)
            return nil
        }

        var bufPtr: UnsafeMutablePointer<UInt8>?
        let written = avio_close_dyn_buf(pbCtx, &bufPtr)
        ctx.pointee.pb = nil
        defer { if let b = bufPtr { av_free(b) } }
        guard written > 8, let bytes = bufPtr else { return nil }

        return extractBox(fourCC: boxFourCC, from: bytes, count: Int(written))
    }

    /// Keep only VPS/SPS/PPS in an Annex-B HEVC config record, still in Annex B.
    ///
    /// When the packets are Annex B too, the record has to be forwarded as it is: movenc reads it to
    /// decide whether to convert the samples, and handing it an `hvcC` here would leave every sample
    /// unconverted. It then builds the `hvcC` itself, and `ff_isom_write_hvcc` collects five NAL types,
    /// not three (`array_idx_to_type`: VPS, SPS, PPS, SEI_PREFIX, SEI_SUFFIX), so a prefix SEI in the
    /// CodecPrivate reaches the init sample description as a fourth array. That is the record Apple TV
    /// hardware rejects (AE#187), and the AE#187 defense cannot see it: `canonicalizeHEVCConfigRecord`
    /// guards on `configurationVersion == 1`, which an Annex-B buffer fails by construction, and the
    /// muxer-built record is never handled by the engine at all. Dropping the SEI on this side of the
    /// muxer is the only place the two constraints both hold.
    ///
    /// NALs are re-emitted with 3-byte start codes, the shape libavformat synthesises for a Matroska
    /// track whose CodecPrivate is Annex B. Returns nil when the buffer is not Annex B, carries no
    /// parameter sets to keep, or has nothing to drop; the caller then forwards the source unchanged.
    static func canonicalizeAnnexBHEVCConfigRecord(_ extradata: [UInt8]) -> [UInt8]? {
        guard isAnnexB(extradata) else { return nil }
        let nals = splitAnnexBNALs(extradata)
        guard !nals.isEmpty else { return nil }

        let parameterSetTypes: Set<Int> = [32, 33, 34]   // VPS, SPS, PPS
        let kept = nals.filter { parameterSetTypes.contains(hevcNALType($0)) }
        guard kept.count < nals.count else { return nil }        // nothing to drop: already canonical
        guard kept.contains(where: { hevcNALType($0) == 33 })    // no SPS means no record at all;
        else { return nil }                                      // forwarding is worse than nothing

        var out: [UInt8] = []
        out.reserveCapacity(kept.reduce(0) { $0 + $1.count + 3 })
        for nal in kept { out += [0x00, 0x00, 0x01]; out += nal }
        return out
    }

    /// What an Annex-B config record is made of, for the log.
    ///
    /// The composition is the discriminating fact when a source with an Annex-B record fails to build a
    /// format description, and it is the one thing the reporter's own capture can carry: the record
    /// itself is not in any log, its size alone does not say whether the excess is a large SPS or an
    /// SEI, and only the latter reaches the muxer-built hvcC.
    static func annexBNALSummary(_ extradata: [UInt8]) -> String {
        var order: [Int] = []
        var counts: [Int: (count: Int, bytes: Int)] = [:]
        for nal in splitAnnexBNALs(extradata) {
            let type = hevcNALType(nal)
            if counts[type] == nil { order.append(type) }
            let existing = counts[type] ?? (0, 0)
            counts[type] = (existing.count + 1, existing.bytes + nal.count)
        }
        return order.map { type in
            let entry = counts[type]!
            return "\(hevcNALTypeName(type))×\(entry.count) (\(entry.bytes) B)"
        }.joined(separator: ", ")
    }

    private static func hevcNALTypeName(_ type: Int) -> String {
        switch type {
        case 32: return "VPS"
        case 33: return "SPS"
        case 34: return "PPS"
        case 39: return "SEI_PREFIX"
        case 40: return "SEI_SUFFIX"
        default: return "NAL\(type)"
        }
    }

    private static func hevcNALType(_ nal: [UInt8]) -> Int {
        nal.isEmpty ? -1 : (Int(nal[0]) >> 1) & 0x3F
    }

    /// Split an Annex-B buffer into NAL payloads, 3-byte and 4-byte start codes alike.
    ///
    /// Zero bytes immediately before a start code belong to the start code (a 4-byte code is a 3-byte
    /// one with a leading `trailing_zero_8bits`), so they are trimmed off the preceding NAL. A
    /// parameter set never ends in `0x00`: its last byte carries the rbsp_stop_one_bit.
    static func splitAnnexBNALs(_ bytes: [UInt8]) -> [[UInt8]] {
        AnnexB.nalRanges(bytes).map { Array(bytes[$0]) }
    }

    /// First payload of a top-level-or-nested box with this four-character code. The probe header is
    /// a few hundred bytes and has exactly one such box, so a linear scan is both sufficient and the
    /// only thing that stays correct if movenc ever changes where it nests the sample entry.
    private static func extractBox(
        fourCC: [UInt8], from bytes: UnsafePointer<UInt8>, count: Int
    ) -> [UInt8]? {
        guard count > 8 else { return nil }
        var i = 4
        while i + 4 <= count {
            if bytes[i] == fourCC[0], bytes[i + 1] == fourCC[1],
               bytes[i + 2] == fourCC[2], bytes[i + 3] == fourCC[3] {
                let sizeOffset = i - 4
                let size = (Int(bytes[sizeOffset]) << 24) | (Int(bytes[sizeOffset + 1]) << 16)
                    | (Int(bytes[sizeOffset + 2]) << 8) | Int(bytes[sizeOffset + 3])
                let payloadStart = i + 4
                guard size > 8, sizeOffset + size <= count else { return nil }
                let payloadCount = size - 8
                guard payloadCount > 0 else { return nil }
                return [UInt8](UnsafeBufferPointer(start: bytes + payloadStart, count: payloadCount))
            }
            i += 1
        }
        return nil
    }

    private static var mkTagHVC1: UInt32 { mkTag(0x68, 0x76, 0x63, 0x31) }   // "hvc1"
    private static var mkTagAVC1: UInt32 { mkTag(0x61, 0x76, 0x63, 0x31) }   // "avc1"

    private static func mkTag(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        a | (b << 8) | (c << 16) | (d << 24)
    }

    private static func setExtradata(
        _ par: UnsafeMutablePointer<AVCodecParameters>, _ bytes: [UInt8]
    ) -> Bool {
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buf = av_malloc(bytes.count + pad) else { return false }
        let typed = buf.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(typed, base, bytes.count) }
        }
        memset(typed + bytes.count, 0, pad)
        par.pointee.extradata = typed
        par.pointee.extradata_size = Int32(bytes.count)
        return true
    }

    private static func discardDynBuf(
        _ pb: UnsafeMutablePointer<AVIOContext>, ctx: UnsafeMutablePointer<AVFormatContext>
    ) {
        var bufPtr: UnsafeMutablePointer<UInt8>?
        _ = avio_close_dyn_buf(pb, &bufPtr)
        ctx.pointee.pb = nil
        if bufPtr != nil { av_free(bufPtr) }
    }

    // MARK: - Packet framing

    /// Does this packet walk cleanly as length-prefixed NALs, consuming every byte exactly?
    ///
    /// This is the discriminator, not "does it start with a start code": every NAL of 256 to 511
    /// bytes carries the length prefix `00 00 01 xx`, which is a start code to anything that only
    /// looks at the head, and SEI or parameter-set NALs sit in that band routinely. The
    /// exact-consumption walk cannot be fooled that way, because Annex-B data would have to encode
    /// its own byte offsets to close.
    static func walksAsLengthPrefixed(
        _ data: UnsafePointer<UInt8>, size: Int, lengthSize: Int = 4
    ) -> Bool {
        guard size > lengthSize, lengthSize >= 1, lengthSize <= 4 else { return false }
        var offset = 0
        var nalCount = 0
        while offset + lengthSize <= size {
            var len = 0
            for i in 0..<lengthSize {
                len = (len << 8) | Int(data[offset + i])
            }
            guard len > 0, offset + lengthSize + len <= size else { return false }
            offset += lengthSize + len
            nalCount += 1
        }
        return offset == size && nalCount > 0
    }

    static func startsWithStartCode(_ data: UnsafePointer<UInt8>, size: Int) -> Bool {
        guard size >= 4 else { return false }
        let rb24 = (UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2])
        let rb32 = (rb24 << 8) | UInt32(data[3])
        return rb24 == 1 || rb32 == 1
    }
}

/// VPS/SPS/PPS NALs from hvcC extradata, raw bytes without a length prefix or start code. A truncated
/// record yields the units before the cut, which is what the dual-layer join wants to seed with.
func parseHVCCParameterSets(_ ed: UnsafePointer<UInt8>, _ size: Int) -> [[UInt8]] {
    let walk = VideoConfigRecord.hvccArrays(UnsafeBufferPointer(start: ed, count: max(0, size)))
    return walk.arrays.flatMap { $0.nals.map { [UInt8](UnsafeBufferPointer(start: ed + $0.lowerBound, count: $0.count)) } }
}
