import Foundation
import CoreMedia
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

/// Audio track selection + audio engine routing helpers, extracted
/// from the main AetherEngine class to keep the core file focused on
/// the load / demux / playback flow. Visibility is internal: the
/// AetherEngine module is the only consumer.
extension AetherEngine {

    public func selectAudioTrack(index: Int) {
        let streamIndex = Int32(index)
        guard streamIndex != activeAudioStreamIndex,
              let stream = demuxer.stream(at: streamIndex) else { return }

        let codecId = stream.pointee.codecpar?.pointee.codec_id
        let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
        let streamIsAtmos = isEAC3 && (stream.pointee.codecpar?.pointee.profile == 30)
        let willBeAtmos = streamIsAtmos && canPassthroughAtmos()

        // Hot-swap fast path for PCM → PCM track changes. A user
        // flipping German AC3 to English AC3 (the common case) does
        // not need a demuxer seek, a video pipeline flush, or a
        // display-layer detach, the master clock keeps ticking, the
        // video pipeline stays untouched, the demuxer keeps reading
        // sequentially. Old-stream audio packets fall off as soon as
        // we flip activeAudioStreamIndex (the demux dispatch checks
        // stream_index == activeAudioStreamIndex), and new-stream
        // packets arrive within a couple hundred milliseconds and
        // route to the freshly opened decoder.
        //
        // Without this, the seek + skip-threshold + display-layer
        // re-attach sequence below produces a visible video burst
        // whenever the user just wants to swap audio languages.
        //
        // Cross-mode swaps (PCM↔Atmos) and Atmos↔Atmos both need the
        // controlTimebase / synchronizer handoff and stay on the
        // original reset path below.
        if audioMode == .pcm && !willBeAtmos {
            audioDecoder.flush()
            audioDecoder.close()
            activeAudioStreamIndex = streamIndex
            do {
                try audioDecoder.open(stream: stream)
                // Drain any old-language frames that were queued
                // ahead of the renderer so the language switch is
                // audible immediately. Crucially, `flushRenderer-
                // KeepingClock` does NOT reset `_isStarted`, so the
                // synchronizer keeps the master clock running and
                // the video display layer keeps presenting frames
                // without a re-attach.
                audioOutput.flushRendererKeepingClock()
            } catch {
                #if DEBUG
                print("[AetherEngine] selectAudioTrack hot-swap failed: \(error), disabling audio")
                #endif
                audioAvailable = false
            }
            #if os(iOS) || os(tvOS)
            let contentCh = Int(stream.pointee.codecpar?.pointee.ch_layout.nb_channels ?? 2)
            let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
            let preferred = max(2, min(contentCh, maxCh))
            try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
            #endif
            return
        }

        // Capture current time BEFORE tearing down the engine
        let seekSeconds = currentTime
        let seekTime = CMTimeMakeWithSeconds(seekSeconds, preferredTimescale: 90000)

        // Tear down current audio engine
        tearDownCurrentAudioEngine()
        activeAudioStreamIndex = streamIndex

        // Flush video pipeline (like a seek), the demux seek below
        // resets both video and audio position
        if usingSoftwareDecode {
            softwareDecoder.flush()
        } else {
            videoDecoder.flush()
        }
        videoRenderer.flush()

        // Seek the demuxer to the current position so the new track
        // starts from the right place in the stream
        demuxer.seek(to: seekSeconds)
        videoRenderer.setSkipThreshold(seekTime)
        if usingSoftwareDecode {
            softwareDecoder.skipUntilPTS = seekTime
        }
        atmosAudioSkipPTS = seekSeconds

        // Open new audio engine for the selected track.
        // Gate the Atmos path on the output route's passthrough capability
        //, a BT speaker can't accept the HLS multichannel stream.
        let isAtmos = willBeAtmos
        #if DEBUG
        if streamIsAtmos && !isAtmos {
            print("[AetherEngine] selectAudioTrack: Atmos stream on non-passthrough route → PCM")
        }
        #endif

        if isAtmos {
            do {
                let engine = HLSAudioEngine()
                engine.onPlaybackFailed = { [weak self] in
                    Task { @MainActor in
                        guard let self,
                              let s = self.demuxer.stream(at: streamIndex) else { return }
                        self.fallbackToPCMAudio(stream: s)
                    }
                }
                engine.onWillStartTimebase = { [weak self] skipPTS in
                    guard let self else { return }
                    if self.usingSoftwareDecode {
                        self.softwareDecoder.flush()
                        self.softwareDecoder.skipUntilPTS = skipPTS
                    } else {
                        self.videoDecoder.flush()
                    }
                    self.videoRenderer.flush()
                    self.videoRenderer.setSkipThreshold(skipPTS)
                }
                try engine.prepare(stream: stream, startTime: seekTime)
                hlsAudioEngine = engine
                audioMode = .atmos
                // Full handoff sequence:
                //   1. detach from synchronizer (sync wait)
                //   2. recreate the display layer, a layer that has been
                //      attached to a synchronizer and is then handed a
                //      controlTimebase enters Apple's "undefined behavior"
                //      regime; on Marty Supreme this manifested as audio
                //      lag that survived every snap, and after a scrub the
                //      layer fast-forwarded through queued frames. F1
                //      (Atmos-only, layer never sees the synchronizer)
                //      didn't have either symptom, strong signal that
                //      the layer's history is the cause. Recreating it
                //      gives controlTimebase a fresh canvas.
                //   3. flush + assign the new timebase on the new layer.
                audioOutput.detachVideoLayer(videoRenderer.displayLayer)
                videoRenderer.recreateDisplayLayer()
                videoRenderer.displayLayer.controlTimebase = engine.videoTimebase
            } catch {
                fallbackToPCMAudio(stream: stream)
                audioOutput.start(at: seekTime)
            }
        } else {
            do {
                try audioDecoder.open(stream: stream)
                audioMode = .pcm
                // Sanitise the display layer before re-attaching to the
                // synchronizer. After an Atmos→PCM teardown the layer can
                // be left in `.failed` (the -12080 we see in logs); a
                // plain attach without flush gives the synchronizer a
                // dead layer → video freeze. Mirror the inverse handoff
                // sequence used in load() and the PCM→Atmos branch above.
                videoRenderer.flushDisplayLayer()
                audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                audioOutput.start(at: seekTime)
            } catch {
                #if DEBUG
                print("[AetherEngine] audioDecoder.open failed in selectAudioTrack: \(error), disabling audio")
                #endif
                audioAvailable = false
                audioMode = .pcm
            }
        }

        #if os(iOS) || os(tvOS)
        let contentCh = Int(stream.pointee.codecpar?.pointee.ch_layout.nb_channels ?? 2)
        let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        let preferred = max(2, min(contentCh, maxCh))
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
        #endif
    }

