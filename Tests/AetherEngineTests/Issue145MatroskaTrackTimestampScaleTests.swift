import Foundation
import Testing
import Libavcodec
@testable import AetherEngine

/// #145 (cmcpherson274): an MKV whose subtitle track carries TrackTimestampScale != 1 came out on a
/// HYBRID timestamp axis: cue pts = cluster timestamp + (in-cluster relative timestamp x TTS),
/// which is neither the unscaled (cluster + rel) nor the fully scaled ((cluster + rel) x TTS) axis.
/// Consequences on a TTS=2.0 fixture: cue starts shifted by relTs x (TTS - 1) per cluster (12->14 s,
/// 24.5->29 s), packets arrived non-monotonic in storage order (a late-rel cue in cluster N landing
/// past an early-rel clear in cluster N+1), and a stale fade outlived its authored clear. All of it
/// silent: right pixels, wrong times, no warning.
///
/// Root cause is inherited from FFmpeg's matroska demuxer (n8.1.2 and master): read_header bakes the
/// track's TrackTimestampScale into the stream time_base (segment scale x TTS) but the block parser
/// divides only the CLUSTER component by TTS (`cluster_time / track->time_scale + block_time`), so
/// the relative component ends up scaled and the cluster component does not.
///
/// The fix (FFmpegBuild patch_ffmpeg_matroska_tts) clamps any TrackTimestampScale != 1.0 to 1.0 at
/// read_header with a warning, extending FFmpeg's own existing `< 0.01` clamp. That lands every
/// track on the coherent, unscaled segment axis (cluster + rel): the axis the file's clusters are
/// stored on, monotonic in storage order, and in sync with the file's other tracks. Full spec
/// scaling was rejected deliberately: RFC 9559 deprecates the element (maxver 3), matroska.org
/// documents that most readers ignore it, and a real-world TTS != 1 is almost always muxer damage
/// where full scaling would desync the track from its siblings instead of playing it correctly.
struct Issue145MatroskaTrackTimestampScaleTests {

    /// One authored subtitle event: absolute time = cluster + rel (both ms on the segment axis).
    fileprivate struct Event {
        let clusterMs: Int
        let relMs: Int
        let durationMs: Int
        var authoredSeconds: Double { Double(clusterMs + relMs) / 1000.0 }
        var authoredDurationSeconds: Double { Double(durationMs) / 1000.0 }
    }

    /// Mirrors the reporter's fixture shape: 5 s clusters, a late-rel cue in the 20 s cluster
    /// (authored 24.5 s) followed by an early-rel event in the 25 s cluster. On the hybrid axis with
    /// TTS=2 those emit as 29 s then 25 s: shifted AND non-monotonic.
    private static let events: [Event] = [
        Event(clusterMs: 0, relMs: 2000, durationMs: 1000),
        Event(clusterMs: 5000, relMs: 2000, durationMs: 1000),
        Event(clusterMs: 10_000, relMs: 2000, durationMs: 1000),
        Event(clusterMs: 20_000, relMs: 4500, durationMs: 500),
        Event(clusterMs: 25_000, relMs: 0, durationMs: 1000),
    ]

    private func demuxSubtitleTimes(_ mkv: Data) throws -> [(pts: Double, duration: Double)] {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: mkv), formatHint: "matroska")
        defer { demuxer.close() }
        guard let stream = demuxer.stream(at: 0) else {
            Issue.record("fixture stream missing")
            return []
        }
        let tb = stream.pointee.time_base
        let tick = Double(tb.num) / Double(tb.den)
        var out: [(pts: Double, duration: Double)] = []
        while let pkt = try demuxer.readPacket() {
            var toFree: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&toFree) }
            guard pkt.pointee.stream_index == 0, pkt.pointee.pts != Int64.min else { continue }
            out.append((Double(pkt.pointee.pts) * tick, Double(pkt.pointee.duration) * tick))
        }
        return out
    }

    @Test("TTS=2.0 track demuxes on the authored segment axis, not the hybrid axis")
    func scaledTrackKeepsAuthoredTimes() throws {
        let packets = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: 2.0,
                                                                     events: Self.events))
        #expect(packets.count == Self.events.count)
        for (packet, event) in zip(packets, Self.events) {
            #expect(abs(packet.pts - event.authoredSeconds) < 0.0005,
                    "cue authored at \(event.authoredSeconds)s emitted at \(packet.pts)s")
            #expect(abs(packet.duration - event.authoredDurationSeconds) < 0.0005,
                    "duration authored \(event.authoredDurationSeconds)s emitted \(packet.duration)s")
        }
    }

    @Test("TTS=2.0 track emits monotonic pts in storage order")
    func scaledTrackStaysMonotonic() throws {
        let packets = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: 2.0,
                                                                     events: Self.events))
        let times = packets.map(\.pts)
        #expect(times == times.sorted(),
                "storage order must stay monotonic on a coherent axis, got \(times)")
    }

    @Test("TTS=2.0 file demuxes identically to the TTS-less control")
    func scaledTrackMatchesControl() throws {
        let control = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: nil,
                                                                     events: Self.events))
        let scaled = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: 2.0,
                                                                    events: Self.events))
        #expect(control.count == scaled.count)
        for (c, s) in zip(control, scaled) {
            #expect(abs(c.pts - s.pts) < 0.0005, "control \(c.pts)s vs scaled \(s.pts)s")
            #expect(abs(c.duration - s.duration) < 0.0005)
        }
    }
}

