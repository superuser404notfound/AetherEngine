import Foundation

/// Lightweight fragmented MP4 muxer for AC3/EAC3 audio streams.
///
/// Takes raw AC3/EAC3 audio frames (as demuxed by FFmpeg) and wraps them
/// in ISO BMFF fragmented MP4 format, suitable for AVPlayer playback via
/// AVAssetResourceLoader. Properly declares dependent substreams in the
/// dec3 box for Dolby Atmos (EAC3+JOC) passthrough.
///
/// ## fMP4 Structure
///
/// ```
/// Init Segment:  ftyp + moov (with ec-3/ac-3 sample entry + dec3/dac3 box)
/// Media Segment: moof (mfhd + traf(tfhd + tfdt + trun)) + mdat (raw frames)
/// ```
final class FMP4AudioMuxer {

    // MARK: - Types

    enum CodecType {
        case ac3
        case eac3
    }

    /// Parsed codec configuration from bitstream headers.
    struct Config {
        let codecType: CodecType
        let sampleRate: UInt32
        let channelCount: UInt32
        let bitRate: UInt32
        let samplesPerFrame: UInt32
        // Bitstream fields for dac3/dec3 box:
        let fscod: UInt8
        let bsid: UInt8
        let bsmod: UInt8
        let acmod: UInt8
        let lfeon: Bool
        let frmsizecod: UInt8    // AC3 only (bit_rate_code = frmsizecod >> 1)
        let numDepSub: UInt8     // >0 indicates Atmos for EAC3
        let depChanLoc: UInt16   // 9-bit channel location for dependent substream
    }

    // MARK: - Properties

    let config: Config
    private var sequenceNumber: UInt32 = 0
    private var baseDecodeTime: UInt64 = 0

    private static let trackID: UInt32 = 1

    // MARK: - Init

    init(config: Config) {
        self.config = config
    }

    // MARK: - Config Detection

    /// Parse codec configuration from the first audio packet's bitstream headers.
    /// Uses channel count from FFmpeg's AVCodecParameters to infer LFE presence.
    static func detectConfig(
        codecType: CodecType,
        sampleRate: UInt32,
        channelCount: UInt32,
        bitRate: UInt32,
        firstPacketData: Data
    ) -> Config? {
        guard firstPacketData.count >= 8,
              firstPacketData[0] == 0x0B,
              firstPacketData[1] == 0x77 else {
            return nil
        }

        switch codecType {
        case .ac3:
            return parseAC3Config(sampleRate: sampleRate, channelCount: channelCount,
                                  bitRate: bitRate, data: firstPacketData)
        case .eac3:
            return parseEAC3Config(sampleRate: sampleRate, channelCount: channelCount,
                                   bitRate: bitRate, data: firstPacketData)
        }
    }

    // MARK: - Init Segment

    /// Generate the fMP4 init segment: ftyp + moov.
    func createInitSegment() -> Data {
        var data = Data()
        data.append(buildFtyp())
        data.append(buildMoov())
        return data
    }

    // MARK: - Media Segment

    /// Generate a media segment from one or more raw audio frames.
    /// Each frame is one complete AC3/EAC3 access unit (including dependent substreams for Atmos).
    func createMediaSegment(frames: [Data]) -> Data {
        guard !frames.isEmpty else { return Data() }

        sequenceNumber += 1
        let sampleCount = frames.count
        let duration = config.samplesPerFrame

        // Pre-compute box sizes (deterministic, avoids patching data_offset later)
        let trunSize = 12 + 4 + 4 + (sampleCount * 8)  // fullbox + count + offset + entries(dur+size)
        let tfdtSize = 20  // fullbox(12) + uint64(8)
        let tfhdSize = 16  // fullbox(12) + track_id(4)
        let trafSize = 8 + tfhdSize + tfdtSize + trunSize
        let mfhdSize = 16  // fullbox(12) + sequence_number(4)
        let moofSize = 8 + mfhdSize + trafSize
        let dataOffset = UInt32(moofSize + 8)  // + mdat header (8 bytes)

        // Single pass: compute payload size and build trun entries together
        var payloadSize = 0
        var trunEntries = Data(capacity: sampleCount * 8)
        for frame in frames {
            trunEntries.appendUInt32BE(duration)
            trunEntries.appendUInt32BE(UInt32(frame.count))
            payloadSize += frame.count
        }

        var data = Data(capacity: moofSize + 8 + payloadSize)

        // moof
        data.appendUInt32BE(UInt32(moofSize))
        data.appendFourCC("moof")

        //   mfhd
        data.appendUInt32BE(UInt32(mfhdSize))
        data.appendFourCC("mfhd")
        data.appendVersionFlags(version: 0, flags: 0)
        data.appendUInt32BE(sequenceNumber)

        //   traf
        data.appendUInt32BE(UInt32(trafSize))
        data.appendFourCC("traf")

        //     tfhd (default-base-is-moof flag)
        data.appendUInt32BE(UInt32(tfhdSize))
        data.appendFourCC("tfhd")
        data.appendVersionFlags(version: 0, flags: 0x020000)
        data.appendUInt32BE(Self.trackID)

        //     tfdt (version 1 for 64-bit base decode time)
        data.appendUInt32BE(UInt32(tfdtSize))
        data.appendFourCC("tfdt")
        data.appendVersionFlags(version: 1, flags: 0)
        data.appendUInt64BE(baseDecodeTime)

        //     trun (data-offset + sample-duration + sample-size)
        data.appendUInt32BE(UInt32(trunSize))
        data.appendFourCC("trun")
        data.appendVersionFlags(version: 0, flags: 0x000301)
        data.appendUInt32BE(UInt32(sampleCount))
        data.appendUInt32BE(dataOffset)
        data.append(trunEntries)

        // mdat
        data.appendUInt32BE(UInt32(8 + payloadSize))
        data.appendFourCC("mdat")
        for frame in frames {
            data.append(frame)
        }

        baseDecodeTime += UInt64(duration) * UInt64(sampleCount)
        return data
    }

