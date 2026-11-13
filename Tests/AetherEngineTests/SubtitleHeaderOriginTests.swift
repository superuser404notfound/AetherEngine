import Foundation
import Testing
@testable import AetherEngine

@Suite("External subtitle initial-request header origins")
struct SubtitleHeaderOriginTests {
    @Test func originAndExplicitAuthority() {
        let media = URL(string: "https://Media.Example:443/movie.mkv")!
        let headers = ["Authorization": "synthetic-media", "X-Custom-Token": "synthetic-custom"]
        func resolve(_ target: String, _ explicit: [String: String]? = nil) -> [String: String] {
            AetherEngine.resolvedSubtitleHeaders(for: URL(string: target)!, explicit: explicit,
                                                mediaURL: media, mediaHeaders: headers)
        }
        #expect(resolve("https://media.example/en.srt") == headers)
        for target in ["https://other.example/en.srt", "https://media.example:444/en.srt",
                       "http://media.example/en.srt", "file:///tmp/en.srt"] {
            #expect(resolve(target).isEmpty)
            #expect(resolve(target, ["Authorization": "subtitle"]) == ["Authorization": "subtitle"])
        }
        #expect(resolve("https://media.example/en.srt", [:]).isEmpty)
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: URL(string: "https://media.example/en.srt")!, explicit: nil,
            mediaURL: URL(string: "http://media.example/movie.mkv"), mediaHeaders: headers).isEmpty)
        #expect(AetherEngine.resolvedSubtitleHeaders(
            for: media, explicit: nil, mediaURL: nil, mediaHeaders: headers).isEmpty)
    }

    @Test func nativeStoreFillKeepsHeadersTrackBound() {
        let media = URL(string: "https://media.example/movie.mkv")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: .init(url: URL(string: "https://media.example/en.srt")!, name: "same"),
            100_001: .init(url: URL(string: "https://other.example/fr.srt")!, name: "other"),
            100_002: .init(url: URL(string: "https://other.example/de.srt")!, name: "explicit",
                          httpHeaders: ["Authorization": "subtitle"]),
        ]
        let entries = registry.keys.sorted().map {
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: $0, language: "en", isForced: false)
        }
        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: entries, registry: registry, stores: entries.map { _ in NativeSubtitleCueStore() },
            defaultHeaders: ["Authorization": "media"], mediaURL: media)
        #expect(jobs.map(\.headers) == [["Authorization": "media"], [:], ["Authorization": "subtitle"]])
        let tracks = registry.keys.sorted().map {
            RemoteHLSSubtitleProvider.Track(externalID: $0, source: registry[$0]!)
        }
        let remoteJobs = RemoteHLSSubtitleProvider.fillJobs(
            tracks: tracks, stores: tracks.map { _ in NativeSubtitleCueStore() },
            defaultHeaders: ["Authorization": "media"], mediaURL: media)
        #expect(remoteJobs.map(\.headers) == jobs.map(\.headers))

    }
}

#if os(macOS)
@MainActor
@Suite("Sidecar requests observed at their origin", .timeLimit(.minutes(3)))
struct SubtitleHeaderOriginRequestTests {
    private let script = #"""
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        text = self.headers.get('Authorization', 'none') + '|' + self.headers.get('X-Custom-Token', 'none')
        body = ('1\n00:00:00,000 --> 00:00:02,000\n' + text + '\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/x-subrip')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('READY ' + str(server.server_port), flush=True)
server.serve_forever()
"""#

    @Test("Both overlays scope the actual first request", arguments: [false, true])
    func actualRequests(secondary: Bool) async throws {
        let origin = try #require(await PythonOrigin.launch(prefix: "sidecar-header-origin", script: script))
        defer {
            origin.process.terminate()
            try? FileManager.default.removeItem(at: origin.workDir)
        }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/en.srt")!
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.setLoadedOptionsForTesting(.init(httpHeaders: ["Authorization": "media", "X-Custom-Token": "custom"]))
        func select(_ headers: [String: String]?) async throws -> [String] {
            if secondary {
                engine.selectSecondarySidecarSubtitle(url: url, httpHeaders: headers)
                await engine.secondarySidecarTask?.value
                return engine.secondarySubtitleCues.compactMap(\.text)
            }
            engine.selectSidecarSubtitle(url: url, httpHeaders: headers)
            await engine.sidecarTask?.value
            return engine.subtitleCues.compactMap(\.text)
        }
        // The media origin need not be contacted. Different ports alone must isolate its headers.
        let otherPort = origin.port == 65535 ? 65534 : Int(origin.port) + 1
        engine.loadedURL = URL(string: "http://127.0.0.1:\(otherPort)/movie.mkv")!
        #expect(try await select(nil) == ["none|none"])
        #expect(try await select(["Authorization": "subtitle"]) == ["subtitle|none"])
        engine.loadedURL = URL(string: "http://127.0.0.1:\(origin.port)/movie.mkv")!
        #expect(try await select(nil) == ["media|custom"])
        #expect(try await select([:]) == ["none|none"])
    }
}
#endif
