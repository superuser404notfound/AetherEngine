import Testing
import Foundation
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// A live MPEG-TS whose PAT lists a program that never sends its PMT keeps `AVFMTCTX_NOHEADER`
/// set, so `avformat_find_stream_info` never takes its "all info found" exit and reads the whole
/// playback budget (50 MiB / 60 s) after every stream it has is resolved. Measured through
/// `aetherctl play --live` on a live-paced synthetic channel: 58.7 s against 2.5 s once the wait is
/// released.
@Suite("The MPEG-TS header wait is released when a PAT program never sends its PMT")
struct MissingPMTReleaseDecisionTests {
    typealias Wait = TransportStreamHeaderWait
    typealias Program = TransportStreamHeaderWait.Program

    private static let due = TransportStreamHeaderWait.releaseAfterNanoseconds
    /// Program 1 with its PMT, video and audio, program 2 listed in the PAT and silent.
    private static let oneMissing = [Program(pmtVersion: 0, audioVideoStreams: 2),
                                     Program(pmtVersion: -1, audioVideoStreams: 0)]

    @Test("2.5 s: five PMT repetitions at the 0.5 s TR 101 290 expects")
    func window() {
        #expect(Self.due == 2_500_000_000)
    }

    @Test("a program without a PMT next to one with streams is released once the window passed")
    func releases() {
        #expect(Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: Self.due,
                                   programs: Self.oneMissing))
        #expect(Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: Self.due * 10,
                                   programs: Self.oneMissing.reversed()))
    }

    @Test("not before the window has passed")
    func notEarly() {
        #expect(!Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: Self.due - 1,
                                    programs: Self.oneMissing))
        #expect(!Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: 0,
                                    programs: Self.oneMissing))
    }

    @Test("only an MPEG-TS that still waits for its header")
    func formatAndFlag() {
        // MPEG-PS (a DVD) and FLV keep the flag too; their wait is not for a PMT.
        #expect(!Wait.shouldRelease(isMPEGTS: false, noHeader: true, elapsedNanoseconds: Self.due,
                                    programs: Self.oneMissing))
        // Every PMT arrived: the demuxer cleared the flag itself and there is nothing to release.
        #expect(!Wait.shouldRelease(isMPEGTS: true, noHeader: false, elapsedNanoseconds: Self.due,
                                    programs: Self.oneMissing))
    }

    @Test("program tables that are left waiting", arguments: [
        // No programs at all.
        [],
        // Every program has its PMT; the wait is for something else.
        [Program(pmtVersion: 0, audioVideoStreams: 2), Program(pmtVersion: 3, audioVideoStreams: 1)],
        // Nothing has arrived yet: releasing would start without any stream.
        [Program(pmtVersion: -1, audioVideoStreams: 0), Program(pmtVersion: -1, audioVideoStreams: 0)],
        // The only PMT that arrived declares no streams.
        [Program(pmtVersion: 0, audioVideoStreams: 0), Program(pmtVersion: -1, audioVideoStreams: 0)],
        // The only PMT that arrived is a data service (SCTE-35, teletext): releasing would end the
        // pass on streams guessed from bare packets while the TV program's PMT is on its way.
        [Program(pmtVersion: 0,
                 audioVideoStreams: Wait.audioVideoCount(of: [AVMEDIA_TYPE_DATA, AVMEDIA_TYPE_SUBTITLE])),
         Program(pmtVersion: -1, audioVideoStreams: 0)],
        // A single program without its PMT.
        [Program(pmtVersion: -1, audioVideoStreams: 0)],
    ])
    func waits(programs: [Program]) {
        #expect(!Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: Self.due * 4,
                                    programs: programs))
    }

    @Test("only audio and video make a program ready")
    func audioVideoOnly() {
        #expect(Wait.audioVideoCount(of: [AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO]) == 2)
        #expect(Wait.audioVideoCount(of: [AVMEDIA_TYPE_DATA, AVMEDIA_TYPE_SUBTITLE, AVMEDIA_TYPE_UNKNOWN,
                                          AVMEDIA_TYPE_ATTACHMENT]) == 0)
        #expect(Wait.audioVideoCount(of: [AVMEDIA_TYPE_DATA, AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_DATA]) == 1)
        #expect(Wait.audioVideoCount(of: []) == 0)
    }

    @Test("a stall counts as one PMT interval, so the window runs on time in which data arrived")
    func stallCountsOnce() {
        let gap = TransportStreamHeaderWait.maxCountedGapNanoseconds
        #expect(gap == 500_000_000)
        #expect(Wait.counted(0, gap: 40_000_000) == 40_000_000)
        #expect(Wait.counted(1_000_000_000, gap: 30_000_000_000) == 1_000_000_000 + gap)
        // Ten seconds of nothing after one second of data is still short of the window.
        #expect(Wait.counted(1_000_000_000, gap: 10_000_000_000) < Self.due)
    }

    @Test("several silent programs next to several with streams")
    func manyPrograms() {
        let programs = [Program(pmtVersion: -1, audioVideoStreams: 0),
                        Program(pmtVersion: 1, audioVideoStreams: 0),
                        Program(pmtVersion: -1, audioVideoStreams: 0),
                        Program(pmtVersion: 2, audioVideoStreams: 3)]
        #expect(Wait.shouldRelease(isMPEGTS: true, noHeader: true, elapsedNanoseconds: Self.due,
                                   programs: programs))
    }
}

