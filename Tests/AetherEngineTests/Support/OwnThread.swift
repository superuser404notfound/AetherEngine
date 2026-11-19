import Foundation

/// Starts `body` on a thread of its own and returns a flag that turns true once it returned, for a test
/// to `waitFor`. For calls that block (a pipeline's `submit` at its depth, `settle`), which never run on
/// the test's own thread or the global dispatch queue (CONTRIBUTING.md, rules 3 and 4).
func runOnOwnThread(_ body: @escaping @Sendable () -> Void) -> TestFlag {
    let flag = TestFlag()
    Thread { body(); flag.set() }.start()
    return flag
}

/// A flag one thread sets and a test reads.
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
