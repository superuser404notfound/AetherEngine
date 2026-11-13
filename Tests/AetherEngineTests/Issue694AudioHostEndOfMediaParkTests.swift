import Testing
import Foundation
@testable import AetherEngine

/// #694: the audio-only host reported end of media while its synchronizer kept rate 1, so
/// `currentTime` walked past `duration` without bound. AE#374 closed the same defect on the software
/// host; this pins it on the audio-only one, end to end against a real decode.
@Suite("Audio host parks its clock at end of media (#694)", .offCooperativePool)
struct Issue694AudioHostEndOfMediaParkTests {

    @MainActor
    @Test("after end of media the clock stands still on the last sample, even when the park runs late",
          .timeLimit(.minutes(3)))
    func clockParksOnTheLastSample() async throws {
        let host = AudioPlaybackHost()
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 1)))
        try await host.load(demuxer: demuxer, startPosition: nil, audioSourceStreamIndex: nil)
        defer { host.stop() }
        host.play()

        try await waitFor { host.didReachEnd }
        #expect(host.didReachEnd)
        // What a loaded runner does to the deferred park (CI: parked at 1.149 s): hold the main actor
        // past the queued tail, so the park runs after the clock has walked on.
        usleep(500_000)

        try await waitFor { host.clockRateForTesting == 0 }
        #expect(host.clockRateForTesting == 0)
        #expect(host.rate == 0)

        let first = try #require(host.clockSecondsForTesting)
        try await Task.sleep(nanoseconds: 500_000_000)
        let second = try #require(host.clockSecondsForTesting)
        #expect(abs(second - first) < 0.01)
        #expect(abs(first - 1.0) < 0.1)
    }

    @Test("a park that runs after the clock passed its target puts it back on the target")
    func lateParkLandsOnTheTarget() {
        #expect(SoftwareEndOfMediaClock.parkSeconds(clockSeconds: 1.149, notAfter: 1.0) == 1.0)
        #expect(SoftwareEndOfMediaClock.parkSeconds(clockSeconds: 0.98, notAfter: 1.0) == nil)
        #expect(SoftwareEndOfMediaClock.parkSeconds(clockSeconds: 1.149, notAfter: .infinity) == nil)
        #expect(SoftwareEndOfMediaClock.parkSeconds(clockSeconds: .nan, notAfter: 1.0) == nil)
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000, channels = 2
        let pcm = Data(count: Int(Double(sampleRate) * seconds) * channels * 2)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
