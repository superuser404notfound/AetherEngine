import Foundation
import CoreVideo
import Testing
@testable import AetherEngine

/// Optional regression harness; its required VC-1 fixture is not bundled yet.
/// This is not the default-CI real-decoder coverage needed before this PR is ready.
/// Fixture contract and commands: docs/vc1-paused-resume.md.
@Suite(.serialized)
@MainActor
struct VC1PausedResumeIntegrationTests {
    @Test("a paused cold resume shows the real scene, not a concealed gray reference",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VC1_RESUME_FILE"] != nil),
          .timeLimit(.minutes(3)), arguments: [789.92911257, 796.46233333])
    func realPausedResume(position: Double) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AETHER_VC1_RESUME_FILE"])
        let dem = Demuxer()
        try await BlockingWork.detached {
            try dem.open(url: URL(fileURLWithPath: path))
        }.value
        let renderer = SampleBufferRenderer()
        let host = SoftwarePlaybackHost(renderer: renderer)
        defer { host.stop() }
        try await host.load(demuxer: dem, startPosition: position, audioSourceStreamIndex: 1, initiallyPaused: true)
        host.pause()
        try await waitFor { host.framesEnqueued > 0 && host.displayedFrame() != nil }
        let displayed = host.displayedFrame()
        let buffer = try #require(displayed)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let data = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var low: UInt8 = 255
        var high: UInt8 = 0
        for y in Swift.stride(from: height / 4, to: height * 3 / 4, by: 8) {
            for x in Swift.stride(from: width / 4, to: width * 3 / 4, by: 8) {
                low = min(low, data[y * stride + x]); high = max(high, data[y * stride + x])
            }
        }
        print("VC1 paused target=\(position) clock=\(host.currentTime) frames=\(host.framesEnqueued) luma=\(low)...\(high)")
        // These two known scenes contain a person and a background with contrast. This is a
        // sample-specific assertion, NEVER a production gray/black-frame rejection heuristic.
        #expect(Int(high) - Int(low) > 16)
        #expect(!host.isPlaying)
        #expect(host.rate == 0)
        #expect(abs(host.currentTime - position) <= 1)
        #expect(abs(dem.resolvedSourceStartOrigin - 600) < 0.1)
        let picturePTS = try #require(renderer.newestEnqueuedPtsSeconds)
        #expect(picturePTS >= position + 600 - 1.0 / 90000)
        #expect(picturePTS - (position + 600) <= 1)
    }
}
