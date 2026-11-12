import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// AE#154 follow-up: the reroute onto the remote-HLS bypass is taken because the engine READ the body and
/// found `#EXTM3U`, but AVFoundation types the URL on its own, from its path extension and the response's
/// `Content-Type`, and never from the body. A playlist behind `/movie.mp4` served as `video/mp4` or
/// `application/octet-stream` (an IPTV panel's VOD link, typically) therefore failed on the bypass in 0.2 to
/// 0.3 s with AVFoundation -11829 / -11828, after the engine had already found the one route that plays it.
/// The bypass now declares the HLS MIME type on the asset, and only where the body proved it.
@Suite("A mis-typed HLS playlist plays on the reroute (AE#154)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct MisTypedPlaylistRerouteTests {

    /// One 32 s segment of the synthetic H.264 / AAC transport stream. H.264, so the HEVC-in-TS ingest
    /// reroute stays out of it and the load reaches the AVPlayer bypass.
    private static let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:33
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:32.0,
        seg0.ts
        #EXT-X-ENDLIST

        """

    private static func origin(servingPlaylistAs contentType: String) throws -> RangeFilesOrigin {
        let origin = try #require(RangeFilesOrigin())
        origin.serve("/vod/movie.mp4", Data(playlist.utf8), contentType: contentType)
        origin.serve("/vod/seg0.ts", try LongGOPTransportStreamFixture.data(), contentType: "video/mp2t")
        return origin
    }

    /// Settled either way: AVPlayer has the item ready, or the session failed.
    private static func settled(_ engine: AetherEngine) -> Bool {
        if case .error = engine.state { return true }
        guard let host = engine.nativeHost else { return false }
        return host.isReady || host.failure != nil
    }

    // MARK: - AVURLAsset options seam

    @Test("AE#154: a body-proven playlist declares the HLS MIME type on the asset")
    func declarationLandsInAssetOptions() throws {
        let options = try #require(
            NativeAVPlayerHost.assetCreationOptions(httpHeaders: [:], declaresHLSPlaylist: true))
        #expect(options[AVURLAssetOverrideMIMETypeKey] as? String == "application/vnd.apple.mpegurl")
        #expect(options.count == 1)
    }

    @Test("AE#154: the declaration rides beside the origin's headers, not instead of them")
    func declarationKeepsHeaders() throws {
        let headers = ["Referer": "https://example.org/"]
        let options = try #require(
            NativeAVPlayerHost.assetCreationOptions(httpHeaders: headers, declaresHLSPlaylist: true))
        #expect(options["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] == headers)
        #expect(options[AVURLAssetOverrideMIMETypeKey] as? String == NativeAVPlayerHost.hlsPlaylistMIMEType)
    }

    @Test("AE#154: without body evidence the asset keeps AVFoundation's own typing")
    func noEvidenceNoDeclaration() {
        #expect(NativeAVPlayerHost.assetCreationOptions(httpHeaders: [:], declaresHLSPlaylist: false) == nil)
        let options = NativeAVPlayerHost.assetCreationOptions(httpHeaders: ["Referer": "https://example.org/"])
        #expect(options?[AVURLAssetOverrideMIMETypeKey] == nil)
    }

    // MARK: - Through the engine

    @Test("AE#154: a playlist behind an .mp4 URL plays on the reroute, whatever the origin types it as",
          arguments: ["video/mp4", "application/octet-stream"])
    func misTypedPlaylistPlays(contentType: String) async throws {
        let origin = try Self.origin(servingPlaylistAs: contentType)
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }

        _ = try await engine.load(url: try #require(URL(string: "\(origin.baseURL)/vod/movie.mp4")),
                                  options: LoadOptions(autoplay: false))

        #expect(engine.loadedOptions.nativeRemoteHLS, "the body should have taken the AE#154 reroute")
        #expect(engine.loadedOptions.hlsPlaylistProvenByBody)
        #expect(engine.nativeHost?.sessionContract.declaresHLSPlaylistMIMEType == true)
        try await waitFor { Self.settled(engine) }
        // Before the declaration this was AVFoundation -11829 (video/mp4) or -11828 (octet-stream).
        #expect(engine.nativeHost?.failure == nil)
        #expect(engine.nativeHost?.isReady == true)
    }

    @Test("AE#154: a rebuild of the rerouted session keeps the declaration")
    func rebuildKeepsDeclaration() async throws {
        let origin = try Self.origin(servingPlaylistAs: "video/mp4")
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: try #require(URL(string: "\(origin.baseURL)/vod/movie.mp4")),
                                  options: LoadOptions(autoplay: false))
        try await waitFor { Self.settled(engine) }
        #expect(engine.nativeHost?.isReady == true)
        let firstItem = engine.nativeHost?.itemGeneration

        // The rebuild replays `loadedOptions` straight onto the bypass and runs no probe, so the body
        // evidence has to travel with the options or the rebuilt item fails where the first one played.
        try await engine.reloadAtCurrentPosition()

        #expect(engine.nativeHost?.itemGeneration != firstItem, "the reload should have mounted a new item")
        #expect(engine.loadedOptions.hlsPlaylistProvenByBody)
        #expect(engine.nativeHost?.sessionContract.declaresHLSPlaylistMIMEType == true)
        try await waitFor { Self.settled(engine) }
        #expect(engine.nativeHost?.failure == nil)
        #expect(engine.nativeHost?.isReady == true)
    }

    @Test("AE#154: a host-declared bypass of an .m3u8 declares nothing")
    func hostDeclaredBypassDeclaresNothing() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        // Dead-end URL: the bypass wires its host synchronously and never awaits readiness.
        _ = try await engine.load(url: try #require(URL(string: "http://127.0.0.1:9/vod.m3u8")),
                                  options: LoadOptions(nativeRemoteHLS: true))
        #expect(!engine.loadedOptions.hlsPlaylistProvenByBody)
        #expect(engine.nativeHost?.sessionContract.declaresHLSPlaylistMIMEType == false)
    }

    @Test("AE#154: a real MP4 at the same URL shape stays on the loopback and declares nothing")
    func realMP4DeclaresNothing() async throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        origin.serve("/vod/movie.mp4", try ProbeTestFixtures.hdr10Plus(), contentType: "video/mp4")
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: try #require(URL(string: "\(origin.baseURL)/vod/movie.mp4")),
                                  options: LoadOptions(autoplay: false))
        #expect(!engine.loadedOptions.nativeRemoteHLS)
        #expect(!engine.loadedOptions.hlsPlaylistProvenByBody)
        #expect(engine.nativeHost?.sessionContract.declaresHLSPlaylistMIMEType == false)
    }
}
