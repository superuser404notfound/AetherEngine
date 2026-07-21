import Foundation
import Testing
import Libavcodec
@testable import AetherEngine

/// #145 (cmcpherson274), premise corrected after upstream review (FFmpeg PR 23852, jamrial):
/// RFC 9559 (11.1.3, 11.2, 5.1.3.5.3) puts Block/SimpleBlock relative timestamps AND BlockDuration
/// in Track Ticks, so a block's absolute time is (cluster + rel x TTS) x TimestampScale. FFmpeg's
/// matroska demuxer implements exactly that (stream time_base = TimestampScale x TTS, cluster
/// component divided by TTS once); the "hybrid axis" this suite originally locked in does not
/// exist. The reporter's fixture (control mux with TrackTimestampScale set to 2.0 and nothing
/// rescaled) was an invalid file: its blocks were authored in Segment Ticks.
///
/// The earlier FFmpegBuild clamp (any TTS != 1 forced to 1.0) made that invalid fixture land on
/// its authored times but would mistime a conformant TTS != 1 file. It is replaced by a warn-only
/// patch: RFC behavior is preserved verbatim and a warning surfaces TTS != 1, since many readers
/// ignore the element and files carrying it may have been authored against such readers. The
/// reporter's core defect (the silence) stays fixed; the axis follows the spec.
///
/// This suite locks the RFC semantics: a conformant Track Ticks file demuxes at its authored
/// times (the clamp would have broken exactly this case), and a segment-axis-authored file
/// (invalid per RFC) demuxes on the RFC-scaled axis, documenting inherited upstream behavior.
struct Issue145MatroskaTrackTimestampScaleTests {

    private static let tts = 2.0

    /// One authored subtitle event: intended absolute time = cluster + rel (both ms).
    fileprivate struct Event {
        let clusterMs: Int
        let relMs: Int
        let durationMs: Int
        var authoredSeconds: Double { Double(clusterMs + relMs) / 1000.0 }
        var authoredDurationSeconds: Double { Double(durationMs) / 1000.0 }
        /// RFC rendering of a file whose block fields carry these ms values verbatim (Segment
        /// Ticks authoring, invalid for TTS != 1): rel and duration are read as Track Ticks.
        func rfcSeconds(tts: Double) -> Double { (Double(clusterMs) + Double(relMs) * tts) / 1000.0 }
        func rfcDurationSeconds(tts: Double) -> Double { Double(durationMs) * tts / 1000.0 }
    }

    /// Mirrors the reporter's fixture shape: 5 s clusters, a late-rel cue in the 20 s cluster
    /// (authored 24.5 s) followed by an early-rel event in the 25 s cluster. All rel/duration
    /// values divide evenly by TTS=2 so the conformant variant needs no rounding.
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

