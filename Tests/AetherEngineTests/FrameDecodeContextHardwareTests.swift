import Foundation
import Testing
@testable import AetherEngine

/// Cache-backed stills are the one extraction path allowed to ask for VideoToolbox: native
/// playback is already on the hardware path, so issue #27's software-playback starvation does
/// not apply. A codec VideoToolbox declines must remain a successful software still, not a miss.
struct FrameDecodeContextHardwareTests {

    @Test("hardware-allowed still falls back for an MPEG-4 Part 2 fixture")
    func declinedCodecStillDecodes() throws {
        let data = try #require(Data(
            base64Encoded: Self.mpeg4FixtureBase64,
            options: .ignoreUnknownCharacters))
        let context = FrameDecodeContext(
            reader: DataIOReader(data: data),
            formatHint: "mp4",
            allowsHardwareDecode: true)
        defer { context.close() }

        try context.ensureOpen()
        let image = context.decodeFrame(
            at: 0,
            mode: .thumbnail,
            targetWidth: 64,
            maxSize: nil,
            isCancelled: { false })

        #expect(image != nil)
        #expect(context.hardwareDecoderName == "none")
    }

    /// One 64x64 MPEG-4 Part 2 frame. VideoToolbox does not offer that legacy codec, while
    /// FFmpeg's software decoder does; this is the deterministic decline/fallback witness.
    /// Regenerate with:
    /// `ffmpeg -f lavfi -i color=c=red:s=64x64:r=1:d=1 -c:v mpeg4 -q:v 5 -pix_fmt yuv420p -movflags +faststart vt-decline.mp4`
    private static let mpeg4FixtureBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA0Ftb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAA
        AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC
        AAACa3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA
        AAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAeNtZGlh
        AAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAABAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFu
        ZGxlcgAAAAGObWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAB
        TnN0YmwAAADqc3RzZAAAAAAAAAABAAAA2m1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAET
        TGF2YzYyLjI4LjEwMCBtcGVnNAAAAAAAAAAAAAAAAAAY//8AAABgZXNkcwAAAAADgICATwABAASAgIBBIBEAAAAAAw1AAAAC
        qAWAgIAvAAABsAEAAAG1iRMAAAEAAAABIADEjYgADQIECBRDAAABskxhdmM2Mi4yOC4xMDAGgICAAQIAAAAQcGFzcAAAAAEA
        AAABAAAAFGJ0cnQAAAAAAAMNQAAAAqgAAAAYc3R0cwAAAAAAAAABAAAAAQAAQAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAEA
        AAABAAAAFHN0c3oAAAAAAAAAVQAAAAEAAAAUc3RjbwAAAAAAAAABAAADbQAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIA
        AAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAwAAAA
        CGZyZWUAAABdbWRhdAAAAbMAEAcAAAG2FgsYWm2C6Bxxtt/G238bbfsAAKFRhabYLoHHG238bbfxtt+/AADBUYWm2C6Bxxtt
        /G238bbfvwAA4VGFptgugccbbfxtt/G2378=
        """
}
