// LiveFixture: a synthetic, offline, never-ending MPEG-TS source for
// the `aetherctl live` harness.
//
// Serves an endless MPEG-TS over HTTP loopback by repeating a finite
// seed `.ts` payload, rewriting per-loop timestamps so the served
// stream looks like a genuine live broadcast with monotonically
// advancing PTS / PCR across loop boundaries (a naive byte-repeat
// would reset timestamps to the seed's start every loop, and the
// demuxer would read every loop seam as a discontinuity / backward
// jump).
//
// What gets rewritten per loop:
//   - PCR (adaptation-field, 33-bit base + 9-bit ext at 27 MHz) gets
//     `loopIndex * loopPeriodTicks * 300` added to the base.
//   - PES PTS and DTS (33-bit, 90 kHz) get `loopIndex * loopPeriodTicks`
//     added. The seed here is PTS-only (no DTS), but DTS is handled too
//     so a different seed still works.
//   - Transport continuity_counter (low nibble of the 2nd header byte
//     group, `packet[3] & 0x0F`) keeps incrementing per-PID across loop
//     boundaries instead of restarting at the seed's first value, so
//     the demuxer sees no continuity error at the seam.
//
// `loopPeriodTicks` is (max PTS - min PTS) + one frame interval, so
// loop N+1's first timestamp sits exactly one frame after loop N's
// last, which is what a real CBR feed produces.
//
// No `Content-Length`. The socket streams TS packets until the client
// disconnects (`Connection: close`), so `AVIOReader` + the demuxer see
// a feed with no end. URL shape: `http://127.0.0.1:<port>/live.ts`.
//
// Socket scaffolding (socket / bind / listen / accept / send) mirrors
// `HLSLocalServer` deliberately: Darwin BSD sockets, not
// Network.framework. See that file's header for the rationale.
//
// YAGNI: a single initializer, no drop / discontinuity injection. Later
// tasks add `--drop-after` / `--discontinuity-at`; this fixture is the
// clean baseline.

import Darwin
import Foundation

final class LiveFixture: @unchecked Sendable {

    // MARK: - Errors

    enum LiveFixtureError: Error, CustomStringConvertible {
        case seedMissing(path: String)
        case seedNotTS(path: String, size: Int)
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case getsockname(errno: Int32)

        var description: String {
            switch self {
            case .seedMissing(let p):
                return "LiveFixture: seed fixture missing at \(p). Expected an H.264 MPEG-TS sample. Pass --seed <path> to override."
            case .seedNotTS(let p, let size):
                return "LiveFixture: seed at \(p) is \(size) bytes, not a whole number of 188-byte TS packets. Not a raw MPEG-TS file."
            case .socketCreate(let e): return "LiveFixture: socket() failed (errno=\(e))"
            case .bind(let e):         return "LiveFixture: bind() failed (errno=\(e))"
            case .listen(let e):       return "LiveFixture: listen() failed (errno=\(e))"
            case .getsockname(let e):  return "LiveFixture: getsockname() failed (errno=\(e))"
            }
        }
    }

    // MARK: - TS constants

    private static let tsPacketSize = 188
    private static let syncByte: UInt8 = 0x47
    /// 90 kHz ticks. The 33-bit PTS / DTS clock and the PCR base run on
    /// this; the PCR extension runs at 27 MHz (base * 300 + ext).
    private static let pcrExtModulus: Int64 = 300

    // MARK: - Seed

    /// The seed TS payload, split into 188-byte packets once at init.
    private let seedPackets: [Data]
    /// Per-loop timestamp increment in 90 kHz ticks (PTS / DTS / PCR base).
    private let loopPeriodTicks: Int64
    /// The lowest PTS / DTS / PCR-base value found in the seed, used so
    /// the served stream can start near zero rather than at the seed's
    /// intrinsic start offset (not strictly required, kept at 0 here, the
    /// per-loop offset is what matters for monotonicity).
    private let seedBasePTS: Int64

    // MARK: - Socket state

    private var listenFd: Int32 = -1
    private var shouldStop = false
    private var clientFds = Set<Int32>()
    private let stateLock = NSLock()
    private(set) var port: UInt16 = 0

    /// When non-nil, the fixture will close the FIRST accepted client socket
    /// after this many seconds of serving (simulating a single recoverable
    /// mid-stream drop). Subsequent connections (the reconnect and any later
    /// clients) are served normally without further forced drops.
    var dropAfterSeconds: Double? = nil
    /// Latched to true after the first drop has fired, so only one drop
    /// is injected regardless of how many reconnects follow.
    private var didFireDrop = false

