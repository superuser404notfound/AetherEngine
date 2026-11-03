import Foundation
import Testing
@testable import AetherEngine

struct LivePlaylistRenewalTests {
    private func makeProvider() -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32)
        let provider = VideoSegmentProvider(cache: cache, segments: [], codecsString: "avc1.64002A",
            supplementalCodecs: nil, resolution: (1920, 1080), videoRange: .sdr,
            frameRate: 30, hdcpLevel: nil, sourceBitrate: 4_000_000, isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil))
        return (provider, cache)
    }

    private func target(_ playlist: String) -> Int? {
        playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
    }

    @Test("long GOP renews the playlist while old video and subtitle URLs remain valid")
    func longGOP() throws {
        let (provider, cache) = makeProvider()
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 2.8)
        provider.appendLiveSegment(index: 1, startSeconds: 2.8, durationSeconds: 1.466)
        let original = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0)
        #expect(target(original) == 4)
        #expect(provider.livePlaylistGeneration == 0)
        provider.appendLiveSegment(index: 2, startSeconds: 4.266, durationSeconds: 8.333)
        #expect(provider.livePlaylistGeneration == 1)
        let retired = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0)
        #expect(target(retired) == 4)
        #expect(!retired.contains("seg2.mp4"))
        #expect(retired.contains("#EXT-X-ENDLIST"))
        #expect(retired.contains("seg1.mp4"))
        let fresh = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 1)
        #expect(try #require(target(fresh)) >= 8)
        #expect(fresh.contains("#EXTINF:8.333,"))
        #expect(fresh.contains("seg0.mp4")) // Same retained timeline, not a source reload.
        let oldSubs = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: provider, generation: 0)
        #expect(target(oldSubs) == 4)
        #expect(!oldSubs.contains("subs_0_2.vtt"))
        let newSubs = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: provider, generation: 1)
        #expect(target(newSubs) == target(fresh))
        #expect(newSubs.contains("subs_0_2.vtt"))
        provider.appendLiveSegment(index: 3, startSeconds: 12.599, durationSeconds: 2)
        #expect(provider.livePlaylistGeneration == 1)
        let stillRetired = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0)
        #expect(target(stillRetired) == 4)
        #expect(provider.livePlaylistEndIndex(generation: 0) == 2)
        #expect(!stillRetired.contains("seg3.mp4"))
        #expect(provider.livePlaylistEndIndex(generation: 1) == nil)
    }

    @Test("a renewed playlist can leave an outage while the retired URL stays closed")
    func renewalAfterOutage() {
        let (provider, cache) = makeProvider()
        defer { cache.close() }
        for index in 0..<6 {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * 2.8, durationSeconds: 2.8)
        }
        _ = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0)
        cache.declareTarget(4)
        provider.consumerBufferedSecondsProvider = { 0 }
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 30)
        #expect(provider.liveOutageEndlist)
        provider.appendLiveSegment(index: 6, startSeconds: 16.8, durationSeconds: 8.333)
        provider.clearLiveOutageEndlist()
        #expect(!provider.liveOutageEndlistLatched)
        #expect(HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0).contains("#EXT-X-ENDLIST"))
        #expect(!HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 1).contains("#EXT-X-ENDLIST"))
    }

    @Test("HTTP clients can finish the old playlist and mount the renewed master", .timeLimit(.minutes(3)))
    func httpRenewal() async throws {
        let (provider, cache) = makeProvider()
        defer { cache.close() }
        for index in 0..<6 {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * 2.8, durationSeconds: 2.8)
        }
        _ = HLSLocalServer.buildMediaPlaylistText(provider: provider, generation: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let original = try #require(server.mediaPlaylistURL)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        _ = try await client.data(from: original)
        provider.appendLiveSegment(index: 6, startSeconds: 16.8, durationSeconds: 8.333)
        let renewed = try #require(server.mediaPlaylistURL)
        #expect(original != renewed)
        #expect(server.renewedLivePlaylistURL(replacing: original) == renewed)
        var lan = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        lan.host = "192.0.2.1"
        let lanURL = try #require(lan.url)
        let renewedLAN = try #require(server.renewedLivePlaylistURL(replacing: lanURL))
        #expect(renewedLAN.host == "192.0.2.1")
        #expect(renewedLAN.path == renewed.path)
        let (oldData, oldResponse) = try await client.data(from: original)
        #expect((oldResponse as? HTTPURLResponse)?.statusCode == 200)
        let oldText = String(decoding: oldData, as: UTF8.self)
        #expect(target(oldText) == 4)
        #expect(!oldText.contains("seg6.mp4"))
        let (newData, newResponse) = try await client.data(from: renewed)
        #expect((newResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: newData, as: UTF8.self).contains("seg6.mp4"))
        let master = try #require(server.playlistURL)
        let (masterData, _) = try await client.data(from: master)
        #expect(String(decoding: masterData, as: UTF8.self).contains("media.m3u8"))
        #expect(URL(string: "media.m3u8", relativeTo: master)?.absoluteURL == renewed)
    }

    @Test("playlist renewal respects the serialized EXTINF rounding boundary")
    func rounding() {
        #expect(LiveTargetDurationSeal.accepts(1.2, target: 1))
        #expect(LiveTargetDurationSeal.accepts(1.4994, target: 1))
        #expect(!LiveTargetDurationSeal.accepts(1.4996, target: 1))
        #expect(!LiveTargetDurationSeal.accepts(.infinity, target: 4))
    }

    @Test("relative media, subtitle and segment routes retain their generation")
    func routes() {
        let paths = ["media.m3u8", "master.m3u8", "master_hdr.m3u8", "subs_0.m3u8", "seg12.mp4", "init.mp4"]
        for path in paths {
            let route = HLSLocalServer.livePlaylistRoute("/live-2/" + path)
            #expect(route.path == "/" + path)
            #expect(route.generation == 2)
        }
        #expect(HLSLocalServer.livePlaylistRoute("/media.m3u8").generation == 0)
        #expect(HLSLocalServer.livePlaylistRoute("/live--1/media.m3u8").generation == 0)
    }
}
