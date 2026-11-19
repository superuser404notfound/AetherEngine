import Foundation
@testable import AetherEngine

/// Eight frames of 10-bit AV1 with film grain, 128x64 at 24 fps in Matroska (4.7 KB): a decode of it
/// takes the GPU conversion route (`GPUFrameConverter`) with grain on every frame.
///
/// Made with ffmpeg and SVT-AV1 4.2.0 from a noisy test pattern, nothing of any real media:
/// `ffmpeg -f lavfi -i "testsrc2=size=128x64:rate=24,noise=alls=60:allf=t+u" -frames:v 8
/// -pix_fmt yuv420p10le -c:v libsvtav1 -preset 10 -crf 55 -svtav1-params
/// "film-grain=12:film-grain-denoise=0" -g 8 -f matroska -map_metadata -1 -fflags +bitexact
/// -flags:v +bitexact grain.mkv`
enum AV1FilmGrainClipFixture {
    static let frameCount = 8

    private static let mkv = """
        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
        """

    /// The clip written to a temporary file; the caller removes it.
    static func write() throws -> URL {
        guard let data = Data(base64Encoded: mkv, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("av1-film-grain-\(UUID().uuidString).mkv")
        try data.write(to: url)
        return url
    }
}
