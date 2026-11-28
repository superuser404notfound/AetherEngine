import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #240 (cmcpherson274, custom tvOS host, 48 GB 4K remux over ~90 Mbit/s Wi-Fi): far seeks in a
/// rapid sequence landed in 13 to 25 s instead of the 4 to 6 s an isolated seek took, and the same
/// segment that served in 2.2 s alone took 7.5 s in the burst. Same bytes, same link: something else
/// was using it.
///
/// It was the subtitle side reader. On Matroska a "subtitle-only" reader is a second full copy of
/// the stream (`matroska_parse_cluster` reads every block off the wire, `matroska_parse_block` only
/// then honours the discard flag), so a subtitled session asks the link for about twice the media
/// rate, measured at 2.6x in #220. At 1.38x headroom the two readers split the link, the seek
/// landing budget expired, and the recovery re-anchor jumped the clock, which rebuilt the prefetch
/// session, which took more link: the engine starved itself in a loop it kept feeding.
///
/// The fix is a strict priority rather than a share. Playback is load-bearing, subtitle lookahead is
/// not, so a side reader fetches while the video path does not need the link, with a bounded grace
/// window after each anchor so a fresh selection is not left with an empty store, and a yield cap so
/// a signal that never clears cannot mute lookahead for the session either.
struct Issue240SideReaderLinkPriorityTests {

    // MARK: - The policy

