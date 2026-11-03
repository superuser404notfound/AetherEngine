import Foundation
// @preconcurrency: AVAudioConverterInputBlock is @Sendable in the SDK; the input closure here
// captures the per-call inBuf/fed locals, which is safe (converter.convert is synchronous).
@preconcurrency import AVFAudio
import AudioToolbox
import CoreMedia

/// #95 SW-path converter: AudioDecoder's interleaved Float32 CMSampleBuffers (source rate,
/// N channels, source-axis PTS) to tap-format AVAudioPCMBuffers. AVAudioConverter handles
/// downmix + resample; PTS continuity is tracked here (>250 ms jump = discontinuity).
final class AudioTapPCMConverter: @unchecked Sendable {

    /// How the source channels reach the converter's input.
    private enum InputShaping {
        /// The converter mixes the source layout itself.
        case none
        /// Every channel averaged by hand (see `converterMixesDown`).
        case fold
        /// One channel copied out: the centre on a `.dialogue` tap (#908).
        case extract(Int)
    }

    private let lock = NSLock()
    private let requestedChannels: AudioTapChannels
    private var converter: AVAudioConverter?
    /// Format of the incoming sample buffers, i.e. what the rebuild check compares against.
    private var sourceFormat: AVAudioFormat?
    /// Format the converter actually takes: `sourceFormat`, or mono at the source rate when the
    /// channels have to be folded or picked by hand first.
    private var converterInputFormat: AVAudioFormat?
    private var shaping = InputShaping.none
    private var expectedNextPTS: Double?
    private var didLogUnsupportedInput = false

    init(channels: AudioTapChannels = .downmix) {
        requestedChannels = channels
    }

