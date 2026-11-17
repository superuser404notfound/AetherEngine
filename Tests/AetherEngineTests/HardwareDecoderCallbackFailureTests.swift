import Testing
import CoreMedia
import VideoToolbox
@testable import AetherEngine

#if DEBUG
/// DEC-204: a frame VideoToolbox fails to deliver through the output callback used to vanish with no
/// count and no log, and a status that kills the session never reached the AE#739 recovery.
@Suite("Hardware decoder callback failures", .timeLimit(.minutes(3)))
struct HardwareDecoderCallbackFailureTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private let pts = CMTime(value: 3000, timescale: 90000)

    @Test("a failed frame is counted and leaves the session alone")
    func countsANonFatalFailure() {
        let decoder = HardwareVideoDecoder()
        let lost = Counter()
        decoder.onSessionLost = { lost.bump() }
        decoder.pretendsToHaveSessionForTesting = true
        decoder.handleCallbackFailure(status: kVTVideoDecoderBadDataErr, pts: pts, infoFlags: .frameDropped)
        decoder.handleCallbackFailure(status: kVTVideoDecoderBadDataErr, pts: pts, infoFlags: [])
        #expect(decoder.callbackFailureCount == 2)
        #expect(!decoder.isSessionLost)
        #expect(lost.value == 0)
    }

    @Test("a session-fatal status takes the AE#739 loss path once")
    func fatalStatusLosesTheSession() async throws {
        for status in [kVTVideoDecoderMalfunctionErr, kVTInvalidSessionErr] {
            let decoder = HardwareVideoDecoder()
            let lost = Counter()
            decoder.onSessionLost = { lost.bump() }
            decoder.pretendsToHaveSessionForTesting = true
            decoder.handleCallbackFailure(status: status, pts: pts, infoFlags: [])
            decoder.handleCallbackFailure(status: status, pts: pts, infoFlags: [])
            try await waitFor { decoder.isSessionLost }
            try await waitFor { lost.value >= 1 }
            try await Task.sleep(for: .milliseconds(50))
            #expect(lost.value == 1, "reported once per lost session, status \(status)")
        }
    }

    @Test("a verdict for a session that has been replaced is ignored")
    func staleVerdictIsIgnored() {
        let decoder = HardwareVideoDecoder()
        let lost = Counter()
        decoder.onSessionLost = { lost.bump() }
        decoder.pretendsToHaveSessionForTesting = true
        let stale = decoder.callbackFailureSessionForTesting &+ 1
        decoder.markSessionLostFromCallback(session: stale, status: kVTVideoDecoderMalfunctionErr)
        #expect(!decoder.isSessionLost)
        #expect(lost.value == 0)
    }

    @Test("only the two session-ending statuses count as fatal")
    func fatalClassification() {
        #expect(HardwareVideoDecoder.isSessionFatal(kVTInvalidSessionErr))
        #expect(HardwareVideoDecoder.isSessionFatal(kVTVideoDecoderMalfunctionErr))
        #expect(!HardwareVideoDecoder.isSessionFatal(kVTVideoDecoderBadDataErr))
        #expect(!HardwareVideoDecoder.isSessionFatal(noErr))
    }
}
#endif
