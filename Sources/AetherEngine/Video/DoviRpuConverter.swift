import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// In-place DV P7 -> P8.1 rewrite: drops unspec63 EL NALs, rewrites unspec62 RPU via libdovi mode 2. AVCC layout (4-byte BE length prefix); libdovi handles emulation-prevention bytes internally.
public enum DoviRpuConverter {

    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU
    private static let nalTypeEL: UInt8  = 63   // unspec63: enhancement layer
    private static let lengthPrefixSize = 4

    /// Both framings this rewrite can emit use a 4-byte prefix, so the packet keeps its layout maths.
    /// A 1/2/3-byte length prefix would need the hvcC's `lengthSizeMinusOne` to agree with whatever we
    /// wrote; rather than write a framing the sample entry does not declare, leave the packet alone.
    private static func canRebuild(_ framing: VideoNALFraming) -> Bool {
        switch framing {
        case .annexB: return true
        case .lengthPrefixed(let size): return size == lengthPrefixSize
        }
    }

    struct DualLayerPacketResult: @unchecked Sendable {
        let elPacket: UnsafeMutablePointer<AVPacket>?
        let rpuData: [UInt8]?
        /// The Profile 8.1 RPU libdovi produced from `rpuData`, as a complete unspec62 NAL
        /// (2-byte HEVC NAL header included). On the remux route this is what goes back into
        /// the packet; on the FEL compose route it is the per-frame display metadata payload
        /// (L1 statistics, L2 trims, L5/L8/L9/L11), which `DoviDisplayMetadata` attaches to the
        /// composed pixel buffer. Nil when there was no RPU or the conversion failed.
        let convertedRpu: [UInt8]?
        #if DualLayerDolbyVision
        let rpuParams: DoviMetalParams?
        #endif
        let isFEL: Bool
        let isMEL: Bool
        let success: Bool
        /// `use_prev_vdr_rpu_flag`: the RPU carries no mapping and means "keep the previous one".
        let usesPreviousMapping: Bool
        /// This RPU's own `disable_residual_flag`. The header is read even when no mapping follows, so
        /// a `use_prev_vdr_rpu_flag` frame can still say whether its residual applies.
        let disableResidual: Bool

        #if DualLayerDolbyVision
        init(elPacket: UnsafeMutablePointer<AVPacket>?, rpuData: [UInt8]?, convertedRpu: [UInt8]? = nil, rpuParams: DoviMetalParams? = nil, isFEL: Bool, isMEL: Bool = false, success: Bool, usesPreviousMapping: Bool = false, disableResidual: Bool = false) {
            self.rpuParams = rpuParams
            self.elPacket = elPacket
            self.rpuData = rpuData
            self.convertedRpu = convertedRpu
            self.isFEL = isFEL
            self.isMEL = isMEL
            self.success = success
            self.usesPreviousMapping = usesPreviousMapping
            self.disableResidual = disableResidual
        }
        #else
        init(elPacket: UnsafeMutablePointer<AVPacket>?, rpuData: [UInt8]?, convertedRpu: [UInt8]? = nil, isFEL: Bool, isMEL: Bool = false, success: Bool, usesPreviousMapping: Bool = false, disableResidual: Bool = false) {
            self.elPacket = elPacket
            self.rpuData = rpuData
            self.convertedRpu = convertedRpu
            self.isFEL = isFEL
            self.isMEL = isMEL
            self.success = success
            self.usesPreviousMapping = usesPreviousMapping
            self.disableResidual = disableResidual
        }
        #endif
    }

    /// Stream classification from one RPU (dolby-vision-fel.md §5.2, invariant I9): a property of the
    /// encode, decided once. Only `el_type` feeds it — a per-frame `disable_residual_flag`
    /// rides to the kernels in `DoviMetalParams.flags` (`.disableResidual`) and never
    /// changes the classification.
    enum StreamKind: Sendable, Equatable {
        case undetermined
        case fel
        case mel
    }

    /// Classifies one `separateDualLayers` result. Pure over the result so the decoder's
    /// one-shot latch and routing can share it.
    static func classifyStream(_ result: DualLayerPacketResult) -> StreamKind {
        if result.isMEL { return .mel }
        if result.isFEL { return .fel }
        return .undetermined
    }

    /// A piece of the rebuilt packet: points into the source packet (a NAL passed through) or into a
    /// libdovi buffer (a rewritten RPU). Audit PERF-111: what survives is described, not copied, and the
    /// one rebuild is the only copy.
    private struct Piece {
        let base: UnsafePointer<UInt8>
        let count: Int
    }

