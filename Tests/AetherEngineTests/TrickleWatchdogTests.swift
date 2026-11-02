import Testing
import Foundation
@testable import AetherEngine

/// A connection that TRICKLES while a read waits on it.
///
/// The field case (4K HDR over a debrid origin, held connection): a fresh generation delivered about
/// 256 KB every 40 to 100 s for three minutes. Every drip reset the delivery-gap watchdog's clock
/// and signalled the read loop's forward wait, so neither detector ever fired, the consumer sat in
/// one slow read after another and AVPlayer stalled. The trickle watchdog judges volume over the
/// last stall period instead, and only while a read is actually blocked on forward data.
///
/// The origin here paces each response individually, which `ThrottledOriginServer` cannot (its
/// throttle is per server, and the open must stay fast): the first request at `dripOffset` gets the
/// scripted pace, every other request is served at loopback speed.
@Suite("Trickle watchdog", .serialized, .offCooperativePool)
struct TrickleWatchdogTests {

    private static let totalSize: Int64 = 256 * 1024 * 1024
    /// The open's bounded range. Its completion puts the next request at `dripOffset`.
    private static let firstRange: Int64 = 2 * 1024 * 1024
    // AE#958: the refill at the frontier re-reads the held bytes before it to check the origin, so the
    // request the origin sees starts that much earlier.
    private static var dripOffset: Int64 { firstRange - Int64(AVIOReader.rangeCheckBytes) }
    private static let stallTimeout: TimeInterval = 0.5

    /// How one response body is written.
    enum Pace: Sendable {
        case fast
        /// `bytes` per write, then `everyUs` microseconds of sleep.
        case drip(bytes: Int, everyUs: useconds_t)
        /// `bytes` at loopback speed, then nothing more on an open socket (no FIN, no error).
        case silentAfter(bytes: Int)
    }

    /// Loopback 206 origin with a per-request pace. Keep-alive, Range-aware, no other features.
    final class PacedOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let totalSize: Int64
        private let pace: @Sendable (_ start: Int64, _ attemptAtStart: Int) -> Pace
        private let lock = NSLock()
        private var _stopped = false
        private var _fds: [Int32] = []
        private var _requests: [(start: Int64, at: Date)] = []
        private var _paceOverride: Pace?

        /// Re-paces every body from its next write on, including one already in progress.
        func setPaceOverride(_ pace: Pace?) {
            lock.lock(); _paceOverride = pace; lock.unlock()
        }
        private var paceOverride: Pace? {
            lock.lock(); defer { lock.unlock() }
            return _paceOverride
        }

        init?(totalSize: Int64, pace: @escaping @Sendable (_ start: Int64, _ attemptAtStart: Int) -> Pace) {
            guard let listener = LoopbackListener() else { return nil }
            self.listener = listener
            self.port = listener.port
            self.totalSize = totalSize
            self.pace = pace
            listener.start { [self] fd in admit(fd) }
        }