@Suite("How the open's stream analysis ended, as the open timings line reports it")
struct ProbeStopReportTests {
    private func stop(closeRequested: Bool = false, interrupted: Bool = false, readError: Bool = false,
                      eofReached: Bool = false, noHeader: Bool = false, unresolved: Int = 0,
                      probeBytes: Int64 = 1_000, probesize: Int64 = 50 * 1_048_576) -> ProbeReport.Stop {
        ProbeReport.stop(closeRequested: closeRequested, interrupted: interrupted, readError: readError,
                         eofReached: eofReached, noHeader: noHeader, unresolved: unresolved,
                         probeBytes: probeBytes, probesize: probesize)
    }

    @Test("each cause, and the order in which they win")
    func order() {
        #expect(stop() == .resolved)
        #expect(stop(noHeader: true) == .analyzeduration)
        #expect(stop(unresolved: 1) == .analyzeduration)
        #expect(stop(unresolved: 1, probeBytes: 50 * 1_048_576) == .probesize)
        #expect(stop(noHeader: true, probeBytes: 60 * 1_048_576) == .probesize)
        #expect(stop(eofReached: true, unresolved: 1, probeBytes: 60 * 1_048_576) == .eof)
        #expect(stop(readError: true, eofReached: true) == .readError)
        #expect(stop(interrupted: true, readError: true) == .interrupted)
        #expect(stop(closeRequested: true, interrupted: true) == .stopped)
        // A user stop outranks a pass that had already found everything.
        #expect(stop(closeRequested: true) == .stopped)
    }

    @Test("unresolved follows what has_codec_parameters asks of audio and video")
    func unresolved() {
        func check(_ type: AVMediaType, width: Int32 = 0, format: Int32 = -1, decoder: Bool = true,
                   rate: Int32 = 0, channels: Int32 = 0) -> Bool {
            ProbeReport.isUnresolved(codecType: type, width: width, format: format, hasDecoder: decoder,
                                     sampleRate: rate, channels: channels)
        }
        let yuv420p = AV_PIX_FMT_YUV420P.rawValue
        #expect(!check(AVMEDIA_TYPE_VIDEO, width: 32, format: yuv420p))
        #expect(check(AVMEDIA_TYPE_VIDEO, width: 0, format: yuv420p))
        #expect(check(AVMEDIA_TYPE_VIDEO, width: 32))
        // Without a decoder FFmpeg cannot know the pixel format, and does not ask for it.
        #expect(!check(AVMEDIA_TYPE_VIDEO, width: 32, decoder: false))
        #expect(!check(AVMEDIA_TYPE_AUDIO, rate: 48_000, channels: 2))
        #expect(check(AVMEDIA_TYPE_AUDIO, rate: 0, channels: 2))
        #expect(check(AVMEDIA_TYPE_AUDIO, rate: 48_000, channels: 0))
        #expect(!check(AVMEDIA_TYPE_SUBTITLE))
        #expect(!check(AVMEDIA_TYPE_ATTACHMENT))
        #expect(!check(AVMEDIA_TYPE_DATA))
    }

