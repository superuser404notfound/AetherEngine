#if DEBUG && DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

/// The DEBUG pin test (`DoviPinTest`) holds its state in an instance, so these tests build their
/// own with a local log sink. They never arm `DoviDisplayMetadataDebug.shared`, which every decoder
/// in the process feeds, and never touch `EngineLog.handler`, so they cannot race another suite.
@Suite("Dolby Vision pin test")
struct DoviPinTestTests {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("disarms cleanly, logging once, when the scan window ends without a parseable L1")
    func disarmsWhenScanWindowEndsWithoutL1() throws {
        let sink = Sink()
        let pin = DoviPinTest(emit: { sink.append($0) })
        let config = try #require(DoviPinTest.parse(spec: "darkest:2,period:2"))
        pin.configure(config)
        #expect(pin.isArmed)

        let junkNAL: [UInt8] = [0x00, 0x00, 0x01, 0xFF]
        _ = pin.substitute(junkNAL)
        #expect(pin.isArmed)

        // The second unparseable frame ends the scan window: it must disarm.
        _ = pin.substitute(junkNAL)
        #expect(!pin.isArmed)
        #expect(!pin.isPinned)

        // Later frames neither re-enter the scan nor log again.
        _ = pin.substitute(junkNAL)
        _ = pin.substitute(junkNAL)

        let failures = sink.lines.filter { $0.contains("found no parseable L1") }
        #expect(failures.count == 1, "Expected exactly 1 disarm log line, got: \(failures)")
    }

    @Test("a threshold rule the title never reaches gives up after the scan limit", .offCooperativePoolOneLane)
    func thresholdRuleGivesUpAfterScanLimit() throws {
        let nal = DoviComposedFrameRpuTests.felNAL
        let hit = DoviPinTest(emit: { _ in })
        hit.configure(DoviPinTest.parse(spec: "maxpq>=0,period:2"))
        _ = hit.substitute(nal)
        #expect(hit.isPinned, "the fixture must parse, or the rest of this test proves nothing")

        let sink = Sink()
        let pin = DoviPinTest(emit: { sink.append($0) })
        pin.configure(DoviPinTest.parse(spec: "maxpq>=4096,period:2"))
        for _ in 1..<DoviPinTest.thresholdScanLimit { _ = pin.substitute(nal) }
        #expect(pin.isArmed)
        _ = pin.substitute(nal)
        #expect(!pin.isArmed)
        #expect(!pin.isPinned)
        #expect(sink.lines.filter { $0.contains("found no frame matching the rule") }.count == 1)
    }

    @Test("an unarmed pin test returns every frame's RPU unchanged")
    func unarmedIsTransparent() {
        let pin = DoviPinTest(emit: { _ in })
        let nal: [UInt8] = [1, 2, 3]
        #expect(pin.substitute(nal) == nal)
        #expect(pin.substitute(nil) == nil)
    }

    @Test("period: is clamped, so a tiny or non-finite value cannot overflow the phase arithmetic")
    func periodIsClamped() throws {
        func period(_ spec: String) throws -> TimeInterval {
            try #require(DoviPinTest.parse(spec: spec)).period
        }
        #expect(try period("darkest:5,period:0") == 0)
        #expect(try period("darkest:5,period:0.0000001") == DoviPinTest.minimumPeriod)
        #expect(try period("darkest:5,period:2") == 2)
        #expect(try period("darkest:5,period:1e9") == DoviPinTest.maximumPeriod)
        #expect(try period("darkest:5,period:nan") == 2)
        #expect(try period("darkest:5,period:inf") == 2)
    }

    @Test("the capture rules dvsurvey prints parse back to the capture they name")
    func surveyPrintedSpecsParse() throws {
        func capture(_ spec: String) throws -> DoviPinTest.Capture {
            try #require(DoviPinTest.parse(spec: spec)).capture
        }
        #expect(try capture("darkest:300,period:2") == .darkest(frames: 300))
        #expect(try capture("brightest:240,period:2") == .brightest(frames: 240))
        #expect(try capture("avgpq<=312,period:2") == .atMost(.avgPQ, 312))
        #expect(try capture("maxpq>=4095,period:2") == .atLeast(.maxPQ, 4095))
        // A window of zero frames is raised to one so the scan can still capture something.
        #expect(try capture("darkest:0") == .darkest(frames: 1))
    }

    @Test("a spec without a capture rule arms nothing")
    func specWithoutCaptureRuleIsRejected() {
        #expect(DoviPinTest.parse(spec: "period:2") == nil)
        #expect(DoviPinTest.parse(spec: "") == nil)
        #expect(DoviPinTest.parse(spec: "darkest:abc") == nil)
        #expect(DoviPinTest.parse(spec: "maxpq>=99999") == nil)
    }
}
#endif
