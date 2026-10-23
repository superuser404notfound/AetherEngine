import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension SoftwarePlaybackHost {

    /// Picks and builds the audio producer for the session's track: the PCM decode every session had,
    /// or one of the two Atmos routes (`SoftwareAtmosRoute`). Every way an Atmos route can be
    /// unavailable (a stream that is not JOC, an OS without the APAC encoder, a build without the
    /// object decoder, a bridge that fails to build) lands on the PCM decode, each logged, so asking
    /// for Atmos never costs a session its audio.
    func makeAudioProducer(
        demuxer dem: Demuxer, streamIndex: Int32, isLive: Bool
    ) async throws -> (producer: any SoftwareAudioProducing, route: SoftwareAtmosRoute) {
        guard let stream = dem.stream(at: streamIndex), let par = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }
        func pcm() throws -> (producer: any SoftwareAudioProducing, route: SoftwareAtmosRoute) {
            let decoder = AudioDecoder()
            try decoder.open(stream: stream)
            return (decoder, .pcm)
        }
        guard objectAudioRendering != .off, !isLive else { return try pcm() }

        // The look at the stream and the DTS:X verdict run off the main actor, and a stop() can land
        // while they do: it closes the demuxer, which frees the streams `stream` and `par` point into.
        // After every suspension nothing below touches them until this has passed.
        func stillLive() throws {
            if stopRequested || Task.isCancelled { throw CancellationError() }
        }

        // The look happens before the resume seek on purpose: JOC is a property of the stream, the
        // first packets are enough to read it, and a peek at the start of the file does not depend on
        // where a resume lands (which, on a remote source, may be far from anything cached).
        var probe: SoftwareEAC3Passthrough.Probe = .notEAC3
        if par.pointee.codec_id == AV_CODEC_ID_EAC3 {
            probe = await BlockingWork.detached(priority: .userInitiated) {
                Self.firstEAC3Entry(demuxer: dem, streamIndex: streamIndex)
            }.value
            try stillLive()
        }
        // #838 on this host: a TrueHD track the probe never decoded a frame of keeps an unknown
        // profile, which reads as "not Atmos" to the route; its own major sync says whether it is.
        // Peeked at the head of the file like the JOC check, and only when rendering is asked for.
        if HLSVideoEngine.needsTrueHDMajorSyncVerdict(
            codecID: par.pointee.codec_id, profile: par.pointee.profile, rendering: objectAudioRendering) {
            let peek = await BlockingWork.detached(priority: .userInitiated) {
                HLSVideoEngine.trueHDMajorSyncVerdict(demuxer: dem, streamIndex: streamIndex)
            }.value
            try stillLive()
            if peek.isAtmos == true { par.pointee.profile = AV_PROFILE_TRUEHD_ATMOS }
            EngineLog.emit("[SWHost] audio: \(peek.summary)", category: .swPlayback)
        }
        let joc = probe.entry
        let route = SoftwareAtmosRoute.route(
            codecID: par.pointee.codec_id, profile: par.pointee.profile,
            sampleRate: par.pointee.sample_rate, channels: par.pointee.ch_layout.nb_channels,
            framesPerPacket: par.pointee.frame_size, isLive: isLive,
            rendering: objectAudioRendering, confirmedJOC: joc?.carriesJOC == true)
        switch route {
        case .pcm:
            if par.pointee.codec_id == AV_CODEC_ID_EAC3 {
                EngineLog.emit("[SWHost] audio: E-AC-3 stays PCM (\(probe.pcmReason(channels: par.pointee.ch_layout.nb_channels)))",
                               category: .swPlayback)
            } else if let reason = SoftwareAtmosRoute.apacRefusal(
                codecID: par.pointee.codec_id, profile: par.pointee.profile,
                sampleRate: par.pointee.sample_rate, rendering: objectAudioRendering) {
                EngineLog.emit("[SWHost] audio: stays PCM (\(reason))", category: .swPlayback)
            }
            return try pcm()
        case .compressedEAC3JOC:
            guard let joc else { return try pcm() }
            do {
                let producer = try SoftwareEAC3Passthrough(stream: stream, formatDescription: joc.formatDescription)
                // The registration takes a moment; it runs while the rest of the load does.
                AtmosDecoderPrimer.shared.begin()
                EngineLog.emit("[SWHost] audio: E-AC-3 JOC goes to the renderer compressed (Atmos decode)",
                               category: .swPlayback)
                return (producer, route)
            } catch {
                EngineLog.emit("[SWHost] audio: E-AC-3 JOC passthrough unavailable (\(error)); PCM decode",
                               category: .swPlayback)
                return try pcm()
            }
        case .apac(let layout):
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return try pcm() }
            let producer = await makeAPACProducer(demuxer: dem, stream: stream, streamIndex: streamIndex, layout: layout)
            if let settled = try Self.settleAPACProducer(producer, stopped: stopRequested || Task.isCancelled) {
                return (settled, route)
            }
            return try pcm()
        }
    }

    /// What the APAC route does with `makeAPACProducer`'s answer. A stop() that landed during the
    /// verdict await makes the answer nil on purpose, and the PCM decode the caller falls back to on
    /// a nil would open a stream the closing demuxer has freed: so a stop is checked before either,
    /// and a producer that was built is closed. nil (no stop) is the plain "use the PCM decode".
    nonisolated static func settleAPACProducer(
        _ producer: (any SoftwareAudioProducing)?, stopped: Bool
    ) throws -> (any SoftwareAudioProducing)? {
        if stopped {
            producer?.close()
            throw CancellationError()
        }
        return producer
    }

    /// The format entry of the stream's E-AC-3 packets, looked at without consuming them. The box is
    /// built from the first audio packet and, if that fails, from the next few: one malformed access
    /// unit at the head of a file must not decide the whole session's audio.
    nonisolated static func firstEAC3Entry(
        demuxer: Demuxer, streamIndex: Int32
    ) -> SoftwareEAC3Passthrough.Probe {
        var result: SoftwareEAC3Passthrough.Probe = .noAudioPacket
        var heldBytes = 0
        var attempts = 0
        var budgetHit = false
        try? demuxer.peekPackets(maxPackets: SoftwareAtmosRoute.jocPeekPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > SoftwareAtmosRoute.jocPeekByteBudget { budgetHit = true; return true }
            guard packet.pointee.stream_index == streamIndex, packet.pointee.size > 0 else { return false }
            attempts += 1
            // The stream is read only inside `withStream`, which close() waits out, and the result is
            // plain values: a stop() that closes the demuxer cannot free what is read here, and
            // nothing keeps a pointer into the stream afterwards. A closed demuxer has no stream.
            let entry = demuxer.withStream(at: streamIndex) { stream -> SoftwareEAC3Passthrough.Entry? in
                guard let par = stream.pointee.codecpar else { return nil }
                return SoftwareEAC3Passthrough.entry(codecpar: par, packet: packet)
            } ?? nil
            if let entry {
                result = .found(entry)
                return true
            }
            result = .dec3BuildFailed
            return attempts >= SoftwareAtmosRoute.jocBoxAttempts
        }
        if case .noAudioPacket = result, budgetHit { return .budgetExhausted }
        return result
    }

