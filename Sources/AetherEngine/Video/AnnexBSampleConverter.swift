import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Rewrites an Annex-B video sample to 4-byte length-prefixed NALs, keeping every NAL.
///
/// movenc does this conversion itself whenever the extradata is Annex B, but for an `hvc1` sample
/// entry it runs `ff_hevc_annexb2mp4` with `filter_ps` set and drops every in-band VPS, SPS and PPS.
/// The decoder is then left with the parameter sets in `hvcC` alone. A Blu-ray or broadcast HEVC
/// stream that sends a new PPS mid-title (seen at 118 s and 345.7 s on one UHD disc) has every later
/// slice decoded against the stale one: macOS reports "Cannot Decode", a device plays sound over a
/// black picture. Converting here, and handing movenc a length-prefixed record so it does not convert
/// again, keeps the parameter sets in the samples. That is the shape a Matroska remux of the same
/// stream already reaches the muxer in (its samples carry their in-band parameter sets and movenc
/// copies them as they are).
///
/// Diagnosed and first implemented by yipengfei329 for MovieClaw (AetherEngine PR #703, patch P38).
enum AnnexBSampleConverter {
    /// The NAL payload ranges of an Annex-B buffer, 3-byte and 4-byte start codes alike, with the
    /// zero bytes in front of the next start code trimmed off, as `ff_nal_parse_units` does. Empty when
    /// the buffer holds no start code.
    static func nalRanges(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count >= 4 else {
            return []
        }
        let n = bytes.count
        var starts: [Int] = []
        var i = 0
        while i + 2 < n {
            // The third byte of a start code is 1 and the two before it are 0, so any byte above 1 at
            // i + 2 rules out a start code beginning at i, i + 1 or i + 2.
            if base[i + 2] > 1 { i += 3; continue }
            if base[i] == 0, base[i + 1] == 0, base[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(starts.count)
        for (k, start) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1] - 3 : n
            while end > start, base[end - 1] == 0 { end -= 1 }
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    /// Replace the packet's payload with its length-prefixed form. False when the payload holds no
    /// start code (the packet is left untouched) or the new buffer could not be allocated.
    ///
    /// The payload goes into a new buffer rather than being rewritten in place: a demuxed packet's
    /// buffer can be shared with another reference.
    ///
    /// `removeUHDPaddingCrop` replaces an SPS that codes 3840x2176 cropped to 2160 with its crop-free
    /// form (`HEVCConformanceCrop`), so the sample agrees with the init segment the tvOS remux wrote.
    static func convertToLengthPrefixed(_ packet: UnsafeMutablePointer<AVPacket>,
                                        removeUHDPaddingCrop: Bool = false) -> Bool {
        guard let packetData = packet.pointee.data, packet.pointee.size > 0 else { return false }
        let packetBytes = UnsafeRawBufferPointer(start: packetData, count: Int(packet.pointee.size))
        let packetRanges = nalRanges(packetBytes)
        guard !packetRanges.isEmpty else { return false }
        if removeUHDPaddingCrop,
           let cropFree = HEVCConformanceCrop.removingUHDPaddingCrop(fromAnnexB: packetBytes, ranges: packetRanges) {
            return cropFree.withUnsafeBytes { write(packet, source: $0, ranges: nalRanges($0)) }
        }
        return write(packet, source: packetBytes, ranges: packetRanges)
    }

    /// Points the packet at a new buffer holding `bytes`, leaving a shared original untouched.
    @discardableResult
    static func replacePayload(_ packet: UnsafeMutablePointer<AVPacket>, with bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count <= Int(Int32.max) else { return false }
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(bytes.count + pad) else { return false }
        guard let dst = newRef.pointee.data else {
            var ref: UnsafeMutablePointer<AVBufferRef>? = newRef
            av_buffer_unref(&ref)
            return false
        }
        bytes.withUnsafeBufferPointer { _ = memcpy(dst, $0.baseAddress!, bytes.count) }
        memset(dst + bytes.count, 0, pad)
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = dst
        packet.pointee.size = Int32(bytes.count)
        return true
    }

    private static func write(_ packet: UnsafeMutablePointer<AVPacket>, source: UnsafeRawBufferPointer,
                              ranges: [Range<Int>]) -> Bool {
        guard let data = source.baseAddress?.assumingMemoryBound(to: UInt8.self), !ranges.isEmpty else { return false }
        let total = ranges.reduce(0) { $0 + 4 + $1.count }
        guard total <= Int(Int32.max) else { return false }

        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad) else { return false }
        guard let dst = newRef.pointee.data else {
            var ref: UnsafeMutablePointer<AVBufferRef>? = newRef
            av_buffer_unref(&ref)
            return false
        }
        var w = 0
        for range in ranges {
            let len = range.count
            dst[w + 0] = UInt8((len >> 24) & 0xFF)
            dst[w + 1] = UInt8((len >> 16) & 0xFF)
            dst[w + 2] = UInt8((len >> 8) & 0xFF)
            dst[w + 3] = UInt8(len & 0xFF)
            w += 4
            memcpy(dst + w, data + range.lowerBound, len)
            w += len
        }
        memset(dst + total, 0, pad)
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        return true
    }
}
