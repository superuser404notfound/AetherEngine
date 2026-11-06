import Foundation
import Testing
@testable import AetherEngine

/// `close()` cancels the producer, but a fetch its segment batch has not reached yet still asks the
/// session for a task. On an invalidated session that raises an Objective-C exception, which aborts
/// the process instead of throwing (CI, 2026-11-06: `-[__NSURLSessionLocal taskForClassInfo:]` under
/// `HLSVODIngestReader.ingestSegmentBatch`). So a closed reader's own session must still hand out
/// tasks; it is invalidated when the reader goes away.
@Suite("A closed VOD ingest reader's session still hands out tasks")
struct HLSVODIngestCloseSessionTests {

    @Test("a task created after close is an ordinary, cancellable task")
    func taskAfterCloseDoesNotRaise() throws {
        let reader = HLSVODIngestReader(
            playlistURL: URL(string: "http://127.0.0.1:9/media.m3u8")!, httpHeaders: [:])
        reader.close()
        let task = reader.session.dataTask(with: URL(string: "http://127.0.0.1:9/seg0.ts")!)
        task.cancel()
        #expect(task.state == .canceling || task.state == .completed)
    }
}

extension HLSVODIngestCloseSessionTests {
    /// The session is invalidated in deinit, so nothing on it may keep the reader alive.
    @Test("a closed reader is released, so deinit gets to invalidate its session")
    func closedReaderIsReleased() {
        weak var weakReader: HLSVODIngestReader?
        do {
            let reader = HLSVODIngestReader(
                playlistURL: URL(string: "http://127.0.0.1:9/media.m3u8")!, httpHeaders: [:])
            weakReader = reader
            reader.close()
        }
        #expect(weakReader == nil)
    }
}
