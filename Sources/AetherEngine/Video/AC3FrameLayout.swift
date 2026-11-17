import Foundation

/// The header fields of an AC-3 or E-AC-3 packet that the fMP4 `dac3` / `dec3` box is built from:
/// sample rate, bitstream id, coding mode (`acmod`) and LFE, per substream. movenc writes that box once
/// per init segment from a parsed frame, so when these change mid-stream (a live channel with 2.0 ads and
/// a 5.1 programme on one PID) the producer needs a new init (`HLSSegmentProducer`).
struct AC3FrameLayout: Equatable, Sendable {

    struct Substream: Equatable, Sendable {
        /// E-AC-3 `strmtyp` (0 independent, 1 dependent, 2 AC-3 converted). 0 for AC-3.
        let streamType: Int
        let substreamID: Int
        /// `fscod`, plus `fscod2` when `fscod` is 3 (E-AC-3 reduced sample rates).
        let sampleRateCode: Int
        let bitstreamID: Int
        let audioCodingMode: Int
        let lfeOn: Bool
    }

    let substreams: [Substream]

    /// Main channels per `acmod` (ATSC A/52 table 5.8).
    private static let channelsPerCodingMode = [2, 1, 2, 3, 3, 4, 4, 5]

    /// "2.0", "5.1" and so on for the first independent substream, for the log.
    var channelLayoutLabel: String {
        guard let first = substreams.first else { return "unknown" }
        let main = Self.channelsPerCodingMode[first.audioCodingMode]
        return "\(main).\(first.lfeOn ? 1 : 0)" + (substreams.count > 1 ? " +\(substreams.count - 1) substream(s)" : "")
    }

    /// Nil for anything that does not start with an AC-3 / E-AC-3 sync frame.
    init?(packet bytes: [UInt8]) {
        guard bytes.count >= 8, bytes[0] == 0x0B, bytes[1] == 0x77 else { return nil }
        let bitstreamID = Int(bytes[5] >> 3)
        if bitstreamID <= 10 {
            guard let substream = Self.parseAC3(bytes) else { return nil }
            substreams = [substream]
            return
        }
        guard bitstreamID <= 16 else { return nil }
        var parsed: [Substream] = []
        var offset = 0
        while offset + 6 <= bytes.count, bytes[offset] == 0x0B, bytes[offset + 1] == 0x77 {
            guard let (substream, frameBytes) = Self.parseEAC3(bytes, at: offset) else { break }
            parsed.append(substream)
            offset += frameBytes
        }
        guard !parsed.isEmpty else { return nil }
        substreams = parsed
    }

    /// ATSC A/52 5.3.1 / 5.3.2: `syncinfo` then `bsi` up to `lfeon`.
    private static func parseAC3(_ bytes: [UInt8]) -> Substream? {
        var reader = BitReader(bytes: bytes, bitOffset: 32)
        guard let sampleRateCode = reader.read(2), sampleRateCode != 3,
              reader.skip(6),
              let bitstreamID = reader.read(5),
              reader.skip(3),
              let codingMode = reader.read(3) else { return nil }
        if codingMode & 1 != 0, codingMode != 1, !reader.skip(2) { return nil }
        if codingMode & 4 != 0, !reader.skip(2) { return nil }
        if codingMode == 2, !reader.skip(2) { return nil }
        guard let lfe = reader.read(1) else { return nil }
        return Substream(streamType: 0, substreamID: 0, sampleRateCode: sampleRateCode,
                         bitstreamID: bitstreamID, audioCodingMode: codingMode, lfeOn: lfe == 1)
    }

    /// ATSC A/52 E.1.2.1 / E.1.2.2: `syncinfo` then `bsi` up to `bsid`. Returns the frame's size in bytes
    /// so the caller can walk the dependent substreams that follow in the same packet.
    private static func parseEAC3(_ bytes: [UInt8], at offset: Int) -> (Substream, Int)? {
        var reader = BitReader(bytes: bytes, bitOffset: (offset + 2) * 8)
        guard let streamType = reader.read(2), streamType != 3,
              let substreamID = reader.read(3),
              let frameSizeWords = reader.read(11),
              let sampleRateCode = reader.read(2),
              let sampleRateCode2OrBlocks = reader.read(2),
              let codingMode = reader.read(3),
              let lfe = reader.read(1),
              let bitstreamID = reader.read(5),
              (11...16).contains(bitstreamID) else { return nil }
        let rate = sampleRateCode == 3 ? 3 << 2 | sampleRateCode2OrBlocks : sampleRateCode
        let substream = Substream(streamType: streamType, substreamID: substreamID, sampleRateCode: rate,
                                  bitstreamID: bitstreamID, audioCodingMode: codingMode, lfeOn: lfe == 1)
        return (substream, (frameSizeWords + 1) * 2)
    }

    private struct BitReader {
        let bytes: [UInt8]
        var bitOffset: Int

        mutating func read(_ count: Int) -> Int? {
            guard bitOffset + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let bit = (bytes[bitOffset >> 3] >> (7 - UInt8(bitOffset & 7))) & 1
                value = value << 1 | Int(bit)
                bitOffset += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool {
            read(count) != nil
        }
    }
}

/// Latches an audio layout change only after the new layout held for several frames in a row. A lost
/// TS packet or a bit error in one frame's header reads as a layout change for that frame alone, and
/// answering it costs a discontinuity and a versioned init for nothing (audit SEG-202).
struct AudioLayoutChangeGate: Sendable {
    /// 3 frames of AC-3 are 96 ms: long enough to outlast damage, short enough for a real switch.
    static let framesToConfirm = 3

    private var candidate: AC3FrameLayout?
    private var candidateFrames = 0

    /// True when `layout` has differed from `current` for `framesToConfirm` consecutive frames.
    mutating func confirmsChange(_ layout: AC3FrameLayout, from current: AC3FrameLayout) -> Bool {
        guard layout != current else {
            candidate = nil
            candidateFrames = 0
            return false
        }
        if layout == candidate {
            candidateFrames += 1
        } else {
            candidate = layout
            candidateFrames = 1
        }
        guard candidateFrames >= Self.framesToConfirm else { return false }
        candidate = nil
        candidateFrames = 0
        return true
    }

    mutating func reset() {
        candidate = nil
        candidateFrames = 0
    }
}
