import AetherLibavcodec

/// Reads the `channelConfiguration` of an AAC `AudioSpecificConfig` (ISO 14496-3 1.6.2.1).
///
/// AE#1047: a record with `channelConfiguration` 0 carries its channel layout in a Program Config
/// Element. FFmpeg's AAC encoder writes that form for any layout without a standard number (a 6.0
/// track, or the CPE, SCE, SCE, CPE layout a Plex transcode produced). CoreMedia refuses it, measured
/// on macOS 26 and iOS 27 on both routes: an fMP4 `esds` fails the loopback item with `-11829` /
/// `-12848`, and an `.m4a` handed to AVPlayer as is ends at 0 s with no duration. Relabelling the
/// record with a standard number opens the item but decodes to silence, because the PCE's element
/// order no longer matches what the decoder expects. libavcodec honours the PCE, so such a track is
/// decoded there instead.
enum AACAudioSpecificConfig {
    /// The 4-bit `channelConfiguration`, or nil for a non-AAC codecpar or extradata too short to read.
    static func channelConfiguration(_ codecpar: UnsafePointer<AVCodecParameters>) -> Int? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_AAC,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else { return nil }
        return channelConfiguration(UnsafeBufferPointer(start: extradata, count: Int(codecpar.pointee.extradata_size)))
    }

    static func channelConfiguration<C: Collection>(_ bytes: C) -> Int? where C.Element == UInt8 {
        var reader = BitReader(Array(bytes.prefix(8)))
        // audioObjectType 31 escapes to 32 + a 6-bit extension.
        guard let objectType = reader.read(5) else { return nil }
        if objectType == 31, reader.read(6) == nil { return nil }
        // samplingFrequencyIndex 15 is followed by an explicit 24-bit rate.
        guard let frequencyIndex = reader.read(4) else { return nil }
        if frequencyIndex == 15, reader.read(24) == nil { return nil }
        return reader.read(4)
    }

    /// Whether CoreMedia refuses this record: its layout lives in a PCE. False when there is no
    /// record to read, so an ADTS stream without one keeps whatever route it had.
    static func coreMediaRejects(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        channelConfiguration(codecpar) == 0
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ count: Int) -> Int? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
                value = (value << 1) | Int(bit)
                position += 1
            }
            return value
        }
    }
}
