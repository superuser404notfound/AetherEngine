import AudioToolbox
import Foundation
import AetherLibavutil

/// Renders a multichannel speaker layout to two-channel binaural PCM for headphones, through
/// Apple's `AUSpatialMixer` in its headphone mode (the renderer behind Spatial Audio, here without
/// head tracking). Every input channel becomes a virtual speaker at the position its CoreAudio label
/// names (`kSpatialMixerSourceMode_AmbienceBed`), so the surrounds come from the side and behind and
/// the heights from above, where a plain fold puts all of them inside the head between L and R.
///
/// The result is ordinary stereo. It needs nothing from the output: any wired or Bluetooth
/// headphones carry it, and Bluetooth on Apple platforms is AAC anyway, which codes two channels
/// whatever is in them.
///
/// The mixer is driven offline: `render` pulls it once per slice on the caller's thread, with the
/// input fed from the caller's buffer through the render callback. Measured on macOS 27 with noise
/// bursts per channel of a 7.1.4 bed: the side surrounds reach the far ear 28 samples (0.58 ms)
/// late and 16 dB down, the fronts 11 samples late and 10 dB down, centre arrives on both ears at
/// once, and the whole render adds 5 samples (0.1 ms) of delay, far below anything lip sync can
/// show, so nothing compensates it.
///
/// Not thread safe: the owner serialises every call, as for `AudioShapingGraph`.
final class BinauralRenderer {

    /// Largest slice handed to the mixer per pull; longer inputs are rendered in slices.
    static let maxFramesPerSlice = 4096

    /// Gain on the mixer's output. The mixer renders each virtual speaker at about the level that
    /// speaker had, so a full bed lands several dB above a plain fold of the same content; this
    /// brings decorrelated 5.1 to the loudness of libswresample's stereo fold of it (within 1 dB,
    /// `BinauralRendererTests`). The shaping limiter catches what is left.
    static let outputGainDB: Float = -2

