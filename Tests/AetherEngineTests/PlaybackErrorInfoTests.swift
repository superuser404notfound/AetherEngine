import Foundation
import Testing
@testable import AetherEngine

/// Covers the machine-readable failure companion (#376). The gap it closes: `PlaybackState.error`
/// carries one string, and on the native paths that string is `AVPlayerItem.error.localizedDescription`
/// forwarded verbatim, so a host classifying its failures was substring-matching text the OS had
/// already translated. The kind and the underlying domain / code are what survive a locale.
@Suite("PlaybackErrorInfo (#376)")
struct PlaybackErrorInfoTests {

    @MainActor
    @Test("A failed custom probe publishes its cause before the host observes the terminal state")
    func customProbeRetainsCause() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var observed: PlaybackErrorInfo?
        let token = engine.$state.sink { state in
            if case .error = state { observed = engine.errorInfo }
        }
        defer { token.cancel() }
        do {
            _ = try await engine.load(source: .custom(DataIOReader(data: Data()), formatHint: "mpegts"))
            Issue.record("An empty custom source must fail its probe")
        } catch {
            #expect(observed?.kind == .customSourceProbeFailed)
            #expect(observed?.underlyingDomain == "AetherEngine.DemuxerError")
            #expect(observed?.underlyingCode != nil)
            #expect(observed?.ffmpegErrorCode != nil)
            #expect(observed == engine.errorInfo)
        }
    }

    @MainActor
    @Test("A live HLS join the origin refuses publishes its answer, not a probe failure",
          .timeLimit(.minutes(1)),
          arguments: [(509, PlaybackErrorKind.sourceRateLimited), (403, .sourceRefused)])
    func refusedLiveJoinPublishesTheOriginsAnswer(status: Int, kind: PlaybackErrorKind) async throws {
        let origin = try #require(RefusingOrigin(status: status))
        defer { origin.stop() }
        let observed = try await failedLiveIngestLoad(
            try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/1.m3u8")))
        #expect(observed?.kind == kind)
        #expect(observed?.underlyingCode == status)
    }

    @MainActor
    @Test("A live HLS join retains the actual connection error", .timeLimit(.minutes(1)))
    func unreachableLiveJoinIsUnavailable() async throws {
        let observed = try await failedLiveIngestLoad(try #require(URL(string: "http://127.0.0.1:1/live/1.m3u8")))
        #expect(observed?.kind == .liveSourceUnavailable)
        #expect(observed?.underlyingDomain == NSURLErrorDomain)
        #expect(observed?.underlyingCode == NSURLErrorCannotConnectToHost)
    }

    @MainActor
    @Test("HLS format limits, invalid bodies and key HTTP refusals stay distinct")
    func hlsFailureClassification() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        for (error, kind, code) in [
            (HLSIngestError.unsupportedSegmentFormat, PlaybackErrorKind.hlsFormatUnsupported, 4),
            (.encryptedNotSupported, .hlsFormatUnsupported, 3),
            (.playlistInvalid(reason: "private"), .hlsIngestFailed, 1),
            (.segmentDecryptFailed(reason: "private"), .hlsIngestFailed, 2),
            (.playlistUnreachable(status: 403), .sourceRefused, 403)
        ] {
            engine.publishLoadFailure(error)
            #expect(engine.errorInfo?.kind == kind)
            #expect(engine.errorInfo?.underlyingCode == code)
        }
        engine.publishLoadFailure(URLError(.secureConnectionFailed))
        #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
        #expect(engine.errorInfo?.underlyingCode == -1200)
    }

    @MainActor
    @Test("A plain-URL live open the origin refuses publishes its answer, not an outage (#796)",
          .timeLimit(.minutes(1)),
          arguments: [(503, PlaybackErrorKind.sourceRateLimited), (403, .sourceRefused)])
    func refusedLiveOpenPublishesTheOriginsAnswer(status: Int, kind: PlaybackErrorKind) async throws {
        let origin = try #require(RefusingOrigin(status: status))
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        do {
            _ = try await engine.load(
                url: try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/1.ts")), options: options)
            Issue.record("A refused live open must fail the load")
        } catch {
            #expect(error as? AVIOReaderError == .httpStatus(status))
        }
        #expect(engine.errorInfo?.kind == kind)
        #expect(engine.errorInfo?.underlyingCode == status)
    }

    /// Loads `url` live through the engine's own HLS ingest, as a known HLS playlist on the live path
    /// is, and returns the failure the load published.
    @MainActor
    private func failedLiveIngestLoad(_ url: URL) async throws -> PlaybackErrorInfo? {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var observed: PlaybackErrorInfo?
        let token = engine.$state.sink { state in
            if case .error = state { observed = engine.errorInfo }
        }
        defer { token.cancel() }
        var options = LoadOptions()
        options.isLive = true
        let reader = HLSLiveIngestReader(playlistURL: url)
        do {
            _ = try await engine.load(
                source: .custom(reader, formatHint: "mpegts"), options: options)
            Issue.record("A refused live playlist must fail the load")
        } catch {
            #expect(reader.terminalError != nil, "Existing hosts must still observe a terminal reader")
        }
        return observed
    }

    /// Answers every request with `status` and an empty body, one response per connection.
    private final class RefusingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener

        init?(status: Int) {
            guard let listener = LoopbackListener(backlog: 8) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { conn in
                Thread.detachNewThread {
                    defer { close(conn) }
                    var request = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                        let n = read(conn, &buffer, buffer.count)
                        guard n > 0 else { return }
                        request.append(contentsOf: buffer[0..<n])
                    }
                    let response = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    _ = response.withCString { write(conn, $0, strlen($0)) }
                }
                return true
            }
        }

        func stop() {
            listener.stop()
        }
    }

    @Test("An underlying NSError contributes its domain and code")
    func capturesUnderlying() {
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let info = PlaybackErrorInfo(kind: .nativeItemFailed,
                                     message: underlying.localizedDescription,
                                     underlying: underlying)
        #expect(info.kind == .nativeItemFailed)
        #expect(info.underlyingDomain == "CoreMediaErrorDomain")
        #expect(info.underlyingCode == -12939)
        #expect(info.ffmpegErrorCode == nil)
    }

    @Test("Demux diagnostics preserve historical case codes and a separate FFmpeg cause")
    func capturesDemuxDiagnostics() {
        let cases: [(DemuxerError, Int)] = [
            (.openFailed(code: -1094995529), 0),
            (.streamInfoFailed(code: -1094995529), 1),
            (.readFailed(code: -1094995529), 2)
        ]
        for (error, code) in cases {
            let info = PlaybackErrorInfo(kind: .customSourceProbeFailed, message: "private", underlying: error)
            #expect(info.underlyingDomain == "AetherEngine.DemuxerError")
            #expect(info.underlyingCode == code)
            #expect(info.ffmpegErrorCode == -1094995529)
        }
        let wrapper = NSError(domain: "wrapper", code: 42,
                              userInfo: [NSUnderlyingErrorKey: DemuxerError.readFailed(code: -5) as NSError])
        let info = PlaybackErrorInfo(kind: .sourceOpenFailed, message: "private", underlying: wrapper)
        #expect(info.underlyingDomain == "wrapper")
        #expect(info.underlyingCode == 42)
        #expect(info.ffmpegErrorCode == -5)
    }

    @Test("FFmpeg metadata requires the SDK domain, a negative Int32 and bounded wrappers")
    func rejectsInvalidDemuxDiagnostics() {
        let invalidValues: [Any] = ["private", -1.5, Double.nan, Double.infinity, 0, 1, Int(Int32.min) - 1]
        for value in invalidValues {
            let error = NSError(domain: DemuxerError.errorDomain, code: 0,
                                userInfo: [DemuxerError.ffmpegErrorCodeKey: value])
            #expect(PlaybackErrorInfo(kind: .sourceOpenFailed, message: "private", underlying: error).ffmpegErrorCode == nil)
        }
        let wrongDomain = NSError(domain: "unrelated", code: 0,
                                  userInfo: [DemuxerError.ffmpegErrorCodeKey: -5])
        #expect(PlaybackErrorInfo(kind: .sourceOpenFailed, message: "private", underlying: wrongDomain).ffmpegErrorCode == nil)
        var wrapped = DemuxerError.openFailed(code: -5) as NSError
        for _ in 0..<6 {
            wrapped = NSError(domain: "wrapper", code: 42, userInfo: [NSUnderlyingErrorKey: wrapped])
        }
        #expect(PlaybackErrorInfo(kind: .sourceOpenFailed, message: "private", underlying: wrapped).ffmpegErrorCode == nil)
    }

    @Test("An engine-authored failure has no underlying domain, which is how a host tells the halves apart")
    func engineAuthoredHasNoUnderlying() {
        let info = PlaybackErrorInfo(kind: .liveSourceUnavailable, message: "Live source unavailable")
        #expect(info.underlyingDomain == nil)
        #expect(info.underlyingCode == nil)
        #expect(info.ffmpegErrorCode == nil)
        // The same constructor path the hosts use when there is nothing underneath.
        let fromNilError = PlaybackErrorInfo(kind: .liveSourceUnavailable,
                                             message: "Live source unavailable",
                                             underlying: nil)
        #expect(fromNilError == info)
    }

    /// The raw values are API: a host ships them into an analytics bucket, so a rename is a silent
    /// break in someone else's histogram rather than a compile error here.
    @Test("Kind raw values are the published tokens and are distinct")
    func rawValuesAreStableAndDistinct() {
        let kinds: [PlaybackErrorKind] = [
            .sourceOpenFailed, .sourceRefused, .customSourceProbeFailed, .liveSourceUnavailable,
            .hlsPlaylistOnRawLivePath, .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported,
            .nativeItemFailed, .noPlayableTrackWithinBudget, .masterPlaylistRejected,
            .vodSourceFailed, .softwarePipelineFailed, .audioSessionFailed,
            .reloadFailed, .liveReloadNeverReady, .audioTrackSwitchFailed,
        ]
        #expect(Set(kinds.map(\.rawValue)).count == kinds.count)
        #expect(PlaybackErrorKind.nativeItemFailed.rawValue == "nativeItemFailed")
        #expect(PlaybackErrorKind(rawValue: "nativeItemFailed") == .nativeItemFailed)
    }

    @MainActor
    @Test("publishError assigns the info BEFORE the state, so a $state sink reads this failure's own")
    func infoIsVisibleFromAStateSink() throws {
        let engine = try AetherEngine()
        var seen: [PlaybackErrorInfo?] = []
        let token = engine.$state
            .dropFirst()                        // the replay of .idle belongs to no failure
            .sink { _ in seen.append(engine.errorInfo) }
        defer { token.cancel() }

        engine.publishError(.liveSourceUnavailable, "Live source unavailable")

        #expect(seen.count == 1)
        #expect(seen.first??.kind == .liveSourceUnavailable)
        #expect(engine.state == .error("Live source unavailable"))
    }

    @MainActor
    @Test("The info dies with the failure it describes")
    func clearedWhenTheStateLeavesError() throws {
        let engine = try AetherEngine()
        engine.publishError(.reloadFailed, "Reload failed: nope")
        #expect(engine.errorInfo?.kind == .reloadFailed)

        engine.state = .loading
        #expect(engine.errorInfo == nil)
    }

    /// The funnel is the reason a published `.error` can never arrive without its classification. A new
    /// failure site that assigns `state` directly would compile, run, and publish an unclassifiable
    /// error, which is exactly the shape this issue exists to remove.
    @Test("Nothing outside the funnel publishes .error")
    func onlyTheFunnelPublishesError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)

        let assignment = try NSRegularExpression(pattern: #"state\s*=\s*\.error\("#)
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "PlaybackErrorInfo.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = assignment.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if hits > 0 { offenders.append("\(file.lastPathComponent) (\(hits))") }
        }
        #expect(offenders.isEmpty, "publish these through publishError instead: \(offenders.joined(separator: ", "))")
    }
}
