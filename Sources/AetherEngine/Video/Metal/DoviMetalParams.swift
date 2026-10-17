// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation

/// How one reshaping piece is evaluated (`mapping_idc`).
enum DoviMapping: UInt32, Sendable {
    case polynomial = 0
    case mmr = 1
}

/// `nlq_method_idc`. Anything the composer cannot invert maps to ``none``,
/// which yields no residual rather than a wrong one.
enum DoviNlqMethod: UInt32, Sendable {
    case linear = 0
    case none = 0xFFFF_FFFF
}

/// Output quantisation mode.
enum DoviDither: UInt32, Sendable {
    case none = 0
    case bayer8x8 = 1
    /// Test only: planes hold the un-quantised 12-bit VDR code shifted left 4, not P010.
    case debugRawVDR = 2
    /// Undithered, but the VDR bits below the 10-bit code are kept in P010's unused low 6 bits,
    /// so a consumer that reads the full 16-bit word sees 12-bit (or finer) precision while one
    /// that reads the top 10 bits sees the truncated code. Not validated on a display path yet.
    case fullPrecision = 3
}

/// `DoviMetalParams.flags` bits.
struct DoviComposerFlags: OptionSet, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// `disable_residual_flag`, or the RPU declares `el_type == MEL`.
    static let disableResidual = DoviComposerFlags(rawValue: 0x1)
    /// The luma curve carries at least one MMR piece, so the luma kernel has to
    /// read the base-layer chroma planes as well.
    static let lumaMmr = DoviComposerFlags(rawValue: 0x2)
}

/// Piecewise reshaping curve for one component; mirrors
/// `struct DoviPolynomialParams` in `DoviShaderSource`.
///
/// `numPivots < 2` means identity passthrough, which is the fail-safe the parser
/// installs whenever a curve cannot be trusted.
struct DoviPolynomialParams: Sendable {
    static let maxPivots = 9
    static let maxPieces = 8
    /// Serialized size in bytes, asserted against the C struct by `_Static_assert`.
    /// num_pivots + pivots + method + order + coef + coef_shift.
    static let stride = 4 * (1 + maxPivots + maxPieces + maxPieces + maxPieces * 3 + maxPieces)

    var numPivots: UInt32 = 0
    var pivots: [UInt32] = Array(repeating: 0, count: DoviPolynomialParams.maxPivots)
    var method: [UInt32] = Array(repeating: 0, count: DoviPolynomialParams.maxPieces)
    var order: [UInt32] = Array(repeating: 0, count: DoviPolynomialParams.maxPieces)
    var coef: [[Int32]] = Array(repeating: [0, 0, 0], count: DoviPolynomialParams.maxPieces)
    var coefShift: [UInt32] = Array(repeating: 0, count: DoviPolynomialParams.maxPieces)

    init() {}

    /// Identity passthrough: the base layer reaches the output unreshaped.
    static var identity: DoviPolynomialParams { DoviPolynomialParams() }

    var isIdentity: Bool { numPivots < 2 }

    /// A pivot count the fixed-size arrays and the kernels cannot hold is a corrupt curve; it takes the
    /// same identity fail-safe as a curve the parser could not trust, instead of indexing past `pivots`.
    mutating func clampToCapacity() {
        if numPivots > UInt32(Self.maxPivots) { numPivots = 0 }
        for i in coefShift.indices where coefShift[i] > 31 { coefShift[i] = 31 }
        if pivots.count < Self.maxPivots { pivots += Array(repeating: 0, count: Self.maxPivots - pivots.count) }
    }

    /// True when any live piece is evaluated as MMR, which is what decides
    /// whether the kernel needs the cross-component inputs.
    var usesMmr: Bool {
        guard numPivots >= 2 else { return false }
        let pieces = min(Int(numPivots) - 1, Self.maxPieces)
        for p in 0..<pieces where p < method.count {
            if method[p] == DoviMapping.mmr.rawValue { return true }
        }
        return false
    }
}

/// Multiple-model regression coefficients, one set per reshaping piece; mirrors
/// `struct DoviMmrParams`.
///
/// Piece count, per-piece order and piece selection live in the matching
/// ``DoviPolynomialParams``; this block carries only the coefficients, as
/// `coef[piece][order * 7 + term]` over `[y, u, v, yu, yv, uv, yuv]`.
struct DoviMmrParams: Sendable {
    static let maxPieces = DoviPolynomialParams.maxPieces
    static let coefficientsPerPiece = 21
    static let stride = 4 * (maxPieces + maxPieces * coefficientsPerPiece + 1)

