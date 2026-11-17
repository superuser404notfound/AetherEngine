import Foundation

/// The one Annex-B NAL scanner. Every walker in the engine goes through it so they agree on the edge cases
/// (BIT-R201): 3-byte and 4-byte start codes alike, bytes before the first start code skipped, zero bytes in
/// front of the next start code (or at the end) trimmed off the NAL, empty NALs dropped. That is what
/// `ff_nal_parse_units` does.
enum AnnexB {
    /// Calls `body` with the payload range of each NAL, in order. Allocates nothing.
    static func forEachNALRange(_ base: UnsafePointer<UInt8>, count n: Int, _ body: (Range<Int>) -> Void) {
        guard n >= 4 else { return }
        var pending = -1
        func flush(upTo next: Int) {
            guard pending >= 0 else { return }
            var end = next
            while end > pending, base[end - 1] == 0 { end -= 1 }
            if end > pending { body(pending..<end) }
        }
        var i = 0
        while i + 2 < n {
            // The third byte of a start code is 1 and the two before it are 0, so any byte above 1 at
            // i + 2 rules out a start code beginning at i, i + 1 or i + 2.
            if base[i + 2] > 1 { i += 3; continue }
            if base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
                flush(upTo: i)
                pending = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        flush(upTo: n)
    }

    /// The NAL payload ranges of an Annex-B buffer. Empty when the buffer holds no start code.
    static func nalRanges(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var ranges: [Range<Int>] = []
        forEachNALRange(base, count: bytes.count) { ranges.append($0) }
        return ranges
    }

    static func nalRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        bytes.withUnsafeBytes { nalRanges($0) }
    }
}
