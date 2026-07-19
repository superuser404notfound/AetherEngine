import Testing
import Foundation
@testable import AetherEngine

/// AE#140: `load(url: m3u8, options: LoadOptions(isLive: true))` without `nativeRemoteHLS` routes the
/// playlist URL onto the raw-byte live reader. The origin serves the finite #EXTM3U body at HTTP 200 and
/// closes; the endless-feed reader then re-fetches it forever (productive-looking reconnects the #71
/// give-up counters can't catch), so avformat_open_input never returns and load() hangs with no terminal
/// state. AVIOReader now classifies the first bytes and fails closed before entering the reconnect loop.
/// These cover the classifier in isolation (no network): a raw media container never opens with '#', so an
/// #EXTM3U prefix is an unambiguous misroute.
struct AVIOReaderHLSMisrouteTests {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    @Test("Media playlist body is detected")
    func mediaPlaylist() {
        let body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts\n"
        #expect(AVIOReader.bodyBeginsWithHLSPlaylistTag(bytes(body)))
    }

    @Test("Master playlist body is detected")
    func masterPlaylist() {
        let body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nvariant.m3u8\n"
        #expect(AVIOReader.bodyBeginsWithHLSPlaylistTag(bytes(body)))
    }

    @Test("UTF-8 BOM before the tag is tolerated")
    func bomPrefix() {
        var b: [UInt8] = [0xEF, 0xBB, 0xBF]
        b.append(contentsOf: bytes("#EXTM3U\n"))
        #expect(AVIOReader.bodyBeginsWithHLSPlaylistTag(b))
    }

    @Test("Leading whitespace before the tag is tolerated")
    func leadingWhitespace() {
        #expect(AVIOReader.bodyBeginsWithHLSPlaylistTag(bytes("  \n\t#EXTM3U\n")))
    }

    @Test("MPEG-TS sync bytes are not a playlist")
    func mpegTSSync() {
        // TS packets sync on 0x47; the raw live path this guards is exactly the TS case.
        let ts: [UInt8] = [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
        #expect(!AVIOReader.bodyBeginsWithHLSPlaylistTag(ts))
    }

    @Test("MP4 ftyp box is not a playlist")
    func mp4Ftyp() {
        let mp4: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70] // ....ftyp
        #expect(!AVIOReader.bodyBeginsWithHLSPlaylistTag(mp4))
    }

    @Test("A bare #EXTINF without the #EXTM3U header is not matched")
    func extinfWithoutHeader() {
        #expect(!AVIOReader.bodyBeginsWithHLSPlaylistTag(bytes("#EXTINF:6.0,\nseg0.ts\n")))
    }

    @Test("A truncated #EXT prefix is not matched")
    func truncatedPrefix() {
        #expect(!AVIOReader.bodyBeginsWithHLSPlaylistTag(bytes("#EXT")))
    }

    @Test("Empty body is not a playlist")
    func emptyBody() {
        #expect(!AVIOReader.bodyBeginsWithHLSPlaylistTag([]))
    }
}