    @Test("conformant TTS=2.0 file (Track Ticks authoring) demuxes at its authored times")
    func conformantScaledTrackKeepsAuthoredTimes() throws {
        let packets = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: Self.tts,
                                                                     events: Self.events,
                                                                     authoring: .trackTicks))
        #expect(packets.count == Self.events.count)
        for (packet, event) in zip(packets, Self.events) {
            #expect(abs(packet.pts - event.authoredSeconds) < 0.0005,
                    "cue authored at \(event.authoredSeconds)s emitted at \(packet.pts)s")
            #expect(abs(packet.duration - event.authoredDurationSeconds) < 0.0005,
                    "duration authored \(event.authoredDurationSeconds)s emitted \(packet.duration)s")
        }
    }

    @Test("conformant TTS=2.0 file demuxes identically to the TTS-less control")
    func conformantScaledTrackMatchesControl() throws {
        let control = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: nil,
                                                                     events: Self.events,
                                                                     authoring: .segmentTicks))
        let scaled = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: Self.tts,
                                                                    events: Self.events,
                                                                    authoring: .trackTicks))
        #expect(control.count == scaled.count)
        for (c, s) in zip(control, scaled) {
            #expect(abs(c.pts - s.pts) < 0.0005, "control \(c.pts)s vs scaled \(s.pts)s")
            #expect(abs(c.duration - s.duration) < 0.0005)
        }
    }

    @Test("conformant TTS=2.0 file emits monotonic pts in storage order")
    func conformantScaledTrackStaysMonotonic() throws {
        let packets = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: Self.tts,
                                                                     events: Self.events,
                                                                     authoring: .trackTicks))
        let times = packets.map(\.pts)
        #expect(times == times.sorted(),
                "conformant authoring must stay monotonic in storage order, got \(times)")
    }

    @Test("segment-axis-authored TTS file (invalid per RFC 9559) demuxes on the RFC-scaled axis")
    func segmentAxisAuthoredFileFollowsRFCScaledAxis() throws {
        let packets = try demuxSubtitleTimes(MatroskaTTSFixture.make(trackTimestampScale: Self.tts,
                                                                     events: Self.events,
                                                                     authoring: .segmentTicks))
        #expect(packets.count == Self.events.count)
        for (packet, event) in zip(packets, Self.events) {
            #expect(abs(packet.pts - event.rfcSeconds(tts: Self.tts)) < 0.0005,
                    "invalid file: RFC renders \(event.rfcSeconds(tts: Self.tts))s, got \(packet.pts)s")
            #expect(abs(packet.duration - event.rfcDurationSeconds(tts: Self.tts)) < 0.0005,
                    "invalid file: RFC duration \(event.rfcDurationSeconds(tts: Self.tts))s, got \(packet.duration)s")
        }
    }
}

/// Minimal in-memory Matroska writer: one S_TEXT/UTF8 subtitle track, one BlockGroup (Block +
/// BlockDuration) per event, one Cluster per distinct cluster timestamp. Sizes are always encoded
/// as 8-byte EBML vints so nesting needs no length backpatching.
///
/// `authoring` selects the axis the block fields are written on. `.trackTicks` divides rel and
/// duration by TrackTimestampScale (conformant per RFC 9559; requires even division).
/// `.segmentTicks` writes the ms values verbatim (the reporter's fixture shape; invalid for
/// TTS != 1, since readers scale these fields by TTS).
private enum MatroskaTTSFixture {

    enum Authoring {
        case trackTicks
        case segmentTicks
    }

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

    static func make(trackTimestampScale: Double?, events: [Event], authoring: Authoring) -> Data {
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

        // Track Ticks authoring divides the ms fields by TTS (conformant); Segment Ticks writes
        // them verbatim (reporter-shaped, invalid for TTS != 1).
        let divisor: Int
        switch authoring {
        case .trackTicks:
            let tts = trackTimestampScale ?? 1.0
            precondition(tts == tts.rounded() && tts >= 1.0, "integer TTS required for tick math")
            divisor = Int(tts)
        case .segmentTicks:
            divisor = 1
        }

        var clusters: [UInt8] = []
        let grouped = Dictionary(grouping: events, by: \.clusterMs).sorted { $0.key < $1.key }
        for (clusterMs, clusterEvents) in grouped {
            var body = element([0xE7], uint(clusterMs))  // Cluster Timestamp
            for event in clusterEvents.sorted(by: { $0.relMs < $1.relMs }) {
                precondition(event.relMs % divisor == 0 && event.durationMs % divisor == 0,
                             "event values must divide evenly by TTS")
                let rel = event.relMs / divisor
                let duration = event.durationMs / divisor
                let block: [UInt8] = [0x81,                             // track number vint
                                      UInt8((rel >> 8) & 0xFF),
                                      UInt8(rel & 0xFF),                // int16 relative timestamp
                                      0x00]                             // flags
                                     + string("line @\(clusterMs + event.relMs)ms")
                body += element([0xA0],                                 // BlockGroup
                                element([0xA1], block) +                // Block
                                element([0x9B], uint(duration)))        // BlockDuration
            }
            clusters += element([0x1F, 0x43, 0xB6, 0x75], body)
        }

        let segment = element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters)
        return Data(header + segment)
    }

    typealias Event = Issue145MatroskaTrackTimestampScaleTests.Event
}
