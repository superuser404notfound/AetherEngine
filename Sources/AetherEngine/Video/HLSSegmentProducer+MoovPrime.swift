import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

// AE#222 audio moov prime: the read-only search for one audio frame on the .muxerFailed exit.
extension HLSSegmentProducer {
    /// AE#222 prime scan: read forward from wherever the pump stopped until the muxed audio stream yields one
    /// packet, and copy its bytes. That single frame is all movenc needs to build the real `dec3` / `dac3` /
    /// `dmlp` sample entry, so the rebuilt session keeps its stream-copy (Atmos included) instead of bridging.
    ///
    /// Scoped to single-demuxer stream-copy audio: a bridged session's muxed frames come from the encoder, not
    /// the source, and feeding the bridge here would consume the very encoder state a restart depends on (#99
    /// root cause B). Bounded so a source whose audio never arrives (or arrives absurdly late) gives up and
    /// leaves the host's fallbacks in charge instead of stalling the session on an unbounded read.
    func scanForAudioMoovPrimeFrame() -> [UInt8]? {
        guard let audio = audioConfig, audio.bridge == nil, sideAudioDemuxer == nil else { return nil }
        // AE#366: a previous producer of this session already looked everywhere it can look. Paying
        // the scan plus the hunt again on every revive attempt buys the same answer for a few hundred
        // MiB of reads, which on a remote source is minutes of black screen before the host is told.
        guard !audioMoovPrimeKnownUnobtainable else {
            EngineLog.emit(
                "[HLSSegmentProducer] AE#366 skipping the moov-prime search: this session already "
                + "searched the whole source for an audio frame and found none",
                category: .session
            )
            markAudioMoovPrimeUnobtainable()
            return nil
        }
        let result = readForwardForAudioFrame(
            streamIndex: audio.sourceStreamIndex,
            byteCap: Self.moovPrimeScanByteCap,
            deadline: Date().addingTimeInterval(Self.moovPrimeScanTimeoutSeconds),
            label: "AE#222 prime scan"
        )
        if let frame = result.frame { return frame }
        guard result.mayRetryElsewhere else { return nil }
        return huntAudioMoovPrimeFrameBySeeking(streamIndex: audio.sourceStreamIndex)
    }

    /// AE#366: the forward scan assumes the audio is a few seconds behind the video in FILE order.
    /// That holds for the #222 shape and fails completely for a track that is sparsely interleaved or
    /// muxed in bulk somewhere else: the first packet of a legacy dub can sit hundreds of MiB in, and
    /// no byte budget rescues that. Worse, the budget is a byte budget, so what it buys shrinks as the
    /// bitrate grows: 128 MiB is five minutes of a 3 Mbps encode and ten seconds of a 97 Mbps UHD one.
    ///
    /// The frame does not have to be the FIRST one. AC-3 and E-AC-3 are one complete syncframe per
    /// packet and movenc's `handle_eac3` builds the whole sample entry from whichever frame it gets
    /// (AE#340), and the prime frame's timestamp is discarded anyway (the muxer truncates the prime
    /// fragment and re-arms `frag_discont`). So instead of reading further and further forward, seek
    /// to a handful of positions and take any frame the track yields there.
    ///
    /// The order is picked for the two shapes that produce this failure: a track present throughout
    /// with wide gaps (the midpoint finds it immediately) and a track muxed in bulk near the end (the
    /// 90 % probe does). Nothing in the container says which one it is: measured on a fixture whose
    /// first audio packet sits at 211 MiB, `AVStream.start_time` for that track still reads 0.
    /// Probe positions in seconds, midpoint first. Empty for a source whose duration is unknown or
    /// too short to have anywhere else to look, which is also every live source.
    static func moovPrimeHuntPositions(durationSeconds: Double) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 1 else { return [] }
        return moovPrimeHuntFractions.map { durationSeconds * $0 }
    }

    private func huntAudioMoovPrimeFrameBySeeking(streamIndex: Int32) -> [UInt8]? {
        // Live is forward-only: a seek would abandon the join point, and a live source that has not
        // produced an audio packet yet will produce one on its own.
        guard !isLive else { return nil }
        let positions = Self.moovPrimeHuntPositions(durationSeconds: demuxer.duration)
        guard !positions.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(Self.moovPrimeHuntTimeoutSeconds)
        fieldJoiner?.reset()

        for target in positions {
            if checkShouldStop() || Date() > deadline { break }
            guard demuxer.seek(to: target) else {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#366 prime hunt: seek to "
                    + "\(String(format: "%.1f", target))s failed; source is not seekable, giving up",
                    category: .session
                )
                markAudioMoovPrimeUnobtainable()
                return nil
            }
            let result = readForwardForAudioFrame(
                streamIndex: streamIndex,
                byteCap: Self.moovPrimeHuntProbeByteCap,
                deadline: deadline,
                label: "AE#366 prime hunt at \(String(format: "%.1f", target))s"
            )
            if let frame = result.frame { return frame }
            if !result.mayRetryElsewhere { return nil }
        }
        EngineLog.emit(
            "[HLSSegmentProducer] AE#366 prime hunt: no audio packet at any probe position; "
            + "the selected track cannot prime the moov in this session",
            category: .session
        )
        markAudioMoovPrimeUnobtainable()
        return nil
    }

    /// Records the structural verdict. Deliberately NOT set when a read threw or the pump was asked
    /// to stop: those say nothing about the track, and treating them as final would turn a transient
    /// I/O hiccup into a dead session.
    private func markAudioMoovPrimeUnobtainable() {
        stateLock.lock()
        _audioMoovPrimeUnobtainable = true
        stateLock.unlock()
    }

    /// One bounded forward read for a packet on `streamIndex`, copying its bytes.
    ///
    /// `mayRetryElsewhere` is false when the read itself failed or the caller was told to stop: those
    /// are reasons to abandon the hunt, unlike "this region carries no audio", which is a reason to
    /// look somewhere else.
    private func readForwardForAudioFrame(
        streamIndex: Int32, byteCap: Int, deadline: Date, label: String
    ) -> (frame: [UInt8]?, mayRetryElsewhere: Bool) {
        var bytesRead = 0
        var packetsRead = 0

        while true {
            if checkShouldStop() { return (nil, false) }
            if bytesRead >= byteCap || Date() > deadline {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) gave up after \(packetsRead) packet(s) / "
                    + "\(bytesRead / (1024 * 1024)) MiB without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            let pkt: UnsafeMutablePointer<AVPacket>?
            do {
                pkt = try demuxer.readPacket()
            } catch {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) read failed: \(error)",
                    category: .session
                )
                return (nil, false)
            }
            guard let packet = pkt else {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) hit EOF after \(packetsRead) packet(s) "
                    + "without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            packetsRead += 1
            bytesRead += Int(max(packet.pointee.size, 0))

            guard packet.pointee.stream_index == streamIndex,
                  packet.pointee.size > 0,
                  let data = packet.pointee.data
            else { continue }

            let frame = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            EngineLog.emit(
                "[HLSSegmentProducer] \(label) captured a \(frame.count) B audio frame after "
                + "\(packetsRead) packet(s) / \(bytesRead / (1024 * 1024)) MiB "
                + "(srcDts=\(packet.pointee.dts))",
                category: .session
            )
            return (frame, true)
        }
    }
}