#if TrueHDObjectAudio || DTSXObjectAudio
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeAPACProducer(
        demuxer dem: Demuxer, stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32,
        layout: SpatialSpeakerLayout
    ) async -> (any SoftwareAudioProducing)? {
        // `nil` after a stop() is as good as any other nil: the caller checks the stop before it
        // touches the stream again. Nothing here reads `stream` once the verdict has been awaited
        // without checking first.
        let par = stream.pointee.codecpar.pointee
        guard let source = HLSVideoEngine.objectAudioSource(codecID: par.codec_id, profile: par.profile) else { return nil }
        let decoder: ObjectAudioDecoding
        do {
            switch source {
            case .trueHDAtmos:
                #if TrueHDObjectAudio
                decoder = try TrueHDObjectAudioDecoder()
                #else
                EngineLog.emit("[SWHost] audio: built without the TrueHDObjectAudio trait; PCM decode", category: .swPlayback)
                return nil
                #endif
            case .dtsHDMasterAudio:
                #if DTSXObjectAudio
                let dtsx = try DTSXObjectAudioDecoder()
                // The detached task is the only user of the decoder until it returns.
                nonisolated(unsafe) let verdictDecoder = dtsx
                let verdict = await BlockingWork.detached(priority: .userInitiated) {
                    HLSVideoEngine.dtsxVerdict(decoder: verdictDecoder, demuxer: dem, streamIndex: streamIndex)
                }.value
                guard !stopRequested, !Task.isCancelled else { return nil }
                guard case .renders(let presentation) = verdict else {
                    EngineLog.emit("[SWHost] audio: DTS-HD MA track is not DTS:X this build renders; PCM decode",
                                   category: .swPlayback)
                    return nil
                }
                EngineLog.emit("[SWHost] audio: DTS-HD MA track is DTS:X \(presentation)", category: .swPlayback)
                dtsx.reset()
                decoder = dtsx
                #else
                EngineLog.emit("[SWHost] audio: built without the DTSXObjectAudio trait; PCM decode", category: .swPlayback)
                return nil
                #endif
            }
            let bridge = try SpatialAudioBridge(srcTimeBase: stream.pointee.time_base, layout: layout, decoder: decoder)
            bridge.onDecoderProducedNothing = { stats in
                EngineLog.emit("[SWHost] ERROR: \(source.name) object decoder produced nothing: \(stats.summary)",
                               category: .swPlayback)
            }
            EngineLog.emit("[SWHost] audio: \(source.name) rendered into \(layout.rawValue) as APAC for the renderer",
                           category: .swPlayback)
            return SoftwareAPACProducer(bridge: bridge, stream: stream)
        } catch {
            EngineLog.emit("[SWHost] audio: \(source.name) APAC route unavailable (\(error)); PCM decode",
                           category: .swPlayback)
            return nil
        }
    }

#else
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeAPACProducer(
        demuxer dem: Demuxer, stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32,
        layout: SpatialSpeakerLayout
    ) async -> (any SoftwareAudioProducing)? {
        EngineLog.emit("[SWHost] audio: built without an object-audio trait; PCM decode", category: .swPlayback)
        return nil
    }
#endif
}
