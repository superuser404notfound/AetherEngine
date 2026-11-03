import Testing
@testable import AetherEngine

@Suite("AE#937 wedged restart on a one-request origin")
struct Issue937WedgedRestartOrderTests {
    @Test("only a wedged read on a one-request origin is aborted before the fresh open")
    func abortOrder() {
        #expect(HLSVideoEngine.abortsWedgedReadBeforeReopen(oldPumpExited: false, originSerial: true))
        #expect(!HLSVideoEngine.abortsWedgedReadBeforeReopen(oldPumpExited: false, originSerial: false))
        // #169 suspect-dead: the pump exited, no read holds the slot.
        #expect(!HLSVideoEngine.abortsWedgedReadBeforeReopen(oldPumpExited: true, originSerial: true))
    }
}