    /// Writes `pieces` into a new padded buffer, each behind its start code or 4-byte length.
    /// nil on an allocation failure. `total` is what `Self.framedSize` returned for the same pieces.
    private static func buildPacketBuffer(
        _ pieces: [Piece], total: Int, emitsStartCodes: Bool
    ) -> UnsafeMutablePointer<AVBufferRef>? {
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let ref = av_buffer_alloc(total + pad) else { return nil }
        guard let dst = ref.pointee.data else {
            var r: UnsafeMutablePointer<AVBufferRef>? = ref
            av_buffer_unref(&r)
            return nil
        }
        var w = 0
        for piece in pieces {
            let n = piece.count
            if emitsStartCodes {
                dst[w + 0] = 0; dst[w + 1] = 0; dst[w + 2] = 0; dst[w + 3] = 1
            } else {
                dst[w + 0] = UInt8((n >> 24) & 0xFF)
                dst[w + 1] = UInt8((n >> 16) & 0xFF)
                dst[w + 2] = UInt8((n >> 8) & 0xFF)
                dst[w + 3] = UInt8(n & 0xFF)
            }
            w += lengthPrefixSize
            if n > 0 {
                memcpy(dst + w, piece.base, n)
            }
            w += n
        }
        memset(dst + total, 0, pad)   // decoders read past size
        return ref
    }

    private static func framedSize(_ pieces: [Piece]) -> Int {
        pieces.reduce(0) { $0 + lengthPrefixSize + $1.count }
    }

    /// The Profile 8.1 form of a parsed RPU (`dovi_convert_rpu_with_mode`, mode 2) written back as an
    /// unspec62 NAL unit, or nil when libdovi refuses either step. The caller frees the result with
    /// `dovi_data_free`. This is the pair of calls the library can abort in, so everything that feeds it
    /// goes through `DoviRpuGuard.parse` first, and the tests drive it through this one entry point.
    ///
    /// Mode 2 and not 5, on the dual-layer route too: by the time a frame reaches the display layer the
    /// Metal composer has already applied the RPU's luma/chroma reshaping and added the residual, so the
    /// picture is finished. Mode 2 sets both curves to no-op (and drops the EL/NLQ part) while keeping
    /// L1/L2 and the rest of the display metadata; an RPU that kept the mapping would make the display
    /// side reshape a second time. `DoviComposedFrameRpuTests` pins this on the RPU attached to composed frames.
    static func convertedUnspec62(_ rpu: OpaquePointer) -> UnsafePointer<DoviData>? {
        guard dovi_convert_rpu_with_mode(rpu, 2) == 0 else { return nil }
        return dovi_write_unspec62_nalu(rpu)
    }