    @Test("the fields, in the order downstream parsers read them")
    func fields() {
        let released = ProbeReport(stop: .resolved, unresolved: 0, programs: 2, pmtMissing: 1,
                                   headerWaitReleasedAfter: 2_504_900_000, probeBytes: 1_814_528,
                                   closeToReturn: nil)
        #expect(released.logFields == "probe stop=resolved, unresolved=0, programs=2, pmtMissing=1, "
                + "headerWait=released@2504ms, probeBytes=1814528, closeToReturn=-")
        let stopped = ProbeReport(stop: .stopped, unresolved: 1, programs: 0, pmtMissing: 0,
                                  headerWaitReleasedAfter: nil, probeBytes: 0, closeToReturn: 3_200_000)
        #expect(stopped.logFields == "probe stop=stopped, unresolved=1, programs=0, pmtMissing=0, "
                + "headerWait=-, probeBytes=0, closeToReturn=3ms")
        #expect(ProbeReport.Stop.readError.rawValue == "read-error")
    }
}

#if os(macOS)
/// Through `Demuxer` and its HTTP reader against a live-paced loopback origin: one second of the
/// fixture at once, then real time, the way a live panel delivers a channel. The fixture is
/// `LongGOPTransportStreamFixture` (32 s, 10 s GOP, H.264 + AAC), edited per case below.
@Suite("A live MPEG-TS whose PAT lists a program without a PMT opens without the full budget",
       .timeLimit(.minutes(3)))
struct MissingPMTLiveOpenTests {

    @Test("a program without a PMT: the release ends the pass with both tracks found")
    func programWithoutPMT() async throws {
        let ts = TransportStreamEdit.listingSilentProgram(try LongGOPTransportStreamFixture.data())
        let open = try await PacedOpen.run(ts, label: "j3")
        #expect(open.field("stop") == "resolved")
        // Never before the window: the release is for a PMT five repetitions late, not a slow one.
        #expect((open.releasedAfterMs ?? 0) >= 2_500)
        #expect(open.field("programs") == "2")
        #expect(open.field("pmtMissing") == "1")
        #expect(open.field("unresolved") == "0")
        #expect(open.tracks == .both)
    }

    @Test("plus audio that starts 5 s late: still waited for after the release")
    func programWithoutPMTAndLateAudio() async throws {
        let base = TransportStreamEdit.listingSilentProgram(try LongGOPTransportStreamFixture.data())
        let ts = TransportStreamEdit.dropping(pid: TransportStreamEdit.audioPID, before: 5, in: base)
        let open = try await PacedOpen.run(ts, label: "j34")
        #expect(open.field("stop") == "resolved")
        #expect((open.releasedAfterMs ?? 0) >= 2_500)
        #expect(open.tracks == .both)
    }

    @Test("plus a join 3 s into a 10 s GOP: the keyframe is still waited for after the release")
    func programWithoutPMTAndLateKeyframe() async throws {
        let base = TransportStreamEdit.listingSilentProgram(try LongGOPTransportStreamFixture.data())
        let ts = TransportStreamEdit.joined(after: 3, in: base)
        let open = try await PacedOpen.run(ts, label: "j35")
        #expect(open.field("stop") == "resolved")
        #expect((open.releasedAfterMs ?? 0) >= 2_500)
        #expect(open.tracks == .both)
    }

    @Test("a data service with its PMT next to a TV program whose PMT is late is not released")
    func dataServiceNextToLatePMT() async throws {
        let ts = TransportStreamEdit.listingDataService(
            in: TransportStreamEdit.delayingPMT(by: 6, in: try LongGOPTransportStreamFixture.data()))
        let open = try await PacedOpen.run(ts, label: "data")
        // With every declared stream counted, the teletext service released the wait at 2.5 s and the
        // pass ended on audio and video guessed from bare packets, with the TV PMT still missing.
        #expect(open.field("headerWait") == "-")
        #expect(open.field("stop") == "resolved")
        #expect(open.field("programs") == "2")
        #expect(open.field("pmtMissing") == "0")
        #expect(open.tracks == .both)
    }

    @Test("a TS whose PMTs all arrive is never released")
    func everyPMTArrives() async throws {
        let open = try await PacedOpen.run(try LongGOPTransportStreamFixture.data(), label: "j1")
        #expect(open.field("stop") == "resolved")
        #expect(open.field("headerWait") == "-")
        #expect(open.field("programs") == "1")
        #expect(open.field("pmtMissing") == "0")
        #expect(open.tracks == .both)
    }

