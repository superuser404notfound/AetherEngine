import Foundation
import Testing
import Libavcodec
@testable import AetherEngine

/// #142: a bare Epoch-Continue display set (PCS+WDS+END, palette and objects referenced from retained
/// decoder state, no PDS/ODS retransmit) must render from that retained state. Stock FFmpeg pgssubdec
/// flushes palettes and objects for ANY composition_state != Normal, including 0xC0 Epoch Continue,
/// so the bare set fails find_palette ("Invalid palette id 0") and is dropped whole; because PGS end
/// times are closed by the successor cue, the predecessor cue then overstays. FFmpegBuild carries a
/// pgssubdec patch that skips the flush for Epoch Continue only; Epoch Start and Acquisition Point
/// keep flushing (both are self-contained restatements by spec, the flush is safe there).
///
/// These tests drive the shipped Libavcodec pgssub decoder directly with synthetic display sets, the
/// same call path EmbeddedSubtitleDecoder uses.
struct Issue142PGSEpochContinueTests {

    // MARK: - Segment builders (layouts per pgssubdec.c parsers)

    /// A PGS segment run: each segment is [type:1][len:2 BE][body:len].
    private func segment(type: UInt8, body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// PCS (0x16): 1920x1080, one composition object referencing object 0 / palette 0 at (100,100).
    private func pcs(compositionState: UInt8) -> [UInt8] {
        segment(type: 0x16, body: [
            0x07, 0x80, 0x04, 0x38,             // width 1920, height 1080
            0x10,                               // frame rate (opaque to the decoder)
            0x00, 0x01,                         // composition number
            compositionState,
            0x00,                               // palette_update_flag
            0x00,                               // palette_id 0
            0x01,                               // one composition object
            0x00, 0x00,                         // object id 0
            0x00,                               // window id 0
            0x00,                               // composition flags (no crop, not forced)
            0x00, 0x64, 0x00, 0x64,             // x 100, y 100
        ])
    }

    /// WDS (0x17): one 8x8 window at (100,100). pgssubdec skips it; present for stream shape fidelity.
    private var wds: [UInt8] {
        segment(type: 0x17, body: [0x01, 0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0x08, 0x00, 0x08])
    }

    /// PDS (0x14): palette 0 with entry 0 transparent and entry 1 opaque white.
    private var pds: [UInt8] {
        segment(type: 0x14, body: [
            0x00, 0x00,                         // palette id 0, version 0
            0x00, 0x10, 0x80, 0x80, 0x00,       // entry 0: transparent
            0x01, 0xEB, 0x80, 0x80, 0xFF,       // entry 1: opaque white
        ])
    }

    /// ODS (0x15): object 0, single-segment (first+last), 8x8 bitmap of palette entry 1.
    /// RLE per line: 0x00 0x88 0x01 (run of 8, color 1) then 0x00 0x00 (end of line) = 5 bytes x 8 lines.
    private var ods: [UInt8] {
        let rle = Array(repeating: [0x00, 0x88, 0x01, 0x00, 0x00] as [UInt8], count: 8).flatMap { $0 }
        return segment(type: 0x15, body: [
            0x00, 0x00,                         // object id 0
            0x00,                               // version
            0xC0,                               // sequence: first and last
            0x00, 0x00, 0x2C,                   // rle length 44 (40 RLE + 4 dimension bytes)
            0x00, 0x08, 0x00, 0x08,             // width 8, height 8
        ] + rle)
    }

    private var end: [UInt8] { segment(type: 0x80, body: []) }

    /// The anchor: a self-contained Epoch Start display set (PCS+WDS+PDS+ODS+END).
    private var epochStartSet: [UInt8] { pcs(compositionState: 0x80) + wds + pds + ods + end }

    /// A bare follow-up set: PCS+WDS+END only, palette/objects expected from retained state.
    private func bareSet(compositionState: UInt8) -> [UInt8] { pcs(compositionState: compositionState) + wds + end }

    // MARK: - Decoder harness

    private func withPGSDecoder(_ body: (UnsafeMutablePointer<AVCodecContext>) -> Void) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE),
              let ctx = avcodec_alloc_context3(codec) else {
            Issue.record("pgssub decoder unavailable")
            return
        }
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            Issue.record("avcodec_open2 failed for pgssub")
            return
        }
        body(ctx)
        var freed: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&freed)
    }

    @discardableResult
    private func decode(_ ctx: UnsafeMutablePointer<AVCodecContext>, _ payload: [UInt8],
                        pts: Int64, into sub: inout AVSubtitle) -> Int32 {
        var got: Int32 = 0
        var bytes = payload
        bytes.withUnsafeMutableBufferPointer { buffer in
            var packet = AVPacket()
            packet.data = buffer.baseAddress
            packet.size = Int32(buffer.count)
            packet.pts = pts
            _ = avcodec_decode_subtitle2(ctx, &sub, &got, &packet)
        }
        return got
    }

    // MARK: - Tests

    @Test("a bare Epoch-Continue set renders from retained palette and objects")
    func bareEpochContinueRendersFromRetainedState() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            #expect(sub.num_rects == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0xC0), pts: 90_000, into: &continued)
            #expect(got == 1, "bare Epoch-Continue set was dropped (pgssubdec flushed retained state)")
            if got == 1 {
                #expect(continued.num_rects == 1)
                if continued.num_rects == 1, let rect = continued.rects?[0]?.pointee {
                    #expect(rect.w == 8)
                    #expect(rect.h == 8)
                    #expect(rect.x == 100)
                    #expect(rect.y == 100)
                }
                avsubtitle_free(&continued)
            }
        }
    }

    @Test("a bare Normal set already renders from retained state (fixture control)")
    func bareNormalSetControl() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0x00), pts: 90_000, into: &continued)
            #expect(got == 1, "bare Normal set failed; the synthetic fixture itself is broken")
            if got == 1 { avsubtitle_free(&continued) }
        }
    }

    @Test("a bare Epoch-Start set still flushes and drops (patch stays scoped to Epoch Continue)")
    func bareEpochStartStillFlushes() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0x80), pts: 90_000, into: &continued)
            #expect(got == 0, "a bare Epoch-Start set must not survive the epoch flush")
            if got == 1 { avsubtitle_free(&continued) }
        }
    }
}
