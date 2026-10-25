import Testing
import Foundation
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// AetherEngine#466 / Sodalite#100: an ATSC 3.0 tune sat at `containerOpened` for most of a minute
/// with nothing surfaced, and backing out was the only way to leave the screen.
///
/// The channel's audio is AC-4, which nothing in this build decodes, and `has_codec_parameters` fails
/// an audio stream with no sample rate. `try_decode_frame` gives up on it immediately (`found_decoder`
/// goes negative) but the outer `find_stream_info` loop keeps reading regardless, because its only
/// exit is every stream resolving. One such stream therefore costs the whole probe budget, and a live
/// source cannot be read ahead of, so that budget is spent in wall-clock seconds.
///
/// Measured against the synthetic stream below (3000 access units, 120 s of media): the same channel
/// reads 1,572,864 bytes without the parking and 262,144 with it, the latter being what the same
/// stream costs with no AC-4 track at all.
@Suite("Unresolvable audio streams")
struct UnresolvableAudioProbeTests {

    // MARK: - The premise, measured rather than assumed

    @Test("this build has no AC-4 and no MPEG-H decoder, and does have the ones beside them")
    func decoderAvailability() {
        #expect(avcodec_find_decoder(AV_CODEC_ID_AC4) == nil)
        #expect(avcodec_find_decoder(AV_CODEC_ID_MPEGH_3D_AUDIO) == nil)
        #expect(avcodec_find_decoder(AV_CODEC_ID_AC3) != nil)
        #expect(avcodec_find_decoder(AV_CODEC_ID_AAC) != nil)
    }

    // MARK: - The predicate

    @Test("an audio stream with no decoder and no parameters can never resolve")
    func undecodableAndUnresolved() {
        #expect(Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_AC4, codecType: AVMEDIA_TYPE_AUDIO,
                                           sampleRate: 0, channels: 0))
        #expect(Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_MPEGH_3D_AUDIO,
                                           codecType: AVMEDIA_TYPE_AUDIO,
                                           sampleRate: 48000, channels: 0))
    }

    /// The guard that keeps `shouldRepairLiveAACCodecpar` alive: a live MPEG-TS AAC stream reaches
    /// the probe with `sample_rate == 0` and is repaired downstream, so parking it would take the
    /// audio off every live channel this engine plays. Having a decoder is what separates them.
    @Test("a live AAC stream with no sample rate is left alone, because it has a decoder")
    func liveAACIsNotParked() {
        #expect(!Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_AAC, codecType: AVMEDIA_TYPE_AUDIO,
                                            sampleRate: 0, channels: 0))
        #expect(SoftwarePlaybackHost.shouldRepairLiveAACCodecpar(
            isLive: true, codecID: AV_CODEC_ID_AAC, sampleRate: 0))
    }

    @Test("a codec the container already described is none of this decision's business")
    func resolvedParametersAreLeftAlone() {
        #expect(!Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_AC4, codecType: AVMEDIA_TYPE_AUDIO,
                                            sampleRate: 48000, channels: 2))
    }

    /// `AV_CODEC_ID_NONE` is a stream still being identified, which is what the probe is for.
    @Test("an unidentified stream is not parked out of the probe that would identify it")
    func unidentifiedStreamIsLeftAlone() {
        #expect(!Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_NONE, codecType: AVMEDIA_TYPE_AUDIO,
                                            sampleRate: 0, channels: 0))
    }

    @Test("video and subtitles are deliberately out of scope",
          arguments: [AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_SUBTITLE])
    func nonAudioIsLeftAlone(_ type: AVMediaType) {
        #expect(!Demuxer.audioCannotResolve(codecID: AV_CODEC_ID_AC4, codecType: type,
                                            sampleRate: 0, channels: 0))
    }

    // MARK: - The whole open, against the shape the report needed a tuner for

    /// Same stream, same budget, with and without the one audio track nothing can decode. The gap is
    /// what an undecodable stream costs a probe that has no other reason to keep reading.
    @Test("an undecodable audio track costs the probe nothing once it is parked")
    func parkedAudioDoesNotExtendTheProbe() throws {
        let plain = try reach(SyntheticTS.broadcast(accessUnits: 3000))
        let withAC4 = try reach(SyntheticTS.broadcast(accessUnits: 3000, audio: .ac4))
        #expect(withAC4 <= plain)
    }

    @Test("an AC-4 channel opens early and still shows its audio stream")
    func ac4ChannelOpensEarly() throws {
        let ts = SyntheticTS.broadcast(accessUnits: 3000, audio: .ac4)
        #expect(ts.count > 5_000_000)
        let reader = ProbeReachReader(data: ts)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", profile: .playback, isLive: true)
        defer { demuxer.close() }

        #expect(demuxer.unresolvableAudioStreams == [
            Demuxer.UnresolvableAudioStream(index: 1, codec: "ac4")
        ])
        #expect(reader.highWaterMark < 1_000_000)

        // Parked FOR the probe, not permanently: the caller sees exactly what a full-budget probe
        // would have left it, an audio stream whose parameters never resolved.
        let audio = try #require(demuxer.stream(at: 1)?.pointee.codecpar)
        #expect(audio.pointee.codec_type == AVMEDIA_TYPE_AUDIO)
        #expect(audio.pointee.codec_id == AV_CODEC_ID_AC4)
        #expect(audio.pointee.sample_rate == 0)
        #expect(demuxer.audioTrackInfos().map(\.codec) == ["ac4"])

        // The real stream still resolved, which is what makes the early stop legitimate.
        #expect(demuxer.videoStreamIndex == 0)
        let video = try #require(demuxer.stream(at: 0)?.pointee.codecpar)
        #expect(video.pointee.codec_id == AV_CODEC_ID_H264)
        #expect(video.pointee.width == 64)
        #expect(video.pointee.height == 64)
    }

    private func reach(_ ts: Data) throws -> Int {
        let reader = ProbeReachReader(data: ts)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", profile: .playback, isLive: true)
        defer { demuxer.close() }
        #expect(demuxer.videoStreamIndex == 0)
        return reader.highWaterMark
    }
}