    /// Whether this platform has the mixer at all; false makes binaural fall back to the fold.
    static let isAvailable: Bool = {
        var desc = componentDescription
        return AudioComponentFindNext(nil, &desc) != nil
    }()

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    /// CoreAudio labels for an FFmpeg layout in its sample order, or nil when a channel has no
    /// speaker position the mixer knows (an unknown or ambisonic order, a discrete channel). The
    /// caller then folds to a bed the mixer does know first.
    ///
    /// The back pair is a rear surround only when the layout also has a side pair. On its own it is
    /// the layout's one surround pair (FFmpeg's 5.1, AAC 5.1), which belongs beside the listener, as
    /// `FLACChannelLabels` already treats it.
    static func labels(for layout: UnsafePointer<AVChannelLayout>) -> [AudioChannelLabel]? {
        let count = Int(layout.pointee.nb_channels)
        guard count > 0 else { return nil }
        var resolved = AVChannelLayout()
        defer { av_channel_layout_uninit(&resolved) }
        if layout.pointee.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&resolved, Int32(count))
        } else {
            av_channel_layout_copy(&resolved, layout)
        }
        let channels = (0..<count).map { av_channel_layout_channel_from_index(&resolved, UInt32($0)) }
        let hasSides = channels.contains(AV_CHAN_SIDE_LEFT) || channels.contains(AV_CHAN_SIDE_RIGHT)
        var labels: [AudioChannelLabel] = []
        for channel in channels {
            guard let label = label(for: channel, layoutHasSides: hasSides) else { return nil }
            labels.append(label)
        }
        return labels
    }

    private static func label(for channel: AVChannel, layoutHasSides: Bool) -> AudioChannelLabel? {
        switch channel {
        case AV_CHAN_FRONT_LEFT: return kAudioChannelLabel_Left
        case AV_CHAN_FRONT_RIGHT: return kAudioChannelLabel_Right
        case AV_CHAN_FRONT_CENTER: return kAudioChannelLabel_Center
        case AV_CHAN_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen
        case AV_CHAN_LOW_FREQUENCY_2: return kAudioChannelLabel_LFE2
        case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurround
        case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurround
        case AV_CHAN_BACK_LEFT: return layoutHasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
        case AV_CHAN_BACK_RIGHT: return layoutHasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
        case AV_CHAN_BACK_CENTER: return kAudioChannelLabel_CenterSurround
        case AV_CHAN_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter
        case AV_CHAN_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter
        case AV_CHAN_WIDE_LEFT: return kAudioChannelLabel_LeftWide
        case AV_CHAN_WIDE_RIGHT: return kAudioChannelLabel_RightWide
        case AV_CHAN_TOP_FRONT_LEFT: return kAudioChannelLabel_VerticalHeightLeft
        case AV_CHAN_TOP_FRONT_RIGHT: return kAudioChannelLabel_VerticalHeightRight
        case AV_CHAN_TOP_FRONT_CENTER: return kAudioChannelLabel_VerticalHeightCenter
        case AV_CHAN_TOP_SIDE_LEFT: return kAudioChannelLabel_LeftTopMiddle
        case AV_CHAN_TOP_SIDE_RIGHT: return kAudioChannelLabel_RightTopMiddle
        case AV_CHAN_TOP_BACK_LEFT: return kAudioChannelLabel_LeftTopRear
        case AV_CHAN_TOP_BACK_RIGHT: return kAudioChannelLabel_RightTopRear
        case AV_CHAN_TOP_BACK_CENTER: return kAudioChannelLabel_TopBackCenter
        case AV_CHAN_TOP_CENTER: return kAudioChannelLabel_TopCenterSurround
        default: return nil
        }
    }

    /// How the samples of one `render` call are laid out.
    enum Input {
        /// One buffer, `inputChannels` samples per frame.
        case interleaved(UnsafePointer<Float>)
        /// One buffer per channel, in label order.
        case planar([UnsafePointer<Float>])
    }

    let inputChannels: Int
    let sampleRate: Int32
    private let unit: AudioUnit
    private let gain: Float
    private var input: Input?
    private var inputOffset = 0
    private var sampleTime: Float64 = 0
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let outputList: UnsafeMutableAudioBufferListPointer

    /// nil when the mixer is missing or refuses the format; the owner then folds as before.
    init?(labels: [AudioChannelLabel], sampleRate: Int32) {
        guard !labels.isEmpty, sampleRate > 0 else { return nil }
        var desc = Self.componentDescription
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else { return nil }
        self.unit = unit
        self.inputChannels = labels.count
        self.sampleRate = sampleRate
        self.gain = pow(10, Self.outputGainDB / 20)
        left = .allocate(capacity: Self.maxFramesPerSlice)
        right = .allocate(capacity: Self.maxFramesPerSlice)
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        guard configure(labels: labels) else {
            AudioComponentInstanceDispose(unit)
            left.deallocate(); right.deallocate(); free(outputList.unsafeMutablePointer)
            return nil
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        left.deallocate()
        right.deallocate()
        free(outputList.unsafeMutablePointer)
    }

    private func configure(labels: [AudioChannelLabel]) -> Bool {
        func set<T>(_ id: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: T) -> Bool {
            var v = value
            return AudioUnitSetProperty(unit, id, scope, 0, &v, UInt32(MemoryLayout<T>.size)) == noErr
        }
        func format(_ channels: Int) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        }
        guard set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, UInt32(1)),
              set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, format(labels.count)),
              set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, format(2)),
              setInputLayout(labels),
              set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input,
                  AUSpatialMixerSourceMode.spatialMixerSourceMode_AmbienceBed.rawValue),
              set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input,
                  AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue),
              set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global,
                  AUSpatialMixerOutputType.spatialMixerOutputType_Headphones.rawValue),
              set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, UInt32(Self.maxFramesPerSlice))
        else { return false }
        var stereo = AudioChannelLayout()
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Output, 0,
                                 &stereo, UInt32(MemoryLayout<AudioChannelLayout>.size))
        // No head tracking: the listener's head is the screen's direction, which is what a film wants
        // and what a fixed-output binaural render can promise on any headphones.
        _ = set(kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, UInt32(0))
        // The listener's own HRTF where the system has one (the Spatial Audio ear scan) and lets this
        // process use it; the generic set otherwise.
        _ = set(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global,
                AUSpatialMixerPersonalizedHRTFMode.auto.rawValue)

        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            Unmanaged<BinauralRenderer>.fromOpaque(refCon).takeUnretainedValue().supply(frames: Int(frames), into: ioData)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else { return false }
        return true
    }

    private func setInputLayout(_ labels: [AudioChannelLabel]) -> Bool {
        let size = MemoryLayout<AudioChannelLayout>.size
            + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        memset(raw, 0, size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        for (i, label) in labels.enumerated() { descriptions[i].mChannelLabel = label }
        return AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0,
                                    layout, UInt32(size)) == noErr
    }

    /// Renders `frames` frames into `output`, interleaved stereo (2 × `frames` floats).
    func render(_ input: Input, frames: Int, into output: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frames {
            let slice = min(Self.maxFramesPerSlice, frames - done)
            self.input = input
            inputOffset = done
            outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(slice * 4), mData: left)
            outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(slice * 4), mData: right)
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mFlags = .sampleTimeValid
            stamp.mSampleTime = sampleTime
            let status = AudioUnitRender(unit, &flags, &stamp, 0, UInt32(slice), outputList.unsafeMutablePointer)
            sampleTime += Float64(slice)
            let out = output + done * 2
            if status == noErr {
                for f in 0..<slice {
                    out[f * 2] = left[f] * gain
                    out[f * 2 + 1] = right[f] * gain
                }
            } else {
                out.update(repeating: 0, count: slice * 2)
            }
            done += slice
        }
        self.input = nil
    }

    /// Drops the mixer's history (its HRTF filter state), for a seek.
    func reset() {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
        sampleTime = 0
    }

    private func supply(frames: Int, into ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return kAudio_ParamError }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            switch input {
            case .interleaved(let base)?:
                let stride = inputChannels
                var src = base + inputOffset * stride + channel
                for f in 0..<frames { data[f] = src.pointee; if f + 1 < frames { src += stride } }
            case .planar(let planes)? where channel < planes.count:
                data.update(from: planes[channel] + inputOffset, count: frames)
            default:
                data.update(repeating: 0, count: frames)
            }
        }
        return noErr
    }
}