    // MARK: - Audio Engine Helpers

    /// True if the current audio output route can accept a Dolby Atmos
    /// bitstream (EAC3 + JOC wrapped as Dolby MAT 2.0 by AVPlayer).
    ///
    /// Bluetooth routes advertise only compressed stereo codecs (A2DP
    /// SBC/AAC), AVPlayer refuses the multichannel HLS stream there
    /// and stalls forever with silent audio and no video. Routes that
    /// can't deliver at least 5.1 also make the Atmos path pointless
    /// even when it technically works, we'd end up asking the system
    /// to downmix what we could downmix ourselves cheaper.
    func canPassthroughAtmos() -> Bool {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        for output in session.currentRoute.outputs {
            switch output.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return false
            default:
                continue
            }
        }
        return session.maximumOutputNumberOfChannels >= 6
        #else
        return false
        #endif
    }

    /// Tear down whichever audio engine is currently active.
    func tearDownCurrentAudioEngine() {
        let previousMode = audioMode

        // Flip the mode first so the atmos drain loops see audioMode != .atmos
        // on their next iteration check and exit cleanly. Without this they
        // can keep decoding into a flushed VideoDecoder during the switch
        // (-12909 kVTVideoDecoderBadDataErr in the logs).
        if previousMode == .atmos {
            audioMode = .pcm
        }

        switch previousMode {
        case .atmos:
            // Empty buffers so the drains terminate at the next emptiness
            // check; then sync-barrier the queues so any in-flight iteration
            // (decoder.decode + renderer back-pressure wait) is fully done
            // before we touch the video pipeline below.
            clearAtmosBuffers()
            atmosVideoQueue.sync { /* barrier */ }
            atmosAudioQueue.sync { /* barrier */ }

            hlsAudioEngine?.stop()
            hlsAudioEngine = nil
            videoRenderer.displayLayer.controlTimebase = nil
            // Layer was driven by controlTimebase, not the synchronizer,
            // no detachVideoLayer here. Calling it for an unattached layer
            // makes synchronizer.removeRenderer's completion never fire,
            // and the semaphore wait blocks the main thread for 1 second.
        case .pcm:
            audioDecoder.flush()
            audioDecoder.close()
            audioOutput.flush()
            audioOutput.detachVideoLayer(videoRenderer.displayLayer)
        }
    }

    /// Fall back from HLS Atmos engine to FFmpeg PCM decode.
    /// Called when AVPlayer fails to play the HLS stream.
    func fallbackToPCMAudio(stream: UnsafeMutablePointer<AVStream>) {
        #if DEBUG
        print("[AetherEngine] Falling back from Atmos to FFmpeg PCM decode")
        #endif

        // Tear down HLS engine
        hlsAudioEngine?.stop()
        hlsAudioEngine = nil
        videoRenderer.displayLayer.controlTimebase = nil

        // Switch to FFmpeg PCM decode
        do {
            try audioDecoder.open(stream: stream)
            audioMode = .pcm
        } catch {
            #if DEBUG
            print("[AetherEngine] PCM fallback failed too: \(error), disabling audio")
            #endif
            audioAvailable = false
            audioMode = .pcm
            return
        }

        // Re-attach display layer to synchronizer
        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
        let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
        audioOutput.start(at: seekTime)
    }
}
