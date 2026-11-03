import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Audit DMX-108: the NAT-7 fix made `stream(at:)` safe against MPEG-TS reallocating `streams`
/// inside `av_read_frame`, and left two holes. The sibling track accessors still walked the live
/// array without the lock, and `close()` freed the streams before it emptied the table, so a caller
/// on another thread could hold a raw `AVStream*` across a live reopen's `close()`.
@Suite("Demuxer stream lifetime and track accessors", .serialized)
struct DemuxerStreamLifetimeTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _index: Int32?
        var index: Int32? { lock.withLock { _index } }
        func set(_ index: Int32) { lock.withLock { _index = index } }
    }

    private final class Tracks: @unchecked Sendable {
        private let lock = NSLock()
        private var _video: Int32?
        private var _subtitles: [Int32]?
        private var _indices: Set<Int32>?
        var video: Int32? { lock.withLock { _video } }
        var subtitles: [Int32]? { lock.withLock { _subtitles } }
        var indices: Set<Int32>? { lock.withLock { _indices } }
        func set(video: Int32, subtitles: [Int32], indices: Set<Int32>) {
            lock.withLock { _video = video; _subtitles = subtitles; _indices = indices }
        }
    }

    @Test("close waits for a caller inside withStream and hands out no stream once it has started",
          .timeLimit(.minutes(3)))
    func closeWaitsForStreamUsers() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)

        let entered = Flag()
        let closed = Flag()
        let seenInsideTheBody = Seen()
        let release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = demuxer.withStream(at: MultiSubtitleContainerFixture.videoStreamIndex) { stream in
                entered.set()
                release.wait()
                seenInsideTheBody.set(stream.pointee.index)
            }
        }
        try await waitFor { entered.value }

        Thread.detachNewThread {
            demuxer.close()
            closed.set()
        }
        // The table is emptied before the streams are freed: nothing new gets a stream from here.
        try await waitFor { demuxer.stream(at: MultiSubtitleContainerFixture.videoStreamIndex) == nil }
        #expect(demuxer.withStream(at: MultiSubtitleContainerFixture.videoStreamIndex) { _ in true } == nil,
                "a stream was handed out after close() had started")

        let closedUnderTheCaller = try await waitFor(upTo: .milliseconds(300)) { closed.value }
        #expect(!closedUnderTheCaller, "close() freed the streams while a caller was still inside withStream")

        release.signal()
        try await waitFor { closed.value }
        #expect(seenInsideTheBody.index == MultiSubtitleContainerFixture.videoStreamIndex)
    }

    @Test("withStream hands out nothing for an index the demuxer does not have")
    func withStreamRejectsUnknownIndices() throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url)

        #expect(demuxer.withStream(at: -1) { _ in true } == nil)
        #expect(demuxer.withStream(at: 99) { _ in true } == nil)
        #expect(demuxer.withStream(at: MultiSubtitleContainerFixture.spanishStreamIndex) {
            $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        } == true)
    }

    @Test("the track accessors answer from their snapshot while a read holds the demuxer",
          .timeLimit(.minutes(3)))
    func accessorsDoNotWaitOutARead() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: url)

        // `isCurrent` runs inside `readPacket` with the access lock held, which is the state a read
        // parked on a slow origin leaves the lock in.
        let holding = Flag()
        let readReleased = DispatchSemaphore(value: 0)
        let readFinished = Flag()
        Thread.detachNewThread {
            _ = try? demuxer.readPacket(isCurrent: {
                holding.set()
                readReleased.wait()
                return true
            })
            readFinished.set()
        }
        try await waitFor { holding.value }

        let answered = Tracks()
        let done = Flag()
        Thread.detachNewThread {
            answered.set(video: demuxer.videoStreamIndex,
                         subtitles: demuxer.subtitleTrackInfos().map { Int32($0.id) },
                         indices: demuxer.subtitleStreamIndices())
            done.set()
        }
        // An accessor that waits out the read never answers before the release; the time limit reports that.
        try await waitFor { done.value }
        readReleased.signal()
        try await waitFor { readFinished.value }

        #expect(answered.video == MultiSubtitleContainerFixture.videoStreamIndex)
        #expect(answered.subtitles == [MultiSubtitleContainerFixture.englishStreamIndex,
                                       MultiSubtitleContainerFixture.spanishStreamIndex])
        #expect(answered.indices == [MultiSubtitleContainerFixture.englishStreamIndex,
                                     MultiSubtitleContainerFixture.spanishStreamIndex])
    }
}
