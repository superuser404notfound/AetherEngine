import Testing
import Foundation
@testable import AetherEngine

@Suite("ThreadCPUSampler")
struct ThreadCPUSamplerTests {

    @Test("a pool's trailing counter folds into one group")
    func groupNames() {
        #expect(ThreadCPUSampler.groupName("com.aetherengine.hls.conn.31") == "com.aetherengine.hls.conn")
        #expect(ThreadCPUSampler.groupName("av:hevc:df1") == "av:hevc:df")
        #expect(ThreadCPUSampler.groupName("AetherEngine.HLSSegmentProducer.pump") == "AetherEngine.HLSSegmentProducer.pump")
        #expect(ThreadCPUSampler.groupName("") == "(unnamed)")
        #expect(ThreadCPUSampler.groupName("42") == "42")
    }

    @Test("time of a thread that ended inside the window is reported as (ended)")
    func endedThreads() {
        let previous: (uptime: UInt64, ended: UInt64, perThread: [UInt64: UInt64]) =
            (0, 0, [1: 0, 2: 100_000_000, 3: 0])
        let threads = [
            ThreadCPUSampler.ThreadTime(id: 1, name: "", nanoseconds: 50_000_000),
            ThreadCPUSampler.ThreadTime(id: 2, name: "pump", nanoseconds: 400_000_000),
        ]
        // Thread 3 ran 200 ms and ended; the task's ended-threads total carries it.
        let report = ThreadCPUSampler.report(
            threads: threads, ended: 200_000_000, now: 1_000_000_000,
            previous: previous, mainThreadID: 1)
        #expect(abs(report.totalPercent - 55) < 0.001)
        #expect(abs(report.mainPercent - 5) < 0.001)
        #expect(report.groups.map(\.name) == ["pump", "(ended)"])
        #expect(abs(report.groups[0].percent - 30) < 0.001)
        #expect(abs(report.groups[1].percent - 20) < 0.001)
    }

    @Test("a busy named thread shows up with its share")
    @MainActor func liveSample() throws {
        let sampler = ThreadCPUSampler()
        #expect(sampler.sample() == nil)
        let done = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Burn thread CPU time, not wall time: on a loaded runner a wall-clock burn gets
        // preempted and its share of the window says nothing about the sampler.
        nonisolated(unsafe) var burned = 0.0
        let thread = Thread {
            pthread_setname_np("cpuprobe-burner")
            var x = 0.0
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) < 200_000_000 { x += sin(x) + 1 }
            if x < 0 { print(x) }
            burned = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
            done.signal()
            release.wait()
        }
        thread.start()
        done.wait()
        let report = try #require(sampler.sample())
        release.signal()
        let burner = try #require(report.groups.first { $0.name == "cpuprobe-burner" })
        #expect(burner.percent / 100 * report.intervalSeconds >= burned * 0.99)
        #expect(report.totalPercent >= burner.percent)
        #expect(report.logFragment().hasPrefix("cpu="))
    }
}
