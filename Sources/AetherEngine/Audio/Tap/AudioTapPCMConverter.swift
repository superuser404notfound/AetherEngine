import Foundation
// @preconcurrency: AVAudioConverterInputBlock is @Sendable in the SDK; the input closure here
// captures the per-call inBuf/fed locals, which is safe (converter.convert is synchronous).
@preconcurrency import AVFAudio
import CoreMedia

/// #95 SW-path converter: AudioDecoder's interleaved Float32 CMSampleBuffers (source rate,
/// N channels, source-axis PTS) to tap-format AVAudioPCMBuffers. AVAudioConverter handles
/// downmix + resample; PTS continuity is tracked here (>250 ms jump = discontinuity).
final class AudioTapPCMConverter: @unchecked Sendable {

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var expectedNextPTS: Double?

    func convert(_ sample: CMSampleBuffer) -> [AudioTapBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return [] }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return [] }

        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: asbd.mSampleRate,
                                     channels: asbd.mChannelsPerFrame,
                                     interleaved: true)!
        if converter == nil || inputFormat?.sampleRate != inFormat.sampleRate
            || inputFormat?.channelCount != inFormat.channelCount {
            converter = AVAudioConverter(from: inFormat, to: AetherEngine.audioTapFormat)
            // Streaming tap: no SRC priming, else each buffer's leading filter fill is withheld
            // and per-call output runs short (latency the tap consumers cannot use anyway).
            converter?.primeMethod = .none
            inputFormat = inFormat
        }
        guard let converter else { return [] }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                           frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(frames)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let byteCount = frames * Int(asbd.mBytesPerFrame)
        let dst = inBuf.audioBufferList.pointee.mBuffers.mData!
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                         destination: dst) == kCMBlockBufferNoErr else { return [] }

        let ratio = AetherEngine.audioTapFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up) + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                            frameCapacity: outCapacity) else { return [] }
        // The converter invokes this input block synchronously on the calling thread,
        // so the one-shot `fed` flag is never touched concurrently; opt out of the check.
        nonisolated(unsafe) var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard convError == nil, outBuf.frameLength > 0 else { return [] }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let discontinuity: Bool
        if let expected = expectedNextPTS, abs(pts - expected) <= 0.25 {
            discontinuity = false
        } else {
            discontinuity = true
        }
        expectedNextPTS = pts + Double(frames) / inFormat.sampleRate
        return [AudioTapBuffer(buffer: outBuf, sourceTime: pts, discontinuity: discontinuity)]
    }
}
