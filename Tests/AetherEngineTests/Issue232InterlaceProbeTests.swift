import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// AE#232: a declared interlaced field order is a claim about carriage, not evidence that any frame
/// is interlaced. `InterlaceProbe` decodes a sample and applies the exact predicate that engages the
/// deinterlacer (`AV_FRAME_FLAG_INTERLACED`, see `SoftwareVideoDecoder`), so a sample that stays
/// clean proves the software detour would be a no-op and the stream can take the native path with
/// hardware decode.
///
/// Fixtures are synthesized 64x64 H.264 at 25 fps, muxed to MP4:
/// - `declaredTTProgressiveBase64`: 24 progressive frames in a container carrying a `fiel` atom
///   (fields=2, detail=1), so `codecpar.field_order` reads TT while no decoded frame is flagged.
///   That is the reporter's signature. Real PsF reaches the same pair of values through the parser
///   (SEI pic_struct=3 on a frame-coded picture) rather than the container, but the routing path
///   consumes only `field_order` and the frame flags, which are identical here.
/// - `interlacedBase64`: 24 genuinely interlaced frames (x264 `--interlaced`, tff). field_order=tt
///   and every decoded frame carries the flag.
/// - `shortDeclaredTTBase64`: the same container lie over 5 frames, below the evidence floor.
@Suite("AE#232: declared interlace verified against decoded frames")
struct Issue232InterlaceProbeTests {

    // MARK: - Harness