/// Minimal in-memory Matroska writer: one S_TEXT/UTF8 subtitle track, one BlockGroup (Block +
/// BlockDuration) per event, one Cluster per distinct cluster timestamp. Sizes are always encoded
/// as 8-byte EBML vints so nesting needs no length backpatching.
private enum MatroskaTTSFixture {

    private static func vintSize(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) {
            bytes.append(UInt8((n >> shift) & 0xFF))
        }
        return bytes
    }

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        id + vintSize(payload.count) + payload
    }

    private static func uint(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = v
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return bytes
    }

    private static func float64(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) }
    }

    private static func string(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func make(trackTimestampScale: Double?, events: [Event]) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3],
                             element([0x42, 0x86], uint(1)) +          // EBMLVersion
                             element([0x42, 0xF7], uint(1)) +          // EBMLReadVersion
                             element([0x42, 0xF2], uint(4)) +          // EBMLMaxIDLength
                             element([0x42, 0xF3], uint(8)) +          // EBMLMaxSizeLength
                             element([0x42, 0x82], string("matroska")) +
                             element([0x42, 0x87], uint(4)) +          // DocTypeVersion
                             element([0x42, 0x85], uint(2)))           // DocTypeReadVersion

        let info = element([0x15, 0x49, 0xA9, 0x66],
                           element([0x2A, 0xD7, 0xB1], uint(1_000_000)) +  // TimestampScale: 1 ms
                           element([0x44, 0x89], float64(30_000)) +        // Duration (ticks)
                           element([0x4D, 0x80], string("aether-#145")) +
                           element([0x57, 0x41], string("aether-#145")))

        var trackFields: [UInt8] = []
        trackFields += element([0xD7], uint(1))          // TrackNumber
        trackFields += element([0x73, 0xC5], uint(1))    // TrackUID
        trackFields += element([0x83], uint(0x11))       // TrackType: subtitle
        trackFields += element([0x9C], uint(0))          // FlagLacing
        trackFields += element([0x86], string("S_TEXT/UTF8"))
        if let tts = trackTimestampScale {
            trackFields += element([0x23, 0x31, 0x4F], float64(tts))  // TrackTimestampScale
        }
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], trackFields))

        var clusters: [UInt8] = []
        let grouped = Dictionary(grouping: events, by: \.clusterMs).sorted { $0.key < $1.key }
        for (clusterMs, clusterEvents) in grouped {
            var body = element([0xE7], uint(clusterMs))  // Cluster Timestamp
            for event in clusterEvents.sorted(by: { $0.relMs < $1.relMs }) {
                let block: [UInt8] = [0x81,                             // track number vint
                                      UInt8((event.relMs >> 8) & 0xFF),
                                      UInt8(event.relMs & 0xFF),        // int16 relative timestamp
                                      0x00]                             // flags
                                     + string("line @\(clusterMs + event.relMs)ms")
                body += element([0xA0],                                 // BlockGroup
                                element([0xA1], block) +                // Block
                                element([0x9B], uint(event.durationMs)))  // BlockDuration
            }
            clusters += element([0x1F, 0x43, 0xB6, 0x75], body)
        }

        let segment = element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters)
        return Data(header + segment)
    }

    typealias Event = Issue145MatroskaTrackTimestampScaleTests.Event
}
