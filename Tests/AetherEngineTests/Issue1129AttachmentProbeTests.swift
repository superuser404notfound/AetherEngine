import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// AE#1129: a Matroska font attachment under an RFC 8081 MIME type (`font/ttf`, `font/otf`, what
/// MKVToolNix writes by default) comes out of `matroskadec` as `AV_CODEC_ID_NONE`, which
/// `find_stream_info` treats as unresolved. An attachment never carries a packet, so the probe read
/// on to `max_analyze_duration`. The demuxer now names such attachments for the probe only.
///
/// Fixture: 75 s of 16x16 black H.264 at 2 fps with a silent 8 kHz PCM track (16 KB a second, so
/// the bytes the stream analysis reads say how far it went), one ASS track and two font attachments,
/// written by mkvmerge (attachments before the first Cluster), raw-deflated to 6 KB. Regenerate with:
///
///     ffmpeg -f lavfi -i color=c=black:s=16x16:r=2:d=75 -f lavfi -i anullsrc=r=8000:cl=mono -t 75 \
///       -c:v libx264 -preset ultrafast -crf 51 -g 50 -pix_fmt yuv420p \
///       -bsf:v filter_units=remove_types=6 -c:a pcm_s16le va.mkv
///     printf '1\n00:00:00,000 --> 00:00:01,000\nline\n' > s.srt && ffmpeg -i s.srt s.ass
///     printf 'AE1129-FONT-A' > a.ttf && printf 'AE1129-FONT-B-OTF' > b.otf
///     mkvmerge --no-date --disable-track-statistics-tags -o fonts.mkv va.mkv s.ass \
///       --attachment-mime-type font/ttf --attach-file a.ttf \
///       --attachment-mime-type font/otf --attach-file b.otf
///     python3 -c "import zlib,base64;c=zlib.compressobj(9,8,-15);d=open('fonts.mkv','rb').read();\
///       print(base64.b64encode(c.compress(d)+c.flush()).decode())"
///
/// Stream layout: 0 = h264 video, 1 = pcm_s16le, 2 = ass, 3 = a.ttf, 4 = b.otf.
@Suite(.timeLimit(.minutes(3)))
struct Issue1129AttachmentProbeTests {

