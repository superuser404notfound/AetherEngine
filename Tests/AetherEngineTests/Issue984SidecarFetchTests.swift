import Testing
import Foundation
@testable import AetherEngine

/// AE#984: a text sidecar is one whole-body GET, and a whole-program subtitle rendition is never held
/// for a sidecar that is still on its way.
///
/// Before: the sidecar borrowed the playback reader, whose open sent the tail range and `bytes=0-` at
/// once (two requests for one file) and replaced an unanswered request after 15 s with one that had 25 s
/// left, so a server needing 25 s or more never delivered. The rendition's `.vtt` handler then held
/// AVPlayer's request for 30 s per try, which held AVPlayer's media loading too: the picture froze.
@Suite("Sidecar fetch and rendition readiness (AE#984)")
struct Issue984SidecarFetchTests {

    private static let vtt = """
    WEBVTT

    00:00:01.000 --> 00:00:03.000
    First line

    00:00:04.000 --> 00:00:06.000
    Second line

    """

    private static let srt = """
    1
    00:00:01,000 --> 00:00:03,000
    First line

    """

    // MARK: - Transport

    @Test("A WebVTT sidecar over HTTP costs exactly one unranged request")
    func vttIsOneUnrangedRequest() async throws {
        let origin = try #require(SidecarOrigin(files: ["/film/english.vtt": Self.vtt]))
        defer { origin.stop() }
        let result = try await SubtitleDecoder.decodeFile(url: origin.url("/film/english.vtt"))
        #expect(result.cues.map(\.text) == ["First line", "Second line"])
        let log = origin.requests
        #expect(log.count == 1)
        #expect(log.first?.range == nil)
    }

    @Test("An extensionless URL takes the same path when the host names the format")
    func formatHintSelectsWholeBodyFetch() async throws {
        let origin = try #require(SidecarOrigin(files: ["/library/streams/7": Self.srt]))
        defer { origin.stop() }
        let result = try await SubtitleDecoder.decodeFile(
            url: origin.url("/library/streams/7"), formatHint: "srt")
        #expect(result.cues.map(\.text) == ["First line"])
        #expect(origin.requests.count == 1)
        #expect(origin.requests.first?.range == nil)
    }

    @Test("A slow first byte is waited for on the same request, not replaced")
    func slowSidecarIsNotRequestedTwice() async throws {
        let origin = try #require(SidecarOrigin(files: ["/s.vtt": Self.vtt], delaySeconds: 1.5))
        defer { origin.stop() }
        let result = try await SubtitleDecoder.decodeFile(url: origin.url("/s.vtt"))
        #expect(result.cues.count == 2)
        #expect(origin.requests.count == 1)
    }