    /// When non-nil, after this many seconds of serving the rewritten
    /// PTS / DTS / PCR stream jumps FORWARD by `discontinuityJumpTicks`
    /// ONCE, then continues monotonically from the jumped value. This
    /// simulates a real broadcast program boundary where the source clock
    /// leaps. The engine must survive it: native via #EXT-X-DISCONTINUITY,
    /// SW via a running PTS offset that keeps the session timeline
    /// continuous. Per-connection wall-clock relative to that connection's
    /// first served packet.
    var discontinuityAfterSeconds: Double? = nil
    /// Size of the one-shot forward jump, in 90 kHz ticks. +1000 s default
    /// (1000 * 90000), well beyond the discontinuity-detection threshold.
    var discontinuityJumpTicks: Int64 = 1000 * 90_000

    /// When true, the serve loop releases bytes at roughly the source's
    /// natural rate (~1 wall-clock second of media per wall-clock second)
    /// instead of as fast as the socket drains. This matches a genuine 1x
    /// live broadcast: the producer / AVPlayer cannot race ahead of real
    /// time, so the live-edge / behind-live dynamics reflect a real feed.
    ///
    /// Pacing is coarse by design: the serve loop tracks how many media
    /// seconds it has emitted (derived from `loopPeriodTicks`, the 90 kHz
    /// span the seed covers per loop, plus an intra-loop fraction by packet
    /// index) and sleeps whenever the emitted media-time gets more than
    /// `pacingLeadSeconds` ahead of the wall clock. It holds the long-run
    /// average rate at 1x; it does not attempt per-packet PCR precision.
    /// Default false: non-paced behaviour is unchanged.
    var paced = false
    /// How far ahead of the wall clock the emitter is allowed to run before
    /// it sleeps. A small lead keeps a startup burst (so the engine can fill
    /// its initial buffer) without letting the producer race minutes ahead.
    var pacingLeadSeconds: Double = 2.0
    /// Media seconds served as fast as the socket drains BEFORE the 1x gate
    /// engages. A real client joining a live channel already has a DVR
    /// back-buffer and several published segments to start from; without a
    /// preroll the producer cannot finalize its first segment before
    /// AVPlayer's initial-buffering stall timer (1.5 * EXT-X-TARGETDURATION)
    /// fires, and playback dies with CoreMedia -12888 at the very first
    /// frame. The preroll lets the producer establish a normal live window,
    /// after which pacing clamps the feed to 1x so the behind-live / edge
    /// dynamics reflect a genuine real-time broadcast. 30 s comfortably
    /// covers a 60 s DVR window's worth of startup plus AVPlayer warm-up.
    var pacingPrerollSeconds: Double = 30.0
    /// Latched true (by a timer scheduled at connection start) once the
    /// discontinuity window has elapsed, so the serve loop starts adding
    /// `discontinuityJumpTicks` to every subsequent packet. A timer-driven
    /// flag (rather than an in-loop wall-clock check) so the jump fires on
    /// schedule even while the serve loop is blocked on a back-pressured
    /// `send`. Guarded by `stateLock`. Single-shot across the session.
    private var discontinuityArmed = false
    private var didFireDiscontinuity = false

    private let acceptQueue = DispatchQueue(
        label: "com.aetherengine.livefixture.accept",
        qos: .userInitiated
    )
    /// Fixture-global wall-clock zero for the broadcast timeline. Each
    /// connection derives its starting loop index from "now", so a
    /// reconnecting client (e.g. after a --drop-after RST) sees the
    /// clock having ADVANCED across the gap, like a real broadcast.
    /// Per-connection resets to zero made reconnect tests exercise the
    /// engine's backward-discontinuity handling instead of its
    /// reconnect-resume behaviour.
    private let fixtureStart = Date()

