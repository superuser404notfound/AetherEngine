import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #853: the load-time inverse telecine probe. Which sources are sampled at all, what the sampler
/// reads off exact frames, and the whole probe (decode, `fieldmatch` + `idet`, decision, budgets) on
/// small MPEG-2 clips: film decides film, interlaced video never does, progressive pictures and spent
/// budgets keep today's deinterlacer.
@Suite("Telecine cadence probe", .timeLimit(.minutes(3)))
struct TelecineCadenceProbeTests {

    // MARK: - Which sources are sampled

    private func gate(_ mode: InverseTelecineMode = .auto, live: Bool = false, seekable: Bool = true,
                      codec: AVCodecID = AV_CODEC_ID_MPEG2VIDEO, order: AVFieldOrder = AV_FIELD_TT,
                      rate: Double? = 30000.0 / 1001.0, height: Int32 = 480) -> TelecineCadenceProbe.Gate {
        TelecineCadenceProbe.gate(mode: mode, isLive: live, isSeekable: seekable, codecID: codec,
                                  fieldOrder: order, frameRate: rate, codedHeight: height)
    }

    @Test("an NTSC DVD frame stream is sampled; everything outside the first scope is not")
    func gateScope() {
        #expect(gate() == .sample)
        #expect(gate(rate: 30) == .sample, "30 fps carries 3:2 film too")
        #expect(gate(order: AV_FIELD_UNKNOWN) == .sample, "the decoded frames decide then")
        #expect(gate(.off) == .skip("LoadOptions.inverseTelecine is .off"))
        guard case .skip = gate(live: true) else { Issue.record("live is excluded"); return }
        guard case .skip = gate(seekable: false) else { Issue.record("a sample needs a rewind"); return }
        guard case .skip = gate(rate: 25) else { Issue.record("PAL 2:2 is a follow-up"); return }
        guard case .skip = gate(rate: 59.94) else { Issue.record("not a frame rate 3:2 film lands on"); return }
        guard case .skip = gate(height: 1080) else { Issue.record(".auto is SD only"); return }
        guard case .skip = gate(order: AV_FIELD_PROGRESSIVE) else { Issue.record("declared progressive"); return }
        guard case .skip = gate(codec: AV_CODEC_ID_VC1) else { Issue.record(".auto is MPEG-2 only"); return }
        guard case .skip = gate(codec: AV_CODEC_ID_H264) else { Issue.record("H.264 can route native"); return }
    }

    @Test("force skips the sample, but never on a codec that can route native or a non-NTSC rate")
    func gateForce() {
        #expect(gate(.force) == .force)
        #expect(gate(.force, live: true, seekable: false, codec: AV_CODEC_ID_VC1, height: 1080) == .force)
        guard case .skip = gate(.force, codec: AV_CODEC_ID_H264) else { Issue.record("H.264"); return }
        guard case .skip = gate(.force, rate: 25) else { Issue.record("25 fps"); return }
    }

    @Test("the display asks for 4/5 of the source rate under inverse telecine")
    func presentationRate() {
        let rate = AetherEngine.presentationFrameRate(source: 30000.0 / 1001.0, inverseTelecine: true)
        #expect(FrameRateSnap.snap(rate ?? 0) == 23.976)
        #expect(AetherEngine.presentationFrameRate(source: 29.97, inverseTelecine: false) == 29.97)
        #expect(FrameRateSnap.snap(AetherEngine.presentationFrameRate(source: 30, inverseTelecine: true) ?? 0) == 24)
    }

    // MARK: - The sampler on exact frames

    private func sample(_ frames: [UnsafeMutablePointer<AVFrame>]) -> TelecineCadenceAnalyzer {
        let sampler = TelecineCadenceSampler(timeBase: TelecineFrameSynthesizer.timeBase,
                                             frameRate: TelecineFrameSynthesizer.frameRate)
        var analyzer = TelecineCadenceAnalyzer()
        for frame in frames {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            for s in sampler.push(frame) ?? [] { analyzer.append(s) }
            av_frame_free(&f)
        }
        for s in sampler.finish() { analyzer.append(s) }
        return analyzer
    }