    @Test("a long keyframe wait with every PMT present is left alone")
    func lateKeyframeWithEveryPMT() async throws {
        let ts = TransportStreamEdit.joined(after: 3, in: try LongGOPTransportStreamFixture.data())
        let open = try await PacedOpen.run(ts, label: "j5")
        #expect(open.field("stop") == "resolved")
        #expect(open.field("headerWait") == "-")
        #expect(open.tracks == .both)
    }

    @Test("a close during the header wait ends the pass at once")
    func closeDuringTheWait() async throws {
        let ts = TransportStreamEdit.listingSilentProgram(try LongGOPTransportStreamFixture.data())
        let open = try await PacedOpen.run(ts, label: "close", closeAfterProbeRunsFor: .milliseconds(500))
        #expect(open.field("stop") == "stopped")
        // Released would mean the pass outlived the close by the rest of the 2.5 s window.
        #expect(open.field("headerWait") == "-")
        let closeToReturn = try #require(open.field("closeToReturn").flatMap { Int($0.dropLast(2)) })
        #expect(closeToReturn < 1_500, "the close took \(closeToReturn) ms to end the pass")
    }
}

/// One open of a fixture through a fresh paced origin, with the open timings line it emitted.
private struct PacedOpen {
    enum Tracks: Equatable { case both, missing(String) }

    let line: String
    let tracks: Tracks

    /// `headerWait=released@<N>ms`, nil when the wait was not released.
    var releasedAfterMs: Int? {
        guard let value = field("headerWait"), value.hasPrefix("released@") else { return nil }
        return Int(value.dropFirst("released@".count).dropLast(2))
    }

    func field(_ name: String) -> String? {
        guard let range = line.range(of: " \(name)=") else { return nil }
        return String(line[range.upperBound...].prefix { $0 != "," && $0 != ";" })
    }

    /// Bytes per second of the unedited fixture (298,544 bytes of 32.02 s), so every edit keeps the
    /// fixture's own pace.
    private static let rate = 9_324
    /// Null packets (PID 0x1FFF, which the demuxer drops) sent after each fixture packet. The fixture
    /// runs at 74 kb/s, and the HTTP reader hands libavformat 256 KiB reads, so unpadded the first
    /// read alone took 27 s; padded the channel runs at about 3 Mb/s, the rate of a live SD channel.
    private static let padding = 40

