import Testing
import Foundation
@testable import AetherEngine

/// #281: opening a non-faststart MP4 cost three sequential round trips before the frame rate was
/// known: the data connection from byte zero, a reconnect to the trailing `moov`, and a third one
/// back to the first sample. The second is inherent to the layout, the third was not: the seek to
/// the tail discarded a window that already held the bytes the return trip went back for.
///
/// These tests work in byte offsets rather than through a real container, so they pin the reader's
/// behaviour rather than one fixture's box layout.
@Suite("Cold-start round trips (#281)", .offCooperativePool, .timeLimit(.minutes(2)))
struct Issue281ColdStartRoundTripTests {

    private let fileSize: Int64 = 512 * 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    private func read(_ reader: AVIOReader, _ size: Int) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(size))
    }

    /// Waits for the speculative fetch to reach the origin. Nothing in the reader blocks on it, but
    /// every caller needs it out, so the wait has no deadline of its own.
    private func waitForTailSpan(_ server: ThrottledOriginServer, tailStart: Int64) async throws {
        try await waitFor {
            server.requestedRanges.contains(where: { $0.start == tailStart })
        }
    }

    @Test("open issues a suffix range for the tail alongside the data connection")
    func openPrefetchesTail() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        try await waitForTailSpan(server, tailStart: tailStart)

        let tail = try #require(server.requestedRanges.first(where: { $0.start == tailStart }),
                                "no tail prefetch was issued: \(server.requestedRanges)")
        #expect(tail.end == fileSize - 1)
    }

    /// The half that removes a whole round trip on the reporter's source: the trailing object is
    /// read without the reader ever connecting to it.
    @Test("a read inside the prefetched tail costs no additional request")
    func tailReadIsServedFromThePrefetch() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 64 * 1024)   // head, as a demuxer walking the box chain would

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        try await waitForTailSpan(server, tailStart: tailStart)
        let requestsBefore = server.rangeRequestCount

        #expect(reader.seek(offset: tailStart + 1024, whence: SEEK_SET) == tailStart + 1024)
        let got = read(reader, 4096)

        #expect(got == 4096, "tail read returned \(got)")
        #expect(server.rangeRequestCount == requestsBefore,
                "tail read opened a connection despite the prefetch: \(server.requestedRanges)")
    }

    /// The retest shape. A loopback origin answers before the demuxer can get anywhere, so every
    /// test above passes while the field trace stays unchanged: there, the data connection's first
    /// byte costs a real round trip, the demuxer walks the box chain and seeks to the tail within
    /// microseconds of it, and the speculative fetch, which pays the SAME round trip plus a body,
    /// is still on the wire at that moment. A fetch nothing waits on therefore never once serves
    /// the read it exists for, and the round trip it was meant to remove is paid in full.
    ///
    /// Both requests are delayed here because both cross the same origin; the suffix one is slower
    /// only by the body it carries, which is the whole margin by which it loses.
    ///
    /// The budget is pinned rather than derived. Deriving it put the test's own two latencies on
    /// either side of a bound computed from one of them (2 x 400 ms against a 550 ms fetch), and a
    /// loaded CI runner spent that 250 ms margin and reconnected, failing a test whose subject is
    /// whether the reader waits at all. The bound's calibration is checked separately, below.
    ///
    /// Pinned at 5 s it still failed once: the budget runs from the fetch's ISSUE, and a starved
    /// run (every test in this suite took 24 to 29 s, the one with no origin delay at all included)
    /// spent it before the read arrived while the landed body was still queued for its delegate.
    /// The suite's time limit is the only bound this test needs.
    ///
    /// The fetch's own request timeout is the detour budget (4 s), and a starved run spent that too:
    /// "tail prefetch rejected after 4057ms: transport: The request timed out" against a 550 ms
    /// origin, then the reconnect. Raised with the wait budget, for the same reason.
    @Test("a tail read waits for a fetch already on the wire instead of connecting past it")
    func tailReadWaitsForTheInFlightPrefetch() async throws {
        let delayed = ThrottledOriginServer(
            totalSize: fileSize,
            firstByteDelayUs: { isSuffix in isSuffix ? 550_000 : 400_000 })
        let server = try #require(delayed)
        defer { server.stop() }
        let label = "tail-wait-\(UUID().uuidString.prefix(8))"
        let log = EngineLogCapture()
        defer { log.end() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, label: label,
                                detourFetchBudget: 90)
        reader.tailPrefetchWaitBudgetForTesting = 90
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 64 * 1024)   // the box chain at the head

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        try await waitForTailSpan(server, tailStart: tailStart)   // the REQUEST is out; its body is not

        #expect(reader.seek(offset: tailStart + 1024, whence: SEEK_SET) == tailStart + 1024)
        let got = read(reader, 4096)

        #expect(got == 4096, "tail read returned \(got)")
        // On the range, not on the count: the reconnect this forbids is identifiable by where it
        // starts (the read position), and a bare count cannot tell it from any other arrival.
        #expect(!server.requestedRanges.contains(where: { $0.start == tailStart + 1024 }),
                "the tail read connected past a fetch already in flight: \(server.requestedRanges); reader log: \(log.matching(label))")
    }

    /// The wait above has to be bounded by something, and the bound is what one round trip against
    /// this origin was measured to cost: past that the fetch is not about to land and a fresh
    /// connection is the better bet. An origin that sits on the suffix request must therefore cost a
    /// reconnect, not an open that hangs on a speculative request nothing depends on.
    @Test("a fetch that is not going to land does not hold the read")
    func tailWaitIsBounded() async throws {
        // The suffix stall has to outlast any pause the test itself can be handed: at 3 s, a test
        // task resumed late found the fetch landed and no fallback left to observe.
        let stalling = ThrottledOriginServer(
            totalSize: fileSize,
            firstByteDelayUs: { isSuffix in isSuffix ? 60_000_000 : 0 })
        let server = try #require(stalling)
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 64 * 1024)

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        try await waitForTailSpan(server, tailStart: tailStart)
        let requestsBefore = server.rangeRequestCount

        let startedAt = Date()
        #expect(reader.seek(offset: tailStart + 1024, whence: SEEK_SET) == tailStart + 1024)
        let got = read(reader, 4096)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(got == 4096, "tail read returned \(got)")
        // Against the 60 s stall, not against the budget: a loaded runner measures a slower first
        // byte and spends seconds on the fallback connection, and either is a healthy read.
        #expect(elapsed < 30.0, "the read waited \(elapsed)s on a fetch that had not landed")
        #expect(server.rangeRequestCount > requestsBefore,
                "the read never fell back to a connection: \(server.requestedRanges)")
    }

    /// The other half: after a parse seek to the tail, coming back to the head is a copy out of the
    /// retained head rather than a third connection.
    @Test("returning to the head after a parse seek costs no additional request")
    func returnTripIsServedFromTheRetainedHead() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)   // fill the window at the head

        // A parse seek far enough forward to leave the window and force a reconnect, but NOT into
        // the prefetched tail, so this exercises the retained head rather than the tail span.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        // Back to the head, where the demuxer reads the first sample.
        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "return read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterSeek,
                "the return trip reconnected instead of using the retained head: \(server.requestedRanges)")
    }

    /// #281 parked the window at seek time, cut from `winStart`, which is the head of the FILE only
    /// while the parse seeks away before reading anything. A parse that reads past `winLookback`
    /// first, which the fragmented layout does by 33 MB, moves `winStart` off the head, and the
    /// return trip the park existed for lands in front of everything parked. Retaining the head as
    /// it arrives is what covers that, and it is measurable: with 300 ms of origin latency per
    /// request, aetherctl's open of a fragmented fixture went from 1732 ms and four requests to
    /// 1219 ms and three.
    @Test("the return to the head survives a parse that read past the window's start")
    func headIsRetainedWhenTheWindowMovesOn() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Past winLookback, so the window no longer starts at the head and a park taken now would
        // begin megabytes into the file.
        _ = read(reader, 20 * 1024 * 1024)

        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "return read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterSeek,
                "the return to the head reconnected: \(server.requestedRanges)")
    }

    /// #281 second retest: releasing the head when the parse ended was one read too early.
    ///
    /// After a trailing-index parse the anchored connection sits at the END of the file, so the
    /// first read of playback is a backward one, and it lands at the head: measured landings of 48
    /// and 263303 in aetherctl, 5752 in the field trace, where it cost a fresh connection whose
    /// first byte took 865 ms. No `probe`-based measurement could see this, because `probe` exits at
    /// exactly the call this tests past.
    @Test("the head survives the open phase to serve playback's first read")
    func headServesPlaybacksFirstRead() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)

        // The parse excursion to a trailing object, which is what leaves the anchor off the head.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)

        reader.markOpenPhaseFinished()
        let requestsAfterParse = server.rangeRequestCount

        // Playback's first read: back at the head, with the connection anchored elsewhere.
        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "playback's first read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterParse,
                "playback's first read reconnected instead of using the retained head: \(server.requestedRanges)")
    }

    /// The head is kept for one read, not forever. Once playback has moved past what it holds, it is
    /// megabytes with nothing left to serve.
    @Test("after the open phase the head is no longer retained")
    func parkingStopsAfterTheOpenPhase() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)

        reader.markOpenPhaseFinished()

        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        _ = read(reader, 32 * 1024)

        #expect(server.rangeRequestCount > requestsAfterSeek,
                "the head was still retained after the open phase ended")
    }

    /// Suffix ranges are not universally implemented. An origin that does not do them answers the
    /// speculative request with 200 and the WHOLE file, and a speculative optimisation that
    /// downloads a feature film to discard it is worse than the round trip it saves. The fetch has
    /// to hang up at the response header, before the body.
    @Test("an origin that answers a suffix range with the whole file is hung up on at the header")
    func wholeFileAnswerIsRejectedAtTheHeader() async throws {
        let declared: Int64 = 4 * 1024 * 1024 * 1024      // a 4 GB "film"
        let bodyOnOffer = 32 * 1024 * 1024                // what the origin would happily write
        let server = try #require(ScriptedOriginServer { recorded in
            // Only the tail prefetch asks with a suffix range; answer that one as a Range-blind
            // origin does. Everything else keeps working so open() itself is unaffected.
            if recorded.range?.contains("bytes=-") == true {
                return .init(status: 200, declaredLength: declared, bodyBytes: bodyOnOffer)
            }
            return .init(status: 206,
                         declaredLength: Int64(1024 * 1024),
                         contentRange: "bytes 0-1048575/\(declared)",
                         bodyBytes: 1024 * 1024)
        })
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/big.mp4")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        try await waitFor { server.requests.contains(where: { $0.range?.contains("bytes=-") == true }) }
        // Give the fetch time to do the wrong thing if it is going to.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Some bytes may be in flight before the cancel lands; what must not happen is the body
        // being taken. Anything near bodyOnOffer means the response was accepted. The count is what
        // the server's write() handed to the kernel, and the loopback socket buffers take a few MB
        // of one write without the client reading a byte (exactly 4 MB, measured), so the bound
        // sits between that and the offer rather than at the buffer size.
        #expect(server.bodyBytesWritten < bodyOnOffer / 2,
                "the 200 body was being downloaded: \(server.bodyBytesWritten) bytes written")
    }

    /// #281 second retest, the reporter's origin: it answers `bytes=-65536` with a 200 and the whole
    /// file, on EVERY open. Hanging up at the header keeps the body off the wire, but the request
    /// itself is still a second connection opened at the same instant as the data connection whose
    /// first byte IS the cold start, and paid again on every open, against a server that has already
    /// shown it cannot serve it.
    @Test("an origin that declined a suffix range is not asked again", .timeLimit(.minutes(3)))
    func declinedSuffixRangesAreNotRetried() async throws {
        let declared: Int64 = 4 * 1024 * 1024 * 1024
        let server = try #require(ScriptedOriginServer { recorded in
            if recorded.range?.contains("bytes=-") == true {
                return .init(status: 200, declaredLength: declared, bodyBytes: 1024)
            }
            return .init(status: 206,
                         declaredLength: Int64(1024 * 1024),
                         contentRange: "bytes 0-1048575/\(declared)",
                         bodyBytes: 1024 * 1024)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/big.mp4")!

        let first = AVIOReader(url: url)
        try first.open()
        try await waitFor { SuffixRangeSupport.shared.denialReason(for: url) != nil }
        first.markClosed(); first.close()

        let reason = try #require(SuffixRangeSupport.shared.denialReason(for: url),
                                  "the 200 answer was never recorded, so this proves nothing")
        #expect(reason.contains("200"))

        let second = AVIOReader(url: url)
        defer { second.markClosed(); second.close() }
        try second.open()
        try await Task.sleep(nanoseconds: 300_000_000)

        let suffixRequests = server.requests.filter { $0.range?.contains("bytes=-") == true }
        #expect(suffixRequests.count == 1,
                "the second open asked an origin that had already declined: \(suffixRequests.count) suffix requests")
    }

    /// What latches, and what does not. A 200 is the server's answer and will repeat; a timeout is
    /// the network's, and a link bad enough to lose this request loses others, so it takes two
    /// before the origin is judged by it.
    @Test("only the origin's own answer latches on the first occurrence")
    func onlyOriginAnswersLatchImmediately() throws {
        let support = SuffixRangeSupport()
        let refusing = URL(string: "http://refusing.invalid:8080/a.mp4")!
        let flaky = URL(string: "http://flaky.invalid:8080/a.mp4")!

        support.noteDeclined(refusing, reason: "status=200 (no suffix range support)")
        #expect(support.denialReason(for: refusing) != nil)

        #expect(support.noteTransportFailure(flaky, reason: "transport: timed out") == false)
        #expect(support.denialReason(for: flaky) == nil, "one timeout condemned the origin")
        #expect(support.noteTransportFailure(flaky, reason: "transport: timed out") == true)
        #expect(support.denialReason(for: flaky) != nil)

        // A fetch that lands says those failures were not this origin refusing the form.
        let recovering = URL(string: "http://recovering.invalid:8080/a.mp4")!
        #expect(support.noteTransportFailure(recovering, reason: "transport: timed out") == false)
        support.noteServed(recovering)
        #expect(support.noteTransportFailure(recovering, reason: "transport: timed out") == false)
        #expect(support.denialReason(for: recovering) == nil,
                "the tally survived a fetch that was served")
    }

    /// Suffix-range support is a property of the server, not of one file on it.
    @Test("the origin key is scheme, host and port")
    func originKeyIgnoresPath() throws {
        let a = try #require(SuffixRangeSupport.originKey(
            for: URL(string: "https://cdn.invalid:8443/a/one.mp4")!))
        let b = try #require(SuffixRangeSupport.originKey(
            for: URL(string: "https://cdn.invalid:8443/b/two.mkv?token=x")!))
        let other = try #require(SuffixRangeSupport.originKey(
            for: URL(string: "https://cdn.invalid:9443/a/one.mp4")!))
        #expect(a == b)
        #expect(a != other)
    }

    /// A 206 that answers with some region other than the one asked for must not be installed at the
    /// requested offset. The header, not the request, says where bytes live.
    @Test("tail bytes are only accepted when Content-Range agrees with them")
    func suffixStartIsTakenFromTheHeader() throws {
        let url = URL(string: "http://example.invalid/movie.bin")!
        func response(_ contentRange: String?, length: Int) -> HTTPURLResponse {
            var headers: [String: String] = [:]
            if let contentRange { headers["Content-Range"] = contentRange }
            return HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        }

        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/1000", length: 100),
                                            expectedLength: 100) == 900)
        // Length disagrees with the header: a truncated or padded body, offsets unknowable.
        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/1000", length: 64),
                                            expectedLength: 64) == nil)
        #expect(AVIOReader.suffixRangeStart(response(nil, length: 100), expectedLength: 100) == nil)
        #expect(AVIOReader.suffixRangeStart(response("bytes */1000", length: 100),
                                            expectedLength: 100) == nil)
        // Audit DMX-8: a suffix ends on the last byte of a numeric total, or it is not a suffix.
        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/*", length: 100),
                                            expectedLength: 100) == nil)
        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/2000", length: 100),
                                            expectedLength: 100) == nil)
        #expect(AVIOReader.suffixRangeStart(
            response("bytes 9223372036854775708-9223372036854775807/*", length: 100),
            expectedLength: 100) == nil)
    }

    /// The calibration the in-flight test above no longer carries, checked where it costs no socket
    /// and no wall clock: two measured round trips, floored so a cache-warm first connection still
    /// buys a wait, capped so a hung fetch cannot own the open.
    @Test("the wait budget is two measured round trips, floored and capped")
    func waitBudgetIsTwoRoundTrips() {
        #expect(AVIOReader.tailPrefetchWaitBudget(firstDataMs: 400) == 0.8)
        #expect(AVIOReader.tailPrefetchWaitBudget(firstDataMs: 0) == 0.25)
        #expect(AVIOReader.tailPrefetchWaitBudget(firstDataMs: 50) == 0.25)
        #expect(AVIOReader.tailPrefetchWaitBudget(firstDataMs: 10_000) == 5.0)
    }
}
