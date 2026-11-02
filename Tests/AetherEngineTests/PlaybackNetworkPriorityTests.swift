import Foundation
import Darwin
import Testing
@testable import AetherEngine

@Suite("Playback network callback priority")
struct PlaybackNetworkPriorityTests {
    @Test("a request started at utility priority completes at playback priority",
          .timeLimit(.minutes(3)))
    func utilityRequestCompletion() async throws {
        let origin = try #require(ThrottledOriginServer(totalSize: 64))
        defer { origin.stop() }
        let queue = AVIOReader.makePlaybackDelegateQueue()
        let session = URLSession(configuration: AVIOReader.makeSessionConfig(),
                                 delegate: EngineTLS.sessionDelegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let result = ProbeTestBox<(qos_class_t, Int, Bool)?>(nil)
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/sample.bin"))
        let task = session.dataTask(with: url) { data, _, error in
            result.update { $0 = (qos_class_self(), data?.count ?? 0, error != nil) }
        }
        let worker = Thread { task.resume() }
        worker.qualityOfService = .utility
        worker.start()
        try await waitFor { result.value != nil }
        let observed = try #require(result.value)
        #expect(observed.0 == QOS_CLASS_USER_INITIATED)
        #expect(observed.1 == 64)
        #expect(!observed.2)
    }

    @Test("serial callbacks execute at the foreground demux priority",
          .timeLimit(.minutes(3)))
    func foregroundCallbacks() async throws {
        let queue = AVIOReader.makePlaybackDelegateQueue()
        #expect(queue.qualityOfService == .userInitiated)
        #expect(queue.maxConcurrentOperationCount == 1)
        let observed = ProbeTestBox<qos_class_t?>(nil)
        queue.addOperation { observed.update { $0 = qos_class_self() } }
        try await waitFor { observed.value != nil }
        #expect(observed.value == QOS_CLASS_USER_INITIATED)
    }
}
