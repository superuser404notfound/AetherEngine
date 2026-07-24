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

    private let task: Task<Outcome, Never>

    init(operation: @escaping Operation) {
        task = Task.detached(priority: .userInitiated) {
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
    }

    func waitIfNeeded(for mode: DeinterlaceMode) async -> Outcome? {
        guard mode == .auto else {
            return nil
        }
        return await task.value
    }
}