    /// Reset muxer state for seeking. Resets sequence numbers and sets
    /// the base decode time to match the new playback position.
    func reset(atTimeSeconds seconds: Double = 0) {
        sequenceNumber = 0
        baseDecodeTime = UInt64(seconds * Double(config.sampleRate))
    }

    // MARK: - AC3 Header Parsing

    private static func parseAC3Config(
        sampleRate: UInt32, channelCount: UInt32,
        bitRate: UInt32, data: Data
    ) -> Config? {
        // AC3 syncframe: 0x0B77 | CRC1(16) | fscod(2) bsmod(3) frmsizecod(6) | bsid(5) bsmod(3) | acmod(3) ...
        let byte4 = data[4]
        let byte5 = data[5]
        let byte6 = data[6]

        let fscod = (byte4 >> 6) & 0x03
        let frmsizecod = byte4 & 0x3F
        let bsid = (byte5 >> 3) & 0x1F
        let bsmod = byte5 & 0x07
        let acmod = (byte6 >> 5) & 0x07

        // Infer LFE from channel count vs. acmod-implied channels
        let acmodChannels: [UInt32] = [2, 1, 2, 3, 3, 4, 4, 5]
        let lfeon = channelCount > acmodChannels[Int(acmod)]

        return Config(
            codecType: .ac3,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate,
            samplesPerFrame: 1536,  // AC3 always 6 blocks × 256 = 1536
            fscod: fscod,
            bsid: bsid,
            bsmod: bsmod,
            acmod: acmod,
            lfeon: lfeon,
            frmsizecod: frmsizecod,
            numDepSub: 0,
            depChanLoc: 0
        )
    }

    // MARK: - EAC3 Header Parsing

    private static func parseEAC3Config(
        sampleRate: UInt32, channelCount: UInt32,
        bitRate: UInt32, data: Data
    ) -> Config? {
        // EAC3 syncframe: 0x0B77 | strmtyp(2) substreamid(3) frmsiz(11) | fscod(2) numblkscod(2) acmod(3) lfeon(1) | bsid(5) ...
        let byte4 = data[4]
        let byte5 = data[5]

        let fscod = (byte4 >> 6) & 0x03
        let numblkscod: UInt8
        if fscod == 0x03 {
            numblkscod = 3  // 6 blocks implied when fscod=3
        } else {
            numblkscod = (byte4 >> 4) & 0x03
        }
        let acmod = (byte4 >> 1) & 0x07
        let lfeon = (byte4 & 0x01) != 0
        let bsid = (byte5 >> 3) & 0x1F

        let numBlocks: UInt32 = [1, 2, 3, 6][Int(numblkscod)]
        let samplesPerFrame = numBlocks * 256

        // Scan packet for dependent substreams (indicates Atmos/JOC)
        // An EAC3+JOC access unit contains:
        //   [independent substream (strmtyp=0)] [dependent substream(s) (strmtyp=1)]
        // Each substream starts with sync word 0x0B77.
        var numDepSub: UInt8 = 0
        var offset = 0

        while offset + 6 < data.count {
            guard data[offset] == 0x0B, data[offset + 1] == 0x77 else { break }
            let b2 = data[offset + 2]
            let b3 = data[offset + 3]
            let frmsiz = (UInt16(b2 & 0x07) << 8) | UInt16(b3)
            let frameSize = (Int(frmsiz) + 1) * 2
            guard frameSize > 0 else { break }

            let strmtyp = (b2 >> 6) & 0x03
            if strmtyp == 1 { numDepSub += 1 }

            offset += frameSize
        }

        return Config(
            codecType: .eac3,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate,
            samplesPerFrame: samplesPerFrame,
            fscod: fscod,
            bsid: bsid,
            bsmod: 0,
            acmod: acmod,
            lfeon: lfeon,
            frmsizecod: 0,
            numDepSub: numDepSub,
            depChanLoc: numDepSub > 0 ? 0x0100 : 0  // Lc/Rc pair (standard Atmos)
        )
    }

