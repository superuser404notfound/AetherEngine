import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// A UHD Blu-ray's Dolby Vision as the transport stream carries it: the base layer on PID 0x1011 and the
/// enhancement layer on PID 0x1015 of the same clip, two HEVC streams. The RPU for each base-layer picture is an
/// `unspec62` NAL inside the enhancement layer's access unit with the same PTS; the base layer carries none, and
/// no DOVI record sits on either stream (the PMT has no Dolby Vision descriptor). Left alone, the base layer plays as
/// plain HDR10.
///
/// The demuxer folds the two back into the single-track shape a Profile 7 remux has (the RPU appended to its base
/// layer access unit, Annex-B), gives the base layer the Profile 7 record such a remux declares, and keeps the
/// enhancement-layer packets to itself. Everything after the demuxer then sees an ordinary Profile 7 source and
/// takes its usual route (by default the conversion to Profile 8.1).
///
/// Measured on a retail UHD disc (a 90 GB main clip): one RPU per enhancement-layer access unit, every base
/// access unit followed by the enhancement unit with its PTS within a few packets.
struct BluRayDolbyVisionLayers {
    /// Blu-ray's fixed PIDs: the primary video, and the Dolby Vision enhancement layer.
    static let basePID: Int32 = 0x1011
    static let enhancementPID: Int32 = 0x1015

    let base: Int32
    let enhancement: Int32

    /// The two layers' stream indices, when the context is a transport stream holding both as HEVC.
    static func detect(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> BluRayDolbyVisionLayers? {
        guard let name = ctx.pointee.iformat?.pointee.name, String(cString: name) == "mpegts" else { return nil }
        var base: Int32?, enhancement: Int32?
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO, par.pointee.codec_id == AV_CODEC_ID_HEVC else { continue }
            if stream.pointee.id == basePID { base = i }
            if stream.pointee.id == enhancementPID { enhancement = i }
        }
        guard let base, let enhancement else { return nil }
        return BluRayDolbyVisionLayers(base: base, enhancement: enhancement)
    }

    /// Gives the base layer the record a Profile 7 remux of the disc declares: dual layer, RPU present,
    /// base-layer signal compatibility 6 (the UHD Blu-ray HDR10 base). The level follows the picture's sample
    /// rate. Returns false if the stream already has one or the allocation failed.
    @discardableResult
    static func declareProfile7(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let codecpar = stream.pointee.codecpar else { return false }
        let par = codecpar.pointee
        for i in 0..<Int(par.nb_coded_side_data) where par.coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF {
            return false
        }
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let item = av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF, size, 0),
              let raw = item.pointee.data else { return false }
        memset(raw, 0, size)
        let rate = stream.pointee.avg_frame_rate.num > 0 && stream.pointee.avg_frame_rate.den > 0
            ? Double(stream.pointee.avg_frame_rate.num) / Double(stream.pointee.avg_frame_rate.den) : 24
        let level = level(width: Int(par.width), height: Int(par.height), fps: rate)
        raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
            rec.pointee.dv_version_major = 1
            rec.pointee.dv_version_minor = 0
            rec.pointee.dv_profile = 7
            rec.pointee.dv_level = UInt8(level)
            rec.pointee.rpu_present_flag = 1
            rec.pointee.el_present_flag = 1
            rec.pointee.bl_present_flag = 1
            rec.pointee.dv_bl_signal_compatibility_id = 6
        }
        return true
    }

    /// The Dolby Vision level for a picture size and rate: the lowest whose luma sample rate holds it.
    static func level(width: Int, height: Int, fps: Double) -> Int {
        let rate = Double(width * height) * fps
        let limits: [Double] = [22_118_400, 27_648_000, 49_766_400, 62_208_000, 124_416_000, 199_065_600,
                                248_832_000, 398_131_200, 497_664_000, 995_328_000, 995_328_000, 1_990_656_000,
                                3_981_312_000]
        for (i, limit) in limits.enumerated() where rate <= limit * 1.001 { return i + 1 }
        return limits.count
    }

    /// The RPU NAL of an Annex-B access unit, with a three-byte start code in front, ready to append; nil when the
    /// unit has none. Trailing zero bytes (the next start code's leading zero, padding) are not part of it.
    static func rpu(inAnnexB data: UnsafeRawBufferPointer) -> [UInt8]? {
        let bytes = data.bindMemory(to: UInt8.self)
        let n = bytes.count
        var i = 0
        func startCode(at j: Int) -> Bool { j + 2 < n && bytes[j] == 0 && bytes[j + 1] == 0 && bytes[j + 2] == 1 }
        while i + 3 < n {
            guard startCode(at: i) else { i += 1; continue }
            let nal = i + 3
            var end = nal + 1
            while end < n && !startCode(at: end) { end += 1 }
            if (bytes[nal] >> 1) & 0x3F == 62 {
                var last = end
                while last > nal && bytes[last - 1] == 0 { last -= 1 }
                guard last - nal > 2 else { return nil }
                return [0, 0, 1] + Array(bytes[nal..<last])
            }
            i = end
        }
        return nil
    }

    /// Appends `rpu` to the packet's payload (Annex-B: the start code is in `rpu`). False if the packet could not
    /// grow, in which case it is unchanged.
    static func append(_ rpu: [UInt8], to packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let old = Int(packet.pointee.size)
        guard av_grow_packet(packet, Int32(rpu.count)) >= 0, let data = packet.pointee.data else { return false }
        rpu.withUnsafeBufferPointer { (data + old).update(from: $0.baseAddress!, count: rpu.count) }
        return true
    }
}