/// Counts how far into the source an open had to read. Disc probing is off because its sparse
/// signature reads seek near the end, and the reach is the whole measurement here.
final class ProbeReachReader: IOReader, @unchecked Sendable {
    private let data: Data
    private var position = 0
    private var furthest = 0
    private let lock = NSLock()

    var highWaterMark: Int { lock.lock(); defer { lock.unlock() }; return furthest }
    var discImageProbeEnabled: Bool { false }

    init(data: Data) { self.data = data }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard position < data.count else { return 0 }
        let n = min(Int(size), data.count - position)
        data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n),
                       from: position..<(position + n))
        position += n
        furthest = max(furthest, position)
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return Int64(data.count) }
        lock.lock()
        defer { lock.unlock() }
        let target: Int
        switch whence {
        case SEEK_SET: target = Int(offset)
        case SEEK_CUR: target = position + Int(offset)
        case SEEK_END: target = data.count + Int(offset)
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, data.count)
        return Int64(position)
    }

    func close() {}
}

/// A minimal MPEG-TS muxer. It exists because the reported source needs an ATSC 3.0 tuner and the
/// property under test (how far a probe reads into a transport stream) needs nothing of the sort.
/// With `ac4` the PMT gains a private stream carrying the `AC-4` registration descriptor, which is
/// the row `mpegts.c` matches to `AV_CODEC_ID_AC4`; the payload behind it is junk, since nothing in
/// this build could decode a real one either.
enum SyntheticTS {

    static let videoPID: UInt16 = 0x0100
    static let pmtPID: UInt16 = 0x1000
    /// 90 kHz ticks per frame at 25 fps.
    private static let frameTicks: Int64 = 3600

