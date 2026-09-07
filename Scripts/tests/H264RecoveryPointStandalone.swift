import Foundation

@main
struct RecoveryPointTests {
    static func main() {
        let classify = H264RecoveryPoint.isImmediateExactRecovery
        precondition(classify([6, 6, 1, 0xc4, 0x80]))
        precondition(classify([6, 5, 2, 1, 2, 6, 1, 0xc4, 0x80]))
        for bytes: [UInt8] in [[], [6], [6, 255], [6, 6, 2, 0xc4],
                              [5, 6, 1, 0xc4, 0x80], [6, 6, 1, 0x84, 0x80],
                              [6, 6, 1, 0x54, 0x80], [0x86, 6, 1, 0xc4, 0x80]] {
            precondition(!classify(bytes))
        }
        precondition(!classify(Array(repeating: 6, count: 4097)))
        var evidence = H264RecoveryPoint.Evidence()
        for _ in 0..<100 {
            evidence.observe(containerKey: true, hasIDR: true, immediateExactRecovery: true)
            evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: false)
            evidence.observe(containerKey: false, hasIDR: false, immediateExactRecovery: true)
        }
        precondition(!evidence.requiresCompatibilityPath)
        for count in 1...3 {
            evidence.observe(containerKey: true, hasIDR: false, immediateExactRecovery: true)
            precondition(evidence.requiresCompatibilityPath == (count == 3))
        }
        print("PASS: exact/delayed recovery, IDR exclusion, container flags, malformed/oversized input, repeated evidence")
    }
}
