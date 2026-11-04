import Combine
import Testing
import AetherEngine

@MainActor
struct PublicSecondarySubtitleIdentityTests {
    @Test func publicReadAndSubscription() throws {
        let engine = try AetherEngine()
        let value: Int? = engine.activeSecondarySubtitleTrackIndex
        let publisher: Published<Int?>.Publisher = engine.$activeSecondarySubtitleTrackIndex
        var received: [Int?] = []
        let subscription = publisher.sink { received.append($0) }
        defer { subscription.cancel() }
        #expect(value == nil)
        #expect(received == [nil])
    }
}