    var constant: [Int32] = Array(repeating: 0, count: DoviMmrParams.maxPieces)
    var coef: [[Int32]] = Array(
        repeating: Array(repeating: 0, count: DoviMmrParams.coefficientsPerPiece),
        count: DoviMmrParams.maxPieces
    )
    var coefShift: UInt32 = 0

    init() {}
}

/// Inverse non-linear quantisation for one component; mirrors
/// `struct DoviNlqParams`.
///
/// A zeroed value is the same neutral the C side gets from `memset`: method
/// ``DoviNlqMethod/linear`` with a zero slope, which produces no residual.
struct DoviNlqParams: Sendable {
    static let stride = 4 * 8

    var nlqMethod: DoviNlqMethod = .linear
    var nlqOffset: Int32 = 0
    var nlqScale: Int32 = 0
    var nlqThreshold: Int32 = 0
    var vdrInMax: Int32 = 0
    var nlqShift: UInt32 = 0
    /// Decoded (prefix-summed) `nlq_pred_pivot_value`. Carried for diagnostics;
    /// the linear inverse has a single segment and does not consult them.
    var nlqPivots: [UInt32] = [0, 1023]

    init() {}

    /// No residual at all, while preserving the shift and pivots already decoded
    /// so a probe can still report what the RPU said.
    static var disabled: DoviNlqParams {
        var nlq = DoviNlqParams()
        nlq.nlqMethod = .none
        return nlq
    }
}

/// Parameter block uploaded to the composition kernels; mirrors
/// `struct DoviMetalParams` in `DoviShaderSource`.
///
/// ``serialize()`` writes the fields in declaration order and asserts each
/// sub-block's size, and `dovi_layout_probe` reads sentinels back out of the
/// uploaded bytes on the GPU, so a field added on one side of the ABI cannot go
/// unnoticed on the other.
struct DoviMetalParams: Sendable {
    var blWidth: UInt32 = 3840
    var blHeight: UInt32 = 2160
    var elWidth: UInt32 = 1920
    var elHeight: UInt32 = 1080

    /// Informational: the output pool is always video-range 10-bit P010.
    var targetMode: UInt32 = 0
    var ditherMode: DoviDither = .bayer8x8
    var frameIndex: UInt32 = 0
    var flags: DoviComposerFlags = []

    var polyY = DoviPolynomialParams()
    var mmrY = DoviMmrParams()
    var nlqY = DoviNlqParams()

    var polyCb = DoviPolynomialParams()
    var mmrCb = DoviMmrParams()
    var nlqCb = DoviNlqParams()

    var polyCr = DoviPolynomialParams()
    var mmrCr = DoviMmrParams()
    var nlqCr = DoviNlqParams()

    var minPq: UInt32 = 0
    var maxPq: UInt32 = 3079 // ~1000 nits
    var avgPq: UInt32 = 1500

    /// `(1 << bl_bit_depth) - 1`; the normalisation divisor for curve inputs.
    var blMax: UInt32 = 1023
    /// `(1 << vdr_bit_depth) - 1`; the reconstruction clamp.
    var vdrMax: UInt32 = 4095
    /// `1 << (vdr_bit_depth - bl_bit_depth)`; residual and denormalisation scale.
    var vdrScale: UInt32 = 4

    init() {}

    /// Byte size of the serialized block, matching `sizeof(struct DoviMetalParams)`.
    static let serializedSize =
        4 * 8
        + 3 * (DoviPolynomialParams.stride + DoviMmrParams.stride + DoviNlqParams.stride)
        + 4 * 6

    /// Derives ``blMax``, ``vdrMax`` and ``vdrScale`` from the RPU's declared bit
    /// depths. Returns false, leaving the values untouched, for a combination the
    /// kernels cannot express.
    mutating func setBitDepths(bl: Int, vdr: Int) -> Bool {
        guard bl >= 8, bl <= 16, vdr >= bl, vdr <= 16 else { return false }
        blMax = UInt32((1 << bl) - 1)
        vdrMax = UInt32((1 << vdr) - 1)
        vdrScale = UInt32(1 << (vdr - bl))
        return true
    }

