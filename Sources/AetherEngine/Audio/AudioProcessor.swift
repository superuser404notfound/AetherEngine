import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Night-mode style dynamic range compression and dialog-frequency
/// EQ boost, applied between the FFmpeg PCM decode and the
/// AVSampleBufferAudioRenderer.
///
/// Skipped entirely for the Atmos passthrough path — that one bypasses
/// `AudioOutput.enqueue` and goes through `HLSAudioEngine` + AVPlayer
/// as an opaque bitstream, so there is no PCM to process.
public enum AudioProcessingMode: String, Sendable, Codable, CaseIterable {
    /// Bypass. No DSP added.
    case off
    /// Mild compression — keeps dynamics, just trims peaks. Good for
    /// late-night TV with the volume turned down.
    case light
    /// Aggressive compression — flattens action peaks, lifts quiet
    /// dialog. Best for very low listening volumes.
    case strong
}

final class AudioProcessor: @unchecked Sendable {

    // MARK: - Public knobs

    var mode: AudioProcessingMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set {
            lock.lock(); _mode = newValue; lock.unlock()
            applyDynamicsParameters()
        }
    }

    var dialogBoost: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _dialogBoost }
        set {
            lock.lock(); _dialogBoost = newValue; lock.unlock()
            applyEQParameters()
        }
    }

    /// Caller may skip the processor entirely when both knobs are off.
    var isBypassed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _mode == .off && !_dialogBoost
    }

    // MARK: - State

    private let lock = NSLock()
    private var _mode: AudioProcessingMode = .off
    private var _dialogBoost = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var dynamics: AVAudioUnitEffect?
    private var eq: AVAudioUnitEQ?
    private var processingFormat: AVAudioFormat?
    private var maxFrameCount: AVAudioFrameCount = 4096
    private var outputBuffer: AVAudioPCMBuffer?

    // MARK: - Public API

    /// Process one decoded PCM sample buffer. Returns the input
    /// unchanged when bypassed or when conversion fails (so audio
    /// keeps playing — DSP is best-effort, never an audio drop-out).
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        if isBypassed { return sampleBuffer }
        guard let processed = runEngine(on: sampleBuffer) else {
            return sampleBuffer
        }
        return processed
    }

    /// Reset the engine. Call on seek/flush/stop. Cheap if engine is
    /// not yet configured.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        teardownEngineLocked()
    }

    // MARK: - Engine lifecycle

    private func runEngine(on sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Lazy / re-init when sample rate or channel count changes
        // (track switch, mid-stream layout shift).
        let needsReinit: Bool = {
            guard let pf = processingFormat else { return true }
            return pf.sampleRate != asbd.mSampleRate
                || pf.channelCount != AVAudioChannelCount(asbd.mChannelsPerFrame)
                || frameCount > maxFrameCount
        }()

        if needsReinit {
            do {
                try configureEngine(sampleRate: asbd.mSampleRate,
                                    channelCount: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                    maxFrameCount: max(frameCount, 4096))
            } catch {
                return nil
            }
        }

        guard let engine, let playerNode, let format = processingFormat,
              let outBuf = outputBuffer else { return nil }

        // Convert input (interleaved Float32 from FFmpeg) into a
        // non-interleaved PCM buffer the engine can consume.
        guard let inputBuffer = makePCMBuffer(from: sampleBuffer,
                                              format: format,
                                              frameCount: frameCount) else {
            return nil
        }

        playerNode.scheduleBuffer(inputBuffer, completionHandler: nil)

        outBuf.frameLength = 0
        let status = (try? engine.renderOffline(frameCount, to: outBuf)) ?? .error
        guard status == .success, outBuf.frameLength == frameCount else {
            return nil
        }

        return makeSampleBuffer(from: outBuf, referenceBuffer: sampleBuffer)
    }

    private func configureEngine(sampleRate: Double,
                                 channelCount: AVAudioChannelCount,
                                 maxFrameCount: AVAudioFrameCount) throws {
        lock.lock(); defer { lock.unlock() }
        teardownEngineLocked()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: channelCount,
                                         interleaved: false) else {
            throw NSError(domain: "AudioProcessor", code: 1)
        }

        let newEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        newEngine.attach(player)

        // Apple's built-in dynamics processor — same algorithm Logic
        // Pro's Compressor exposes, configured for broadcast-style
        // late-night listening.
        let dynDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let dyn = AVAudioUnitEffect(audioComponentDescription: dynDesc)
        newEngine.attach(dyn)

        // 1-band parametric EQ centred at 2.5 kHz — speech
        // intelligibility band. Lifted ~4 dB when dialog boost is on,
        // bypassed otherwise.
        let parametricEQ = AVAudioUnitEQ(numberOfBands: 1)
        let band = parametricEQ.bands[0]
        band.filterType = .parametric
        band.frequency = 2500
        band.bandwidth = 1.5
        band.gain = 4
        band.bypass = !_dialogBoost
        newEngine.attach(parametricEQ)

        newEngine.connect(player, to: dyn, format: format)
        newEngine.connect(dyn, to: parametricEQ, format: format)
        newEngine.connect(parametricEQ, to: newEngine.mainMixerNode, format: format)

        try newEngine.enableManualRenderingMode(.realtime,
                                                format: format,
                                                maximumFrameCount: maxFrameCount)
        try newEngine.start()
        player.play()

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: maxFrameCount) else {
            throw NSError(domain: "AudioProcessor", code: 2)
        }

        engine = newEngine
        playerNode = player
        dynamics = dyn
        eq = parametricEQ
        processingFormat = format
        self.maxFrameCount = maxFrameCount
        outputBuffer = outBuf

        applyDynamicsParametersLocked()
        applyEQParametersLocked()
    }

    private func teardownEngineLocked() {
        playerNode?.stop()
        engine?.stop()
        engine?.disableManualRenderingMode()
        engine = nil
        playerNode = nil
        dynamics = nil
        eq = nil
        processingFormat = nil
        outputBuffer = nil
    }

    // MARK: - Parameter application

    private func applyDynamicsParameters() {
        lock.lock(); defer { lock.unlock() }
        applyDynamicsParametersLocked()
    }

    private func applyDynamicsParametersLocked() {
        guard let unit = dynamics?.audioUnit else { return }

        // Threshold / makeup gain pairs picked for "TV at 11 PM" usage.
        // Light: noticeable but transparent. Strong: aggressive flatten.
        let threshold: Float
        let makeup: Float
        let attack: Float
        let release: Float

        switch _mode {
        case .off:
            threshold = 0
            makeup = 0
            attack = 0.01
            release = 0.1
        case .light:
            threshold = -20
            makeup = 6
            attack = 0.005
            release = 0.15
        case .strong:
            threshold = -32
            makeup = 10
            attack = 0.002
            release = 0.25
        }

        AudioUnitSetParameter(unit,
                              AudioUnitParameterID(kDynamicsProcessorParam_Threshold),
                              kAudioUnitScope_Global, 0, threshold, 0)
        AudioUnitSetParameter(unit,
                              AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom),
                              kAudioUnitScope_Global, 0, 5, 0)
        AudioUnitSetParameter(unit,
                              AudioUnitParameterID(kDynamicsProcessorParam_AttackTime),
                              kAudioUnitScope_Global, 0, attack, 0)
        AudioUnitSetParameter(unit,
                              AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime),
                              kAudioUnitScope_Global, 0, release, 0)
        AudioUnitSetParameter(unit,
                              AudioUnitParameterID(kDynamicsProcessorParam_OverallGain),
                              kAudioUnitScope_Global, 0, makeup, 0)
    }

    private func applyEQParameters() {
        lock.lock(); defer { lock.unlock() }
        applyEQParametersLocked()
    }

    private func applyEQParametersLocked() {
        eq?.bands[0].bypass = !_dialogBoost
    }

    // MARK: - Buffer conversion

    /// Build a non-interleaved AVAudioPCMBuffer from the FFmpeg
    /// interleaved Float32 input.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                               format: AVAudioFormat,
                               frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let channelCount = Int(format.channelCount)
        let totalBytes = Int(frameCount) * channelCount * MemoryLayout<Float>.size

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        var totalLength = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == noErr, let raw = dataPointer, totalLength >= totalBytes else {
            return nil
        }

        let interleaved = raw.withMemoryRebound(to: Float.self,
                                                capacity: Int(frameCount) * channelCount) { $0 }
        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(frameCount)

        for c in 0..<channelCount {
            let dst = channelData[c]
            for i in 0..<frames {
                dst[i] = interleaved[i * channelCount + c]
            }
        }

        return buffer
    }

    /// Re-pack a non-interleaved processed buffer into a CMSampleBuffer
    /// that matches the input's format description and timing — A/V
    /// sync depends on the PTS surviving the round-trip unchanged.
    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer,
                                  referenceBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(pcmBuffer.format.channelCount)
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        let totalBytes = frameCount * bytesPerFrame

        guard let channelData = pcmBuffer.floatChannelData else { return nil }

        // Re-interleave into a contiguous block.
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * channelCount)
        defer { interleaved.deallocate() }

        for c in 0..<channelCount {
            let src = channelData[c]
            for i in 0..<frameCount {
                interleaved[i * channelCount + c] = src[i]
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == noErr, let bb = blockBuffer else { return nil }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: interleaved,
            blockBuffer: bb,
            offsetIntoDestination: 0,
            dataLength: totalBytes
        )
        guard copyStatus == noErr else { return nil }

        guard let formatDesc = CMSampleBufferGetFormatDescription(referenceBuffer) else {
            return nil
        }

        var timingInfo = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(referenceBuffer,
                                                             at: 0,
                                                             timingInfoOut: &timingInfo)
        guard timingStatus == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }
}