    private static func openFixture(_ base64: String) throws -> Demuxer {
        let demuxer = Demuxer()
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    // MARK: - The decision, end to end on one file

    @Test("a stream declared TT whose frames are all progressive stops routing to software")
    func declaredInterlaceRefutedByFrames() throws {
        let demuxer = try Self.openFixture(Self.declaredTTProgressiveBase64)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)

        // What the declaration alone decides today: software, for a deinterlace pass.
        #expect(codecpar.pointee.field_order == AV_FIELD_TT)
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: codecpar.pointee.codec_id,
            fieldOrder: codecpar.pointee.field_order,
            av1Available: true))
        #expect(VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
            codecID: codecpar.pointee.codec_id,
            fieldOrder: codecpar.pointee.field_order,
            spsIndicatesInterlaced: false))

        // What the frames say: the deinterlacer would never engage, so the detour buys nothing.
        // `AetherEngine.load` joins exactly these two, clearing useSoftwarePath on a refutation.
        let verdict = InterlaceProbe.run(demuxer: demuxer, streamIndex: demuxer.videoStreamIndex)
        guard case .progressive(let frames) = verdict else {
            Issue.record("expected .progressive, got \(verdict)")
            return
        }
        #expect(frames >= InterlaceProbe.minimumFrames)
        #expect(InterlaceProbe.refutesDeclaredInterlace(verdict))
    }

    @Test("software loads and reloads carry the interlace decision and stop clears it", .timeLimit(.minutes(2)),
          arguments: [false, true])
    @MainActor
    func loadCarriesWarmupDecision(interlaced: Bool) async throws {
        let fixture = interlaced ? Self.interlacedBase64 : Self.declaredTTProgressiveBase64
        let bytes = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("deinterlace-demand-\(UUID().uuidString).mp4")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        #expect(engine.lastRequiresDeinterlaceWarmup == interlaced)
        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastRequiresDeinterlaceWarmup == interlaced)
        engine.stop()
        #expect(!engine.lastRequiresDeinterlaceWarmup)
    }

    @Test("custom-source reload preserves a same-title progressive verdict and rechecks a different title",
          .timeLimit(.minutes(2)), arguments: [false, true])
    @MainActor
    func customReloadUsesTitleIdentity(changesTitle: Bool) async throws {
        let bytes = try #require(Data(base64Encoded: Self.declaredTTProgressiveBase64,
                                     options: .ignoreUnknownCharacters))
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        options.preferredDecodePath = .software
        _ = try await engine.load(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"),
                                  options: options)
        #expect(!engine.lastRequiresDeinterlaceWarmup, "decoded frames refute the TT declaration")

        // Exercise the real custom-reader reopen without a large disc image. The title identity is
        // the only extra state a disc contributes to this decision; the reopened codecpar still
        // declares TT, so recomputing it wrongly loses the same title's verified progressive result.
        engine.activeDiscTitleID = 11
        if changesTitle {
            let url = try #require(engine.loadedURL)
            let error = await engine.reloadWithAudioOverride(
                url: url, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration,
                discTitleIDOverride: 12)
            #expect(error == nil)
        } else {
            try await engine.reloadAtCurrentPosition()
        }
        #expect(engine.lastRequiresDeinterlaceWarmup == changesTitle)
    }

    @Test("custom-source background reload retains interlace evidence through repeated teardown",
          .timeLimit(.minutes(2)), arguments: [false, true], [false, true])
    @MainActor
    func customBackgroundReloadRetainsWarmupDecision(interlaced: Bool, hasDiscTitle: Bool) async throws {
        let fixture = interlaced ? Self.interlacedBase64 : Self.declaredTTProgressiveBase64
        let bytes = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        options.preferredDecodePath = .software
        _ = try await engine.load(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"),
                                  options: options)
        #expect(engine.lastRequiresDeinterlaceWarmup == interlaced)
        if hasDiscTitle { engine.activeDiscTitleID = 11 }

        // This is the production background teardown on every platform. Its second invocation
        // models a re-armed grace window while the live session has already been cleared.
        engine.releaseVideoPipelineForBackground()
        engine.releaseVideoPipelineForBackground()
        #expect(!engine.lastRequiresDeinterlaceWarmup)
        #expect(engine.activeDiscTitleID == nil)
        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastRequiresDeinterlaceWarmup == interlaced)
        #expect(engine.backgroundTeardownSelection == nil)
    }

    @Test("a fresh custom load discards the parked source's warm-up decision",
          .timeLimit(.minutes(2)), arguments: [false, true])
    @MainActor
    func freshCustomLoadDiscardsParkedWarmupDecision(initiallyInterlaced: Bool) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        options.preferredDecodePath = .software
        for interlaced in [initiallyInterlaced, !initiallyInterlaced] {
            let fixture = interlaced ? Self.interlacedBase64 : Self.declaredTTProgressiveBase64
            let bytes = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
            _ = try await engine.load(source: .custom(DataIOReader(data: bytes), formatHint: "mp4"),
                                      options: options)
            #expect(engine.lastRequiresDeinterlaceWarmup == interlaced)
            #expect(engine.backgroundTeardownSelection == nil)
            if interlaced == initiallyInterlaced {
                engine.releaseVideoPipelineForBackground()
                #expect(engine.backgroundTeardownSelection != nil)
            }
        }
    }

    @Test("the shared SPS fallback only breaks an unknown H.264 field-order tie")
    func codecParametersGateSPSTieBreaker() throws {
        let demuxer = try Self.openFixture(Self.interlacedBase64)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let parameters = try #require(stream.pointee.codecpar)
        parameters.pointee.field_order = AV_FIELD_UNKNOWN
        #expect(VideoRoutingPolicy.spsIndicatesInterlaced(codecParameters: parameters))
        parameters.pointee.field_order = AV_FIELD_PROGRESSIVE
        #expect(!VideoRoutingPolicy.spsIndicatesInterlaced(codecParameters: parameters))
        parameters.pointee.field_order = AV_FIELD_UNKNOWN
        parameters.pointee.codec_id = AV_CODEC_ID_VP9
        #expect(!VideoRoutingPolicy.spsIndicatesInterlaced(codecParameters: parameters))
    }

    // MARK: - Probe verdicts

    @Test("a flagged frame upholds the declaration and stops the sample at once")
    func interlacedSampleUpholdsDeclaration() throws {
        let demuxer = try Self.openFixture(Self.interlacedBase64)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(VideoRoutingPolicy.interlacedFieldOrders.contains(
            stream.pointee.codecpar.pointee.field_order))

        let verdict = InterlaceProbe.run(demuxer: demuxer, streamIndex: demuxer.videoStreamIndex)
        guard case .interlaced(let afterFrames) = verdict else {
            Issue.record("expected .interlaced, got \(verdict)")
            return
        }
        // Early exit: genuinely interlaced material pays a frame or two of decode, not a full sample.
        #expect(afterFrames <= 2)
        #expect(!InterlaceProbe.refutesDeclaredInterlace(verdict))
    }

    @Test("a sample below the frame floor never overrules the declaration")
    func shortSampleIsInconclusive() throws {
        let demuxer = try Self.openFixture(Self.shortDeclaredTTBase64)
        defer { demuxer.close() }

        let verdict = InterlaceProbe.run(demuxer: demuxer, streamIndex: demuxer.videoStreamIndex)
        guard case .inconclusive = verdict else {
            Issue.record("expected .inconclusive, got \(verdict)")
            return
        }
        #expect(!InterlaceProbe.refutesDeclaredInterlace(verdict))
    }

    @Test("a truncated budget is inconclusive, not progressive")
    func exhaustedBudgetIsInconclusive() throws {
        let demuxer = try Self.openFixture(Self.declaredTTProgressiveBase64)
        defer { demuxer.close() }

        // The same clean fixture that refutes above, cut off after two packets: the absence of a
        // flagged frame must not read as evidence when almost nothing was decoded.
        let verdict = InterlaceProbe.run(
            demuxer: demuxer, streamIndex: demuxer.videoStreamIndex, packetBudget: 2)
        guard case .inconclusive = verdict else {
            Issue.record("expected .inconclusive, got \(verdict)")
            return
        }
    }

    @Test("no video stream is inconclusive, never a refutation")
    func missingStreamIsInconclusive() throws {
        let demuxer = try Self.openFixture(Self.declaredTTProgressiveBase64)
        defer { demuxer.close() }

        let verdict = InterlaceProbe.run(demuxer: demuxer, streamIndex: -1)
        guard case .inconclusive = verdict else {
            Issue.record("expected .inconclusive, got \(verdict)")
            return
        }
    }

    @Test("the demuxer is usable from the head after the sample")
    func demuxerRewindsAfterSample() throws {
        // The load path hands the SAME demuxer to the session, so a sample that left the read
        // position mid-stream would start playback in the middle of the title.
        let demuxer = try Self.openFixture(Self.declaredTTProgressiveBase64)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex

        _ = InterlaceProbe.run(demuxer: demuxer, streamIndex: videoIdx)
        demuxer.seek(to: 0)

        var firstVideoPTS: Int64?
        for _ in 0..<20 {
            guard let packet = try demuxer.readPacket() else { break }
            if packet.pointee.stream_index == videoIdx, firstVideoPTS == nil {
                firstVideoPTS = packet.pointee.pts
            }
            av_packet_unref(packet)
            av_packet_free_safe(packet)
            if firstVideoPTS != nil { break }
        }
        #expect(firstVideoPTS == 0)
    }

    // MARK: - Which streams may be probed at all

    @Test("only the declared-interlace rule opens the door to a probe")
    func probeGateMatchesTheInterlaceRule() {
        for order in [AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT] {
            #expect(VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
                codecID: AV_CODEC_ID_H264, fieldOrder: order, spsIndicatesInterlaced: false))
        }
        #expect(VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, spsIndicatesInterlaced: true))
        #expect(!VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_PROGRESSIVE, spsIndicatesInterlaced: true))
    }

    @Test("codecs that are software-bound anyway never trigger a probe")
    func softwareBoundCodecsSkipTheProbe() {
        // A probe on these would burn decode time for an answer that cannot change the route:
        // MPEG-2 / VC-1 / VP9 are unconditionally software, AV1 follows hardware availability, and
        // the deinterlace rule was never extended to HEVC.
        for codec in [AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1, AV_CODEC_ID_VP9,
                      AV_CODEC_ID_AV1, AV_CODEC_ID_HEVC] {
            #expect(!VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
                codecID: codec, fieldOrder: AV_FIELD_TT, spsIndicatesInterlaced: true))
        }
    }

    // MARK: - Fixtures

    /// 24 progressive frames; container `fiel` atom makes codecpar.field_order read TT.
    private static let declaredTTProgressiveBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAAAxttZGF0AAACKgYF//8m
    3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBF
    Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
    b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFs
    eXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
    IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9u
    ZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhl
    YWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9
    MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0w
    IGtleWludD0yNCBrZXlpbnRfbWluPTIgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3Fw
    IG1idHJlZT0wIHFwPTQwIGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAEmWIhDom5OTk666666666666
    8AAAAAVBmiKCMAAAAAVBmkKCMAAAAAVBmmKCMAAAAAVBmoKCMAAAAAVBmqKCMAAAAAVBmsKCMAAA
    AAVBmuKCMAAAAAVBmwKCMAAAAAVBmyKCMAAAAAVBm0KCMAAAAAVBm2KCMAAAAAVBm4KCMAAAAAVB
    m6KCMAAAAAVBm8KCMAAAAAVBm+KCMAAAAAVBmgKCMAAAAAVBmiKCMAAAAAVBmkKCMAAAAAVBmmKC
    MAAAAAVBmoKCMAAAAAVBmqKCMAAAAAVBmsKCMAAAAAVBmuKCMAAAA41tb292AAAAbG12aGQAAAAA
    AAAAAAAAAAAAAAPoAAADwAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
    AAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACt3RyYWsAAABcdGtoZAAA
    AAMAAAAAAAAAAAAAAAEAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEA
    AAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA8AAAAAA
    AAEAAAAAAi9tZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAADIAAAAwAFXEAAAAAAAtaGRscgAAAAAA
    AAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAHabWluZgAAABR2bWhkAAAAAQAAAAAA
    AAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABmnN0YmwAAADCc3RzZAAA
    AAAAAAABAAAAsmF2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEV
    TGF2YzYyLjI4LjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAY//8AAAAuYXZjQwFCwAr/4QAWZ0LACtoQ
    mwEQAAADABAAAAMDIPEiagEABWjOA5yAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAGZ4A
    AAAAAAAACmZpZWwCAQAAABhzdHRzAAAAAAAAAAEAAAAYAAACAAAAABRzdHNzAAAAAAAAAAEAAAAB
    AAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAYAAAAAQAAAHRzdHN6AAAAAAAAAAAAAAAYAAACRAAAAAkA
    AAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAA
    AAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAAFHN0Y28AAAAAAAAAAQAAADAAAABidWR0
    YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAA
    Jal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMQ==
    """

    /// 24 genuinely interlaced frames (x264 --interlaced, tff): field_order=tt and every decoded
    /// frame carries AV_FRAME_FLAG_INTERLACED.
    private static let interlacedBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAABCZtZGF0AAACLAYF//8o
    3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBF
    Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
    b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFs
    eXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
    IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9u
    ZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhl
    YWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9
    dGZmIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRw
    PTAga2V5aW50PTI0IGtleWludF9taW49MiBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1j
    cXAgbWJ0cmVlPTAgcXA9NDAgaXBfcmF0aW89MS40MCBhcT0wAIAAAAAFBgEBMoAAAAAVZYiCLDqT
    cm8nJ5OTycnrr11669deAAAABQYBATKAAAAAB0GaI2KX4+AAAAAFBgEBMoAAAAAHQZpFYpfj4AAA
    AAUGAQFCgAAAAAdBmmdil+PgAAAABQYBAUKAAAAAB0GaiWKX4+AAAAAFBgEBQoAAAAAHQZqrYpfj
    4AAAAAUGAQFCgAAAAAdBms1il+PgAAAABQYBAUKAAAAAB0Ga72KX4+AAAAAFBgEBQoAAAAAHQZsB
    Ypfj4AAAAAUGAQFCgAAAAAdBmyNil+PgAAAABQYBAUKAAAAAB0GbRWKX4+AAAAAFBgEBQoAAAAAH
    QZtnYpfj4AAAAAUGAQFCgAAAAAdBm4lil+PgAAAABQYBAUKAAAAAB0Gbq2KX4+AAAAAFBgEBQoAA
    AAAHQZvNYpfj4AAAAAUGAQFCgAAAAAdBm+9il+PgAAAABQYBAUKAAAAAB0GaAWKX4+AAAAAFBgEB
    QoAAAAAHQZojYpfj4AAAAAUGAQFCgAAAAAdBmkVil+PgAAAABQYBAUKAAAAAB0GaZ2KX4+AAAAAF
    BgEBQoAAAAAHQZqJYpfj4AAAAAUGAQFCgAAAAAdBmqtil+PgAAAABQYBAUKAAAAAB0GazWKX4+AA
    AAAFBgEBQoAAAAAHQZrvYpfj4AAAA4Jtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAADwAAB
    AAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAACAAACrHRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAA
    AAADwAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAA
    QAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA8AAAAAAAAEAAAAAAiRtZGlhAAAAIG1k
    aGQAAAAAAAAAAAAAAAAAADIAAAAwAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAA
    AFZpZGVvSGFuZGxlcgAAAAHPbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJl
    ZgAAAAAAAAABAAAADHVybCAAAAABAAABj3N0YmwAAAC3c3RzZAAAAAAAAAABAAAAp2F2YzEAAAAA
    AAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEVTGF2YzYyLjI4LjEwMSBsaWJ4
    MjY0AAAAAAAAAAAAAAAY//8AAAAtYXZjQwFNQBX/4QAVZ01AFfQibARAAAADAEAAAAyHxQqoAQAF
    aN4DnIAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAiTwAAAAAAAAAYc3R0cwAAAAAAAAAB
    AAAAGAAAAgAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAAAAEAAAABAAAAGAAAAAEA
    AAB0c3RzegAAAAAAAAAAAAAAGAAAAlIAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAA
    ABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAA
    FAAAABRzdGNvAAAAAAAAAAEAAAAwAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAA
    bWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4x
    Mi4xMDE=
    """

    /// 5 progressive frames under the same TT declaration: decodes cleanly, stays under the floor.
    private static let shortDeclaredTTBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAAAnJtZGF0AAACLAYF//8o
    3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBF
    Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
    b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFs
    eXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
    IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9u
    ZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhl
    YWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9
    MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0w
    IGtleWludD0yNTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1j
    cXAgbWJ0cmVlPTAgcXA9NDAgaXBfcmF0aW89MS40MCBhcT0wAIAAAAASZYiEOibk5OTrrrrrrrrr
    rrrwAAAABUGaIoIwAAAABUGaQoIwAAAABUGaYoIwAAAABUGagoIwAAADQW1vb3YAAABsbXZoZAAA
    AAAAAAAAAAAAAAAAA+gAAADIAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAA
    AAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJrdHJhawAAAFx0a2hk
    AAAAAwAAAAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAA
    AQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAyAAA
    AAAAAQAAAAAB421kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAMgAAAAoAVcQAAAAAAC1oZGxyAAAA
    AAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAY5taW5mAAAAFHZtaGQAAAABAAAA
    AAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAFOc3RibAAAAMJzdHNk
    AAAAAAAAAAEAAACyYXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAAAAAA
    ARVMYXZjNjIuMjguMTAxIGxpYngyNjQAAAAAAAAAAAAAABj//wAAAC5hdmNDAULACv/hABZnQsAK
    2hCbARAAAAMAEAAAAwMg8SJqAQAFaM4DnIAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAABg
    kAAAAAAAAAAKZmllbAIBAAAAGHN0dHMAAAAAAAAAAQAAAAUAAAIAAAAAFHN0c3MAAAAAAAAAAQAA
    AAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAUAAAABAAAAKHN0c3oAAAAAAAAAAAAAAAUAAAJGAAAA
    CQAAAAkAAAAJAAAACQAAABRzdGNvAAAAAAAAAAEAAAAwAAAAYnVkdGEAAABabWV0YQAAAAAAAAAh
    aGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAAB
    AAAAAExhdmY2Mi4xMi4xMDE=
    """
}
