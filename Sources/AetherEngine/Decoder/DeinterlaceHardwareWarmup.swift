import Foundation

final class DeinterlaceHardwareWarmup: @unchecked Sendable {

    enum Outcome: String, Sendable, Equatable {
        case ready
        case unavailable
    }

    typealias Operation = @Sendable () async -> Outcome

    static let shared = DeinterlaceHardwareWarmup {
        DeinterlaceFilter.prewarmHardwarePipeline() ? .ready : .unavailable
    }

    // The operation is immutable; every read/write of the shared task is under this lock.
    // No lock is held across an await, and waiter cancellation does not cancel the shared task.
    private let operation: Operation
    private let lock = NSLock()
    private var task: Task<Outcome, Never>?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    private func sharedTask() -> Task<Outcome, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task {
            return task
        }
        let operation = operation
        let task = BlockingWork.detached(priority: .userInitiated) {
            let started = DispatchTime.now()
            EngineLog.emit(
                "[Deinterlace] hardware warm-up started",
                category: .swPlayback
            )
            let outcome = await operation()
            let elapsed = Double(
                DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            ) / 1_000_000_000
            EngineLog.emit(
                "[Deinterlace] hardware warm-up \(outcome.rawValue) "
                + "after \(String(format: "%.3f", elapsed))s",
                category: .swPlayback
            )
            return outcome
        }
        self.task = task
        return task
    }

    func waitIfNeeded(
        for mode: DeinterlaceMode,
        sourceIsInterlaced: Bool
    ) async -> Outcome? {
        guard mode == .auto, sourceIsInterlaced else {
            return nil
        }
        return await sharedTask().value
    }
}
