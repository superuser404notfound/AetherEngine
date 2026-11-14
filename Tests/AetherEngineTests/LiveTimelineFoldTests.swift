import Testing
@testable import AetherEngine

/// AE#1053: the software fold finds each stream's seams on that stream's own timestamps. The read
/// orders below are the shape of an MPEG-TS splice, where the two streams cross a seam at different
/// bytes, so a packet of one stream is read between the other stream's seam and its own.
@Suite("Live timeline fold per stream")
struct LiveTimelineFoldTests {

    private struct Packet {
        let stream: LiveTimelineFold.Stream
        let raw: Double
    }

    /// Video at 30 fps and AC-3 at 32 ms, interleaved by raw time, with `shift` added to every
    /// packet whose raw time sits in `spike`, the way a TS source stamps a short run of packets ahead.
    private static func readOrder(until end: Double, shiftedIn spike: Range<Double>? = nil,
                                  by shift: Double = 0, audioLagSeconds: Double = 0) -> [Packet] {
        var packets: [(order: Double, packet: Packet)] = []
        var t = 0.0
        while t < end {
            packets.append((t, Packet(stream: .video, raw: t)))
            t += 1.0 / 30
        }
        t = 0
        while t < end {
            // A muxer that puts audio ahead of or behind the picture in the byte stream: the read
            // position of an audio packet is its time plus the lag.
            packets.append((t + audioLagSeconds, Packet(stream: .audio, raw: t)))
            t += 0.032
        }
        return packets.sorted { $0.order < $1.order }.map { entry in
            guard let spike, spike.contains(entry.order) else { return entry.packet }
            return Packet(stream: entry.packet.stream, raw: entry.packet.raw + shift)
        }
    }

    /// Folded times per stream, in read order.
    private static func fold(_ packets: [Packet]) -> (video: [Double], audio: [Double], seams: [LiveTimelineFold.Seam]) {
        var fold = LiveTimelineFold()
        var video: [Double] = [], audio: [Double] = [], seams: [LiveTimelineFold.Seam] = []
        for packet in packets {
            if let seam = fold.observe(packet.stream, rawSeconds: packet.raw) { seams.append(seam) }
            let folded = packet.raw - fold.offsetSeconds(for: packet.stream)
            if packet.stream == .video { video.append(folded) } else { audio.append(folded) }
        }
        return (video, audio, seams)
    }

    private static func largestStep(_ times: [Double]) -> Double {
        zip(times, times.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    @Test("a +347 s spike whose audio edges straddle the video edges keeps both streams on the clock",
          arguments: [-0.3, 0, 0.3])
    func spikeStraddlingTheVideoSeam(audioLag: Double) {
        // The reporter's shape: a run of packets stamped 347 s ahead, then the original timeline.
        let packets = Self.readOrder(until: 20, shiftedIn: 10..<10.7, by: 347, audioLagSeconds: audioLag)
        let result = Self.fold(packets)
        #expect(Self.largestStep(result.video) < 0.1)
        #expect(Self.largestStep(result.audio) < 0.1)
        #expect(result.audio.allSatisfy { $0 > -0.1 && $0 < 20.1 })
        #expect(result.seams.count == 4)
    }

    @Test("a splice that moves both streams by the same amount keeps them in sync to the tick")
    func spliceAdoptsTheOtherStreamsOffset() {
        // A real seam (no return): every packet from 10 s on is 5000 s later on the raw timeline.
        let packets = Self.readOrder(until: 20, shiftedIn: 10..<100, by: 5000, audioLagSeconds: 0.25)
        var fold = LiveTimelineFold()
        for packet in packets { fold.observe(packet.stream, rawSeconds: packet.raw) }
        #expect(fold.offsetSeconds(for: .video) == fold.offsetSeconds(for: .audio))
        let result = Self.fold(packets)
        #expect(result.seams.filter(\.adopted).count == 1)
    }

    @Test("a stream that starts after the other has folded joins it on the folded axis")
    func lateStreamStartsOnTheFoldedAxis() {
        var fold = LiveTimelineFold()
        fold.observe(.video, rawSeconds: 1.0)
        fold.observe(.video, rawSeconds: 1.033)
        fold.observe(.video, rawSeconds: 900.0)
        let offset = fold.offsetSeconds(for: .video)
        #expect(offset > 898 && offset < 899)
        fold.observe(.audio, rawSeconds: 900.01)
        #expect(fold.offsetSeconds(for: .audio) == offset)
    }

    @Test("jumps under the threshold are content, not seams")
    func smallJumpsAreLeftAlone() {
        var fold = LiveTimelineFold()
        fold.observe(.audio, rawSeconds: 10)
        #expect(fold.observe(.audio, rawSeconds: 19.9) == nil)
        #expect(fold.observe(.audio, rawSeconds: 15) == nil)
        #expect(fold.offsetSeconds(for: .audio) == 0)
    }
}