    @Test("A refused sidecar fails typed with its status")
    func refusalIsTyped() async throws {
        let origin = try #require(SidecarOrigin(files: [:]))
        defer { origin.stop() }
        await #expect(throws: SubtitleDecoderError.self) {
            _ = try await SubtitleDecoder.decodeFile(url: origin.url("/missing.vtt"))
        }
        #expect(origin.requests.count == 1)
    }

    @Test("The budget outlasts a server that extracts the stream before answering")
    func budgetIsGenerous() {
        #expect(SidecarTextFetch.requestTimeout >= 60)
        #expect(SidecarTextFetch.resourceTimeout >= SidecarTextFetch.requestTimeout)
        #expect(SidecarTextFetch.sessionConfiguration().timeoutIntervalForRequest == SidecarTextFetch.requestTimeout)
    }

    @Test("Containers and bitmap sidecars stay on the reader")
    func onlyTextTakesTheWholeBodyPath() throws {
        let base = try #require(URL(string: "https://jf.test/a"))
        #expect(SidecarTextFetch.appliesTo(base.appendingPathExtension("vtt"), formatHint: nil))
        #expect(SidecarTextFetch.appliesTo(base.appendingPathExtension("ASS"), formatHint: nil))
        #expect(SidecarTextFetch.appliesTo(base, formatHint: "subrip"))
        #expect(!SidecarTextFetch.appliesTo(base.appendingPathExtension("mks"), formatHint: nil))
        #expect(!SidecarTextFetch.appliesTo(base.appendingPathExtension("sup"), formatHint: nil))
        #expect(!SidecarTextFetch.appliesTo(URL(fileURLWithPath: "/tmp/a.vtt"), formatHint: nil))
    }

    // MARK: - Store readiness

    @Test("A store reports where its sidecar fill stands")
    func storeServeStates() {
        let store = NativeSubtitleCueStore()
        #expect(store.wholeProgramServe == .waitForReader)
        store.markExternalFillPending()
        #expect(store.wholeProgramServe == .retryLater)
        store.markExternalFillFailed()
        #expect(store.wholeProgramServe == .failedFill)

        let filled = NativeSubtitleCueStore()
        filled.markExternalFillPending()
        filled.markFinished()
        #expect(filled.wholeProgramServe == .complete)
        filled.markExternalFillPending()
        filled.markExternalFillFailed()
        #expect(filled.wholeProgramServe == .complete)
    }

    @Test("A fill whose sidecar is refused marks its store failed, not finished")
    func refusedFillIsMarkedFailed() async throws {
        let origin = try #require(SidecarOrigin(files: [:]))
        defer { origin.stop() }
        let store = NativeSubtitleCueStore()
        let job = AetherEngine.ExternalSubtitleFillJob(
            url: origin.url("/gone.vtt"), headers: [:], targets: [.init(streamIndex: nil, store: store)])
        await AetherEngine.runExternalSubtitleFill(job: job)
        #expect(!store.isFinished)
        #expect(store.wholeProgramServe == .failedFill)
    }

    // MARK: - Rendition handler

    @Test("The rendition answers 404 while its sidecar is on the way, then the whole file")
    func renditionIsNotHeldForAPendingFill() async throws {
        let origin = try #require(SidecarOrigin(files: ["/slow.vtt": Self.vtt], delaySeconds: 2))
        defer { origin.stop() }
        let provider = Self.provider(sidecar: origin.url("/slow.vtt"))
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop(); provider.cancelFill() }
        provider.startFill()

        // The status is the verdict, not the wall clock: a held request ends 200 once the fill lands
        // (or empty at its deadline), never 404, and a timing bound flakes in a parallel run.
        let early = try await Self.get("/\(server.pathToken)/subs_0_0.vtt", port: server.port)
        #expect(early.status == 404)

        await provider.awaitFill()
        let late = try await Self.get("/\(server.pathToken)/subs_0_0.vtt", port: server.port)
        #expect(late.status == 200)
        #expect(late.body.contains("First line"))
        #expect(late.body.contains("Second line"))
    }

    @Test("A failed fill is served empty at once")
    func failedFillIsServedEmpty() async throws {
        let origin = try #require(SidecarOrigin(files: [:]))
        defer { origin.stop() }
        let provider = Self.provider(sidecar: origin.url("/gone.vtt"))
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop(); provider.cancelFill() }
        provider.startFill()
        await provider.awaitFill()

        let answer = try await Self.get("/\(server.pathToken)/subs_0_0.vtt", port: server.port)
        #expect(answer.status == 200)
        #expect(answer.body.hasPrefix("WEBVTT"))
        #expect(!answer.body.contains("-->"))
    }

    // MARK: - Helpers

    private static func provider(sidecar: URL) -> RemoteHLSSubtitleProvider {
        RemoteHLSSubtitleProvider(
            tracks: [RemoteHLSSubtitleProvider.Track(
                externalID: 100_000,
                source: ExternalSubtitleTrack(url: sidecar, name: "English", language: "en"))],
            masterBody: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"
            https://jf.test/videos/42/main.m3u8
            """,
            programDuration: 60, defaultHeaders: [:], mediaURL: nil)
    }

    private static func get(_ path: String, port: UInt16) async throws -> (status: Int, body: String) {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
    }
}

/// A loopback origin that serves fixed bodies by path, one request per connection, and records every
/// request it is asked: its path and its Range header. A path it does not know answers 404.
private final class SidecarOrigin: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let range: String?
    }

    private let listener: LoopbackListener
    private let files: [String: String]
    private let delayMicros: useconds_t
    private let lock = NSLock()
    private var log: [Request] = []

    init?(files: [String: String], delaySeconds: Double = 0) {
        guard let listener = LoopbackListener() else { return nil }
        self.listener = listener
        self.files = files
        delayMicros = useconds_t(delaySeconds * 1_000_000)
        listener.start { [self] fd in
            Thread.detachNewThread { [self] in serve(fd) }
            return true
        }
    }

    var requests: [Request] { lock.withLock { log } }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port)\(path)")! }

    func stop() { listener.stop() }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var head = Data()
        var byte: UInt8 = 0
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard read(fd, &byte, 1) == 1 else { return }
            head.append(byte)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return }
        let path = String(parts[1])
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        lock.withLock { log.append(Request(path: path, range: range)) }
        if delayMicros > 0 { usleep(delayMicros) }
        let response: String
        if let body = files[path] {
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n" + body
        } else {
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            sent += n
        }
    }
}
