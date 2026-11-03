import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// A Dolby Vision Profile 7 source whose two layers are separate streams of the container: the UHD Blu-ray layout
/// (base layer on PID 0x1011, enhancement layer on PID 0x1015, `BluRayDolbyVisionLayers`) or a Matroska / MP4 file
/// with the enhancement layer as a video track of its own. The Dolby Vision configuration the container declares
/// links the tracks: the enhancement track says profile 7 with the enhancement layer present and the base layer not,
/// the base track says profile 7 with the base layer present.
///
/// What the demuxer does with it (`Demuxer`): by default it folds the enhancement layer's RPUs into the base layer
/// (the single-layer shape that plays as Profile 8.1); when the dual-layer route is taken it joins the whole
/// enhancement layer in, as the unspec63 NALs a single-track remux carries (`DolbyVisionLayerJoin`).
struct SeparateDolbyVisionLayers: Equatable {

    enum Carriage: Equatable {
        /// Two PIDs of one transport stream (UHD Blu-ray), Annex-B packets.
        case transportPID
        /// Two tracks of a Matroska or MP4 file, length-prefixed packets.
        case track
    }

    let base: Int32
    let enhancement: Int32
    let carriage: Carriage

    /// The two layers' stream indices, or nil when the context holds no such pair.
    static func detect(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> SeparateDolbyVisionLayers? {
        if let pids = BluRayDolbyVisionLayers.detect(ctx) {
            return SeparateDolbyVisionLayers(base: pids.base, enhancement: pids.enhancement, carriage: .transportPID)
        }
        return detectTracks(ctx)
    }

    /// One HEVC track declaring the enhancement layer only, one declaring the base layer, the enhancement layer no
    /// larger than the base layer. Anything ambiguous (several candidates) or unlinked is left alone: a file with two
    /// unrelated HEVC video tracks is not a dual-layer source.
    static func detectTracks(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> SeparateDolbyVisionLayers? {
        guard let name = ctx.pointee.iformat?.pointee.name else { return nil }
        let formats = String(cString: name).split(separator: ",").map(String.init)
        guard formats.contains(where: { ["matroska", "webm", "mov", "mp4"].contains($0) }) else { return nil }
        var bases: [Int32] = [], enhancements: [Int32] = []
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO, par.pointee.codec_id == AV_CODEC_ID_HEVC,
                  let record = doviRecord(par) else { continue }
            guard record.dv_profile == 7 else { continue }
            if record.el_present_flag != 0 && record.bl_present_flag == 0 {
                enhancements.append(i)
            } else if record.bl_present_flag != 0 {
                bases.append(i)
            }
        }
        guard bases.count == 1, enhancements.count == 1,
              let b = ctx.pointee.streams[Int(bases[0])]?.pointee.codecpar,
              let e = ctx.pointee.streams[Int(enhancements[0])]?.pointee.codecpar,
              e.pointee.width > 0, e.pointee.height > 0,
              e.pointee.width <= b.pointee.width, e.pointee.height <= b.pointee.height else { return nil }
        return SeparateDolbyVisionLayers(base: bases[0], enhancement: enhancements[0], carriage: .track)
    }

    private static func doviRecord(_ par: UnsafeMutablePointer<AVCodecParameters>) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(par.pointee.nb_coded_side_data)
        guard count > 0, let side = par.pointee.coded_side_data else { return nil }
        for i in 0..<count where side[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let raw = side[i].data, side[i].size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { continue }
            return raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        }
        return nil
    }

    /// How a stream's packets frame their NAL units: by the configuration record when it is an hvcC, Annex-B
    /// otherwise (a transport stream, or an Annex-B CodecPrivate).
    static func framing(of stream: UnsafeMutablePointer<AVStream>) -> VideoNALFraming {
        guard let par = stream.pointee.codecpar else { return .annexB }
        if let size = NALUnitChain.lengthPrefixSize(
            codecID: par.pointee.codec_id, extradata: par.pointee.extradata, extradataSize: Int(par.pointee.extradata_size)) {
            return .lengthPrefixed(size: size)
        }
        return .annexB
    }