    // MARK: - ftyp Box

    private func buildFtyp() -> Data {
        var d = Data()
        d.appendUInt32BE(32)     // size: 4+4+4+4 + 4*4 = 32
        d.appendFourCC("ftyp")
        d.appendFourCC("isom")   // major brand
        d.appendUInt32BE(0x200)  // minor version
        d.appendFourCC("isom")   // compatible brands
        d.appendFourCC("iso6")
        d.appendFourCC("mp41")
        d.appendFourCC("dash")
        return d
    }

    // MARK: - moov Box (built inside-out)

    private func buildMoov() -> Data {
        let mvhd = buildMvhd()
        let trak = buildTrak()
        let mvex = buildMvex()
        return mp4Box("moov", content: mvhd + trak + mvex)
    }

    private func buildMvhd() -> Data {
        // Movie Header Box (version 0)
        var d = Data()
        d.appendUInt32BE(0)          // creation_time
        d.appendUInt32BE(0)          // modification_time
        d.appendUInt32BE(1000)       // timescale (1ms units)
        d.appendUInt32BE(0)          // duration (unknown for fragmented)
        d.appendUInt32BE(0x00010000) // rate (1.0 fixed-point 16.16)
        d.appendUInt16BE(0x0100)     // volume (1.0 fixed-point 8.8)
        d.appendZeros(10)            // reserved
        d.append(identityMatrix)     // matrix (36 bytes)
        d.appendZeros(24)            // pre_defined
        d.appendUInt32BE(2)          // next_track_ID
        return mp4FullBox("mvhd", version: 0, flags: 0, content: d)
    }

    private func buildTrak() -> Data {
        let tkhd = buildTkhd()
        let mdia = buildMdia()
        return mp4Box("trak", content: tkhd + mdia)
    }

    private func buildTkhd() -> Data {
        // Track Header Box (flags=3: track_enabled | track_in_movie)
        var d = Data()
        d.appendUInt32BE(0)             // creation_time
        d.appendUInt32BE(0)             // modification_time
        d.appendUInt32BE(Self.trackID)  // track_ID
        d.appendUInt32BE(0)             // reserved
        d.appendUInt32BE(0)             // duration (unknown)
        d.appendZeros(8)                // reserved
        d.appendUInt16BE(0)             // layer
        d.appendUInt16BE(0)             // alternate_group
        d.appendUInt16BE(0x0100)        // volume (1.0 for audio)
        d.appendUInt16BE(0)             // reserved
        d.append(identityMatrix)        // matrix (36 bytes)
        d.appendUInt32BE(0)             // width (0 for audio)
        d.appendUInt32BE(0)             // height (0 for audio)
        return mp4FullBox("tkhd", version: 0, flags: 3, content: d)
    }

    private func buildMdia() -> Data {
        let mdhd = buildMdhd()
        let hdlr = buildHdlr()
        let minf = buildMinf()
        return mp4Box("mdia", content: mdhd + hdlr + minf)
    }

    private func buildMdhd() -> Data {
        // Media Header Box (version 0)
        var d = Data()
        d.appendUInt32BE(0)                   // creation_time
        d.appendUInt32BE(0)                   // modification_time
        d.appendUInt32BE(config.sampleRate)   // timescale = sample rate
        d.appendUInt32BE(0)                   // duration (unknown)
        d.appendUInt16BE(0x55C4)              // language: 'und' (undetermined)
        d.appendUInt16BE(0)                   // pre_defined
        return mp4FullBox("mdhd", version: 0, flags: 0, content: d)
    }

    private func buildHdlr() -> Data {
        // Handler Box
        var d = Data()
        d.appendUInt32BE(0)             // pre_defined
        d.appendFourCC("soun")          // handler_type (sound)
        d.appendZeros(12)               // reserved
        d.append(contentsOf: "SoundHandler".utf8)
        d.append(0)                     // null terminator
        return mp4FullBox("hdlr", version: 0, flags: 0, content: d)
    }

