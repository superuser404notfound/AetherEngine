import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// The object-audio format a source would be rendered as, before it is confirmed.
    enum ObjectAudioSource: Equatable {
        /// TrueHD that FFmpeg marked Atmos.
        case trueHDAtmos
        /// Lossless DTS-HD Master Audio, which may carry DTS:X whatever FFmpeg's label says, so
        /// LibDTSX decides on its first frames (see `dtsxVerdict`).
        case dtsHDMasterAudio

        /// How the log and the pipeline description name it.
        var name: String {
            switch self {
            case .trueHDAtmos: return "TrueHD Atmos"
            case .dtsHDMasterAudio: return "DTS:X"
            }
        }

        /// Whether this build carries the source's decoder (its package trait). Without it the source
        /// keeps the channel bridge whatever `objectAudioRendering` asks.
        var isBuiltIn: Bool {
            switch self {
            case .trueHDAtmos: return AetherEngine.linksTrueHDObjectDecoder
            case .dtsHDMasterAudio: return AetherEngine.linksDTSXObjectDecoder
            }
        }

        var traitName: String {
            switch self {
            case .trueHDAtmos: return "TrueHDObjectAudio"
            case .dtsHDMasterAudio: return "DTSXObjectAudio"
            }
        }
    }

    /// The bed a source should be rendered into, or nil to keep the ordinary bridge.
    ///
    /// TrueHD only when FFmpeg marked the stream Atmos (`AV_PROFILE_TRUEHD_ATMOS`, which mlpdec sets
    /// from the major sync while the probe decodes a frame): a TrueHD track without an object
    /// presentation gains nothing from rendering and would lose its lossless 7.1 for it. DTS when it
    /// is DTS-HD Master Audio, with or without FFmpeg's DTS:X label: FFmpeg names only two of DTS:X's
    /// markers, so the label misses some DTS:X, and a DTS-HD MA track that turns out not to be DTS:X
    /// is refused before the bridge is built (`buildSpatialAudioProducerIfEligible`). 48 kHz, or not
    /// yet known, since TrueHD reports its rate from the first frame and both formats are only ever
    /// authored at 48 kHz. Nil as well when the build lacks the source's decoder trait.
    static func spatialRenderingLayout(
        rendering: ObjectAudioRendering,
        codecID: AVCodecID,
        profile: Int32,
        sampleRate: Int32
    ) -> SpatialSpeakerLayout? {
        guard let layout = rendering.layout,
              objectAudioSource(codecID: codecID, profile: profile)?.isBuiltIn == true,
              sampleRate == 0 || sampleRate == Int32(ObjectAudioRendering.sampleRate)
        else { return nil }
        return layout
    }

    static func objectAudioSource(codecID: AVCodecID, profile: Int32) -> ObjectAudioSource? {
        switch (codecID, profile) {
        case (AV_CODEC_ID_TRUEHD, AV_PROFILE_TRUEHD_ATMOS):
            return .trueHDAtmos
        case (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA),
             (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA_X),
             (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA_X_IMAX):
            return .dtsHDMasterAudio
        default:
            return nil
        }
    }

    #if DTSXObjectAudio
    /// Packets of the source's head `dtsxVerdict` may look at. LibDTSX needs three frames of the
    /// track, which a muxed file interleaves within the first few dozen packets; the same budget as
    /// the planner's head scans bounds a file whose audio starts late.
    static let dtsxVerdictPacketBudget = 512
    /// Bytes the peek may hold. Unlike the planner's scans, peeked packets stay resident until the
    /// producer reads them, video included, so a late-starting track in a 4K remux must not pin
    /// hundreds of megabytes; three DTS-HD frames normally sit within the first few of them.
    static let dtsxVerdictByteBudget = 24 << 20

    /// Shows LibDTSX the audio stream's first packets, without consuming them (the producer reads the
    /// same packets afterwards), until it says whether the track is DTS:X it renders. Nil when a
    /// budget ran out or the source could not be read first.
    func dtsxVerdict(
        decoder: DTSXObjectAudioDecoder,
        demuxer: Demuxer,
        streamIndex: Int32
    ) -> DTSXObjectAudioDecoder.Verdict? {
        var verdict: DTSXObjectAudioDecoder.Verdict?
        var heldBytes = 0
        try? demuxer.peekPackets(maxPackets: Self.dtsxVerdictPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > Self.dtsxVerdictByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
            verdict = decoder.verdict(feeding: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
            return verdict != nil
        }
        return verdict
    }
    #endif

    /// Build the producer on a `SpatialAudioBridge` when the host asked for object rendering and the
    /// source qualifies. Nil means "not this route": ineligible, unsupported OS, not DTS:X, or a
    /// bridge/header failure, each logged, and the caller carries on with the ordinary bridge
    /// cascade, so asking for Atmos never costs a session its audio.
    func buildSpatialAudioProducerIfEligible(
        audioStream: UnsafeMutablePointer<AVStream>,
        audioDemuxer: Demuxer,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?
    ) -> HLSSegmentProducer? {
        let par = audioStream.pointee.codecpar.pointee
        guard let layout = Self.spatialRenderingLayout(
            rendering: objectAudioRendering, codecID: par.codec_id,
            profile: par.profile, sampleRate: par.sample_rate),
              let source = Self.objectAudioSource(codecID: par.codec_id, profile: par.profile)
        else {
            if objectAudioRendering != .off,
               let source = Self.objectAudioSource(codecID: par.codec_id, profile: par.profile),
               !source.isBuiltIn {
                EngineLog.emit(
                    "[HLSVideoEngine] \(source.name) rendering requested but not built in (\(source.traitName) "
                    + "trait off); keeping the channel bridge",
                    category: .session
                )
            } else if par.codec_id == AV_CODEC_ID_TRUEHD {
                if objectAudioRendering != .off {
                    EngineLog.emit(
                        "[HLSVideoEngine] object rendering requested but TrueHD is not 48 kHz Atmos "
                        + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                        category: .session
                    )
                } else if par.profile == AV_PROFILE_TRUEHD_ATMOS {
                    // The host's choice, not a failure, but the one a missing-heights report turns on:
                    // the channel bridge plays the 7.1 presentation, where the objects are mixed into
                    // the floor channels.
                    EngineLog.emit(
                        "[HLSVideoEngine] TrueHD Atmos with objectAudioRendering off; the channel bridge "
                        + "carries the 7.1 presentation, with the objects mixed into the floor channels",
                        category: .session
                    )
                }
            } else if par.codec_id == AV_CODEC_ID_DTS, objectAudioRendering != .off {
                // Lossy DTS has no DTS:X to render; only the lossless profiles are offered to LibDTSX.
                EngineLog.emit(
                    "[HLSVideoEngine] object rendering requested but DTS is not 48 kHz DTS-HD Master Audio "
                    + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                    category: .session
                )
            }
            return nil
        }
        // VOD only: the live reopen and splice paths re-time the bridge in ways this one's encoder
        // latency and fixed packet stamping do not follow.
        guard !isLiveSession else {
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name) rendering is VOD only; keeping the channel bridge on this live session",
                category: .session
            )
            return nil
        }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name) rendering needs OS 26 (APAC encoder API); keeping the channel bridge",
                category: .session
            )
            return nil
        }
        #if TrueHDObjectAudio || DTSXObjectAudio
        return buildSpatialAudioProducer(
            audioStream: audioStream, audioDemuxer: audioDemuxer, sourceAudioStreamIndex: sourceAudioStreamIndex,
            sourceCodecLabel: sourceCodecLabel, audioHLSCodecs: &audioHLSCodecs, audioLanguage: audioLanguage,
            layout: layout, source: source)
        #else
        return nil
        #endif
    }

    #if TrueHDObjectAudio || DTSXObjectAudio
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func buildSpatialAudioProducer(
        audioStream: UnsafeMutablePointer<AVStream>,
        audioDemuxer: Demuxer,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?,
        layout: SpatialSpeakerLayout,
        source: ObjectAudioSource
    ) -> HLSSegmentProducer? {
        let bridge: SpatialAudioBridge
        do {
            let decoder: ObjectAudioDecoding
            switch source {
            case .trueHDAtmos:
                #if TrueHDObjectAudio
                decoder = try TrueHDObjectAudioDecoder()
                #else
                return nil
                #endif
            case .dtsHDMasterAudio:
                #if DTSXObjectAudio
                let dtsx = try DTSXObjectAudioDecoder()
                // On a resume the verdict reads where the first producer starts, not the file head
                // that step 8's seek would then drop; LibDTSX decides mid-stream as well.
                if audioDemuxer === demuxer {
                    seekToInitialProducerStart(audioDemuxer)
                    demuxerAtInitialProducerStart = true
                }
                let started = DispatchTime.now()
                let verdict = dtsxVerdict(decoder: dtsx, demuxer: audioDemuxer, streamIndex: sourceAudioStreamIndex)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                switch verdict {
                case .renders(let presentation):
                    EngineLog.emit(
                        "[HLSVideoEngine] DTS-HD MA track is DTS:X \(presentation) (LibDTSX, "
                        + "\(String(format: "%.0f", ms)) ms)",
                        category: .session
                    )
                    // The verdict decoded the first packets; the bridge starts from the same ones again.
                    dtsx.reset()
                    decoder = dtsx
                    audioIsConfirmedDTSX = true
                case .refused(let reason):
                    EngineLog.emit(
                        "[HLSVideoEngine] DTS-HD MA track is not DTS:X LibDTSX renders (\(reason)); "
                        + "keeping the channel bridge",
                        category: .session
                    )
                    return nil
                case nil:
                    EngineLog.emit(
                        "[HLSVideoEngine] no DTS:X verdict within \(Self.dtsxVerdictPacketBudget) packets or "
                        + "\(Self.dtsxVerdictByteBudget >> 20) MiB; keeping the channel bridge",
                        category: .session
                    )
                    return nil
                }
                #else
                return nil
                #endif
            }
            bridge = try SpatialAudioBridge(
                srcTimeBase: audioStream.pointee.time_base, layout: layout, decoder: decoder)
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] ERROR: \(source.name) rendering unavailable (\(error)); keeping the channel bridge",
                category: .session
            )
            return nil
        }
        guard let cp = bridge.encoderCodecpar else {
            bridge.close()
            return nil
        }
        let cfg = HLSSegmentProducer.AudioConfig(
            codecpar: cp,
            timeBase: bridge.encoderTimeBase,
            sourceStreamIndex: sourceAudioStreamIndex,
            inputTimeBase: bridge.encoderTimeBase,
            sourceTimeBase: audioStream.pointee.time_base,
            bridge: bridge,
            language: audioLanguage
        )
        savedAudioConfig = cfg
        audioBridge = bridge
        // Same surfacing as the channel bridge: a decoder that never answers is a failure, not silence.
        if sideAudioDemuxer == nil {
            let streamIndex = sourceAudioStreamIndex
            bridge.onDecoderProducedNothing = { [weak self] stats in
                self?.handleBridgeDecodedNothing(streamIndex: streamIndex, summary: stats.summary)
            }
        }
        do {
            let producer = try makeProducer(baseIndex: initialProducerBaseIndex)
            audioHLSCodecs = bridge.hlsCodecs
            // Short on purpose: hosts append it to a track title in one-line stats rows.
            audioPipelineDescription = source == .trueHDAtmos
                ? "\(sourceCodecLabel) Atmos → APAC \(layout.rawValue)"
                : "DTS:X → APAC \(layout.rawValue)"
            audioDelivery = .bridged
            audioIsAPAC = true
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name): "
                + (source == .trueHDAtmos ? "objects" : "bed, heights and objects")
                + " rendered into \(layout.rawValue), delivered as \(bridge.hlsCodecs) (lossy; the lossless "
                + (source == .trueHDAtmos ? "7.1 channel presentation" : "7.1 downmix") + " is not used)",
                category: .session
            )
            return producer
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] APAC producer header write failed (\(error)); keeping the channel bridge",
                category: .session
            )
            savedAudioConfig = nil
            audioBridge = nil
            bridge.close()
            return nil
        }
    }
    #endif
}