    /// Whether the joined unit (`DolbyVisionLayerUnits.compose`: four-byte lengths whatever the source's framing) can
    /// stand in for the base layer's packets: the base layer's own record must declare four-byte lengths, or the
    /// stream must be Annex-B (the join then builds the record).
    static func canJoin(baseFraming: VideoNALFraming) -> Bool {
        switch baseFraming {
        case .annexB: return true
        case .lengthPrefixed(let size): return size == 4
        }
    }

    /// Rewrites the base layer's Dolby Vision record to the one a single-track Profile 7 remux declares: both layers
    /// present, RPU present. The signal compatibility id and level a container declared are kept. Creates the record
    /// when there is none. Returns false if the allocation failed.
    @discardableResult
    static func declareSingleTrackProfile7(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let codecpar = stream.pointee.codecpar else { return false }
        let par = codecpar.pointee
        for i in 0..<Int(par.nb_coded_side_data) where par.coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let raw = par.coded_side_data[i].data,
                  par.coded_side_data[i].size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return false }
            raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_profile = 7
                rec.pointee.rpu_present_flag = 1
                rec.pointee.el_present_flag = 1
                rec.pointee.bl_present_flag = 1
                if rec.pointee.dv_bl_signal_compatibility_id == 0 { rec.pointee.dv_bl_signal_compatibility_id = 6 }
            }
            return true
        }
        return BluRayDolbyVisionLayers.declareProfile7(stream)
    }

    /// The VPS, SPS and PPS an enhancement track's configuration record carries (hvcC arrays, or an Annex-B blob),
    /// for the units whose own bytes do not repeat them.
    static func parameterSets(of stream: UnsafeMutablePointer<AVStream>) -> [[UInt8]] {
        guard let par = stream.pointee.codecpar, let ed = par.pointee.extradata, par.pointee.extradata_size > 0 else { return [] }
        let size = Int(par.pointee.extradata_size)
        let nals: [[UInt8]]
        if ed[0] == 1 {
            nals = parseHVCCParameterSets(ed, size)
        } else {
            nals = VideoConfigRecord.splitAnnexBNALs([UInt8](UnsafeBufferPointer(start: ed, count: size)))
        }
        return nals.filter { nal in
            guard let first = nal.first else { return false }
            return (32...34).contains(Int((first >> 1) & 0x3F))
        }
    }
}

/// Byte-level work on the access units of a split Dolby Vision source: the RPU of a unit, whether a unit starts a
/// decodable sequence, and the single-track unit the dual-layer decoder reads.
enum DolbyVisionLayerUnits {

    /// The unspec62 RPU NAL of an access unit in the Annex-B form `BluRayDolbyVisionLayers.rpu(inAnnexB:)` returns
    /// (a three-byte start code in front, trailing zeros trimmed), whatever the unit's framing; nil when it has none.
    static func rpu(in data: UnsafeRawBufferPointer, framing: VideoNALFraming) -> [UInt8]? {
        switch framing {
        case .annexB:
            return BluRayDolbyVisionLayers.rpu(inAnnexB: data)
        case .lengthPrefixed:
            guard let base = data.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var found: [UInt8]?
            A53SEIParser.forEachNAL(base, data.count, framing) { nal, len in
                guard found == nil, len > 2, (nal[0] >> 1) & 0x3F == 62 else { return }
                found = [0, 0, 1] + Array(UnsafeBufferPointer(start: nal, count: len))
            }
            return found
        }
    }