    /// Splits a Profile 7 packet into its layers in one walk.
    ///
    /// The base-layer packet is rewritten in place to hold the base layer and the Profile 8.1 RPU (mode 2),
    /// unless `useCustomBlockSource` leaves it untouched for a decoder that skips the unspec NALs itself.
    /// With `extractEL` the enhancement layer comes back as a separate packet of its own (the 2-byte
    /// unspec63 header stripped), stamped like the source; with `extractParams` the RPU is also parsed into
    /// the composition parameters. This is the walk `convertPacketToProfile81` runs with both off.
    ///
    /// A libdovi failure drops the offending RPU, reports `success == false` and leaves the rest of the
    /// packet usable (#135). The RPU is parsed through `DoviRpuGuard`, which refuses the CRC-valid inputs
    /// that make libdovi abort.
    static func separateDualLayers(
        _ packet: UnsafeMutablePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4),
        extractEL: Bool = true,
        useCustomBlockSource: Bool = false,
        extractParams: Bool = true
    ) -> DualLayerPacketResult {
        let untouched = DualLayerPacketResult(elPacket: nil, rpuData: nil, isFEL: false, success: true)
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return untouched }
        guard Self.canRebuild(framing) else { return untouched }
        let size = Int(packet.pointee.size)

        // The libdovi buffers a piece points into live until this function returns.
        var pieces: [Piece] = []
        pieces.reserveCapacity(16)
        var elPieces: [Piece] = []
        var rewritten: [UnsafePointer<DoviData>] = []
        defer { for buffer in rewritten { dovi_data_free(buffer) } }
        let keepRpuBytes = extractEL || extractParams
        var rawRpuBytes: [UInt8]?
        var convertedRpuBytes: [UInt8]?
        #if DualLayerDolbyVision
        var rpuParams: DoviMetalParams?
        #endif
        var converted = false
        var isFEL = false
        var isMEL = false
        var hadEL = false
        var degraded = false
        var usesPrevious = false
        var disableResidual = false

        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            // HEVC NAL type: bits 1..6 of byte 0.
            let nalType = (nal[0] >> 1) & 0x3F

            switch nalType {
            case nalTypeRPU:
                // Everything this RPU contributes is collected in locals and committed together once it has
                // converted, so a packet with several RPUs never mixes bytes from one with parameters or
                // a conversion from another: the outputs are those of the last RPU that fully succeeded.
                let thisRaw: [UInt8]? = keepRpuBytes ? [UInt8](UnsafeBufferPointer(start: nal, count: len)) : nil
                // Any libdovi failure drops the RPU (degraded) instead of muxing a stale P7 RPU
                // inside a container already declared 8.1 (mixed-profile hazard, #135).
                guard let rpu = DoviRpuGuard.parse(nal, len) else {
                    degraded = true
                    return
                }
                defer { dovi_rpu_free(rpu) }
                #if DualLayerDolbyVision
                let thisParams: DoviMetalParams? = extractParams ? DoviFelComposer.parseRpuParameters(rpu: rpu) : nil
                #endif
                var thisPrevious = false, thisDisableResidual = false, thisFEL = false, thisMEL = false
                // Only the dual-layer outputs read the header; the P8.1 rewrite drops what it yields.
                if keepRpuBytes, let hdr = dovi_rpu_get_header(rpu) {
                    if hdr.pointee.use_prev_vdr_rpu_flag { thisPrevious = true }
                    thisDisableResidual = hdr.pointee.disable_residual_flag
                    if let elTypePtr = hdr.pointee.el_type {
                        switch String(cString: elTypePtr) {
                        case "FEL": thisFEL = true
                        case "MEL": thisMEL = true
                        default: break
                        }
                    }
                    // `disable_residual_flag` is per-RPU, not per-stream: it reaches the kernels as
                    // `DoviComposerFlags.disableResidual` (set by `parseRpuParameters` above) and must
                    // not flip the stream classification.
                    dovi_rpu_free_header(hdr)
                }
                guard let out = Self.convertedUnspec62(rpu) else {
                    degraded = true
                    return
                }
                guard let outData = out.pointee.data, out.pointee.len > 0 else {
                    dovi_data_free(out)
                    degraded = true
                    return
                }
                rewritten.append(out)
                if !useCustomBlockSource {
                    pieces.append(Piece(base: outData, count: out.pointee.len))
                }
                converted = true

                rawRpuBytes = thisRaw
                convertedRpuBytes = keepRpuBytes ? [UInt8](UnsafeBufferPointer(start: outData, count: out.pointee.len)) : nil
                #if DualLayerDolbyVision
                rpuParams = thisParams
                #endif
                usesPrevious = thisPrevious
                disableResidual = thisDisableResidual
                isFEL = thisFEL
                isMEL = thisMEL

            case nalTypeEL:
                hadEL = true
                // Strip the 2-byte unspec63 NAL header (0x7E, 0x01) to reveal the raw HEVC NAL.
                if extractEL && len > 2 {
                    elPieces.append(Piece(base: nal + 2, count: len - 2))
                }

            default:
                if !useCustomBlockSource {
                    pieces.append(Piece(base: nal, count: len))
                }
            }
        }

        var allocationFailed = false

        // The EL packet is built BEFORE the base layer is rebuilt: its pieces point into the original buffer.
        var producedElPacket: UnsafeMutablePointer<AVPacket>?
        let elTotal = framedSize(elPieces)
        if extractEL, elTotal > 0 {
            var elPktOpt = trackedPacketAlloc()
            if let elPkt = elPktOpt,
               let elRef = buildPacketBuffer(elPieces, total: elTotal, emitsStartCodes: framing == .annexB) {
                elPkt.pointee.pts = packet.pointee.pts
                elPkt.pointee.dts = packet.pointee.dts
                elPkt.pointee.duration = packet.pointee.duration
                elPkt.pointee.flags = packet.pointee.flags
                elPkt.pointee.stream_index = packet.pointee.stream_index
                elPkt.pointee.buf = elRef
                elPkt.pointee.data = elRef.pointee.data
                elPkt.pointee.size = Int32(elTotal)
                producedElPacket = elPkt
            } else {
                // The packet shell allocated but its buffer did not: free the shell.
                if elPktOpt != nil { trackedPacketFree(&elPktOpt) }
                allocationFailed = true
            }
        }

        // Rebuild the base layer (not with a custom block source: the FEL decoder needs the original
        // packet untouched so VT can skip unspec62/63 NALs via the base-layer format description).
        if (converted || hadEL || degraded), !useCustomBlockSource {
            let total = framedSize(pieces)
            // Degenerate: all NALs were RPU/EL. Leave the packet untouched rather than emit a zero-length video packet.
            if total > 0 {
                if let newRef = buildPacketBuffer(pieces, total: total, emitsStartCodes: framing == .annexB) {
                    av_buffer_unref(&packet.pointee.buf)
                    packet.pointee.buf = newRef
                    packet.pointee.data = newRef.pointee.data
                    packet.pointee.size = Int32(total)
                } else {
                    allocationFailed = true
                }
            }
        }

        // A dropped-RPU degrade still produces a valid HDR10 packet, but reports failure so callers
        // can log it and the probe can flag the source for dovi_tool inspection.
        #if DualLayerDolbyVision
        return DualLayerPacketResult(
            elPacket: producedElPacket,
            rpuData: rawRpuBytes,
            convertedRpu: convertedRpuBytes,
            rpuParams: rpuParams,
            isFEL: isFEL && !isMEL,
            isMEL: isMEL,
            success: !degraded && !allocationFailed,
            usesPreviousMapping: usesPrevious,
            disableResidual: disableResidual
        )
        #else
        return DualLayerPacketResult(
            elPacket: producedElPacket,
            rpuData: rawRpuBytes,
            convertedRpu: convertedRpuBytes,
            isFEL: isFEL && !isMEL,
            isMEL: isMEL,
            success: !degraded && !allocationFailed,
            usesPreviousMapping: usesPrevious,
            disableResidual: disableResidual
        )
        #endif
    }

    /// Returns `false` when a libdovi conversion fails (or on an internal allocation failure).
    /// On a libdovi failure the offending RPU (and EL) are dropped so the frame degrades to the
    /// clean HDR10 base, rather than shipping a P7 RPU inside a container already declared 8.1
    /// (mixed-profile hazard, #135). Packets with no RPU/EL are left untouched and return `true`.
    ///
    /// `framing` must be the framing of THIS packet, and the rewritten packet is emitted in the same
    /// one: the mp4 muxer decides whether to convert samples from the extradata, so a packet that
    /// changes framing under it is a second defect (#365). An Annex-B packet walked as length-
    /// prefixed reads `00 00 01 40` as a 320-byte NAL and finds no RPU at all, which is how a P7
    /// source shipped its RPU and EL untouched inside a container already rewritten to 8.1.
    ///
    /// This is `separateDualLayers` with the enhancement layer dropped and no composition parameters.
    public static func convertPacketToProfile81(
        _ packet: UnsafeMutablePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> Bool {
        separateDualLayers(packet, framing: framing, extractEL: false, extractParams: false).success
    }

    /// Enhancement-layer type ("FEL" or "MEL") of the first unspec62 RPU in a P7 packet, or nil if
    /// there is no RPU, the RPU is unparseable, or the source is not profile 7. One-shot diagnostic:
    /// a FEL source loses highlight/detail refinement in the P8.1 conversion (the EL is discarded),
    /// so callers can explain why a FEL disc looks flatter than on a native P7 player.
    public static func enhancementLayerType(
        _ packet: UnsafePointer<AVPacket>,
        framing: VideoNALFraming = .lengthPrefixed(size: 4)
    ) -> String? {
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return nil }
        let size = Int(packet.pointee.size)

        var result: String?
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            guard result == nil, (nal[0] >> 1) & 0x3F == nalTypeRPU else { return }
            // Behind the CRC and panic-path checks: libdovi aborts the process on some malformed RPUs.
            guard let rpu = DoviRpuGuard.parse(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            guard let hdr = dovi_rpu_get_header(rpu) else { return }
            defer { dovi_rpu_free_header(hdr) }
            guard let el = hdr.pointee.el_type else { return }
            result = String(cString: el)
        }
        return result
    }
}