    private static let script = #"""
    import base64, http.server, os, time
    RATE, BURST, PAD = \#(rate * (padding + 1)), 1.0, \#(padding)
    NULL = b'\x47\x1f\xff\x10' + b'\xff' * 184
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            try:
                raw = base64.b64decode(open(os.path.basename(self.path) + '.b64', 'rb').read())
            except OSError:
                self.send_error(404)
                return
            data = b''.join(raw[i:i + 188] + NULL * PAD for i in range(0, len(raw), 188))
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp2t')
            self.end_headers()
            start, sent = time.monotonic(), 0
            try:
                while sent < len(data):
                    allowed = int((BURST + time.monotonic() - start) * RATE)
                    if sent >= allowed:
                        time.sleep(0.01)
                        continue
                    n = min(188 * 64, allowed - sent, len(data) - sent)
                    self.wfile.write(data[sent:sent + n])
                    sent += n
            except (BrokenPipeError, ConnectionResetError):
                pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print('READY ' + str(server.server_port), flush=True)
    server.serve_forever()
    """#

    static func run(_ ts: Data, label: String, closeAfterProbeRunsFor closeDelay: Duration? = nil)
        async throws -> PacedOpen
    {
        let origin = try #require(await PythonOrigin.launch(
            prefix: "missing-pmt-origin", script: script, files: ["live.ts.b64": ts.base64EncodedString()]))
        defer {
            origin.process.terminate()
            try? FileManager.default.removeItem(at: origin.workDir)
        }
        let capture = EngineLogCapture()
        defer { capture.end() }
        // The reader label is this open's marker in a log every parallel test writes to.
        let marker = "missing-pmt-\(label)-\(UUID().uuidString.prefix(8))"
        let url = URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!
        let demuxer = Demuxer()
        defer { demuxer.close() }
        let containerOpened = InstantBox<ContinuousClock.Instant?>(nil)
        demuxer.onOpenProgress = { stage in
            if stage == .containerOpened { containerOpened.set(ContinuousClock.now) }
        }

        let opening = Task { await openOffTheTestThread(demuxer, url: url,
                                                        profile: .playback.withReaderLabel(marker)) }
        if let closeDelay {
            try await waitFor { containerOpened.get().map { ContinuousClock.now >= $0 + closeDelay } ?? false }
            demuxer.markClosed()
        }
        _ = await opening.value

        let line = try #require(capture.matching("open timings (\(marker))").first,
                                "the open emitted no timings line")
        return PacedOpen(line: line, tracks: tracks(of: demuxer))
    }

    private static func tracks(of demuxer: Demuxer) -> Tracks {
        guard let video = demuxer.stream(at: demuxer.videoStreamIndex)?.pointee.codecpar?.pointee,
              video.width == 32, video.height == 32 else { return .missing("video") }
        guard let audio = demuxer.stream(at: demuxer.audioStreamIndex)?.pointee.codecpar?.pointee,
              audio.sample_rate == 44_100, audio.ch_layout.nb_channels == 2 else { return .missing("audio") }
        return .both
    }

    /// `open` blocks for as long as the pass reads, which on a paced source is seconds, so it runs on
    /// a thread of its own. Cancelling the test closes the demuxer, which ends the open.
    private static func openOffTheTestThread(_ demuxer: Demuxer, url: URL,
                                             profile: DemuxerOpenProfile) async -> Error? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
                Thread.detachNewThread {
                    do {
                        try demuxer.open(url: url, profile: profile, isLive: true)
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
        } onCancel: {
            demuxer.markClosed()
        }
    }
}

private final class InstantBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

/// Packet-level edits of an ffmpeg-muxed transport stream: PAT on PID 0, PMT on 0x1000, H.264 on
/// 0x100, AAC on 0x101, each PES starting a packet.
private enum TransportStreamEdit {
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101
    static let pmtPID: UInt16 = 0x1000
    /// A PMT PID nothing in the fixture uses, for the program whose PMT never arrives.
    static let silentPMTPID: UInt16 = 0x1FF0
    /// The PMT PID of a data-only service, and its one teletext stream.
    static let dataPMTPID: UInt16 = 0x1FE0
    static let teletextPID: UInt16 = 0x0200

    private static func packets(_ ts: Data) -> [Data] {
        stride(from: 0, to: ts.count - 187, by: 188).map { ts.subdata(in: $0..<($0 + 188)) }
    }

    private static func pid(_ p: Data) -> UInt16 {
        UInt16(p[p.startIndex + 1] & 0x1F) << 8 | UInt16(p[p.startIndex + 2])
    }

    private static func payloadStart(_ p: Data) -> Bool { p[p.startIndex + 1] & 0x40 != 0 }

    private static func payloadOffset(_ p: Data) -> Int {
        let control = p[p.startIndex + 3] & 0x30
        return control & 0x20 != 0 ? 5 + Int(p[p.startIndex + 4]) : 4
    }

    /// The PTS of a PES that starts in this packet, in 90 kHz ticks.
    private static func pts(_ p: Data) -> Int64? {
        guard payloadStart(p) else { return nil }
        let b = [UInt8](p.dropFirst(payloadOffset(p)))
        guard b.count >= 14, b[0] == 0, b[1] == 0, b[2] == 1, b[7] & 0x80 != 0 else { return nil }
        return (Int64(b[9] & 0x0E) << 29) | (Int64(b[10]) << 22) | (Int64(b[11] & 0xFE) << 14)
            | (Int64(b[12]) << 7) | (Int64(b[13]) >> 1)
    }

    private static func firstVideoPTS(_ all: [Data]) -> Int64 {
        all.lazy.filter { pid($0) == videoPID }.compactMap(pts).first ?? 0
    }

    /// Every PAT also lists program 2 on `silentPMTPID`, whose PMT never arrives.
    static func listingSilentProgram(_ ts: Data) -> Data {
        listing(pmtPID: silentPMTPID, in: ts)
    }

    /// Every PAT also lists program 2 on `dataPMTPID`, and is followed by that program's PMT: one
    /// teletext stream (stream type 0x06 with a teletext descriptor), no audio, no video.
    static func listingDataService(in ts: Data) -> Data {
        var section: [UInt8] = [0x02, 0xB0, 0x00, 0x00, 0x02, 0xC1, 0x00, 0x00,
                                0xFF, 0xFF, // no PCR PID
                                0xF0, 0x00, // no program descriptors
                                0x06, UInt8(0xE0 | (teletextPID >> 8)), UInt8(teletextPID & 0xFF), 0xF0, 0x07,
                                0x56, 0x05, 0x65, 0x6E, 0x67, 0x09, 0x00] // teletext, "eng", page 100
        section[2] = UInt8(section.count - 3 + 4)
        let crc = mpegCRC32(section)
        section.append(contentsOf: [24, 16, 8, 0].map { UInt8((crc >> UInt32($0)) & 0xFF) })
        var counter: UInt8 = 0
        return Data(packets(listing(pmtPID: dataPMTPID, in: ts)).flatMap { p -> [Data] in
            guard pid(p) == 0, payloadStart(p) else { return [p] }
            // Payload unit start, payload only, the continuity counter, a zero pointer field.
            var pmt: [UInt8] = [0x47, UInt8(0x40 | (dataPMTPID >> 8)), UInt8(dataPMTPID & 0xFF),
                                0x10 | counter, 0x00]
            pmt += section
            pmt += [UInt8](repeating: 0xFF, count: 188 - pmt.count)
            counter = (counter + 1) & 0x0F
            return [p, Data(pmt)]
        }.joined())
    }

    private static func listing(pmtPID: UInt16, in ts: Data) -> Data {
        Data(packets(ts).map { p -> Data in
            guard pid(p) == 0, payloadStart(p) else { return p }
            var bytes = [UInt8](p)
            let start = payloadOffset(p) + 1 + Int(bytes[payloadOffset(p)])
            let length = Int(bytes[start + 1] & 0x0F) << 8 | Int(bytes[start + 2])
            // The section without its CRC, then the new program entry.
            var section = Array(bytes[start..<(start + 3 + length - 4)])
            section.append(contentsOf: [0x00, 0x02, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
            let newLength = section.count - 3 + 4
            section[1] = (section[1] & 0xF0) | UInt8(newLength >> 8)
            section[2] = UInt8(newLength & 0xFF)
            let crc = mpegCRC32(section)
            section.append(contentsOf: [24, 16, 8, 0].map { UInt8((crc >> UInt32($0)) & 0xFF) })
            bytes.replaceSubrange(start..<(start + section.count), with: section)
            return Data(bytes)
        }.joined())
    }

    /// Drops every PES of `pid` that starts before `seconds` past the first video frame, the shape of
    /// a channel whose audio begins after its picture.
    static func dropping(pid target: UInt16, before seconds: Double, in ts: Data) -> Data {
        let all = packets(ts)
        let cutoff = firstVideoPTS(all) + Int64(seconds * 90_000)
        var dropping = true
        return Data(all.filter { p in
            guard pid(p) == target else { return true }
            if let start = pts(p) { dropping = start < cutoff }
            return !dropping
        }.joined())
    }

    /// Drops the program's PMT until the video reaches `seconds` past its first frame: a program
    /// whose PMT is late.
    static func delayingPMT(by seconds: Double, in ts: Data) -> Data {
        let all = packets(ts)
        let cutoff = firstVideoPTS(all) + Int64(seconds * 90_000)
        var videoPTS = Int64.min
        return Data(all.filter { p in
            if pid(p) == videoPID, let start = pts(p) { videoPTS = start }
            return pid(p) != pmtPID || videoPTS >= cutoff
        }.joined())
    }

    /// Starts the stream at the first video PES `seconds` past the first frame: a live join in the
    /// middle of a GOP.
    static func joined(after seconds: Double, in ts: Data) -> Data {
        let all = packets(ts)
        let cutoff = firstVideoPTS(all) + Int64(seconds * 90_000)
        let index = all.firstIndex { pid($0) == videoPID && (pts($0) ?? 0) >= cutoff } ?? 0
        return Data(all[index...].joined())
    }

    private static func mpegCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}
#endif