    /// Appends an Annex-B-form RPU (see `rpu(in:framing:)`) to a packet in the packet's own framing.
    static func append(_ annexBRPU: [UInt8], to packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming) -> Bool {
        switch framing {
        case .annexB:
            return BluRayDolbyVisionLayers.append(annexBRPU, to: packet)
        case .lengthPrefixed(let size):
            let nal = annexBRPU.dropFirst(3)
            var wire = [UInt8](repeating: 0, count: size)
            var n = nal.count
            for k in stride(from: size - 1, through: 0, by: -1) { wire[k] = UInt8(n & 0xFF); n >>= 8 }
            guard n == 0 else { return false }
            return BluRayDolbyVisionLayers.append(wire + nal, to: packet)
        }
    }

    /// Whether the unit holds an IRAP picture (a slice of NAL type 16 to 23): the only place a layer can start.
    static func isIRAP(_ data: UnsafeRawBufferPointer, framing: VideoNALFraming) -> Bool {
        guard let base = data.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
        var irap = false
        A53SEIParser.forEachNAL(base, data.count, framing) { nal, len in
            guard len > 1 else { return }
            let type = Int((nal[0] >> 1) & 0x3F)
            if (16...23).contains(type) { irap = true }
        }
        return irap
    }

    /// The single-track unit of one picture pair, length-prefixed with four-byte lengths (what the dual-layer decoder
    /// reads whatever the source's framing): the base layer's NALs, then every enhancement NAL wrapped in an unspec63
    /// NAL (the two-byte header `7E 01`), then the RPU last. The RPU is the enhancement unit's, or the base unit's
    /// own when the enhancement unit has none. `parameterSets` are the enhancement track's own (VPS, SPS, PPS); they
    /// go in, wrapped, ahead of the enhancement NALs when `injectParameterSets` is set and the unit carries none,
    /// because a track that keeps them in its configuration record only never repeats them in band.
    static func compose(
        base: UnsafeRawBufferPointer, baseFraming: VideoNALFraming,
        enhancement: UnsafeRawBufferPointer?, enhancementFraming: VideoNALFraming,
        parameterSets: [[UInt8]] = [], injectParameterSets: Bool = false
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(base.count + (enhancement?.count ?? 0) + 64)
        func put(_ bytes: UnsafeBufferPointer<UInt8>, prefix: [UInt8] = []) {
            let n = bytes.count + prefix.count
            out.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                                    UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            out.append(contentsOf: prefix)
            out.append(contentsOf: bytes)
        }
        var baseRPU: UnsafeBufferPointer<UInt8>?
        if let b = base.baseAddress?.assumingMemoryBound(to: UInt8.self) {
            A53SEIParser.forEachNAL(b, base.count, baseFraming) { nal, len in
                if (nal[0] >> 1) & 0x3F == 62 { baseRPU = UnsafeBufferPointer(start: nal, count: len); return }
                put(UnsafeBufferPointer(start: nal, count: len))
            }
        }
        var enhancementRPU: UnsafeBufferPointer<UInt8>?
        if let enhancement, let e = enhancement.baseAddress?.assumingMemoryBound(to: UInt8.self) {
            var carriesParameterSets = false
            A53SEIParser.forEachNAL(e, enhancement.count, enhancementFraming) { nal, len in
                let type = Int((nal[0] >> 1) & 0x3F)
                if type == 62 { enhancementRPU = UnsafeBufferPointer(start: nal, count: len); return }
                if (32...34).contains(type) { carriesParameterSets = true }
            }
            if injectParameterSets, !carriesParameterSets {
                for set in parameterSets { set.withUnsafeBufferPointer { put($0, prefix: [0x7E, 0x01]) } }
            }
            A53SEIParser.forEachNAL(e, enhancement.count, enhancementFraming) { nal, len in
                guard (nal[0] >> 1) & 0x3F != 62 else { return }
                put(UnsafeBufferPointer(start: nal, count: len), prefix: [0x7E, 0x01])
            }
        }
        if let rpu = enhancementRPU ?? baseRPU { put(rpu) }
        return out
    }
}
