import Foundation

/// Pump-local evidence that an AVC access unit no longer matches the sample description.
/// Merely repeating SPS/PPS, or announcing an unused set, is not a decoder failure, and neither is a
/// set that differs only where the native decoder takes the in-band value: a new PPS, VUI or level
/// (#785 follow-up, see `H264SPS.decoderSignature`).
/// No frames are decoded and only parameter sets / short slice headers are copied.
struct H264ConfigurationTracker {
    struct Mismatch: Sendable, Equatable {
        let width: Int
        let height: Int
        let spsID: Int
        let ppsID: Int
        var summary: String { "H264 active SPS/PPS differs from native init: \(width)x\(height), SPS=\(spsID), PPS=\(ppsID)" }
    }

    private let baselineSignatures: Set<[UInt8]>
    private var sps: [Int: [UInt8]]
    private var pps: [Int: [UInt8]]

    init?(avcC: [UInt8]) {
        guard avcC.count >= 7, avcC[0] == 1, [0, 1, 3].contains(avcC[4] & 3) else { return nil }
        var cursor = 6
        var sequences: [Int: [UInt8]] = [:], pictures: [Int: [UInt8]] = [:]
        func readSet() -> [UInt8]? {
            guard cursor + 2 <= avcC.count else { return nil }
            let size = Int(avcC[cursor]) * 256 + Int(avcC[cursor + 1]); cursor += 2
            guard size > 0, size <= avcC.count - cursor else { return nil }
            defer { cursor += size }
            return Array(avcC[cursor..<(cursor + size)])
        }
        for _ in 0..<Int(avcC[5] & 31) {
            guard let nal = readSet(), let id = Self.sequenceID(nal),
                  Self.dimensions(nal) != nil, sequences[id] == nil else { return nil }
            sequences[id] = nal
        }
        guard cursor < avcC.count else { return nil }
        let count = Int(avcC[cursor]); cursor += 1
        for _ in 0..<count {
            guard let nal = readSet(), let ids = Self.pictureIDs(nal),
                  sequences[ids.sps] != nil, pictures[ids.pps] == nil else { return nil }
            pictures[ids.pps] = nal
        }
        guard !sequences.isEmpty, !pictures.isEmpty else { return nil }
        baselineSignatures = Set(sequences.values.compactMap(H264SPS.decoderSignature(fromNAL:)))
        sps = sequences; pps = pictures
    }

    /// All length fields must be valid before any observation is committed. In particular a
    /// truncated packet cannot poison the state used to judge the next IDR.
    mutating func observe(_ bytes: UnsafeBufferPointer<UInt8>, lengthSize: Int) -> Mismatch? {
        guard [1, 2, 4].contains(lengthSize) else { return nil }
        var cursor = 0, ranges: [Range<Int>] = []
        while cursor < bytes.count {
            guard bytes.count - cursor >= lengthSize, ranges.count < 4096 else { return nil }
            var size = 0
            for i in 0..<lengthSize { size = (size << 8) | Int(bytes[cursor + i]) }
            cursor += lengthSize
            guard size > 0, size <= bytes.count - cursor, bytes[cursor] & 0x80 == 0 else { return nil }
            ranges.append(cursor..<(cursor + size)); cursor += size
        }
        var sequences = sps, pictures = pps
        var mismatch: Mismatch?
        for range in ranges {
            switch bytes[range.lowerBound] & 31 {
            case 7:
                guard range.count <= 65535 else { return nil }
                let nal = Array(bytes[range])
                guard let id = Self.sequenceID(nal), Self.dimensions(nal) != nil else { return nil }
                sequences[id] = nal
            case 8:
                guard range.count <= 65535 else { return nil }
                let nal = Array(bytes[range])
                guard let ids = Self.pictureIDs(nal) else { return nil }
                pictures[ids.pps] = nal
            case 5:
                // Read in NAL order: sets announced after a slice do not describe that slice.
                let prefix = Array(bytes[range.lowerBound..<min(range.upperBound, range.lowerBound + 33)])
                guard let id = Self.slicePPS(prefix), let picture = pictures[id],
                      let ids = Self.pictureIDs(picture), let sequence = sequences[ids.sps],
                      let size = Self.dimensions(sequence),
                      let signature = H264SPS.decoderSignature(fromNAL: sequence) else { continue }
                if !baselineSignatures.contains(signature) {
                    mismatch = Mismatch(width: size.width, height: size.height, spsID: ids.sps, ppsID: id)
                }
            default: break
            }
        }
        sps = sequences; pps = pictures
        return mismatch
    }

    private static func sequenceID(_ nal: [UInt8]) -> Int? {
        guard nal.count >= 5, nal[0] & 0x9f == 7 else { return nil }
        var r = H264SPS.BitReader(H264SPS.unescape(Array(nal.dropFirst())))
        guard r.u(24) != nil, let id = r.ue(), id < 32 else { return nil }
        return id
    }
    private static func pictureIDs(_ nal: [UInt8]) -> (pps: Int, sps: Int)? {
        guard nal.count >= 2, nal[0] & 0x9f == 8 else { return nil }
        var r = H264SPS.BitReader(H264SPS.unescape(Array(nal.dropFirst())))
        guard let p = r.ue(), p < 256, let s = r.ue(), s < 32 else { return nil }
        return (p, s)
    }
    private static func slicePPS(_ nal: [UInt8]) -> Int? {
        guard nal.count >= 2, nal[0] & 0x9f == 5, nal[0] & 0x60 != 0 else { return nil }
        var r = H264SPS.BitReader(H264SPS.unescape(Array(nal.dropFirst())))
        guard r.ue() != nil, let type = r.ue(), type <= 9, type % 5 == 2,
              let p = r.ue(), p < 256 else { return nil }
        return p
    }
    private static func dimensions(_ nal: [UInt8]) -> (width: Int, height: Int)? {
        return H264SPS.dimensions(fromNAL: nal)
    }
}
