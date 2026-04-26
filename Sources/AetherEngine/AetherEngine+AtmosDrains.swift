import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Atmos audio + video drain machinery, extracted from the main
/// AetherEngine class. Both drains run on dedicated dispatch queues
/// so the demux thread never blocks on display-layer back-pressure or
/// AVPlayer stalls. The buffers themselves and their locks live as
/// stored properties on the engine class — the methods here simply
/// drive them.
extension AetherEngine {

    /// Clear all buffered atmos packets. Called from seek (non-async safe).
    /// Also resets the drain-active flags — a drain loop that exited
    /// through the `stopRequested` early-return leaves them stuck at
    /// `true`, and the next load()/startAtmosXxxDrain() would be a
    /// no-op → packets pile up in the buffer and nothing ever decodes
    /// (classic "second playback black screen" symptom).
    nonisolated func clearAtmosBuffers() {
        atmosAudioLock.lock()
        atmosAudioBuffer.removeAll()
        atmosAudioDrainActive = false
        atmosAudioLock.unlock()
        atmosVideoLock.lock()
        for pkt in atmosVideoBuffer { av_packet_free_safe(pkt) }
        atmosVideoBuffer.removeAll()
        atmosVideoDrainActive = false
        atmosVideoLock.unlock()
    }

    // MARK: - Atmos Audio Drain

    /// Starts the background drain loop if not already running.
    /// Drains buffered audio packets to the HLS engine on a separate queue,
    /// completely independent of video back-pressure.
    /// `nonisolated` so the demux queue can start it without a main-actor hop.
    nonisolated func startAtmosAudioDrain() {
        atmosAudioLock.lock()
        guard !atmosAudioDrainActive else { atmosAudioLock.unlock(); return }
        atmosAudioDrainActive = true
        atmosAudioLock.unlock()

        atmosAudioQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.atmosAudioLock.lock()
                guard !self.atmosAudioBuffer.isEmpty else {
                    self.atmosAudioDrainActive = false
                    self.atmosAudioLock.unlock()
                    return
                }
                // Bail on track switch — feedAudioData can block up to 10s
                // waiting for AVPlayer to start, which would in turn block
                // tearDownCurrentAudioEngine's sync barrier.
                guard self.audioMode == .atmos else {
                    self.atmosAudioBuffer.removeAll()
                    self.atmosAudioDrainActive = false
                    self.atmosAudioLock.unlock()
                    return
                }
                let packetData = self.atmosAudioBuffer.popFront()
                self.atmosAudioLock.unlock()

                self.hlsAudioEngine?.feedAudioData(packetData)
            }
        }
    }

    // MARK: - Atmos Video Drain

    /// Decodes video packets from the buffer with normal back-pressure.
    /// Runs on its own queue so it doesn't block the demux thread.
    /// `nonisolated` so the demux queue can start it without a main-actor hop.
    nonisolated func startAtmosVideoDrain() {
        atmosVideoLock.lock()
        guard !atmosVideoDrainActive else { atmosVideoLock.unlock(); return }
        atmosVideoDrainActive = true
        atmosVideoLock.unlock()

        atmosVideoQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.atmosVideoLock.lock()
                guard !self.atmosVideoBuffer.isEmpty else {
                    self.atmosVideoDrainActive = false
                    self.atmosVideoLock.unlock()
                    return
                }
                // Audio-track switch flips audioMode to .pcm before tearing
                // down the HLS engine. Bail at every loop entry so we don't
                // race the switch and decode into a flushed VideoDecoder
                // (-12909 in the logs).
                guard self.audioMode == .atmos else {
                    let packet = self.atmosVideoBuffer.popFront()
                    av_packet_free_safe(packet)
                    self.atmosVideoDrainActive = false
                    self.atmosVideoLock.unlock()
                    return
                }
                let packet = self.atmosVideoBuffer.popFront()
                self.atmosVideoLock.unlock()

                // Back-pressure on THIS thread (doesn't affect demux or audio).
                // The audioMode check exits immediately on a track switch —
                // without it the wait can pin a paused-timebase layer forever
                // and block tearDownCurrentAudioEngine's sync barrier.
                while !self.videoRenderer.displayLayer.isReadyForMoreMediaData
                    && !self.stopRequested
                    && self.audioMode == .atmos {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard !self.stopRequested, self.audioMode == .atmos else {
                    av_packet_free_safe(packet)
                    // Clear drainActive on early-exit so the next load() can
                    // start a fresh drain. Forgetting this made the second
                    // playback of the same file show a black screen.
                    self.atmosVideoLock.lock()
                    self.atmosVideoDrainActive = false
                    self.atmosVideoLock.unlock()
                    return
                }

                if self.usingSoftwareDecode {
                    self.softwareDecoder.decode(packet: packet)
                } else {
                    self.videoDecoder.decode(packet: packet)
                }
                av_packet_free_safe(packet)
            }
        }
    }
}
