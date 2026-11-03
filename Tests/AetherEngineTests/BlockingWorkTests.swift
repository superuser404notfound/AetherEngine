import Foundation
import Testing
@testable import AetherEngine

@Suite(.timeLimit(.minutes(3)))
struct BlockingWorkTests {
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    @Test("Blocking work runs off the cooperative pool, before and after an await")
    func runsOffThePool() async {
        let labels = await BlockingWork.detached(priority: .userInitiated) { () async -> [String] in
            let before = Self.currentQueueLabel()
            await Task.yield()
            return [before, Self.currentQueueLabel()]
        }.value
        #expect(labels.allSatisfy { !$0.contains("cooperative") }, "ran on \(labels)")
    }

    // More blocked jobs than the pool has threads: on the pool the last waiter could never
    // start, here every one of them is parked at once.
    @Test("Blocked jobs do not hold the cooperative pool")
    func blockedJobsLeaveThePoolFree() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let gate = ProbeTestGate()
        let parked = ProbeTestBox(0)
        let tasks = (0..<count).map { _ in
            BlockingWork.detached { gate.wait { parked.update { $0 += 1 } } }
        }
        try await waitFor { parked.value == count }
        gate.open()
        for task in tasks { await task.value }
    }

    @Test("The off-pool trait moves a synchronous test body off the cooperative pool", .offCooperativePool)
    func traitMovesASyncBody() {
        let label = Self.currentQueueLabel()
        #expect(!label.contains("cooperative"), "ran on \(label)")
    }

    @Test("A throwing operation reports its error")
    func throwsThrough() async {
        struct Refused: Error {}
        let task = BlockingWork.detached { () async throws -> Int in throw Refused() }
        await #expect(throws: Refused.self) { try await task.value }
    }

    // Comments may name it; code may not. `BlockingWork.swift` is the one place that calls it.
    @Test("No engine source creates a detached task on the cooperative pool")
    func noBareDetachedTasks() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "BlockingWork.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("Task.detached") { offenders.append("\(url.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "use BlockingWork.detached: \(offenders)")
    }

    @Test("Job priorities map onto the matching GCD class")
    @available(visionOS 2, *)
    func priorityMapping() {
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.userInitiated.rawValue)) == .userInitiated)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.utility.rawValue)) == .utility)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.background.rawValue)) == .background)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: 0)) == .default)
    }
}