    /// The reported window. A seek owns the link until it lands; that budget is the whole point,
    /// and not even a just-anchored reader may spend it.
    @Test("a seek in flight takes the link, grace window or not")
    func seekWins() {
        #expect(SideReaderLinkPolicy.shouldYield(
            seeking: true, videoProducing: false, inAnchorGrace: false, yieldedSeconds: 0))
        #expect(SideReaderLinkPolicy.shouldYield(
            seeking: true, videoProducing: true, inAnchorGrace: true, yieldedSeconds: 0))
    }

    /// A pump that is pulling from the source outranks lookahead.
    @Test("a fetching producer takes the link from a settled side reader")
    func producerWinsOutsideGrace() {
        #expect(SideReaderLinkPolicy.shouldYield(
            seeking: false, videoProducing: true, inAnchorGrace: false, yieldedSeconds: 0))
    }

    /// The grace window: a freshly anchored reader has nothing in the store for the new position,
    /// so it fetches through a busy pump for a bounded time. Bounded is the load-bearing word: the
    /// rule this replaced was "fetch while the lead is under 5 s", and on a link that cannot carry
    /// two readers the lead never rises, so that rule never expired. Measured on a 1.4x bench, the
    /// reader kept 47% of the link and the seek landings did not move.
    @Test("a just-anchored reader fetches through a busy pump, a settled one does not")
    func anchorGraceIsBounded() {
        #expect(!SideReaderLinkPolicy.shouldYield(
            seeking: false, videoProducing: true, inAnchorGrace: true, yieldedSeconds: 0))
        #expect(SideReaderLinkPolicy.shouldYield(
            seeking: false, videoProducing: true, inAnchorGrace: false, yieldedSeconds: 0))
    }

    /// A parked pump has a full buffer and no use for the link.
    @Test("an idle video path leaves the link to the side reader")
    func idleVideoPathYieldsTheLink() {
        #expect(!SideReaderLinkPolicy.shouldYield(
            seeking: false, videoProducing: false, inAnchorGrace: false, yieldedSeconds: 0))
    }

    /// The valve. A wedged pump never parks and a host that reports no producer at all never claims
    /// the link; neither may silently disable subtitle lookahead for the rest of the session.
    @Test("a continuous yield past the cap takes the link back")
    func yieldCapIsAValve() {
        #expect(SideReaderLinkPolicy.shouldYield(
            seeking: true, videoProducing: true, inAnchorGrace: false,
            yieldedSeconds: SideReaderLinkPolicy.maxYieldSeconds - 0.01))
        #expect(!SideReaderLinkPolicy.shouldYield(
            seeking: true, videoProducing: true, inAnchorGrace: false,
            yieldedSeconds: SideReaderLinkPolicy.maxYieldSeconds))
    }

    // MARK: - The gate

    /// A restart overlaps an exiting pump with a starting one. A flag would let the old pump's
    /// teardown clear the new pump's claim, and the side readers would read a free link in the
    /// middle of the busiest moment there is.
    @Test("the producing claim is a count, so a restart cannot drop it")
    func gateCountsClaims() {
        let gate = SideReaderLinkGate()
        #expect(gate.state.videoProducing == false)

        gate.videoFetchBegan()      // pump A running
        gate.videoFetchBegan()      // pump B (restart) starts before A has unwound
        gate.videoFetchEnded()      // A exits
        #expect(gate.state.videoProducing, "B is still pulling from the source")

        gate.videoFetchEnded()
        #expect(gate.state.videoProducing == false)

        gate.videoFetchEnded()      // unbalanced extra
        #expect(gate.state.videoProducing == false, "the count floors at zero")
    }

    @Test("the seek flag mirrors what it is set to")
    func gateMirrorsSeeking() {
        let gate = SideReaderLinkGate()
        gate.setSeeking(true)
        #expect(gate.state.seeking)
        gate.setSeeking(false)
        #expect(gate.state.seeking == false)
    }

    // MARK: - The prefetch loop

    /// Fixture is Issue104SubtitleDiscardTests': 15 s MP4, h264 at 10 fps with IRAPs at 0/3/6/9/12 s,
    /// plus mov_text samples at 0/1/3/8/10/13/14.5 s.
    private static func makeDemuxer() throws -> Demuxer {
        let data = try #require(Data(base64Encoded: Issue104SubtitleDiscardTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    /// Run the real loop against the fixture with the park disabled, so the only thing that can stop
    /// the read is the link arbitration. The playhead closure holds at 0 for a bounded number of
    /// calls and then returns nil, the loop's "engine gone" exit, so a yielding loop terminates
    /// instead of spinning the test.
    private static func harvestedPTS(
        link: SideReaderLinkArbiter?,
        reanchor: SubtitleForwardPrefetcher.SideReaderReanchor? = nil,
        playheadCalls: Int = 200,
        leadSeconds: Double = 3600,
        requestAnchor: (onCall: Int, seconds: Double)? = nil
    ) async throws -> [Double] {
        let demuxer = try makeDemuxer()
        defer { demuxer.close() }
        let subtitleIndex = Int32(try #require(demuxer.subtitleTrackInfos().first).id)
        demuxer.seek(to: 0)
        let pacingIndex = demuxer.prefetchPacingStreamIndex()
        demuxer.discardAllStreamsExcept([subtitleIndex], pacing: pacingIndex)

        let store = SubtitlePacketStore()
        let calls = CallBudget(limit: playheadCalls)
        _ = await SubtitleForwardPrefetcher.run(
            demuxer: demuxer, store: store,
            streamIndices: [subtitleIndex], assemblyIndices: [],
            pacingIndex: pacingIndex,
            leadSeconds: leadSeconds,          // 3600 disables the park: the arbitration is the subject
            parkPollNanoseconds: 1_000_000,
            link: link,
            reanchor: reanchor,
            playhead: {
                guard await calls.next() else { return nil }
                // #496: the park is what calls back, so a request posted from here arrives while
                // the reader is parked, which is the shape a backward seek leaves behind.
                if let requestAnchor, await calls.used == requestAnchor.onCall {
                    reanchor?.request(requestAnchor.seconds)
                }
                return 0.0
            })
        return store.entries(streamIndex: subtitleIndex, from: 0, through: 1000).map(\.ptsSeconds)
    }

    private static func arbiter(
        seeking: Bool = false, videoProducing: Bool = false,
        maxYieldSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds,
        valveGrantSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds,
        anchorGraceSeconds: Double = 0
    ) -> SideReaderLinkArbiter {
        var a = SideReaderLinkArbiter(state: { (seeking, videoProducing) })
        a.maxYieldSeconds = maxYieldSeconds
        a.valveGrantSeconds = valveGrantSeconds
        a.anchorGraceSeconds = anchorGraceSeconds
        a.pollNanoseconds = 1_000_000
        return a
    }

    /// The defect and the fix in one pair. Ungated the reader walks the whole file, which over a
    /// 48 GB remux is the second copy of the stream that took the reporter's link; gated behind a
    /// fetching video path it stops once its grace window is spent.
    @Test("a fetching video path stops the side reader once its grace is spent")
    func readerStopsWhileTheVideoPathFetches() async throws {
        let ungated = try await Self.harvestedPTS(link: nil)
        #expect(ungated.contains { $0 >= 13 }, "ungated the reader walks the whole fixture")

        let gated = try await Self.harvestedPTS(link: Self.arbiter(videoProducing: true))
        #expect(!gated.contains { $0 >= 13 }, "a busy video path owns the link")

        let inGrace = try await Self.harvestedPTS(
            link: Self.arbiter(videoProducing: true, anchorGraceSeconds: 30))
        #expect(inGrace.contains { $0 >= 13 },
                "inside its grace window the reader fetches through a busy pump")
    }

    /// The reported window, at the loop: a seek in flight stops the reader even below the floor,
    /// because the landing budget is what the priority exists to protect.
    @Test("a seek in flight stops the side reader")
    func readerStopsWhileSeeking() async throws {
        let gated = try await Self.harvestedPTS(link: Self.arbiter(seeking: true))
        #expect(gated.isEmpty, "a seek owns the link until it lands")
    }

    /// The valve, at the loop: a signal that never clears must not mute subtitles for good.
    @Test("the yield cap lets the reader through a signal that never clears")
    func yieldCapReleasesTheReader() async throws {
        let gated = try await Self.harvestedPTS(
            link: Self.arbiter(seeking: true, videoProducing: true, maxYieldSeconds: 0.002))
        #expect(gated.contains { $0 >= 13 },
                "past the cap the reader takes the link back rather than staying dark")
    }

    /// And it must hold the link long enough to be worth having. The cap is evaluated per loop
    /// iteration, so without a grant window the valve would return one packet and yield again for a
    /// full cap: a duty cycle indistinguishable from silence. With a zero-length grant that is
    /// exactly what happens, and this is the test that would catch its removal.
    @Test("the valve hands back a window, not a single packet")
    func valveGrantsAWindow() async throws {
        let noGrant = try await Self.harvestedPTS(
            link: Self.arbiter(seeking: true, videoProducing: true,
                               maxYieldSeconds: 0.002, valveGrantSeconds: 0),
            playheadCalls: 6)
        let withGrant = try await Self.harvestedPTS(
            link: Self.arbiter(seeking: true, videoProducing: true,
                               maxYieldSeconds: 0.002, valveGrantSeconds: 30),
            playheadCalls: 6)
        #expect(withGrant.count > noGrant.count,
                "the same yield budget must buy more than one packet at a time")
    }

    // MARK: - In-place re-anchor

    /// A playhead jump used to tear the session down and build a new one: fresh open, Matroska
    /// cue-index prewarm, positioning seek, each a bounded 32 MiB range the origin delivers in full.
    /// The running session already holds an open, positioned demuxer, so a jump is one seek.
    @Test("a pending re-anchor moves the running reader instead of rebuilding it")
    func reanchorMovesTheCursorInPlace() async throws {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 15, seekTimeout: 5)
        box.request(10)

        let harvested = try await Self.harvestedPTS(link: nil, reanchor: box)
        #expect(harvested.contains { $0 >= 10 }, "the reader must land at the requested anchor")
        // The cue covering the anchor is expected: the shared backscan starts 2 s behind it, and on
        // mov each stream is positioned at its own sample at or before that, which here is the 3 s
        // cue. What must not come back is the run-up, the part a rebuilt session re-reads.
        #expect(!harvested.contains { $0 <= 1 },
                "the run-up before the anchor belongs to the session it was read in")
        #expect(box.take() == nil, "the request is consumed once, not re-run every iteration")
    }

    /// #496: both of the loop's waits sit BEFORE the point where the pending move is taken, so
    /// either of them can hold a move the viewer has already made. Reported as subtitles dropping
    /// out for 20 to 40 s at a time in the middle of healthy playback, with `prefetchLead` measured
    /// at -215.8 s: a reader still banking packets for the stretch the viewer left, while the
    /// stretch he is in is harvested by nobody.
    @Test("a busy video path may not hold a pending re-anchor")
    func reanchorSurvivesTheLinkYield() async throws {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 15, seekTimeout: 5)
        box.request(10)

        _ = try await Self.harvestedPTS(
            link: Self.arbiter(videoProducing: true, anchorGraceSeconds: 0), reanchor: box)
        #expect(box.take() == nil, "the move must be applied, not left waiting on the link")
        // What the reader then BANKS at the new position is bought by the grace window, which
        // `readerStopsWhileTheVideoPathFetches` covers; this arbiter runs with none on purpose, so
        // that applying the move is the only thing the expectation above can be measuring.
    }

    /// The other wait, and the worse one: a backward seek leaves the read position far past the new
    /// playhead, so the park's own condition stays true for as long as the viewer stays behind it.
    /// The pending move is what ends that, and the park never looks.
    @Test("a parked reader may not hold a pending re-anchor")
    func reanchorSurvivesThePark() async throws {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 15, seekTimeout: 5)

        // Lead 1 s against a playhead held at 0 parks the loop on the fixture's 3 s cue, and the
        // move arrives after that, from inside the park's own callback.
        _ = try await Self.harvestedPTS(link: nil, reanchor: box, leadSeconds: 1,
                                        requestAnchor: (onCall: 3, seconds: 0))
        #expect(box.take() == nil, "the move must be applied, not left waiting behind the park")
    }

    /// A seek burst is several jumps in a few seconds. The reader owes the link one move to where
    /// the viewer ended up, not one per seek along the way.
    @Test("only the newest anchor survives a burst")
    func latestRequestWins() {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 0, seekTimeout: 1)
        box.request(600, seekGeneration: 4)
        box.request(30, seekGeneration: 5)
        box.request(302, seekGeneration: 6)
        // #250: the surviving request carries its own seek generation, so the position the reader
        // banks after the move is fenced to the seek that asked for it, not to the burst's first.
        #expect(box.take() == .init(seconds: 302, seekGeneration: 6))
        #expect(box.take() == nil)
    }

    @Test("clearing drops a pending request")
    func clearDropsPending() {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 0, seekTimeout: 1)
        box.request(42)
        box.clear()
        #expect(box.take() == nil)
    }

    // MARK: - Shared positioning

    /// Both the session start and the in-place move go through one positioning function, so an
    /// in-place anchor cannot drift from the rules the session was built with (#234).
    @Test("positioning seeks behind the anchor by the shared backscan")
    func repositionAppliesTheBackscan() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitleIndex = Int32(try #require(demuxer.subtitleTrackInfos().first).id)

        let landed = SubtitleForwardPrefetcher.reposition(
            demuxer: demuxer, to: 10, anchorCandidates: [subtitleIndex],
            fallbackDuration: 15, timeout: 5)
        #expect(landed == .seek)

        var firstSubtitlePts: Double? = nil
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == subtitleIndex, pkt.pointee.pts != Int64.min,
               let tb = demuxer.stream(at: subtitleIndex)?.pointee.time_base {
                firstSubtitlePts = Double(pkt.pointee.pts) * Double(tb.num) / Double(tb.den)
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            if firstSubtitlePts != nil { break }
        }
        let pts = try #require(firstSubtitlePts)
        #expect(pts >= 8 - 0.001,
                "the backscan starts at the anchor minus \(SubtitleForwardPrefetcher.anchorBackscanSeconds)s")
        #expect(pts <= 10, "and not so far back that the whole gap is re-read")
    }
}

/// Bounded playhead source: hands out a fixed playhead for `limit` calls, then nil, which is the
/// loop's engine-gone exit. Lets a yielding loop terminate without a timeout.
private actor CallBudget {
    private var remaining: Int
    private(set) var used = 0
    init(limit: Int) { remaining = limit }
    func next() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        used += 1
        return true
    }
}
