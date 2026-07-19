// Tests/AetherEngineTests/PacketRingBufferTests.swift
import XCTest
@testable import AetherEngine

final class PacketRingBufferTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbtest-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testAppendAndKeyframeSeek() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1]))
        try ring.append(pts: 2, isKeyframe: true,  isVideo: true, bytes: Data([2]))
        try ring.append(pts: 3, isKeyframe: false, isVideo: true, bytes: Data([3]))
        XCTAssertEqual(try ring.keyframePts(atOrBefore: 3.5), 2)
        XCTAssertEqual(try ring.packets(fromPts: 2).map(\.pts), [2, 3])
    }
    func testEvictsOutsideWindow() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        // edge 20, window 5 -> oldest retained must keep a keyframe at/below 15
        XCTAssertLessThanOrEqual(try XCTUnwrap(ring.oldestPts), 15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ring.oldestPts), 13)
    }
    func testReplayBytesRoundTrip() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([9, 8, 7]))
        XCTAssertEqual(try ring.packets(fromPts: 0).first?.bytes, Data([9, 8, 7]))
    }

    /// SW DVR reseed: host routes replay by `isVideo` (audio shares `isKeyframe == false`); verify flag + payload round-trip in order.
    func testReseedRoutingPreservesStreamKindInOrder() throws {
        let ring = try PacketRingBuffer(windowSeconds: 30, scratch: tmpDir())
        try ring.append(pts: 10.0, isKeyframe: true,  isVideo: true,  bytes: Data([1]))
        try ring.append(pts: 10.0, isKeyframe: false, isVideo: false, bytes: Data([2]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: true,  bytes: Data([3]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: false, bytes: Data([4]))
        try ring.append(pts: 10.2, isKeyframe: false, isVideo: true,  bytes: Data([5]))

        let kf = try XCTUnwrap(try ring.keyframePts(atOrBefore: 10.15))
        XCTAssertEqual(kf, 10.0)

        let replay = try ring.packets(fromPts: kf)
        XCTAssertEqual(replay.count, 5)
        XCTAssertEqual(replay.map(\.isVideo), [true, false, true, false, true])
        XCTAssertEqual(replay.map(\.isKeyframe), [true, false, false, false, false])
        XCTAssertEqual(replay.filter(\.isKeyframe).count, 1)
        XCTAssertTrue(replay.first?.isKeyframe == true && replay.first?.isVideo == true)
        XCTAssertEqual(replay.map { $0.bytes.first }, [1, 2, 3, 4, 5])
    }

    /// #136: close() clears the in-RAM index synchronously (ring immediately unusable) and is
    /// idempotent, so a second teardown from a racing thread is a no-op rather than a crash.
    func testCloseClearsStateSynchronouslyAndIsIdempotent() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1]))
        XCTAssertNotNil(ring.oldestPts)

        ring.close()
        XCTAssertNil(ring.oldestPts)
        XCTAssertNil(try ring.keyframePts(atOrBefore: .infinity))
        XCTAssertTrue(try ring.packets(fromPts: 0).isEmpty)
        XCTAssertEqual(ring.seqBounds.first, ring.seqBounds.end)

        ring.close()  // second teardown must be a harmless no-op
    }

    /// #136: scratch-directory removal is dispatched to a background queue so close() never blocks the
    /// caller; the directory (and every spooled packet file under it) is gone shortly after.
    func testCloseRemovesScratchDirectoryOffCaller() throws {
        let scratch = tmpDir()
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: scratch)
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: true, isVideo: true, bytes: Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))

        ring.close()

        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: scratch.path), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path),
                       "scratch dir should be removed by the background teardown")
    }

    /// Target predating the window: host clamps to `oldestPts`, which the ring guarantees is a keyframe.
    func testTargetBeforeWindowClampsToKeyframeOldest() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        let oldest = try XCTUnwrap(ring.oldestPts)
        XCTAssertNil(try ring.keyframePts(atOrBefore: -100))
        let firstAtOldest = try XCTUnwrap(try ring.packets(fromPts: oldest).first)
        XCTAssertTrue(firstAtOldest.isKeyframe)
    }
}