        var requests: [(start: Int64, at: Date)] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        private var stopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return _stopped
        }

        func stop() {
            lock.lock()
            let already = _stopped
            _stopped = true
            let fds = already ? [] : _fds
            for fd in fds { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
            if !already { listener.stop() }
        }

        private func admit(_ fd: Int32) -> Bool {
            lock.lock()
            if _stopped {
                lock.unlock()
                shutdown(fd, SHUT_RDWR)
                close(fd)
                return false
            }
            _fds.append(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in
                while !stopped, serveOne(fd) {}
                lock.lock()
                _fds.removeAll { $0 == fd }
                close(fd)
                lock.unlock()
            }
            return true
        }

        private func serveOne(_ fd: Int32) -> Bool {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var collected = Data()
            while collected.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return false }
                collected.append(contentsOf: buf[0..<n])
            }
            let request = String(decoding: collected, as: UTF8.self)
            var start: Int64 = 0
            var last = totalSize - 1
            if let line = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }),
               let eq = line.range(of: "bytes=") {
                let spec = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    if parts[0].isEmpty, let suffix = Int64(parts[1]) {
                        start = max(0, totalSize - suffix)
                    } else {
                        start = Int64(parts[0]) ?? 0
                        if let end = Int64(parts[1]) { last = min(end, totalSize - 1) }
                    }
                }
            }
            lock.lock()
            let attempt = _requests.filter { $0.start == start }.count + 1
            _requests.append((start, Date()))
            lock.unlock()

            let length = last - start + 1
            let header = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(start)-\(last)/\(totalSize)\r\n"
                + "Content-Length: \(length)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: keep-alive\r\n\r\n"
            guard writeAll(fd, Array(header.utf8)) else { return false }

            let requested = pace(start, attempt)
            let body = [UInt8](repeating: 0x55, count: 256 * 1024)
            var sent: Int64 = 0
            while sent < length {
                if stopped { return false }
                let current = paceOverride ?? requested
                let piece: Int
                var sleepUs: useconds_t = 0
                switch current {
                case .fast:
                    piece = 256 * 1024
                case .drip(let bytes, let everyUs):
                    piece = min(bytes, body.count)
                    sleepUs = everyUs
                case .silentAfter(let bytes):
                    if sent >= Int64(bytes) {
                        while !stopped { usleep(50_000) }
                        return false
                    }
                    piece = min(body.count, bytes - Int(sent))
                }
                let n = Int(min(Int64(piece), length - sent))
                guard writeAll(fd, Array(body[0..<n])) else { return false }
                sent += Int64(n)
                if sleepUs > 0 { usleep(sleepUs) }
            }
            return true
        }

        private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { return false }
                off += n
            }
            return true
        }
    }

    /// Reads on a detached thread so the blocking read never runs on the test's own thread.
    private static func readInBackground(_ reader: AVIOReader, bytes target: Int,
                                         sliceCap: Int) async -> Int {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
                defer { buf.deallocate() }
                var got = 0
                let stopAt = Date().addingTimeInterval(60)
                while got < target && Date() < stopAt {
                    let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
                    if n <= 0 { break }
                    got += Int(n)
                }
                continuation.resume(returning: got)
            }
        }
    }

    private static func makeReader(_ origin: PacedOrigin, held: Bool = false,
                                   trickleFloorBytes: Int64? = nil,
                                   stallTimeout: TimeInterval = stallTimeout) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!,
                   boundedInitialFetch: held ? nil : firstRange,
                   connStallTimeout: stallTimeout, trickleFloorBytes: trickleFloorBytes,
                   heldConnection: held, backoffScale: 0.02)
    }

    /// Outcome of a read loop left running on its own thread, polled rather than awaited, so a test
    /// can observe a reader that never finishes and still close it.
    final class ReadProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var _got = 0
        private var _last: Int32?
        private var _done = false
        func add(_ n: Int) { lock.lock(); _got += n; lock.unlock() }
        func finish(last: Int32) { lock.lock(); _last = last; _done = true; lock.unlock() }
        var got: Int { lock.lock(); defer { lock.unlock() }; return _got }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
        var lastReturn: Int32? { lock.lock(); defer { lock.unlock() }; return _last }
    }

    private static func startReading(_ reader: AVIOReader, bytes target: Int) -> ReadProgress {
        let progress = ReadProgress()
        Thread.detachNewThread {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
            defer { buf.deallocate() }
            var got = 0
            var n: Int32 = 0
            while got < target {
                n = reader.read(into: buf, size: Int32(min(256 * 1024, target - got)))
                if n <= 0 { break }
                got += Int(n)
                progress.add(Int(n))
            }
            progress.finish(last: n)
        }
        return progress
    }

    // MARK: - Detection

    @Test("a connection trickling far below the floor while a read waits is ended and replaced",
          .timeLimit(.minutes(3)))
    func tricklingConnectionIsReplaced() async throws {
        let dripOffset = Self.dripOffset
        // 1 KB every 50 ms is 40 KB per 2 s period. The scaled floor at 2 s is 2 MiB / 10, about
        // 210 KB, so this is a fifth of it. The threshold is longer than the suite's because a loaded
        // runner that stalls the origin for a whole threshold opens a delivery gap: the gap path then
        // ends the connection first, the fast replacement finishes the read, and no trickle is seen
        // (0.5 s lost that race at a load average of 24).
        let stallTimeout: TimeInterval = 2
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { start, attempt in
            start == dripOffset && attempt == 1 ? .drip(bytes: 1024, everyUs: 50_000) : .fast
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin, stallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { !reader.hasLiveConnectionForTesting }

        // Past the first range: this read drains the window, puts the refill at `dripOffset` on the
        // wire, and then blocks on it.
        let target = Int(Self.firstRange) + 1024 * 1024
        let progress = Self.startReading(reader, bytes: target)
        try await waitFor { origin.requests.contains { $0.start == dripOffset } }
        let dripRequest = origin.requests.first { $0.start == dripOffset }
        let dripStartedAt = try #require(dripRequest?.at)

        try await waitFor { reader.trickleEndCountForTesting > 0 || progress.done }
        try #require(reader.trickleEndCountForTesting > 0, "the read finished without a trickle end")
        let detectedAfter = Date().timeIntervalSince(dripStartedAt)
        // Nominally two thresholds (one starved period, then the next tick). The bound is what the
        // drip would need to finish the read on its own, halved: a multiple of the threshold was
        // a wall-clock budget, and a runner that froze every test for a second spent it (10.97 s
        // against 10, 2026-11-02). A stall freezes the origin's drip too, so this one cannot be spent.
        let dripAlone = Double(target - Int(dripOffset)) / (1024 / 0.05)
        #expect(detectedAfter < dripAlone / 2,
                "the trickle was ended \(detectedAfter)s after it started, the drip alone needs \(dripAlone)s")

        // The replacement is asked for where the drip left off and served at full rate.
        try await waitFor { progress.done }
        #expect(progress.got == target, "the read did not complete after the trickle was replaced")
        let replacements = origin.requests.filter { $0.start > dripOffset && $0.start < dripOffset + 1024 * 1024 }
        #expect(!replacements.isEmpty, "no replacement request after the trickle end: \(origin.requests.map(\.start))")
    }

    // MARK: - No false positives

    @Test("a healthy stream a long read waits on is never ended as a trickle",
          .timeLimit(.minutes(3)))
    func healthyStreamIsLeftAlone() async throws {
        let dripOffset = Self.dripOffset
        // 64 KB every 20 ms, about 3 MB/s: well above the floor, and slow enough that one 4 MB read
        // waits several stall periods, which is the state the verdict is evaluated in.
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { start, _ in
            start == dripOffset ? .drip(bytes: 64 * 1024, everyUs: 20_000) : .fast
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { !reader.hasLiveConnectionForTesting }

        let target = Int(Self.firstRange) + 6 * 1024 * 1024
        let got = await Self.readInBackground(reader, bytes: target, sliceCap: 4 * 1024 * 1024)
        #expect(got == target)
        #expect(reader.trickleEndCountForTesting == 0, "a healthy stream was ended as a trickle")
        #expect(origin.requests.filter { $0.start == dripOffset }.count == 1)
        #expect(!origin.requests.contains { $0.start > dripOffset && $0.start < dripOffset + 6 * 1024 * 1024 },
                "the healthy stream was replaced: \(origin.requests.map(\.start))")
    }

    @Test("a trickle with no read outstanding is not judged", .timeLimit(.minutes(3)))
    func trickleWithoutAWaitingReadIsLeftAlone() async throws {
        let dripOffset = Self.dripOffset
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { start, _ in
            start == dripOffset ? .drip(bytes: 4 * 1024, everyUs: 200_000) : .fast
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { !reader.hasLiveConnectionForTesting }

        // Draw just enough to put the refill on the wire, then park the consumer: a paused player.
        // The window still holds read-ahead, so no read ever blocks on the drip.
        let drawn = await Self.readInBackground(reader, bytes: 64 * 1024, sliceCap: 64 * 1024)
        #expect(drawn == 64 * 1024)
        try await waitFor { origin.requests.contains { $0.start == dripOffset } }

        let ended = try await waitFor(upTo: .seconds(8 * Self.stallTimeout)) {
            reader.trickleEndCountForTesting > 0 || !reader.hasLiveConnectionForTesting
        }
        #expect(!ended, "a drip nobody was waiting on was ended")
        #expect(reader.trickleEndCountForTesting == 0)
    }

    /// A raw live source arrives at its own bitrate, so a read waits on forward data almost all the
    /// time, and a radio stream sits below the floor for good. Judging it would end a healthy live
    /// connection every threshold and rejoin at the edge.
    @Test("a live source below the floor with a read waiting is never ended as a trickle",
          .timeLimit(.minutes(3)))
    func lowBitrateLiveIsLeftAlone() async throws {
        // 4 KB every 0.2 s is about 160 kbit/s, an audio-only live channel.
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { _, _ in
            .drip(bytes: 4 * 1024, everyUs: 200_000)
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!,
                                isLive: true, connStallTimeout: Self.stallTimeout, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // One AVIO-sized read takes about 13 s at this rate, so it stays blocked on forward data for
        // the whole observation, which is the state the verdict is evaluated in.
        _ = Self.startReading(reader, bytes: 256 * 1024)
        let ended = try await waitFor(upTo: .seconds(8 * Self.stallTimeout)) {
            reader.trickleEndCountForTesting > 0 || origin.requests.count > 1
        }
        #expect(!ended, "a low-bitrate live connection was replaced: \(origin.requests.map(\.start))")
        #expect(reader.trickleEndCountForTesting == 0)
    }

    @Test("a held connection parked on a full window with zero delivery is not judged",
          .timeLimit(.minutes(3)))
    func heldFullWindowIsLeftAlone() async throws {
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { _, _ in .fast })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin, held: true)
        defer { reader.markClosed(); reader.close() }
        reader.playIntentProvider = { true }
        try reader.open()
        // The window fills at loopback speed; from then on the pump is refused a budget and nothing
        // is delivered at all, and no read is outstanding.
        try await waitFor { reader.windowDiagnostics.aheadBytes >= 15 * 1024 * 1024 }

        let ended = try await waitFor(upTo: .seconds(8 * Self.stallTimeout)) {
            reader.trickleEndCountForTesting > 0 || !reader.hasLiveConnectionForTesting
        }
        #expect(!ended, "a parked held connection was ended")
        #expect(reader.trickleEndCountForTesting == 0)
        #expect(origin.requests.filter { $0.start == 0 }.count == 1,
                "the park re-requested: \(origin.requests.map(\.start))")
    }

    // MARK: - Review round: AVIO-sized reads, the ending's route, pre-wait marks

    /// The field drip, scaled: 256 KB every 15 s against a 20 s threshold and a 2 MiB floor. Each
    /// AVIO-sized read is served inside the threshold, so a clock that restarts per read never
    /// reaches a verdict; the consumer is starved all the same.
    @Test("a drip that serves every AVIO-sized read inside the threshold still trips",
          .timeLimit(.minutes(3)))
    func avioSizedReadsDoNotResetTheStarvedClock() async throws {
        let dripOffset = Self.dripOffset
        // 256 KB every 1.5 s (15/20 of a 2 s threshold): about 341 KB per period, under the 2 MiB
        // floor this reader is given, which is the field's read-size-to-floor ratio. The longer
        // threshold keeps half a second between a drip and the gap verdict, so a loaded runner does
        // not hand the connection to the gap path before the starved clock runs out.
        let stallTimeout: TimeInterval = 2
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { start, attempt in
            start == dripOffset && attempt == 1 ? .drip(bytes: 256 * 1024, everyUs: 1_500_000) : .fast
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin, trickleFloorBytes: 2 * 1024 * 1024, stallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { !reader.hasLiveConnectionForTesting }

        let target = Int(Self.firstRange) + 4 * 1024 * 1024
        let progress = Self.startReading(reader, bytes: target)
        try await waitFor { origin.requests.contains { $0.start == dripOffset } }
        let dripRequest = origin.requests.first { $0.start == dripOffset }
        let dripStartedAt = try #require(dripRequest?.at)

        try await waitFor { reader.trickleEndCountForTesting > 0 || progress.done }
        let detectedAfter = Date().timeIntervalSince(dripStartedAt)
        #expect(reader.trickleEndCountForTesting > 0, "the drip was never judged")
        #expect(detectedAfter < 5 * stallTimeout,
                "the trickle was ended \(detectedAfter)s after it started, over 5x the threshold")
        try await waitFor { progress.done }
        #expect(progress.got == target)
    }

    /// The gap path's ending of a connection that had delivered data is the reference: a waiting
    /// read replaces it through `seekReconnect`, one generation per threshold, the watchdog itself
    /// being the pacing. A trickle end must behave exactly like it, no faster and with the same
    /// give-up, so an origin that trickles on every connection is compared against one that goes
    /// silent after a few bytes on every connection.
    @Test("an origin that trickles on every connection is replaced like a silent one",
          .timeLimit(.minutes(3)))
    func perpetualTrickleMatchesTheGapPath() async throws {
        let dripOffset = Self.dripOffset
        let totalSize = Self.totalSize
        let region: (Int64) -> Bool = { $0 >= dripOffset && $0 < dripOffset + 8 * 1024 * 1024 }

        func observe(_ pace: Pace) async throws -> (starts: [Date], ended: Bool, trickleEnds: Int) {
            let originMaybe = PacedOrigin(totalSize: totalSize, pace: { start, _ in
                start >= dripOffset && start < dripOffset + 8 * 1024 * 1024 ? pace : .fast
            })
            let origin = try #require(originMaybe)
            defer { origin.stop() }
            let reader = Self.makeReader(origin)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            try await waitFor { !reader.hasLiveConnectionForTesting }
            let progress = Self.startReading(reader, bytes: Int(Self.firstRange) + 4 * 1024 * 1024)
            try await waitFor { origin.requests.contains { region($0.start) } }
            // Ten thresholds: room for several replacements, and for any backoff or give-up to show.
            _ = try await waitFor(upTo: .seconds(10 * Self.stallTimeout)) { progress.done }
            return (origin.requests.filter { region($0.start) }.map(\.at),
                    progress.done, reader.trickleEndCountForTesting)
        }

        let trickle = try await observe(.drip(bytes: 4 * 1024, everyUs: 200_000))
        let silent = try await observe(.silentAfter(bytes: 4 * 1024))

        func minGap(_ starts: [Date]) -> TimeInterval {
            zip(starts.dropFirst(), starts).map { $0.timeIntervalSince($1) }.min() ?? .infinity
        }
        #expect(trickle.trickleEnds >= 2, "the perpetual trickle was not replaced repeatedly")
        // No expectation on which detector ends the silent origin: 4 KB in a threshold is under the
        // floor too, so the trickle verdict and the gap verdict race for it. Either one ends it the
        // same way, which is the point of the comparison.
        #expect(trickle.starts.count >= 2 && silent.starts.count >= 2)
        // Not faster than the reference: each replacement waits out a full threshold.
        #expect(minGap(trickle.starts) >= 0.8 * Self.stallTimeout,
                "trickle replacements \(minGap(trickle.starts))s apart, under the threshold")
        #expect(minGap(silent.starts) >= 0.8 * Self.stallTimeout)
        #expect(trickle.starts.count <= silent.starts.count + 2,
                "trickle: \(trickle.starts.count) requests, silent: \(silent.starts.count)")
        // Same give-up as the silent origin.
        #expect(trickle.ended == silent.ended,
                "trickle read ended: \(trickle.ended), silent read ended: \(silent.ended)")
    }

    /// The reviewers' scenario: a held connection parks on a full window for several thresholds
    /// with zero delivery, the consumer then drains it and blocks, and the origin delivers 3.5 MiB
    /// per 20 s scaled to this threshold, 1.75x the floor. A mark from before the wait would fold
    /// the park into the span and end a healthy stream.
    @Test("a park on a full window followed by a healthy drip does not trip",
          .timeLimit(.minutes(3)))
    func parkThenHealthyDripDoesNotTrip() async throws {
        // Loopback caveat: whatever the kernel buffered for the socket during the park arrives as a
        // burst once the pump resumes, and that burst alone lifts a stale span over the floor. So on
        // this harness the case passes even without the pre-wait guard. It pins the behaviour; the
        // guard in `trickleVerdictLocked` (no mark older than the starved clock) is what decides it
        // when the origin itself is the slow side and no buffered burst follows the park.
        let originMaybe = PacedOrigin(totalSize: Self.totalSize, pace: { _, _ in .fast })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = Self.makeReader(origin, held: true)
        defer { reader.markClosed(); reader.close() }
        reader.playIntentProvider = { true }
        try reader.open()
        try await waitFor { reader.windowDiagnostics.aheadBytes >= 15 * 1024 * 1024 }
        // The park: four thresholds of zero delivery on a full window.
        let parkEnded = try await waitFor(upTo: .seconds(4 * Self.stallTimeout)) {
            reader.trickleEndCountForTesting > 0 || !reader.hasLiveConnectionForTesting
        }
        #expect(!parkEnded)

        // 3.5 MiB / 20 s at 0.5 s is 91750 B per threshold: 18350 B every 100 ms.
        origin.setPaceOverride(.drip(bytes: 18_350, everyUs: 100_000))
        let ahead = reader.windowDiagnostics.aheadBytes
        let target = ahead + 512 * 1024
        let progress = Self.startReading(reader, bytes: target)
        try await waitFor { progress.done }
        #expect(progress.got == target)
        #expect(reader.trickleEndCountForTesting == 0, "a healthy drip after a park was ended as a trickle")
        #expect(origin.requests.filter { $0.start == 0 }.count == 1,
                "the healthy held connection was replaced: \(origin.requests.map(\.start))")
    }
}