    /// Two all-intra 64x64 H.264 frames, so any number of repeats is a valid elementary stream.
    private static let h264Base64 = """
    AAAAAWdCwArcQmwEQAAAAwBAAAAMo8SJ4AAAAAFozgOcgAAAAQYF//8l3EXpvebZSLeWLNgg2SPu
    73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAt
    IENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAt
    IG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEg
    c3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNo
    cm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bz
    a2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNs
    aWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0
    PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0xIGtleWlu
    dF9taW49MSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcXAgbWJ0cmVlPTAgcXA9NDAg
    aXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6DGAB8kZpGFhwsq9e/gRZsx64APveloMv66Ak7Zj1
    4cQLkQAAqCGEz/U3f6gBHpTH0QIQKUhZEAMYAqfIgAgB35T+AGduiCneEREl//4SgYCBAIAcgUc7
    A/YHjjLT/sq2AavjTQ4YwHR8zACAAEBR+B0ZZYdGWX9f/wOAAQOAAIC4QKBrIImlgbsgLvj+sAO5
    WQBcefDGAAiehVkcuThglTBY4SP8d7gCE13rs8F9uT2EX9deGFwiCAAKgAsCKv59PWVcHnb5wYRe
    vW0v3jsABN47/3Zi8oCDAARt/yvN+/6T8RvRuqvAb4giJc/9wb7HbRXxBES4QIZ7gciJc/M76p4W
    cABNMPfcgMJzLDjv8GAD7VWyIM/chgUj34rIK+9D3fu51iGGavfqxKxHYAPJi+3Z3bsq/+BwCRbm
    AzKgJclV7/T08c4ACTYtv3VGzq3/8DiEe5ATmT2A3DmDHnUozZgACAEBRLX4Hd3e8GVLDyFL8pKW
    IGJmPX4YAIQLhgAEAKDgXj8s1fHC4uMSwER5ljTsDGAGTQOgysD/cZbNrrBkpYeRSwGX3cdvCCAX
    FhiAMDovFHDIad+E6/YEfMrEDbl/jtlhgkAMdEoADAiS/KqqtZOyyqcvyq5ZVct2xhQABAMBdCAA
    YFQKNweQrQMglpgbDocA8quUBGyCUpTBfABmxtgkc4BH/j/4pdN1thdlk7LrrBgmhICDoUUzH3Ni
    jjOPEgJruGKlwAAAAAFnQsAK3EJsBEAAAAMAQAAADKPEieAAAAABaM4DnIAAAAFliIIOgxgAfJGa
    RhYcLKvXv4EWbMeuAD73paDL+ugJO2Y9eHEC5EAAKghhM/1N3+oAR6Ux9ECEClIWRADGAKnyIAIA
    d+U/gBnbogp3hERJf/+EoGAgQCAHIFHOwP2B44y0/7KtgGr400OGMB0fMwAgABAUfgdGWWHRll/X
    /8DgAEDgACAuECgayCJpYG7IC74/rADuVkAXHnwxgAInoVZHLk4YJUwWOEj/He4AhNd67PBfbk9h
    F/XXhhcIggACoALAir+fT1lXB52+cGEXr1tL947AATeO/92YvKAgwAEbf8rzfv+k/Eb0bqrwG+II
    iXP/cG+x20V8QREuECGe4HIiXPzO+qeFnAATTD33IDCcyw47/BgA+1VsiDP3IYFI9+KyCvvQ937u
    dYhhmr36sSsR2ADyYvt2d27Kv/gcAkW5gMyoCXJVe/09PHOAAk2Lb91Rs6t//A4hHuQE5k9gNw5g
    x71KM3GAAIAQOJsDu7veDKlh5Cl+UlLEDEzHr8MAEIFwwACAFBwLx+WavjhcXGJYCI8yYadgYwAy
    aB0GRgf7jLZtdYMlLDyKWAy+7jt4QQC0sMEOLReKOGQ078J1+wI+ZWIGyl/jtlhgkAIdJcABgyxK
    qqtZOyyqcvyq5ZVct2xhQABAMBdCAAYFYKNweQrQMglpgsA0LAacaAI2QSlKYL4AM2PYJCnAZ/4/
    +KXTdbYXZZOy66wYJISAQdCimY+5sVxnHiQE13DFS4A=
"""

    static let audioPID: UInt16 = 0x0101
    static let subtitlePID: UInt16 = 0x0102

    /// What the PMT declares on the audio PID.
    enum AudioShape { case none, ac4 }

    /// What the PMT declares on the subtitle PID. `.pgs` is a Blu-ray PGS track that never carries a
    /// packet, the shape of a sparse track whose first cue lies past the probe.
    enum SubtitleShape { case none, pgs }

    static func broadcast(accessUnits: Int, audio: AudioShape = .none,
                          subtitle: SubtitleShape = .none) -> Data {
        let au = Data(base64Encoded: h264Base64, options: .ignoreUnknownCharacters) ?? Data()
        var cc: [UInt16: UInt8] = [:]
        var out = Data()
        out.append(psi(pid: 0x0000, cc: &cc, section: patSection()))
        out.append(psi(pid: pmtPID, cc: &cc, section: pmtSection(audio: audio, subtitle: subtitle)))
        for i in 0..<accessUnits {
            let pts = Int64(i) * frameTicks
            out.append(pes(pid: videoPID, streamID: 0xE0, payload: au, pts: pts, cc: &cc))
            guard audio != .none else { continue }
            out.append(pes(pid: audioPID, streamID: 0xBD,
                           payload: Data(repeating: 0xA4, count: 160), pts: pts, cc: &cc))
        }
        return out
    }

    // MARK: - Sections

