import Testing
import Foundation
@testable import AetherEngine

/// AE#187 follow-up: a fragmented `empty_moov` init carries no samples in the `moov`, so a zero-sample
/// `sdtp` (per-sample dependency flags) in the video `stbl` is meaningless. Apple TV's HEVC hardware track
/// builder validates it against the empty sample table and drops the video track (item tracks audio-only,
/// -11829 / -12848) while macOS/Simulator ignore the stray box; FFmpeg's own fragmented init omits it. The
/// pinned FFmpegBuild (n8.1.2) never writes it, but a consumer that links an older FFmpeg the wrong way does
/// (a `-force_load`ed 7.1.5 shadowing the vendored build). These cover the pure guard that removes such a box
/// and reconciles every ancestor's size field.
@Suite("HEVC init sdtp strip")
struct HEVCInitSdtpStripTests {

    static func be(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }
    /// hdlr fullbox whose handler_type (payload offset 8) is `vide`, which is how the strip picks the video track.
    static func videoHdlr() -> [UInt8] {
        box("hdlr", be(0) + be(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 12))
    }
    static let emptyStts = { box("stts", be(0) + be(0)) }()
    static let emptyStsc = { box("stsc", be(0) + be(0)) }()

    /// Build a minimal `ftyp + moov>trak>mdia(hdlr vide)>minf>stbl` init; `sdtp` is one of the stbl children
    /// (between stts and stsc, movenc's position) only when `sdtpPayload` is non-nil.
    static func synthInit(sdtpPayload: [UInt8]?) -> [UInt8] {
        var stblChildren = emptyStts
        if let p = sdtpPayload { stblChildren += box("sdtp", p) }
        stblChildren += emptyStsc
        let stbl = box("stbl", stblChildren)
        let minf = box("minf", stbl)
        let mdia = box("mdia", videoHdlr() + minf)
        let trak = box("trak", box("tkhd", [UInt8](repeating: 0, count: 84)) + mdia)
        let moov = box("moov", trak)
        let ftyp = box("ftyp", Array("iso5".utf8) + be(0))
        return ftyp + moov
    }

    static func firstIndex(of ascii: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(ascii.utf8)
        guard bytes.count >= needle.count else { return nil }
        for i in 0...(bytes.count - needle.count) where Array(bytes[i..<i+needle.count]) == needle { return i }
        return nil
    }

    @Test("Removes a zero-sample video sdtp and reproduces the sdtp-free init byte for byte")
    func stripsEmptySdtp() {
        let withSdtp = Self.synthInit(sdtpPayload: Self.be(0))       // sdtp = 0000000c 73647470 00000000
        let withoutSdtp = Self.synthInit(sdtpPayload: nil)
        #expect(withSdtp.count == withoutSdtp.count + 12)
        guard let stripped = HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: withSdtp) else {
            Issue.record("expected the empty sdtp to be stripped")
            return
        }
        // Byte-exact equality proves both the box removal and every ancestor size fixup (stbl/minf/mdia/trak/moov).
        #expect(stripped == withoutSdtp)
        #expect(Self.firstIndex(of: "sdtp", in: stripped) == nil)
    }

    @Test("No sdtp present is a no-op (nil, init forwarded unchanged)")
    func noSdtpIsNoOp() {
        #expect(HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: Self.synthInit(sdtpPayload: nil)) == nil)
    }

    @Test("An sdtp that actually describes samples (non-fragmented) is preserved")
    func nonEmptySdtpPreserved() {
        // Two per-sample dependency bytes -> box size 14, not the zero-sample size 12: must not be stripped.
        let withSampled = Self.synthInit(sdtpPayload: Self.be(0) + [0x00, 0x00])
        #expect(HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: withSampled) == nil)
    }

    @Test("A sdtp in an audio-only track is left alone (video-track scoped)")
    func audioTrackSdtpUntouched() {
        // moov with a single sound-handler trak carrying a zero-sample sdtp: the strip targets vide only.
        let stbl = Self.box("stbl", Self.emptyStts + Self.box("sdtp", Self.be(0)) + Self.emptyStsc)
        let minf = Self.box("minf", stbl)
        let soundHdlr = Self.box("hdlr", Self.be(0) + Self.be(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 12))
        let mdia = Self.box("mdia", soundHdlr + minf)
        let trak = Self.box("trak", mdia)
        let moov = Self.box("moov", trak)
        #expect(HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: moov) == nil)
    }

    @Test("Non-mp4 / truncated input is forwarded unchanged (nil)")
    func garbageInput() {
        #expect(HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: [0, 1, 2, 3, 4]) == nil)
        #expect(HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: []) == nil)
    }
}
