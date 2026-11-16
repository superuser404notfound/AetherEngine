import Foundation
import AVFoundation
import MediaToolbox
import os

/// Sodalite#242: runs `NormalizationGainProcessor` inside an `AVPlayerItem` through an
/// `MTAudioProcessingTap`, so `AudioAVPlayerHost` can lift a quiet track instead of stopping at
/// `AVPlayer.volume`'s 1.0.
///
/// This only works because the native audio-only host hands AVPlayer the source file itself: a
/// progressive asset vends the `AVAssetTrack` an `AVAudioMix` binds to. An HLS-streamed asset does
/// not (see `AetherEngine+AudioDelay.swift`), so the video paths cannot use it.
///
/// The tap's C callbacks reach the processor through the tap storage. `Context` is retained by the
/// tap and released in its finalize callback, and the host keeps its own reference to read the
/// figures after the tap is gone.
final class NormalizationTap: @unchecked Sendable {

    /// What the tap found when AVPlayer prepared it.
    enum Preparation: Equatable, Sendable {
        /// Not prepared yet (AVPlayer prepares it once the item starts rendering).
        case pending
        /// Running on Float32 PCM.
        case running(sampleRate: Double, channels: Int)
        /// AVPlayer handed it a format the processor does not read; audio passes untouched.
        case unsupported(String)
    }

    final class Context: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        struct State {
            var gainDB: Double
            var processor: NormalizationGainProcessor?
            var preparation: Preparation = .pending
            var interleaved = false
            /// Figures of processors an earlier preparation built (AVPlayer re-prepares on a route change).
            var carried = NormalizationGainProcessor.Statistics()
            init(gainDB: Double = 0) { self.gainDB = gainDB }
        }

        init(gainDB: Double) {
            lock.withLock { $0.gainDB = gainDB }
        }

        var preparation: Preparation { lock.withLock { $0.preparation } }
        var statistics: NormalizationGainProcessor.Statistics? {
            lock.withLock { state in
                guard let current = state.processor?.statistics else {
                    return state.carried.frames > 0 ? state.carried : nil
                }
                return state.carried.merged(with: current)
            }
        }
        var gainDB: Double { lock.withLock { $0.gainDB } }

        func setGainDB(_ db: Double) {
            let processor = lock.withLock { state -> NormalizationGainProcessor? in
                state.gainDB = db
                return state.processor
            }
            processor?.setGainDB(db)
        }

        fileprivate func prepare(format: AudioStreamBasicDescription) {
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let channels = Int(format.mChannelsPerFrame)
            lock.withLock { state in
                guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32,
                      channels > 0 else {
                    if let previous = state.processor?.statistics { state.carried = state.carried.merged(with: previous) }
                    state.processor = nil
                    state.preparation = .unsupported("format=\(format.mFormatID) flags=\(format.mFormatFlags) "
                                                     + "bits=\(format.mBitsPerChannel) ch=\(channels)")
                    return
                }
                if let previous = state.processor?.statistics { state.carried = state.carried.merged(with: previous) }
                let processor = NormalizationGainProcessor(gainDB: state.gainDB, sampleRate: format.mSampleRate,
                                                           channels: channels)
                state.processor = processor
                state.interleaved = !nonInterleaved
                state.preparation = .running(sampleRate: format.mSampleRate, channels: channels)
            }
        }

        fileprivate func unprepare() {
            // Keep the processor: its statistics are what the host reads after the track.
        }

        /// The render-thread view: the processor and layout, or nil while preparing.
        fileprivate func renderState() -> (NormalizationGainProcessor, Bool)? {
            lock.withLockIfAvailable { state in
                state.processor.map { ($0, state.interleaved) }
            } ?? nil
        }
    }

    let context: Context
    let tap: MTAudioProcessingTap

    /// Builds the tap, or nil if MediaToolbox refuses one.
    init?(gainDB: Double) {
        let context = Context(gainDB: gainDB)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().unprepare()
            },
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil,
                                                                frameCountOut)
                guard status == noErr else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                guard let (processor, interleaved) = context.renderState() else { return }
                NormalizationTap.render(processor: processor, interleaved: interleaved,
                                        bufferList: bufferList, frames: Int(frameCountOut.pointee))
            })
        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PreEffects, &tapOut)
        guard status == noErr, let tapOut else {
            // The tap never took the context, so the retain above is ours to give back.
            Unmanaged<Context>.passUnretained(context).release()
            return nil
        }
        self.context = context
        self.tap = tapOut
    }

    /// An audio mix that runs this tap on `track`.
    func audioMix(for track: AVAssetTrack) -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func render(processor: NormalizationGainProcessor, interleaved: Bool,
                               bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if interleaved {
            guard buffers.count == 1, let data = buffers[0].mData else { return }
            let available = Int(buffers[0].mDataByteSize) / (4 * processor.channels)
            processor.process(interleaved: data.assumingMemoryBound(to: Float.self), frames: min(frames, available))
        } else {
            guard buffers.count == processor.channels else { return }
            var planes: [UnsafeMutablePointer<Float>] = []
            planes.reserveCapacity(buffers.count)
            var available = frames
            for buffer in buffers {
                guard let data = buffer.mData else { return }
                available = min(available, Int(buffer.mDataByteSize) / 4)
                planes.append(data.assumingMemoryBound(to: Float.self))
            }
            processor.process(planes: planes, frames: available)
        }
    }
}