    private func buildMinf() -> Data {
        let smhd = buildSmhd()
        let dinf = buildDinf()
        let stbl = buildStbl()
        return mp4Box("minf", content: smhd + dinf + stbl)
    }

    private func buildSmhd() -> Data {
        // Sound Media Header Box
        var d = Data()
        d.appendUInt16BE(0) // balance
        d.appendUInt16BE(0) // reserved
        return mp4FullBox("smhd", version: 0, flags: 0, content: d)
    }

    private func buildDinf() -> Data {
        // Data Reference Box containing a self-referencing URL entry
        let urlContent = Data()  // empty URL = self-contained (flag 1)
        let urlBox = mp4FullBox("url ", version: 0, flags: 1, content: urlContent)

        var drefContent = Data()
        drefContent.appendUInt32BE(1) // entry_count
        drefContent.append(urlBox)
        let dref = mp4FullBox("dref", version: 0, flags: 0, content: drefContent)

        return mp4Box("dinf", content: dref)
    }

    private func buildStbl() -> Data {
        let stsd = buildStsd()
        // Empty tables required for valid fMP4 init segment
        let stts = mp4FullBox("stts", version: 0, flags: 0, content: Data(uint32BE: 0))
        let stsc = mp4FullBox("stsc", version: 0, flags: 0, content: Data(uint32BE: 0))
        var stszContent = Data()
        stszContent.appendUInt32BE(0) // sample_size (variable)
        stszContent.appendUInt32BE(0) // sample_count
        let stsz = mp4FullBox("stsz", version: 0, flags: 0, content: stszContent)
        let stco = mp4FullBox("stco", version: 0, flags: 0, content: Data(uint32BE: 0))
        return mp4Box("stbl", content: stsd + stts + stsc + stsz + stco)
    }

    private func buildStsd() -> Data {
        let sampleEntry = buildAudioSampleEntry()
        var d = Data()
        d.appendUInt32BE(1) // entry_count
        d.append(sampleEntry)
        return mp4FullBox("stsd", version: 0, flags: 0, content: d)
    }

    private func buildAudioSampleEntry() -> Data {
        // AudioSampleEntry base (ISO 14496-12)
        let fourCC = config.codecType == .ac3 ? "ac-3" : "ec-3"
        let codecBox = buildCodecConfigBox()

        var d = Data()
        // SampleEntry base
        d.appendZeros(6)                          // reserved
        d.appendUInt16BE(1)                       // data_reference_index
        // AudioSampleEntry fields
        d.appendZeros(8)                          // reserved (2 × uint32)
        d.appendUInt16BE(UInt16(config.channelCount))  // channelcount
        d.appendUInt16BE(16)                      // samplesize
        d.appendUInt16BE(0)                       // pre_defined
        d.appendUInt16BE(0)                       // reserved
        d.appendUInt32BE(config.sampleRate << 16) // samplerate (fixed-point 16.16)
        d.append(codecBox)

        return mp4Box(fourCC, content: d)
    }

    private func buildCodecConfigBox() -> Data {
        switch config.codecType {
        case .ac3:  return buildDAC3()
        case .eac3: return buildDEC3()
        }
    }

    /// Build dac3 box (3 bytes of codec config).
    /// Layout: fscod(2) | bsid(5) | bsmod(3) | acmod(3) | lfeon(1) | bit_rate_code(5) | reserved(5)
    private func buildDAC3() -> Data {
        var bw = BitWriter()
        bw.write(bits: UInt32(config.fscod), count: 2)
        bw.write(bits: UInt32(config.bsid), count: 5)
        bw.write(bits: UInt32(config.bsmod), count: 3)
        bw.write(bits: UInt32(config.acmod), count: 3)
        bw.write(bits: config.lfeon ? 1 : 0, count: 1)
        bw.write(bits: UInt32(config.frmsizecod >> 1), count: 5)  // bit_rate_code
        bw.write(bits: 0, count: 5)  // reserved
        bw.flush()
        return mp4Box("dac3", content: bw.data)
    }

