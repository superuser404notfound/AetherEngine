import Testing
@testable import AetherEngine

@Suite("H.264 recovery points are not HLS IDRs")
struct H264RecoveryPointTests {
    @Test func exactRecovery() {
        #expect(H264RecoveryPoint.isImmediateExactRecovery(seiNAL: [6, 6, 1, 0xc4, 0x80]))
        #expect(!H264RecoveryPoint.isImmediateExactRecovery(seiNAL: [6, 6, 1, 0x84, 0x80]))
        #expect(!H264RecoveryPoint.isImmediateExactRecovery(seiNAL: [6, 6, 1, 0x54, 0x80]))
        #expect(!H264RecoveryPoint.isImmediateExactRecovery(seiNAL: [6, 6, 2, 0xc4]))
        #expect(!H264RecoveryPoint.isImmediateExactRecovery(seiNAL: [5, 6, 1, 0xc4, 0x80]))
    }
    @Test func requiresRepeatedPositiveEvidence() {
        var evidence = H264RecoveryPoint.Evidence()
        for _ in 0..<100 {
            evidence.observe(containerKey: true, hasIDR: true, immediateExactRecovery: true)
            evidence.observe(containerKey: false, hasIDR: false, immediateExactRecovery: true)
            evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: false)
        }
        #expect(!evidence.requiresCompatibilityPath)
        for _ in 0..<2 {
            evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: true)
        }
        #expect(!evidence.requiresCompatibilityPath)
        evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: true)
        #expect(evidence.requiresCompatibilityPath)
    }
}
