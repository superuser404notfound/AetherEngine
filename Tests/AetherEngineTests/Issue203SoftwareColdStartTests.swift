import Foundation
import Testing
@testable import AetherEngine

struct Issue203SoftwareColdStartTests {

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen {
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
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
        let started = Gate()
        let release = Gate()
        let counter = Counter()
        let warmup = DeinterlaceHardwareWarmup {
            counter.increment()
            await started.open()
            await release.wait()
            return .ready
        }

        await started.wait()

        async let first = warmup.waitIfNeeded(for: .auto)
        async let second = warmup.waitIfNeeded(for: .auto)
        await release.open()

        #expect(await first == .ready)
        #expect(await second == .ready)
        #expect(counter.value == 1)
    }

    @Test("forced software mode bypasses an unfinished hardware warm-up")
    func softwareModeDoesNotWait() async {
        let release = Gate()
        let warmup = DeinterlaceHardwareWarmup {
            await release.wait()
            return .ready
        }

        let started = DispatchTime.now()
        let result = await warmup.waitIfNeeded(for: .software)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000

        await release.open()
        #expect(result == nil)
        #expect(elapsed < 1)
    }

    @Test("cancelling a waiter does not cancel the process warm-up")
    func cancelledWaiterDoesNotCancelWarmup() async {
        let started = Gate()
        let release = Gate()
        let warmup = DeinterlaceHardwareWarmup {
            await started.open()
            await release.wait()
            return .ready
        }
        await started.wait()

        let waiter = Task {
            await warmup.waitIfNeeded(for: .auto)
        }
        waiter.cancel()
        await release.open()

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