    private static func patSection() -> Data {
        var body = Data([0x00, 0x01])
        body.append(contentsOf: [0xC1, 0x00, 0x00])
        body.append(contentsOf: [0x00, 0x01])
        body.append(contentsOf: [UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
        return section(tableID: 0x00, body: body)
    }

    private static func pmtSection(audio: AudioShape, subtitle: SubtitleShape) -> Data {
        var body = Data([0x00, 0x01])
        body.append(contentsOf: [0xC1, 0x00, 0x00])
        body.append(contentsOf: [UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF)])
        if subtitle == .pgs {
            // `mpegts.c` only reads the HDMV stream types under an `HDMV` program registration.
            body.append(contentsOf: [0xF0, 0x06, 0x05, 0x04])
            body.append(contentsOf: Array("HDMV".utf8))
        } else {
            body.append(contentsOf: [0xF0, 0x00])
        }
        body.append(contentsOf: [0x1B, UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF),
                                 0xF0, 0x00])
        switch audio {
        case .none:
            break
        case .ac4:
            body.append(contentsOf: [0x06, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF),
                                     0xF0, 0x06,
                                     0x05, 0x04])                 // registration_descriptor
            body.append(contentsOf: Array("AC-4".utf8))
        }
        if subtitle == .pgs {
            body.append(contentsOf: [0x90, UInt8(0xE0 | (subtitlePID >> 8)), UInt8(subtitlePID & 0xFF),
                                     0xF0, 0x00])
        }
        return section(tableID: 0x02, body: body)
    }

    private static func section(tableID: UInt8, body: Data) -> Data {
        let length = body.count + 4
        var s = Data([tableID, UInt8(0xB0 | ((length >> 8) & 0x0F)), UInt8(length & 0xFF)])
        s.append(body)
        let crc = mpegCRC32([UInt8](s))
        for shift in stride(from: 24, through: 0, by: -8) {
            s.append(UInt8((crc >> UInt32(shift)) & 0xFF))
        }
        return s
    }

    private static func mpegCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    // MARK: - Packets

    private static func psi(pid: UInt16, cc: inout [UInt16: UInt8], section: Data) -> Data {
        var payload = Data([0x00])
        payload.append(section)
        payload.append(contentsOf: [UInt8](repeating: 0xFF, count: 184 - payload.count))
        return packet(pid: pid, pusi: true, payload: payload, cc: &cc)
    }

    /// PTS and DTS both present: the probe's analyze-duration accounting reads the dts span, so a
    /// stream with presentation timestamps alone never reaches the cap at all.
    private static func pes(pid: UInt16, streamID: UInt8, payload: Data, pts: Int64,
                            cc: inout [UInt16: UInt8]) -> Data {
        var header = Data([0x00, 0x00, 0x01, streamID, 0x00, 0x00])
        header.append(contentsOf: [0x80, 0xC0, 0x0A])
        header.append(contentsOf: timestamp(pts, marker: 0x31))
        header.append(contentsOf: timestamp(pts, marker: 0x11))
        header.append(payload)

        var out = Data()
        var offset = 0
        var first = true
        while offset < header.count {
            let take = min(184, header.count - offset)
            out.append(packet(pid: pid, pusi: first,
                              payload: header.subdata(in: offset..<(offset + take)), cc: &cc))
            offset += take
            first = false
        }
        return out
    }

    private static func timestamp(_ value: Int64, marker: UInt8) -> [UInt8] {
        [
            UInt8((marker & 0xF1) | UInt8((value >> 29) & 0x0E)),
            UInt8((value >> 22) & 0xFF),
            UInt8(0x01 | ((value >> 14) & 0xFE)),
            UInt8((value >> 7) & 0xFF),
            UInt8(0x01 | ((value << 1) & 0xFE)),
        ]
    }

    private static func packet(pid: UInt16, pusi: Bool, payload: Data,
                               cc: inout [UInt16: UInt8]) -> Data {
        precondition(payload.count <= 184)
        let counter = cc[pid, default: 0]
        var p = Data([0x47, UInt8((pusi ? 0x40 : 0x00) | Int(pid >> 8)), UInt8(pid & 0xFF)])
        let stuffing = 184 - payload.count
        if stuffing == 0 {
            p.append(0x10 | counter)
        } else {
            p.append(0x30 | counter)
            p.append(UInt8(stuffing - 1))
            if stuffing >= 2 {
                p.append(0x00)
                p.append(contentsOf: [UInt8](repeating: 0xFF, count: stuffing - 2))
            }
        }
        p.append(payload)
        cc[pid] = (counter &+ 1) & 0x0F
        return p
    }
}