    func convert(_ sample: CMSampleBuffer) -> [AudioTapBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return [] }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return [] }

        guard let srcFormat = makeSourceFormat(fmtDesc, asbd) else { return [] }
        if converter == nil || sourceFormat != srcFormat {
            rebuildConverter(for: srcFormat)
            sourceFormat = srcFormat
        }
        guard let converter, let inFormat = converterInputFormat else { return [] }

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        srcBuf.frameLength = AVAudioFrameCount(frames)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let byteCount = frames * Int(asbd.mBytesPerFrame)
        let dst = srcBuf.audioBufferList.pointee.mBuffers.mData!
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                         destination: dst) == kCMBlockBufferNoErr else { return [] }

        let shaped: AVAudioPCMBuffer?
        switch shaping {
        case .none: shaped = srcBuf
        case .fold: shaped = toMono(srcBuf, as: inFormat, channel: nil)
        case .extract(let channel): shaped = toMono(srcBuf, as: inFormat, channel: channel)
        }
        guard let inBuf = shaped else { return [] }

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
        let delivered: AudioTapChannels
        if case .extract = shaping { delivered = .dialogue } else { delivered = .downmix }
        return [AudioTapBuffer(buffer: outBuf, sourceTime: pts, discontinuity: discontinuity,
                               channels: delivered)]
    }

    // MARK: - Input format

    /// #400: the source format has to carry the CHANNEL LAYOUT. The channel-count-only
    /// AVAudioFormat initializer returns nil for every count above 2 (measured 3...8), and
    /// AudioDecoder emits the source layout up to 7.1 without downmixing, so a multichannel
    /// track on the software path used to trap here on its first buffer. The decoder already
    /// attaches the layout to its format description, so read it back instead of re-deriving
    /// it, and fall back to the engine's own mapping if a description arrives without one.
    private func makeSourceFormat(_ fmtDesc: CMAudioFormatDescription,
                                  _ asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        // The byte copy in convert() feeds one interleaved buffer, so accept only the packed
        // interleaved Float32 shape AudioDecoder guarantees rather than building a format the
        // copy would then misread.
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBitsPerChannel == 32,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBytesPerFrame == asbd.mChannelsPerFrame * 4 else {
            noteUnsupportedInput("not packed interleaved Float32 (\(asbd.mChannelsPerFrame)ch, "
                                 + "\(asbd.mBitsPerChannel)bit, flags \(asbd.mFormatFlags))")
            return nil
        }

        var layout: AVAudioChannelLayout?
        var layoutSize = 0
        if let acl = CMAudioFormatDescriptionGetChannelLayout(fmtDesc, sizeOut: &layoutSize),
           layoutSize > 0 {
            layout = AVAudioChannelLayout(layout: acl)
        }
        if layout == nil {
            layout = AVAudioChannelLayout(
                layoutTag: audioChannelLayoutTag(for: Int32(asbd.mChannelsPerFrame)))
        }
        guard let layout else {
            noteUnsupportedInput("no channel layout for \(asbd.mChannelsPerFrame)ch")
            return nil
        }

        var asbd = asbd
        guard let format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout) else {
            noteUnsupportedInput("AVAudioFormat rejected \(asbd.mChannelsPerFrame)ch layout "
                                 + "\(layout.layoutTag)")
            return nil
        }
        return format
    }

    private func rebuildConverter(for srcFormat: AVAudioFormat) {
        converter = nil
        converterInputFormat = nil
        shaping = .none

        if requestedChannels == .dialogue, let centre = Self.centreIndex(of: srcFormat),
           let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: srcFormat.sampleRate,
                                    channels: 1, interleaved: true),
           let picked = makeConverter(from: mono) {
            converter = picked
            converterInputFormat = mono
            shaping = .extract(centre)
            return
        }

        if let direct = makeConverter(from: srcFormat), converterMixesDown(direct, from: srcFormat) {
            converter = direct
            converterInputFormat = srcFormat
            return
        }
        // Either no converter for this layout, or one that maps it to silence. Fold the channels
        // ourselves and leave the converter with the sample-rate conversion it does handle.
        guard srcFormat.channelCount > 1,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: srcFormat.sampleRate,
                                       channels: 1, interleaved: true),
              let folded = makeConverter(from: mono) else {
            noteUnsupportedInput("no usable converter from \(srcFormat.channelCount)ch "
                                 + "layout \(srcFormat.channelLayout?.layoutTag ?? 0)")
            return
        }
        converter = folded
        converterInputFormat = mono
        shaping = .fold
        EngineLog.emit("[AudioTap] AVAudioConverter has no mixdown for layout "
                       + "\(srcFormat.channelLayout?.layoutTag ?? 0) "
                       + "(\(srcFormat.channelCount)ch), folding channels in the tap",
                       category: .engine)
    }

    private func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: format, to: AetherEngine.audioTapFormat)
        // Streaming tap: no SRC priming, else each buffer's leading filter fill is withheld
        // and per-call output runs short (latency the tap consumers cannot use anyway).
        converter?.primeMethod = .none
        // Without this the converter does not mix at all, it maps by channel label: a stereo
        // track reached the tap as its left channel alone, 2.1 as silence, and 4.0 up to 7.1 as
        // the centre alone, score and effects gone (measured per channel, #908).
        converter?.downmix = true
        return converter
    }

    /// Whether this converter actually carries signal from `format` to the mono tap format.
    /// Some layouts have no mixdown matrix (measured with `downmix` on: every DiscreteInOrder
    /// layout) and convert to digital silence WITHOUT reporting an error, which
    /// is indistinguishable from a muted source at the consumer. Rather than hard-coding which
    /// layouts Apple currently mixes (a table that would go stale silently), run one buffer of
    /// full-scale samples through the converter and look at what comes out.
    private func converterMixesDown(_ converter: AVAudioConverter,
                                    from format: AVAudioFormat) -> Bool {
        guard format.channelCount > 1 else { return true }
        defer { converter.reset() }

        let frames: AVAudioFrameCount = 4096
        guard let probeIn = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let probeOut = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                              frameCapacity: frames + 64) else { return true }
        probeIn.frameLength = frames
        guard let raw = probeIn.audioBufferList.pointee.mBuffers.mData else { return true }
        let samples = raw.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) * Int(format.channelCount) { samples[i] = 1.0 }

        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: probeOut, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return probeIn
        }
        // No verdict without output: keep the converter rather than guessing it is broken.
        guard error == nil, probeOut.frameLength > 0,
              let out = probeOut.floatChannelData?[0] else { return true }
        for i in 0..<Int(probeOut.frameLength) where out[i] != 0 { return true }
        return false
    }

    /// Index of the centre channel in `format`'s layout, nil when it has none or is mono (#908).
    /// The layout arrives as a tag (AudioDecoder attaches one), so it is expanded to channel
    /// descriptions before the label can be looked up.
    static func centreIndex(of format: AVAudioFormat) -> Int? {
        guard format.channelCount > 1, let layout = format.channelLayout else { return nil }
        let labels = channelLabels(layout.layout)
        guard labels.count == Int(format.channelCount) else { return nil }
        return labels.firstIndex(of: kAudioChannelLabel_Center)
    }

    private static func channelLabels(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptionLabels(layout) }
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap
            specifier = layout.pointee.mChannelBitmap.rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag
            specifier = tag
        }
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(property, specifierSize, &specifier, &size, raw) == noErr
        else { return [] }
        // The expansion keeps the tag and fills in the descriptions (measured on macOS 26).
        return descriptionLabels(UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self)))
    }

    /// `mChannelDescriptions` is a variable-length C array: index off the struct's address, not
    /// off a copy of its first element.
    private static func descriptionLabels(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0,
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
        let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { first[$0].mChannelLabel }
    }

    /// One mono buffer at the source rate: the given channel copied out, or with `channel` nil the
    /// average of all of them. The average is only reached for layouts AVAudioConverter refuses to
    /// mix, so there is no ITU matrix to preserve; the tap consumers need signal, not a reference
    /// downmix. LFE is not excluded: no layout that carries one lands on that path.
    private func toMono(_ buffer: AVAudioPCMBuffer, as monoFormat: AVAudioFormat,
                        channel: Int?) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0,
              let src = buffer.audioBufferList.pointee.mBuffers.mData?
                  .assumingMemoryBound(to: Float.self),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                          frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.audioBufferList.pointee.mBuffers.mData?
                  .assumingMemoryBound(to: Float.self) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        if let channel {
            guard channel < channels else { return nil }
            for frame in 0..<frames { dst[frame] = src[frame * channels + channel] }
            return mono
        }
        let scale = 1.0 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += src[frame * channels + channel] }
            dst[frame] = sum * scale
        }
        return mono
    }

    /// One line per converter, not one per buffer: the sink runs at decode rate. Silence here
    /// would leave the host with a tap that never yields and no reason why.
    private func noteUnsupportedInput(_ reason: String) {
        guard !didLogUnsupportedInput else { return }
        didLogUnsupportedInput = true
        EngineLog.emit("[AudioTap] SW sink cannot convert input, tap stays silent: \(reason)",
                       category: .engine)
    }
}