    static func fixture() throws -> Data {
        guard let packed = Data(base64Encoded: base64.joined()) else { throw CocoaError(.fileReadCorruptFile) }
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    /// Opens the fixture from a file, so it goes through `AVIOReader` and the probe report counts the
    /// bytes the stream analysis read.
    private func open(_ profile: DemuxerOpenProfile = .playback) throws -> (Demuxer, URL, Int) {
        let data = try Self.fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ae1129-\(UUID().uuidString).mkv")
        try data.write(to: url)
        let demuxer = Demuxer()
        do {
            try demuxer.open(url: url, profile: profile)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return (demuxer, url, data.count)
    }

    /// Without the park the analysis reads its 60 s window: 983 KB of this 1.2 MB file, against
    /// 393 KB with it.
    @Test func theProbeStopsOnceTheTracksAreKnown() throws {
        let (demuxer, url, size) = try open()
        defer { demuxer.close(); try? FileManager.default.removeItem(at: url) }
        #expect(demuxer.unnamedAttachmentsParked == 2)
        #expect(demuxer.probeReport?.attachmentsParked == 2)
        #expect(demuxer.probeReport?.logFields.hasSuffix("attachmentsParked=2") == true)
        let read = try #require(demuxer.probeReport?.probeBytes)
        #expect(read < Int64(size) / 2, "the stream analysis read \(read) of \(size) bytes")
    }

    @Test func theAttachmentsComeBackUnnamedWithTheirFonts() throws {
        let (demuxer, url, _) = try open()
        defer { demuxer.close(); try? FileManager.default.removeItem(at: url) }
        for index: Int32 in [3, 4] {
            let codecpar = try #require(demuxer.stream(at: index)?.pointee.codecpar)
            #expect(codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT)
            #expect(codecpar.pointee.codec_id == AV_CODEC_ID_NONE)
        }
        let fonts = demuxer.fontAttachmentInfos()
        #expect(fonts.map(\.filename) == ["a.ttf", "b.otf"])
        #expect(fonts.map(\.data) == [Data("AE1129-FONT-A".utf8), Data("AE1129-FONT-B-OTF".utf8)])
        #expect(demuxer.stream(at: 0)?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO)
        #expect(demuxer.stream(at: 1)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_PCM_S16LE)
        #expect(demuxer.stream(at: 2)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_ASS)
    }

    @Test func anOpenWithoutAttachmentsParksNothing() throws {
        let (demuxer, url, _) = try open(.playback.skippingAttachments())
        defer { demuxer.close(); try? FileManager.default.removeItem(at: url) }
        #expect(demuxer.unnamedAttachmentsParked == 0)
        #expect(demuxer.stream(at: 3) == nil)
    }

    @Test func onlyAnUnnamedAttachmentIsParked() {
        #expect(Demuxer.attachmentNeedsNoProbe(codecID: AV_CODEC_ID_NONE, codecType: AVMEDIA_TYPE_ATTACHMENT))
        #expect(!Demuxer.attachmentNeedsNoProbe(codecID: AV_CODEC_ID_TTF, codecType: AVMEDIA_TYPE_ATTACHMENT))
        #expect(!Demuxer.attachmentNeedsNoProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecType: AVMEDIA_TYPE_ATTACHMENT))
        #expect(!Demuxer.attachmentNeedsNoProbe(codecID: AV_CODEC_ID_NONE, codecType: AVMEDIA_TYPE_AUDIO))
        #expect(!Demuxer.attachmentNeedsNoProbe(codecID: AV_CODEC_ID_NONE, codecType: AVMEDIA_TYPE_UNKNOWN))
    }

    static let base64 = [
        "7d1djJzXYR7gGW4Od7k/2D+7UBm1HDqGrdY0/8IqisyL/bgkI6GSlhUpV0rUeFfkimJEkSq5q0ipL/YsNzYj64PtSHHcGRXY+oiI",
        "igqCXLuMHCHoAHZQX9iFXaBRGxjoBrmg0OYibg24V23n8JMU9abonYvD55HofWc8O979SMiYd8+82nnsP6d05HOxfeSng1//Lf7c",
        "kf8eR46sX31qaeXSxctPLh35/OCu347bbju5drbdGpj5ra9M399b+f79b71w8l9ufPjef/H4ydfWp4aam3/j1OtP5pvP3f9WPbh5",
        "+8m3BjevzDx3trk9c+rbZ2/e/lbz8L9ZvXJu8PDbHvnLhddbAAAAwP9n8uv+H//dt79+ZfLI3P1r6fy5x5Yfe+p855kDew/t/aXO",
        "JzqDO95rEPKdv7T34D+s/uCpJ595avnS2eXBPft/ce/+zh0fP/XEcufo0qUnLyxfvvzxv9O589AnHzu3cvR3Nn7ldz/buvzKl+75",
        "1U/94Oy//83/8NCf/afp4ZGpH+Z6Yf4fvD535e3YvvwnV9/89a8cWTzx4oeuxPbV2Ho5tj7yr1++snrhzOe++OnP3H/i2K8c2nfv",
        "yYV91afnT3/tWvtIf/R//Xnrw2cHH//sn7SnWq2h1s3/mPvxR36j3QpP/Lv273d+4S+ubPyt7y8Pnuef5efZ6r0Rp/4oTp16Y2Pw",
        "LU+d+qObHx56Y+Ohb8X26//m7bht8EW88MM3hn/+j7++80rcdvWvv4K6+syJ+fv33fvAqX333XsqP++2x371vef9843HzsSp1498",
        "/u04NHiGb/3jj/zCSw/+1396JU5/4Ht4/uRnTh17+NS+6uTJ01878tCvnTx96dzTK517Lzx+8R9NjH6q8+7ts8sXli8trSyf6Tz2",
        "XOf48aeeXj67776lZ07feXDvwbv2Hth/YGK0eeSp555evrvzzKG9+/d/YmL0xPml5x5cvvzw3Z1fvOvQ+zcfubtz8K678mcsnV8+",
        "c+TipTPLl6oLZ04+sXTm4m/e3Xlu+fLE6CPzj81f6tw/+M099+zdnQcuXlieGJ0Y/bVPH/pE5+TKc+eXLw++uuMXLw1+9wf/7dJT",
        "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",
        "AAAAFC33gJPWAwEAAACgaKmOkydyCFVvrTkeOGVMEAAAAACKluo4fTSHUPU2m1pw2pggAAAAABQtLYT1mf5GcCUAAAC4JV4H13H2",
        "rhxC1evPXts1f3119+GdN9b/52I+KdOyqwUAAAAARcs9YNuQFgAAAAAULdWx/dkcQtXbaoa0thnSAgAAAICipToOPZ1DqLqtphYc",
        "6qsFAQAAAKBkuQcM1gMBAAAAoGipjuFMDqHqdprjgduNCQIAAABA0VIdhx/OIVTduaYWHDYmCAAAAABFyz3giPVAAAAAAChaquOO",
        "+3IIVXexOR44akwQAAAAAIqW6jg2l0OoumtNLThmTBAAAAAAipZ7wHHrgQAAAABQtFTHiUM5hKq72RwPnDAmCAAAAABFyz3gpPVA",
        "AAAAAChaquPkHTmEqttvjgdOWQ8EAAAAgKKlOk7fnkOoultNLThtTBAAAAAAipYWwvpMfyO4EgAAANwSr4PrODuVQ6h6rdlru+av",
        "r+7e94UbV9ozU/moTMuwFgAAAAAULfeAbUtaAAAAAFC0VMf2qRxC1es0S1rbLGkBAAAAQNFSHYfuySFUvbmmFhzqqwUBAAAAoGS5",
        "BwzWAwEAAACgaKmO4XAOoeotNscDtxsTBAAAAICipToO788hVL21phYcNiYIAAAAAEXLPeCI9UAAAAAAKFqq446P5hCq3mZzPHDU",
        "mCAAAAAAFC3Vcey2HELV6ze14JgxQQAAAAAoWu4Bx60HAgAAAEDRUh0nxnMIVW+rOR44YUwQAAAAAIqW6jh5M4Sq22pqwUljggAA",
        "AABQtNwDTlkPBAAAAICipTpO/SSHUHU7zfHAaWOCAAAAAFC0dGRjfaa/5kLws3T7ybee/P5bX/xGbP3h8z+N7R+v3/Zv/yoOvfVS",
        "vuOLP41DN+9Y/9Df/lfrQ++89eVvrC+9+odfyI+7sv2XZ/4q/ly+69sn3r1r/JHDg7tmTn377Nzbly9vnu6vnf1u91j6/LEH5heO",
        "Hnvw6Ofr+5aeefzOg3sPDP7ef+Dy5T893f/C6T+5+uavf+XI4okXP3T2u1/74KN/b/Do04NHH7wrP7pz/txjzx6889DZ724eS1eP",
        "PvRgderehQeOfv539++/e/+Buw/8vb3733P58n9snviFH74x/PN//PWdZ7/7ygef+Pf/zyd++vRTn7l84M7zy/8PT/2/AQ==",
    ]
}
