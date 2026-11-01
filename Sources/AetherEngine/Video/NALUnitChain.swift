import AetherLibavcodec
import AetherLibavutil
import Foundation

/// Audit BIT-104: whether a video sample of the session's track has walked exactly as a
/// length-prefixed chain (BIT-1). Held by the session rather than by one muxer, because every seek,
/// restart and reload builds a fresh muxer, and a muxer's first sample is exactly the one a restart
/// lands on.
final class NALFramingLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed: Bool

    init(confirmed: Bool = false) { self.confirmed = confirmed }

    var isConfirmed: Bool { lock.withLock { confirmed } }

    func confirm() { lock.withLock { confirmed = true } }
}

/// The length-prefixed NAL chain (avcC / hvcC framing) as Apple's fMP4 parser walks it.
///
/// A sample in an mp4 video track is a run of NAL units, each introduced by a big-endian length of
/// the width the configuration record declares. The parser walks that run by addition, so a length
/// that reaches past the end of the sample leaves it with no way to continue: VideoToolbox answers
/// the whole segment with `CoreMediaErrorDomain -19602` and the session is over.
///
/// Damaged sources carry such a sample (AE#561: a Blu-ray remux whose sixth length field declared
/// 384137139 bytes with 350873 left in the packet). libavcodec logs `Invalid NAL unit size` and
/// skips the frame, which is why such files play in mpv, and MKVToolNix drops the unparsable tail on
/// remux, which is why remuxing them fixes them. This does the same thing one step before the write.
enum NALUnitChain {

    /// Length-prefix width declared by an avcC (H.264) or hvcC (HEVC) configuration record.
    ///
    /// Nil for any other codec, for Annex B extradata (which starts with a start code, not a
    /// configuration version), and for a record too short to hold the field: those payloads are not
    /// length-prefixed chains and must not be walked as one.
    static func lengthPrefixSize(
        codecID: AVCodecID,
        extradata: UnsafePointer<UInt8>?,
        extradataSize: Int
    ) -> Int? {
        guard let extradata, extradataSize > 0, extradata[0] == 1 else { return nil }
        switch codecID {
        case AV_CODEC_ID_HEVC:
            guard extradataSize >= 23 else { return nil }
            return Int(extradata[21] & 0x03) + 1
        case AV_CODEC_ID_H264:
            guard extradataSize >= 5 else { return nil }
            return Int(extradata[4] & 0x03) + 1
        default:
            return nil
        }
    }

    /// Byte length of the leading run of complete NAL units, or nil when the payload already ends on
    /// one and nothing needs to change.
    ///
    /// Zero means not one NAL unit in the payload is complete, which leaves the caller nothing to
    /// write.
    ///
    /// `framingConfirmed` says an earlier sample of this track already walked exactly as a
    /// length-prefixed chain. Audit BIT-1: with a 4-byte prefix, every first NAL of 256 to 511 bytes
    /// starts `00 00 01 xx`, so the head test alone let exactly those damaged samples through. Once
    /// the track is known to be length-prefixed that head is a length, not a start code.
    static func completeRunLength(
        _ bytes: UnsafeRawBufferPointer, lengthPrefixSize: Int, framingConfirmed: Bool = false
    ) -> Int? {
        let count = bytes.count
        guard (1...4).contains(lengthPrefixSize), count >= lengthPrefixSize else { return nil }
        // An Annex B payload is not this framing at all, and reading its start code as a length would
        // cut every frame of a healthy stream down to nothing.
        let threeByteHeadIsLength = framingConfirmed && lengthPrefixSize == 4
        if !threeByteHeadIsLength, count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return nil }
        if count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return nil }

        var offset = 0
        while offset + lengthPrefixSize <= count {
            var length = 0
            for i in 0..<lengthPrefixSize {
                length = (length << 8) | Int(bytes[offset + i])
            }
            guard length > 0, offset + lengthPrefixSize + length <= count else { break }
            offset += lengthPrefixSize + length
        }
        return offset == count ? nil : offset
    }

    /// Whether the payload walks as a length-prefixed chain that ends exactly on its last byte. Annex B
    /// data cannot do that by accident, since it would have to encode its own byte offsets.
    static func walksExactly(_ bytes: UnsafeRawBufferPointer, lengthPrefixSize: Int) -> Bool {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
        return VideoConfigRecord.walksAsLengthPrefixed(base, size: bytes.count, lengthSize: lengthPrefixSize)
    }

    /// HEVC's NAL header is two bytes, even for EOS/EOB. A one-byte EOS from a
    /// truncated transport-stream tail can have a perfectly valid length prefix,
    /// so the overrun guard above cannot catch it. Apple's parser refuses the
    /// entire HLS segment, while libavcodec ignores the damaged delimiter.
    /// Return only the malformed units, preserving valid pictures and RPUs after
    /// them. Never treat an unconfirmed Annex-B start code as a length of one.
    static func shortHEVCHeaderRanges(
        _ bytes: UnsafeRawBufferPointer, lengthPrefixSize: Int, framingConfirmed: Bool
    ) -> [Range<Int>] {
        guard (1...4).contains(lengthPrefixSize), bytes.count >= lengthPrefixSize else { return [] }
        if !framingConfirmed, bytes.count >= 3, bytes[0] == 0, bytes[1] == 0,
            bytes[2] == 1 || (bytes.count >= 4 && bytes[2] == 0 && bytes[3] == 1)
        {
            return []
        }
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset + lengthPrefixSize <= bytes.count {
            var length = 0
            for index in 0..<lengthPrefixSize { length = (length << 8) | Int(bytes[offset + index]) }
            let payload = offset + lengthPrefixSize
            guard length > 0, length <= bytes.count - payload else { return [] }
            let end = payload + length
            if length < 2 { ranges.append(offset..<end) }
            offset = end
        }
        return offset == bytes.count ? ranges : []
    }
}