    /// Build dec3 box with dependent substream info for Atmos.
    /// Layout: data_rate(13) | num_ind_sub(3) | [per substream: fscod(2) | bsid(5) | ...]
    private func buildDEC3() -> Data {
        var bw = BitWriter()

        // Header
        let dataRate = min(config.bitRate / 1000, 8191)  // 13-bit max
        bw.write(bits: UInt32(dataRate), count: 13)
        bw.write(bits: 0, count: 3)  // num_ind_sub = 0 (means 1 independent substream)

        // Independent substream 0
        bw.write(bits: UInt32(config.fscod), count: 2)
        bw.write(bits: UInt32(config.bsid), count: 5)
        bw.write(bits: 1, count: 1)  // reserved = 1
        bw.write(bits: 0, count: 1)  // asvc = 0
        bw.write(bits: UInt32(config.bsmod), count: 3)
        bw.write(bits: UInt32(config.acmod), count: 3)
        bw.write(bits: config.lfeon ? 1 : 0, count: 1)
        bw.write(bits: 0, count: 3)  // reserved
        bw.write(bits: UInt32(config.numDepSub), count: 4)

        if config.numDepSub > 0 {
            bw.write(bits: UInt32(config.depChanLoc), count: 9)
        }

        // JOC/Atmos extension flag (ETSI TS 102 366 v1.4.1)
        if config.numDepSub > 0 {
            bw.write(bits: 0, count: 7)   // reserved
            bw.write(bits: 1, count: 1)   // flag_ec3_extension_type_a = 1 (JOC)
            bw.write(bits: 16, count: 8)  // complexity_index_type_a = 16
        }

        bw.flush()
        return mp4Box("dec3", content: bw.data)
    }

    private func buildMvex() -> Data {
        // Track Extends Box — defaults for media segments
        var d = Data()
        d.appendUInt32BE(Self.trackID)       // track_ID
        d.appendUInt32BE(1)                  // default_sample_description_index
        d.appendUInt32BE(config.samplesPerFrame) // default_sample_duration
        d.appendUInt32BE(0)                  // default_sample_size
        d.appendUInt32BE(0x02000000)         // default_sample_flags (independent)
        let trex = mp4FullBox("trex", version: 0, flags: 0, content: d)
        return mp4Box("mvex", content: trex)
    }

    // MARK: - MP4 Box Helpers

    /// Standard MP4 box: size(4) + type(4) + content.
    private func mp4Box(_ type: String, content: Data) -> Data {
        var d = Data(capacity: 8 + content.count)
        d.appendUInt32BE(UInt32(8 + content.count))
        d.appendFourCC(type)
        d.append(content)
        return d
    }

    /// Full box: size(4) + type(4) + version(1) + flags(3) + content.
    private func mp4FullBox(_ type: String, version: UInt8, flags: UInt32, content: Data) -> Data {
        var inner = Data(capacity: 4 + content.count)
        inner.appendVersionFlags(version: version, flags: flags)
        inner.append(content)
        return mp4Box(type, content: inner)
    }

    /// 3×3 identity matrix in MP4 fixed-point format (36 bytes).
    private var identityMatrix: Data {
        var d = Data(capacity: 36)
        d.appendUInt32BE(0x00010000); d.appendUInt32BE(0); d.appendUInt32BE(0)
        d.appendUInt32BE(0); d.appendUInt32BE(0x00010000); d.appendUInt32BE(0)
        d.appendUInt32BE(0); d.appendUInt32BE(0); d.appendUInt32BE(0x40000000)
        return d
    }
}

// MARK: - BitWriter

/// MSB-first bit writer for constructing codec-specific MP4 box data.
private struct BitWriter {
    var data = Data()
    private var currentByte: UInt8 = 0
    private var bitIndex: Int = 0

    mutating func write(bits value: UInt32, count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let bit = (value >> UInt32(i)) & 1
            currentByte |= UInt8(bit) << (7 - bitIndex)
            bitIndex += 1
            if bitIndex == 8 {
                data.append(currentByte)
                currentByte = 0
                bitIndex = 0
            }
        }
    }

    mutating func flush() {
        if bitIndex > 0 {
            data.append(currentByte)
            currentByte = 0
            bitIndex = 0
        }
    }
}

// MARK: - Data Extensions

private extension Data {
    /// Create Data containing a single big-endian UInt32.
    init(uint32BE value: UInt32) {
        self.init(capacity: 4)
        appendUInt32BE(value)
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32(value >> 32))
        appendUInt32BE(UInt32(value & 0xFFFFFFFF))
    }

    mutating func appendFourCC(_ cc: String) {
        for c in cc.utf8 { append(c) }
    }

    mutating func appendZeros(_ count: Int) {
        append(Data(count: count))
    }

    /// Append FullBox version(1) + flags(3) field.
    mutating func appendVersionFlags(version: UInt8, flags: UInt32) {
        append(version)
        append(UInt8((flags >> 16) & 0xFF))
        append(UInt8((flags >> 8) & 0xFF))
        append(UInt8(flags & 0xFF))
    }
}
