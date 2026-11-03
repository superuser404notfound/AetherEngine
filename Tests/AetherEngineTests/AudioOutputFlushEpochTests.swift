import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// Audit DEC-106: both FFmpeg hosts decided "this buffer still belongs to the current position" with a
/// seek-generation read and then called `AudioOutput.enqueue`, so a seek whose renderer flush landed
/// between the two parked a pre-seek buffer in the fresh queue (silence until the clock reached its
/// stamp, and on the software host a false rebuffer). The check has to be made under the lock `flush`
/// takes, against an epoch the flush retires.
@Suite("AudioOutput flush epoch (DEC-106)")
struct AudioOutputFlushEpochTests {

    private func makeBuffer(pts: Double, samples: Int = 1024, sampleRate: Int32 = 48000) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: samples * 4,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: samples * 4,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: sampleRate),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(samples),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    @Test("a buffer decided on before a flush is refused after it")
    func staleBufferIsRefused() throws {
        let output = AudioOutput()
        let buffer = try #require(makeBuffer(pts: 100))
        let captured = output.epoch
        output.flush()
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: captured) == false)
    }

    @Test("a buffer decided on after the flush is accepted")
    func freshBufferIsAccepted() throws {
        let output = AudioOutput()
        output.flush()
        let buffer = try #require(makeBuffer(pts: 100))
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: output.epoch))
    }

    @Test("every flush retires the epoch, and stop counts as one")
    func flushAndStopMoveTheEpoch() {
        let output = AudioOutput()
        let start = output.epoch
        output.flush()
        let afterFlush = output.epoch
        #expect(afterFlush != start)
        output.stop()
        #expect(output.epoch != afterFlush)
    }

    private final class Returned: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func set() { lock.withLock { done = true } }
        var isSet: Bool { lock.withLock { done } }
    }

    private final class BufferBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    /// AE#549's observer takes the output's lock on whatever thread AVFoundation posts from, and `enqueue`
    /// now holds that lock across `renderer.enqueue`. A renderer that posts from inside `enqueue` (the
    /// 27 SDKs move the same condition into the enqueue call itself) would make the feed thread wait on a
    /// lock it already holds, and every later `flush()` / `stop()` / `seekClock()` with it.
    @Test("an automatic-flush notification posted from inside enqueue does not hang the feed",
          .timeLimit(.minutes(3)))
    func automaticFlushPostedInsideEnqueueDoesNotDeadlock() async throws {
        let output = AudioOutput()
        let box = BufferBox(try #require(makeBuffer(pts: 1)))
        output.afterRendererEnqueueForTesting = { [unowned output] in
            NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                            object: output.renderer)
        }
        let returned = Returned()
        let feed = Thread {
            output.enqueue(sampleBuffer: box.buffer)
            returned.set()
        }
        feed.start()

        // A feed thread parked on a lock it holds itself never returns; the time limit reports that.
        try await waitFor { returned.isSet }

        try await waitFor { output.automaticFlushCount == 1 }
        #expect(output.automaticFlushCount == 1, "the flush still happens, serialized with enqueueing")
    }

    @Test("an unconditional enqueue is untouched by the epoch")
    func unconditionalEnqueueStillEnqueues() throws {
        let output = AudioOutput()
        output.flush()
        let buffer = try #require(makeBuffer(pts: 1))
        #expect(output.enqueue(sampleBuffer: buffer))
    }
}