    /// Little-endian sequential writer to a raw buffer pointer. Appending in declaration order and
    /// checking each sub-block's length is what keeps the layout honest; writes directly into
    /// preallocated Metal buffers without intermediate Data or array allocations.
    private struct BufferWriter {
        let buffer: UnsafeMutableRawBufferPointer
        var offset: Int = 0

        init(buffer: UnsafeMutableRawBufferPointer) {
            precondition(buffer.count >= DoviMetalParams.serializedSize,
                         "Buffer too small for serialized DoviMetalParams")
            self.buffer = buffer
        }

        mutating func u32(_ value: UInt32) {
            let v = value.littleEndian
            buffer.storeBytes(of: v, toByteOffset: offset, as: UInt32.self)
            offset += 4
        }

        mutating func i32(_ value: Int32) {
            let v = value.littleEndian
            buffer.storeBytes(of: v, toByteOffset: offset, as: Int32.self)
            offset += 4
        }

        mutating func u32s(_ values: [UInt32], count: Int) {
            for i in 0..<count { u32(i < values.count ? values[i] : 0) }
        }

        mutating func i32s(_ values: [Int32], count: Int) {
            for i in 0..<count { i32(i < values.count ? values[i] : 0) }
        }

        mutating func append(_ poly: DoviPolynomialParams) {
            let start = offset
            u32(poly.numPivots)
            u32s(poly.pivots, count: DoviPolynomialParams.maxPivots)
            u32s(poly.method, count: DoviPolynomialParams.maxPieces)
            u32s(poly.order, count: DoviPolynomialParams.maxPieces)
            for p in 0..<DoviPolynomialParams.maxPieces {
                i32s(p < poly.coef.count ? poly.coef[p] : [], count: 3)
            }
            u32s(poly.coefShift, count: DoviPolynomialParams.maxPieces)
            precondition(offset - start == DoviPolynomialParams.stride,
                         "DoviPolynomialParams serialization is not stride bytes")
        }

        mutating func append(_ mmr: DoviMmrParams) {
            let start = offset
            i32s(mmr.constant, count: DoviMmrParams.maxPieces)
            for p in 0..<DoviMmrParams.maxPieces {
                i32s(p < mmr.coef.count ? mmr.coef[p] : [],
                     count: DoviMmrParams.coefficientsPerPiece)
            }
            u32(mmr.coefShift)
            precondition(offset - start == DoviMmrParams.stride,
                         "DoviMmrParams serialization is not stride bytes")
        }

        mutating func append(_ nlq: DoviNlqParams) {
            let start = offset
            u32(nlq.nlqMethod.rawValue)
            i32(nlq.nlqOffset)
            i32(nlq.nlqScale)
            i32(nlq.nlqThreshold)
            i32(nlq.vdrInMax)
            u32(nlq.nlqShift)
            u32(nlq.nlqPivots.count > 0 ? nlq.nlqPivots[0] : 0)
            u32(nlq.nlqPivots.count > 1 ? nlq.nlqPivots[1] : 0)
            precondition(offset - start == DoviNlqParams.stride,
                         "DoviNlqParams serialization is not stride bytes")
        }
    }

    /// Serializes directly into a preallocated raw buffer pointer without allocating Data (dolby-vision-fel.md §5.6).
    func serialize(into buffer: UnsafeMutableRawBufferPointer) {
        var w = BufferWriter(buffer: buffer)

        w.u32(blWidth)
        w.u32(blHeight)
        w.u32(elWidth)
        w.u32(elHeight)
        w.u32(targetMode)
        w.u32(ditherMode.rawValue)
        w.u32(frameIndex)
        w.u32(flags.rawValue)

        w.append(polyY)
        w.append(mmrY)
        w.append(nlqY)

        w.append(polyCb)
        w.append(mmrCb)
        w.append(nlqCb)

        w.append(polyCr)
        w.append(mmrCr)
        w.append(nlqCr)

        w.u32(minPq)
        w.u32(maxPq)
        w.u32(avgPq)
        w.u32(blMax)
        w.u32(vdrMax)
        w.u32(vdrScale)

        precondition(w.offset == Self.serializedSize,
                     "DoviMetalParams serialization is not serializedSize bytes")
    }

    /// Serializes to the exact C/Metal memory layout.
    func serialize() -> Data {
        var data = Data(count: Self.serializedSize)
        data.withUnsafeMutableBytes { raw in
            serialize(into: raw)
        }
        return data
    }
}
#endif
