import XCTest
import Testing
import Synchronization
@testable import AetherEngine

final class ByteFIFOTests: XCTestCase {

    func testWriteThenReadRoundTrip() {
        let fifo = ByteFIFO(capacity: 1024)
        XCTAssertTrue(fifo.write(Data([1, 2, 3, 4])))
        var buffer = [UInt8](repeating: 0, count: 8)
        let n = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 8)
        }
        XCTAssertEqual(n, 4)
        XCTAssertEqual(Array(buffer[0..<4]), [1, 2, 3, 4])
    }

    func testReadBlocksUntilWrite() {
        let fifo = ByteFIFO(capacity: 1024)
        let expectation = expectation(description: "read returned")
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4)
            let n = buffer.withUnsafeMutableBufferPointer {
                fifo.read(into: $0.baseAddress!, maxLength: 4)
            }
            XCTAssertEqual(n, 2)
            expectation.fulfill()
        }
        while fifo.parkedWaiterCount == 0 { usleep(200) }  // the park, not a guess at it
        XCTAssertTrue(fifo.write(Data([9, 9])))
        wait(for: [expectation], timeout: 300)
    }

    func testFinishDrainsThenSignalsEOF() {
        let fifo = ByteFIFO(capacity: 1024)
        _ = fifo.write(Data([7]))
        fifo.finish()
        var buffer = [UInt8](repeating: 0, count: 4)
        let first = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        XCTAssertEqual(first, 1)
        let second = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        XCTAssertEqual(second, 0, "EOF after drain")
    }

    func testCancelUnblocksReaderWithError() {
        let fifo = ByteFIFO(capacity: 1024)
        let expectation = expectation(description: "read returned")
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4)
            let n = buffer.withUnsafeMutableBufferPointer {
                fifo.read(into: $0.baseAddress!, maxLength: 4)
            }
            XCTAssertEqual(n, -1, "cancel surfaces as read error")
            expectation.fulfill()
        }
        while fifo.parkedWaiterCount == 0 { usleep(200) }  // the park, not a guess at it
        fifo.cancel()
        wait(for: [expectation], timeout: 300)
    }

    // audit NET-8: storage moved from one re-based `Data` to a queue of chunks plus a head offset;
    // these pin that a read still spans chunk boundaries and resumes mid-chunk correctly.
    func testReadSpansMultipleWrites() {
        let fifo = ByteFIFO(capacity: 1024)
        XCTAssertTrue(fifo.write(Data([1, 2])))
        XCTAssertTrue(fifo.write(Data([3, 4, 5])))
        var buffer = [UInt8](repeating: 0, count: 10)
        let n = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 10)
        }
        XCTAssertEqual(n, 5)
        XCTAssertEqual(Array(buffer[0..<5]), [1, 2, 3, 4, 5])
    }

    func testPartialReadResumesMidChunk() {
        let fifo = ByteFIFO(capacity: 1024)
        XCTAssertTrue(fifo.write(Data([1, 2, 3, 4, 5, 6])))
        var first = [UInt8](repeating: 0, count: 3)
        let n1 = first.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 3)
        }
        XCTAssertEqual(n1, 3)
        XCTAssertEqual(Array(first[0..<3]), [1, 2, 3])
        var second = [UInt8](repeating: 0, count: 3)
        let n2 = second.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 3)
        }
        XCTAssertEqual(n2, 3)
        XCTAssertEqual(Array(second[0..<3]), [4, 5, 6])
    }

    func testWriteBlocksAtCapacityUntilRead() {
        let fifo = ByteFIFO(capacity: 4)
        XCTAssertTrue(fifo.write(Data([1, 2, 3, 4])))
        let expectation = expectation(description: "second write returned")
        Thread.detachNewThread {
            XCTAssertTrue(fifo.write(Data([5, 6])))
            expectation.fulfill()
        }
        while fifo.parkedWaiterCount == 0 { usleep(200) }  // the park, not a guess at it
        var buffer = [UInt8](repeating: 0, count: 4)
        _ = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        wait(for: [expectation], timeout: 300)
    }
}

// Empty writes must not masquerade as the EOF that the ingest reader returns to FFmpeg.
// Run potentially blocking calls on real threads so cancellation can still release them.
@Suite(.timeLimit(.minutes(3)))
struct ByteFIFOEmptyOperationsTests {
    @Test("an empty write leaves a reader waiting for bytes")
    func emptyWriteDoesNotSignalEOF() async throws {
        let fifo = ByteFIFO(capacity: 4)
        defer { fifo.cancel() }
        #expect(fifo.write(Data()))
        let result = Mutex<Int?>(nil)
        Thread.detachNewThread {
            var byte: UInt8 = 0
            let count = fifo.read(into: &byte, maxLength: 1)
            result.withLock { $0 = count }
        }
        try await waitFor { result.withLock { $0 != nil } || fifo.parkedWaiterCount > 0 }
        #expect(result.withLock { $0 == nil }, "an empty write must not return zero (EOF)")
        #expect(fifo.isEmptyWithReaderParked)
        #expect(fifo.write(Data([42])))
        try await waitFor { result.withLock { $0 != nil } }
        #expect(result.withLock { $0 == 1 })
    }

    @Test("an empty write completes even when capacity is occupied")
    func emptyWriteDoesNotWaitForCapacity() async throws {
        let fifo = ByteFIFO(capacity: 1)
        defer { fifo.cancel() }
        #expect(fifo.write(Data([42])))
        let result = Mutex<Bool?>(nil)
        Thread.detachNewThread {
            let accepted = fifo.write(Data())
            result.withLock { $0 = accepted }
        }
        try await waitFor { fifo.parkedWaiterCount > 0 || result.withLock { $0 != nil } }
        #expect(fifo.parkedWaiterCount == 0)
        fifo.cancel()
        try await waitFor { result.withLock { $0 != nil } }
        #expect(result.withLock { $0 == true })
    }

    @Test("empty writes still reject a finished or cancelled FIFO")
    func emptyWriteHonorsTerminalState() {
        let finished = ByteFIFO(capacity: 1)
        finished.finish()
        #expect(!finished.write(Data()))
        let cancelled = ByteFIFO(capacity: 1)
        cancelled.cancel()
        #expect(!cancelled.write(Data()))
    }

    @Test("a nonpositive read length is an error and preserves queued bytes", arguments: [0, -1, Int.min])
    func invalidLengthPreservesBytes(length: Int) {
        let fifo = ByteFIFO(capacity: 1)
        #expect(fifo.write(Data([42])))
        var byte: UInt8 = 99
        #expect(fifo.read(into: &byte, maxLength: length) == -1)
        #expect(byte == 99)
        #expect(fifo.read(into: &byte, maxLength: 1) == 1)
        #expect(byte == 42)
    }
}
