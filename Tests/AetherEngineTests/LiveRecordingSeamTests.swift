import Testing
import Foundation
@testable import AetherEngine

/// The seam between the engine and the two engine-owned live routes (AE#560).
///
/// It gets its own tests because it is the contract `HLSSegmentProducer` and `SoftwarePlaybackHost`
/// both implement, and a mistake in it is discovered late and expensively: the route conformances
/// are only exercisable against a real live origin.
@Suite("Live recording seam")
struct LiveRecordingSeamTests {

    private final class SpySink: LiveRecordingSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _indices: [Int32] = []
        var indices: [Int32] { lock.lock(); defer { lock.unlock() }; return _indices }

        func accept(packetBytes: UnsafeRawBufferPointer,
                    sourceStreamIndex: Int32,
                    pts: Int64, dts: Int64, duration: Int64,
                    isKeyframe: Bool) {
            lock.lock(); _indices.append(sourceStreamIndex); lock.unlock()
        }
    }

    @Test("a descriptor carries the source stream index and its time base")
    func descriptorCarriesIdentity() {
        let d = RecordingStreamDescriptor(sourceStreamIndex: 1,
                                          timeBaseNum: 1, timeBaseDen: 90000,
                                          codecParameters: nil, isVideo: true)
        #expect(d.sourceStreamIndex == 1)
        #expect(d.timeBaseNum == 1)
        #expect(d.timeBaseDen == 90000)
    }

    @Test("a sink receives the source stream index it was handed")
    func sinkReceivesIndex() {
        let sink = SpySink()
        var byte: UInt8 = 0x47
        withUnsafeBytes(of: &byte) { buf in
            sink.accept(packetBytes: buf, sourceStreamIndex: 3,
                        pts: 0, dts: 0, duration: 0, isKeyframe: true)
        }
        #expect(sink.indices == [3])
    }
}