    private let workQueue = DispatchQueue(
        label: "com.aetherengine.livefixture.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Init

    /// Build the fixture from a seed `.ts` file. Throws if the seed is
    /// missing or not a whole number of 188-byte TS packets.
    init(seedPath: String) throws {
        guard FileManager.default.fileExists(atPath: seedPath) else {
            throw LiveFixtureError.seedMissing(path: seedPath)
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: seedPath))
        guard raw.count > 0,
              raw.count % LiveFixture.tsPacketSize == 0,
              raw[raw.startIndex] == LiveFixture.syncByte else {
            throw LiveFixtureError.seedNotTS(path: seedPath, size: raw.count)
        }

        var packets: [Data] = []
        packets.reserveCapacity(raw.count / LiveFixture.tsPacketSize)
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let end = raw.index(idx, offsetBy: LiveFixture.tsPacketSize)
            packets.append(raw.subdata(in: idx..<end))
            idx = end
        }
        self.seedPackets = packets

        // Scan the seed for the PTS span so the per-loop offset lands the
        // next loop exactly one frame after the previous loop's last.
        let span = LiveFixture.measureTimestampSpan(packets: packets)
        self.seedBasePTS = span.minPTS
        // loopPeriod = span + one frame interval. Falls back to a 5 s
        // period (450000 ticks) when the seed has no parseable PTS deltas.
        let frameInterval = span.frameInterval > 0 ? span.frameInterval : 3750
        let rawPeriod = (span.maxPTS - span.minPTS) + frameInterval
        self.loopPeriodTicks = rawPeriod > 0 ? rawPeriod : 450_000
    }

    // MARK: - Lifecycle

    /// Bind + listen, spawn the accept/serve loop on a background thread,
    /// return the live URL once the kernel has assigned a port.
    func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw LiveFixtureError.socketCreate(errno: errno) }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        // No SIGPIPE when the client disconnects mid-stream; send() returns
        // EPIPE and the serve loop exits cleanly.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // kernel picks ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.bind(errno: err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.listen(errno: err)
        }

        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        guard getNameResult == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.getsockname(errno: err)
        }
        let assignedPort = UInt16(bigEndian: actual.sin_port)

        stateLock.lock()
        listenFd = fd
        port = assignedPort
        shouldStop = false
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        guard let url = URL(string: "http://127.0.0.1:\(assignedPort)/live.ts") else {
            // Unreachable: the string is always a valid URL.
            throw LiveFixtureError.getsockname(errno: 0)
        }
        return url
    }

    func stop() {
        stateLock.lock()
        shouldStop = true
        let fdToClose = listenFd
        listenFd = -1
        port = 0
        let clients = clientFds
        clientFds.removeAll()
        stateLock.unlock()

        if fdToClose >= 0 { close(fdToClose) }
        for fd in clients { close(fd) }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stopping = shouldStop
            let fd = listenFd
            stateLock.unlock()
            if stopping || fd < 0 { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                let err = errno
                if err == EBADF || err == EINVAL { return }
                if err == EINTR || err == EAGAIN { continue }
                // Unexpected errno (e.g. EMFILE under fd exhaustion):
                // say so. A silent exit leaves the fixture parked but
                // not accepting, which looks exactly like an
                // engine-side connect failure during debugging.
                print("[LiveFixture] accept failed: errno=\(err); accept loop exiting")
                return
            }

            var on: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                           socklen_t(MemoryLayout<Int32>.size))

            stateLock.lock()
            clientFds.insert(clientFd)
            stateLock.unlock()

            workQueue.async { [weak self] in
                self?.serve(clientFd)
            }
        }
    }

    // MARK: - Per-connection serve

    /// Read (and discard) the HTTP request line, send a chunked-free
    /// streaming 200 response with no Content-Length, then push rewritten
    /// TS packets forever until the peer disconnects or `stop()` runs.
    ///
    /// If `dropAfterSeconds` is set and no drop has fired yet, closes this
    /// connection after the configured number of seconds ONCE mid-stream
    /// (simulating a single recoverable drop). The next accepted connection
    /// (the reconnect) is served normally.
    private func serve(_ fd: Int32) {
        // Close ownership: whoever removes the fd from `clientFds` (under
        // stateLock) owns the close. The drop timer, stop(), and this
        // defer all follow that rule, so the fd is closed exactly once
        // and a recycled fd number can never be closed by a stale party.
        defer {
            stateLock.lock()
            let owned = clientFds.remove(fd) != nil
            stateLock.unlock()
            if owned {
                close(fd)
            }
        }

        // Drain the request headers (we only ever serve /live.ts, so the
        // exact request line does not change behaviour). Bail on EOF.
        guard readRequest(fd) else { return }

        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: video/mp2t\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        guard writeAll(fd: fd, bytes: Array(header.utf8)) else { return }

        // If this is the first streaming connection and a drop is configured,
        // schedule an async RST of this fd after `dropAfterSeconds`. Using
        // SO_LINGER=0 + close() sends RST immediately, causing the client
        // URLSession to receive a network error rather than a clean EOF, which
        // exercises the persistent reader's error-driven reconnect path. The
        // blocked send() in the write loop returns EBADF/EPIPE, serve() exits.
        stateLock.lock()
        let shouldScheduleDrop = (dropAfterSeconds != nil && !didFireDrop)
        let dropDelay = dropAfterSeconds ?? 0
        stateLock.unlock()

        if shouldScheduleDrop {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                // Claim close ownership by removing the fd from clientFds.
                // If the connection already ended (serve()'s defer removed
                // it), the fd number may have been recycled by a new
                // accept(), so closing it here would kill the very
                // reconnect this drop exists to exercise. In that case
                // don't latch didFireDrop either: the drop re-arms on the
                // next connection so it still fires mid-stream once.
                let owned = !self.didFireDrop && self.clientFds.remove(fd) != nil
                if owned { self.didFireDrop = true }
                self.stateLock.unlock()
                if owned {
                    print("[LiveFixture] Injecting mid-stream drop after ~\(Int(dropDelay))s (fd=\(fd))")
                    // SO_LINGER l_linger=0 causes close() to send RST.
                    var ling = Darwin.linger()
                    ling.l_onoff = 1
                    ling.l_linger = 0
                    _ = setsockopt(fd, SOL_SOCKET, SO_LINGER,
                                   &ling, socklen_t(MemoryLayout<Darwin.linger>.size))
                    Darwin.close(fd)
                }
            }
            workQueue.asyncAfter(deadline: .now() + dropDelay, execute: item)
        }

        // Per-PID continuity counter, carried across loop boundaries so the
        // seam never produces a continuity_counter discontinuity.
        var ccByPID: [Int: UInt8] = [:]
        // Broadcast-clock start for THIS connection: whole loops elapsed
        // since the fixture came up (see `fixtureStart`). The pacing gate
        // below measures against `startLoopIndex`, so only media emitted
        // on this connection counts toward its 1x budget.
        let startLoopIndex: Int64 = loopPeriodTicks > 0
            ? Int64((Date().timeIntervalSince(fixtureStart) * 90_000.0) / Double(loopPeriodTicks))
            : 0
        var loopIndex: Int64 = startLoopIndex

        // One-shot program-boundary discontinuity. After `discontinuityAfter`
        // seconds of serving, every subsequent packet's PTS / DTS / PCR gets
        // an EXTRA forward jump of `discontinuityJumpTicks` added ON TOP of
        // the normal per-loop offset. The jump is applied once and then held
        // constant, so the stream continues monotonically from the jumped
        // value (a real broadcast program switch). The continuity_counter is
        // untouched, so the only anomaly the demuxer sees is the timestamp
        // leap, which is exactly the case the engine must survive.
        //
        // Armed by a timer (like the drop path) so it fires on schedule even
        // when the serve loop is parked in a back-pressured `send`.
        stateLock.lock()
        let discontinuityAfter = discontinuityAfterSeconds
        let discontinuityJump = discontinuityJumpTicks
        let scheduleDiscontinuity = (discontinuityAfter != nil && !didFireDiscontinuity)
        stateLock.unlock()
        if let after = discontinuityAfter, scheduleDiscontinuity {
            workQueue.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                if !self.didFireDiscontinuity {
                    self.didFireDiscontinuity = true
                    self.discontinuityArmed = true
                    print("[LiveFixture] Arming one-shot PTS/PCR discontinuity "
                          + "after ~\(Int(after))s (+\(discontinuityJump / 90_000)s jump)")
                }
                self.stateLock.unlock()
            }
        }
        var discontinuityOffset: Int64 = 0

        // Reusable per-packet scratch buffer (188 bytes), rewritten in place
        // each iteration, so the serve loop allocates nothing steady-state.
        var scratch = [UInt8](repeating: 0, count: LiveFixture.tsPacketSize)

        // Real-time pacing state. `loopPeriodSeconds` is the media duration the
        // seed covers per loop pass (the 90 kHz span / 90000). `serveStart` is
        // this connection's wall-clock zero. Each packet, we estimate how many
        // media seconds have been emitted (whole loops + intra-loop fraction by
        // packet index) and, if paced, sleep until the wall clock catches up to
        // within `pacingLeadSeconds`.
        let loopPeriodSeconds = Double(loopPeriodTicks) / 90_000.0
        let packetsPerLoop = max(1, seedPackets.count)
        // Wall-clock zero for the 1x gate. Set when the preroll window has been
        // fully emitted (the preroll itself is served as fast as the socket
        // drains), so pacing measures media-beyond-preroll against wall-time-
        // since-preroll rather than against the burst.
        var pacingClockStart: Date? = nil

        while true {
            stateLock.lock()
            let stopping = shouldStop
            stateLock.unlock()
            if stopping { return }

            for (packetIndex, packet) in seedPackets.enumerated() {
                // Real-time gate: hold the average emit rate at ~1x. Sleep in
                // coarse slices whenever the emitted media-time runs more than
                // `pacingLeadSeconds` ahead of wall-clock elapsed. Coarse on
                // purpose (no per-packet sleep): we only re-check + nap when the
                // lead is exceeded, which keeps overhead negligible while still
                // holding the long-run rate.
                if paced {
                    let emittedMedia = Double(loopIndex - startLoopIndex) * loopPeriodSeconds
                        + (Double(packetIndex) / Double(packetsPerLoop)) * loopPeriodSeconds
                    // Serve the preroll window unpaced so the producer can
                    // establish a live window before the 1x clamp engages. Once
                    // past it, gate media-beyond-preroll against wall-time-since-
                    // preroll, holding the long-run rate at ~1x.
                    if emittedMedia > pacingPrerollSeconds {
                        if pacingClockStart == nil { pacingClockStart = Date() }
                        let mediaPastPreroll = emittedMedia - pacingPrerollSeconds
                        while paced {
                            stateLock.lock()
                            let stopNow = shouldStop
                            stateLock.unlock()
                            if stopNow { return }
                            let wall = Date().timeIntervalSince(pacingClockStart!)
                            let lead = mediaPastPreroll - wall
                            if lead <= pacingLeadSeconds { break }
                            // Nap off the excess lead (cap each nap so stop() is
                            // honoured promptly), then re-evaluate.
                            let nap = min(lead - pacingLeadSeconds, 0.25)
                            usleep(useconds_t(max(0.005, nap) * 1_000_000))
                        }
                    }
                }
                // Poll the armed flag per packet (not just per seed-loop pass):
                // the serve loop spends most of its time parked in a back-
                // pressured `send` mid-pass, so an outer-loop-only check would
                // not see the timer's arm until the next full pass, which can
                // be many seconds late on a bursty reader.
                if discontinuityOffset == 0 {
                    stateLock.lock()
                    let armed = discontinuityArmed
                    stateLock.unlock()
                    if armed {
                        discontinuityOffset = discontinuityJump
                        print("[LiveFixture] Injecting one-shot PTS/PCR discontinuity "
                              + "(+\(discontinuityJump / 90_000)s jump, fd=\(fd))")
                    }
                }
                let tsOffset = loopIndex * loopPeriodTicks &+ discontinuityOffset
                packet.copyBytes(to: &scratch, count: LiveFixture.tsPacketSize)
                rewritePacket(&scratch, tsOffset: tsOffset, ccByPID: &ccByPID)
                if !writeAll(fd: fd, bytes: scratch) {
                    return // peer gone or fd closed by drop timer
                }
            }

            loopIndex &+= 1
        }
    }

    /// Read until the end of the HTTP request headers (`\r\n\r\n`) or EOF.
    /// Returns true if a request line was read, false on immediate EOF /
    /// error.
    private func readRequest(_ fd: Int32) -> Bool {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n == 0 { return !buffer.isEmpty }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                return false
            }
            buffer.append(contentsOf: chunk[0..<n])
            if let end = headersTerminator(buffer) {
                _ = end
                return true
            }
            if buffer.count > 8192 { return false }
        }
    }

    private func headersTerminator(_ buf: [UInt8]) -> Int? {
        guard buf.count >= 4 else { return nil }
        var i = 0
        while i <= buf.count - 4 {
            if buf[i] == 0x0D && buf[i + 1] == 0x0A
                && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Blocking send loop. Returns false on broken pipe / error.
    private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var written = 0
        let total = bytes.count
        if total == 0 { return true }
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while written < total {
                let result = send(fd, base.advanced(by: written), total - written, 0)
                if result < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return false // EPIPE / ECONNRESET / etc.
                }
                if result == 0 { return false }
                written += result
            }
            return true
        }
    }

    // MARK: - TS packet rewrite

    /// Rewrite one 188-byte TS packet in place: add `tsOffset` (90 kHz
    /// ticks) to PCR / PTS / DTS, and rewrite the continuity_counter so it
    /// keeps incrementing per-PID across loop boundaries.
    private func rewritePacket(_ p: inout [UInt8], tsOffset: Int64, ccByPID: inout [Int: UInt8]) {
        guard p[0] == LiveFixture.syncByte else { return }

        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let afc = (p[3] >> 4) & 0x3            // adaptation_field_control
        let hasAF = (afc & 0x2) != 0
        let hasPayload = (afc & 0x1) != 0
        let pusi = (p[1] >> 6) & 0x1           // payload_unit_start_indicator

        // --- continuity_counter ---
        // Per H.222: the CC increments only on packets that carry a payload
        // (afc 0x1 or 0x3). Packets with adaptation-only (afc 0x2) repeat
        // the previous CC. PID 0x1FFF (null) is exempt; we have none here.
        // We drive a per-PID counter so the value is continuous across the
        // loop seam regardless of what the seed's last CC was.
        if pid != 0x1FFF {
            if hasPayload {
                let next = (ccByPID[pid].map { ($0 &+ 1) & 0x0F }) ?? (p[3] & 0x0F)
                ccByPID[pid] = next
                p[3] = (p[3] & 0xF0) | next
            } else {
                // Adaptation-only: repeat last CC for this PID if we have one.
                if let last = ccByPID[pid] {
                    p[3] = (p[3] & 0xF0) | last
                }
            }
        }

        if tsOffset == 0 { return } // loop 0: no timestamp shift needed.

        // --- adaptation field: PCR ---
        var payloadOffset = 4
        if hasAF {
            let afLen = Int(p[4])
            if afLen > 0 {
                let flags = p[5]
                let pcrFlag = (flags >> 4) & 0x1
                if pcrFlag != 0 {
                    // PCR occupies p[6..<12]: 33-bit base, 6 reserved bits,
                    // 9-bit extension. value = base * 300 + ext.
                    let b0 = Int64(p[6]), b1 = Int64(p[7]), b2 = Int64(p[8])
                    let b3 = Int64(p[9]), b4 = Int64(p[10]), b5 = Int64(p[11])
                    let base = (b0 << 25) | (b1 << 17) | (b2 << 9) | (b3 << 1) | (b4 >> 7)
                    let ext = ((b4 & 0x1) << 8) | b5
                    var full = base * LiveFixture.pcrExtModulus + ext
                    full &+= tsOffset * LiveFixture.pcrExtModulus
                    let newBase = (full / LiveFixture.pcrExtModulus) & 0x1_FFFF_FFFF
                    let newExt = full % LiveFixture.pcrExtModulus
                    p[6] = UInt8((newBase >> 25) & 0xFF)
                    p[7] = UInt8((newBase >> 17) & 0xFF)
                    p[8] = UInt8((newBase >> 9) & 0xFF)
                    p[9] = UInt8((newBase >> 1) & 0xFF)
                    // bit0 of p[10] is PCR base LSB; bits 7..1 are reserved
                    // (all 1s per spec); bit0..? Actually p[10] = (baseLSB<<7)
                    // | (0x3F<<1) | extHigh. Reconstruct preserving reserved.
                    let baseLSB: Int64 = (newBase & 0x1) << 7
                    let reserved: Int64 = 0x3F << 1
                    let extHigh: Int64 = (newExt >> 8) & 0x1
                    p[10] = UInt8((baseLSB | reserved | extHigh) & 0xFF)
                    p[11] = UInt8(newExt & 0xFF)
                }
            }
            payloadOffset = 5 + afLen
        }

        // --- PES header: PTS / DTS ---
        guard hasPayload, pusi != 0, payloadOffset <= 184 else { return }
        let pl = payloadOffset
        // PES start code 00 00 01, then stream_id.
        guard pl + 9 <= LiveFixture.tsPacketSize,
              p[pl] == 0x00, p[pl + 1] == 0x00, p[pl + 2] == 0x01 else { return }
        let ptsDtsFlags = (p[pl + 7] >> 6) & 0x3
        guard ptsDtsFlags & 0x2 != 0 else { return }

        // PTS at p[pl+9 ..< pl+14].
        if pl + 14 <= LiveFixture.tsPacketSize {
            rewriteTimestampField(&p, at: pl + 9, offset: tsOffset, marker: ptsDtsFlags == 0x3 ? 0x3 : 0x2)
        }
        // DTS at p[pl+14 ..< pl+19] when both flags set.
        if ptsDtsFlags == 0x3, pl + 19 <= LiveFixture.tsPacketSize {
            rewriteTimestampField(&p, at: pl + 14, offset: tsOffset, marker: 0x1)
        }
    }

    /// Decode a 5-byte PTS / DTS field, add `offset` (mod 2^33), re-encode
    /// preserving the 4-bit prefix marker and the three marker bits.
    private func rewriteTimestampField(_ p: inout [UInt8], at i: Int, offset: Int64, marker: UInt8) {
        let b0 = Int64(p[i]), b1 = Int64(p[i + 1]), b2 = Int64(p[i + 2])
        let b3 = Int64(p[i + 3]), b4 = Int64(p[i + 4])
        let value =
            (((b0 >> 1) & 0x7) << 30) |
            (b1 << 22) |
            (((b2 >> 1) & 0x7F) << 15) |
            (b3 << 7) |
            (b4 >> 1)
        let nv = (value &+ offset) & 0x1_FFFF_FFFF // wrap at 33 bits

        // Re-encode. Prefix nibble = marker (0010 PTS-only / 0011 PTS-with-DTS
        // / 0001 DTS). Each of the three sub-fields ends in a marker_bit = 1.
        p[i] = UInt8((marker << 4) | UInt8(((nv >> 30) & 0x7) << 1) | 0x1)
        p[i + 1] = UInt8((nv >> 22) & 0xFF)
        p[i + 2] = UInt8(UInt8(((nv >> 15) & 0x7F) << 1) | 0x1)
        p[i + 3] = UInt8((nv >> 7) & 0xFF)
        p[i + 4] = UInt8(UInt8((nv & 0x7F) << 1) | 0x1)
    }

    // MARK: - Seed timestamp measurement

    private struct TimestampSpan {
        var minPTS: Int64
        var maxPTS: Int64
        var frameInterval: Int64
    }

    /// Scan all packets once to find the min / max PES PTS and the most
    /// common adjacent-PTS delta (the frame interval). Pure read, no mutation.
    private static func measureTimestampSpan(packets: [Data]) -> TimestampSpan {
        var ptsValues: [Int64] = []
        for packet in packets {
            let p = [UInt8](packet)
            guard p.count == tsPacketSize, p[0] == syncByte else { continue }
            let afc = (p[3] >> 4) & 0x3
            let hasPayload = (afc & 0x1) != 0
            let pusi = (p[1] >> 6) & 0x1
            var payloadOffset = 4
            if (afc & 0x2) != 0 {
                payloadOffset = 5 + Int(p[4])
            }
            guard hasPayload, pusi != 0, payloadOffset <= 184,
                  payloadOffset + 14 <= tsPacketSize else { continue }
            let pl = payloadOffset
            guard p[pl] == 0x00, p[pl + 1] == 0x00, p[pl + 2] == 0x01 else { continue }
            let ptsDtsFlags = (p[pl + 7] >> 6) & 0x3
            guard ptsDtsFlags & 0x2 != 0 else { continue }
            let b0 = Int64(p[pl + 9]), b1 = Int64(p[pl + 10]), b2 = Int64(p[pl + 11])
            let b3 = Int64(p[pl + 12]), b4 = Int64(p[pl + 13])
            let pts =
                (((b0 >> 1) & 0x7) << 30) |
                (b1 << 22) |
                (((b2 >> 1) & 0x7F) << 15) |
                (b3 << 7) |
                (b4 >> 1)
            ptsValues.append(pts)
        }

        guard !ptsValues.isEmpty else {
            return TimestampSpan(minPTS: 0, maxPTS: 0, frameInterval: 0)
        }
        let sorted = ptsValues.sorted()
        var deltaCounts: [Int64: Int] = [:]
        for i in 1..<sorted.count {
            let d = sorted[i] - sorted[i - 1]
            if d > 0 { deltaCounts[d, default: 0] += 1 }
        }
        let frameInterval = deltaCounts.max(by: { $0.value < $1.value })?.key ?? 0
        return TimestampSpan(minPTS: sorted.first!, maxPTS: sorted.last!, frameInterval: frameInterval)
    }
}
