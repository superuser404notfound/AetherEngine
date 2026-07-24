import Foundation
import Testing
@testable import AetherEngine

struct Issue203SoftwareColdStartTests {

    private func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout))
            }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test("construction starts one process warm-up shared by concurrent auto waiters")
    func oneTaskServesConcurrentWaiters() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let counter = Counter()
        let warmup = DeinterlaceHardwareWarmup {
            counter.increment()
            started.signal()
            release.wait()
            return .ready
        }

        #expect(await wait(for: started, timeout: .now() + 2) == .success)

        async let first = warmup.waitIfNeeded(for: .auto)
        async let second = warmup.waitIfNeeded(for: .auto)
        release.signal()

        #expect(await first == .ready)
        #expect(await second == .ready)
        #expect(counter.value == 1)
    }

    @Test("forced software mode bypasses an unfinished hardware warm-up")
    func softwareModeDoesNotWait() async {
        let release = DispatchSemaphore(value: 0)
        let warmup = DeinterlaceHardwareWarmup {
            release.wait()
            return .ready
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            release.signal()
        }

        let started = DispatchTime.now()
        let result = await warmup.waitIfNeeded(for: .software)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000

        release.signal()
        #expect(result == nil)
        #expect(elapsed < 1)
    }

    @Test("cancelling a waiter does not cancel the process warm-up")
    func cancelledWaiterDoesNotCancelWarmup() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let warmup = DeinterlaceHardwareWarmup {
            started.signal()
            release.wait()
            return .ready
        }
        #expect(await wait(for: started, timeout: .now() + 2) == .success)

        let waiter = Task {
            await warmup.waitIfNeeded(for: .auto)
        }
        waiter.cancel()
        release.signal()

        #expect(await waiter.value == .ready)
        #expect(await warmup.waitIfNeeded(for: .auto) == .ready)
    }

    @Test("hardware unavailability completes the gate without throwing")
    func unavailableCompletesNormally() async {
        let warmup = DeinterlaceHardwareWarmup {
            .unavailable
        }

        #expect(await warmup.waitIfNeeded(for: .auto) == .unavailable)
    }
}