    @Test("matched 3:2 film samples progressive with the repeated frame at one phase")
    func samplerReadsFilm() {
        let analyzer = sample((0..<150).map { TelecineFrameSynthesizer.telecinedFrame($0) })
        #expect(analyzer.samples.count == 150)
        let e = analyzer.evidence(from: 0)
        #expect(e.progressiveShare > 0.95, "\(e)")
        #expect(e.cadenceShare > 0.9, "\(e)")
        #expect(analyzer.finalDecision().0 == .film)
    }

    @Test("interlaced video samples combed with no cadence")
    func samplerReadsVideo() {
        let analyzer = sample((0..<150).map { TelecineFrameSynthesizer.interlacedVideoFrame($0) })
        let e = analyzer.evidence(from: 0)
        #expect(e.progressiveShare < 0.1, "\(e)")
        #expect(e.cadenceHits == 0, "\(e)")
        #expect(analyzer.finalDecision().0 == .video)
    }

    // MARK: - The whole probe on MPEG-2 clips

    private func open(_ data: Data) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        return demuxer
    }

    private func probe(_ data: Data, startSeconds: Double? = nil,
                       packetBudget: Int = TelecineCadenceProbe.packetBudget) throws -> TelecineCadenceProbe.Verdict {
        let demuxer = try open(data)
        defer { demuxer.close() }
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        return TelecineCadenceProbe.run(
            demuxer: demuxer, streamIndex: index, startSeconds: startSeconds,
            frameRate: DeinterlaceConfig.SourceFrameRate(stream: stream), packetBudget: packetBudget)
    }

    @Test("the clips are what the probe's gate expects of an NTSC DVD")
    func fixturesLookLikeADVD() throws {
        let demuxer = try open(TelecineCadenceFixtures.telecinedFilm)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let par = try #require(stream.pointee.codecpar)
        #expect(par.pointee.codec_id == AV_CODEC_ID_MPEG2VIDEO)
        #expect(par.pointee.field_order != AV_FIELD_PROGRESSIVE)
        #expect(DeinterlaceConfig.SourceFrameRate(stream: stream) == .init(num: 30000, den: 1001))
    }

    @Test("hard-telecined film decides film")
    func telecinedClipIsFilm() throws {
        let verdict = try probe(TelecineCadenceFixtures.telecinedFilm)
        #expect(verdict.isFilm, "\(verdict)")
        #expect(verdict.report.decided >= TelecineCadenceAnalyzer.decidedWindow)
    }

    @Test("interlaced video never decides film")
    func interlacedClipIsVideo() throws {
        let verdict = try probe(TelecineCadenceFixtures.interlacedVideo)
        #expect(!verdict.isFilm, "\(verdict)")
        guard case .video = verdict else { Issue.record("expected .video, got \(verdict)"); return }
    }

    @Test("progressive pictures are not hard telecine, whatever the container says")
    func progressiveClipIsNotInterlaced() throws {
        let verdict = try probe(TelecineCadenceFixtures.progressive)
        #expect(verdict == .inconclusive(reason: "the frames are not interlaced", verdict.report))
    }

    @Test("a spent packet budget is inconclusive, which keeps the deinterlacer")
    func packetBudgetIsInconclusive() throws {
        let verdict = try probe(TelecineCadenceFixtures.telecinedFilm, packetBudget: 20)
        guard case .inconclusive(let reason, _) = verdict else {
            Issue.record("expected .inconclusive, got \(verdict)")
            return
        }
        #expect(reason.hasPrefix("packet budget"), "\(reason)")
    }

    @Test("the sample starts at the load's start position")
    func sampleStartsAtTheStartPosition() throws {
        // The clip has a keyframe every 30 frames, so a seek lands on the one before its target: from
        // 4.6 s that is the last, at 4 s, with about 30 frames after it. Too little to decide, where the
        // same clip from its first frame decides film.
        let verdict = try probe(TelecineCadenceFixtures.telecinedFilm, startSeconds: 4.6)
        guard case .inconclusive(let reason, let report) = verdict else {
            Issue.record("expected .inconclusive, got \(verdict)")
            return
        }
        #expect(reason.hasPrefix("only"), "\(reason)")
        #expect(report.frames < TelecineCadenceAnalyzer.minimumDecided)
    }
}
