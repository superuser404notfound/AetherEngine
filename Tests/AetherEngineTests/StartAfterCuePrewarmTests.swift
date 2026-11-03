import Testing
import Foundation
@testable import AetherEngine

/// Playback's first read past the retained head, after the cue prewarm moved the streaming
/// connection to the middle of the file, went to a 4 MB detour block. On an origin that grants one
/// request (TorBox), the block waited its whole 4 s budget for a slot the held connection was using,
/// then the rescue reconnect anchored at the same place. Field trace (Kitchen, 1080p MKV): seg0 4 s
/// late, first frame 11.0 s instead of ~5 s. The cursor reset after the index pass is a playback
/// reposition, so the first miss anchors the connection there, as a producer restart's does (AE#782).
@Suite("Playback's first read after the cue prewarm anchors, not detours", .offCooperativePool)
struct StartAfterCuePrewarmTests {

    private static let chunk = 256 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, detourFetchBudget: 30)
    }

    private func readForward(_ reader: AVIOReader, _ buf: UnsafeMutablePointer<UInt8>, bytes: Int, from offset: Int64) -> Bool {
        var read = 0
        while read < bytes {
            let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
            if n <= 0 { return false }
            if !(0..<n).allSatisfy({ buf[$0] == ThrottledOriginServer.patternByte(at: offset + Int64(read + $0)) }) {
                return false
            }
            read += n
        }
        return true
    }

    /// The engine's start sequence: open, index pass (seek to the middle, read, seek back to 0),
    /// then playback reads forward from 0 through the head and past it.
    private func startSequence(notePlayback: Bool) throws -> (ThrottledOriginServer, AVIOReader, Bool) {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        let reader = makeReader(server)
        try reader.open()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        // The parse reads the head during the open phase.
        _ = reader.read(into: buf, size: Int32(Self.chunk))
        reader.markOpenPhaseFinished()

        reader.beginIndexPass()
        let middle: Int64 = 32 * 1024 * 1024
        _ = reader.seek(offset: middle, whence: Int32(SEEK_SET))
        _ = reader.read(into: buf, size: Int32(Self.chunk))
        _ = reader.seek(offset: 0, whence: Int32(SEEK_SET))
        reader.endIndexPass()
        if notePlayback { reader.notePlaybackRepositioned() }

        let ok = readForward(reader, buf, bytes: 3 * 1024 * 1024, from: 0)
        return (server, reader, ok)
    }

    @Test("after the reposition note, the first miss past the head opens the connection there",
          .timeLimit(.minutes(2)))
    func firstMissAnchors() throws {
        let (server, reader, ok) = try startSequence(notePlayback: true)
        defer { reader.markClosed(); reader.close(); server.stop() }
        #expect(ok, "playback read the wrong bytes")
        #expect(reader.detourResidentBlocksForTesting == 0,
                "playback's first miss was served as a detour block: \(server.requestedRanges.map(\.start))")
        #expect(server.requestedRanges.contains { $0.start > 0 && $0.start < 2 * 1024 * 1024 && ($0.end ?? Int64.max) - $0.start + 1 > 4 * 1024 * 1024 },
                "no streaming connection was anchored near the head: \(server.requestedRanges.map { ($0.start, $0.end as Any) })")
    }

    @Test("without the note the same start detours, which is the 4 s the field trace paid",
          .timeLimit(.minutes(2)))
    func withoutNoteDetours() throws {
        let (server, reader, ok) = try startSequence(notePlayback: false)
        defer { reader.markClosed(); reader.close(); server.stop() }
        #expect(ok)
        #expect(reader.detourResidentBlocksForTesting >= 1)
    }

    @Test("the engine's start sequence notes the reposition after the cursor reset")
    func engineNotesReposition() throws {
        // The fix is the call in HLSVideoEngine's step 6; keep it from being dropped silently.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/Video/HLSVideoEngine.swift"), encoding: .utf8)
        let step6 = try #require(source.range(of: "dem.endIndexPass()      // AE#585"))
        let after = source[step6.upperBound...].prefix(900)
        #expect(after.contains("dem.notePlaybackRepositioned()"),
                "step 6 resets the cursor to 0 without telling the reader playback starts there")
    }
}
