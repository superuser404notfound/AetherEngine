import Testing
import Foundation
import Combine
@testable import AetherEngine

/// The engine's per-session callbacks are stored on the objects they observe, so they must not hold those
/// objects. A strong capture made a cycle: every played HLS session (its ingest reader, URL session and caches)
/// and its request header store stayed alive after `stop`, found with `leaks` on a host after live playback.
@Suite("Session callbacks release their session")
@MainActor
struct SessionCallbackReleaseTests {

    @Test("the playlist shift relay does not keep its session")
    func shiftRelayReleasesSession() throws {
        let engine = try AetherEngine()
        weak var released: HLSVideoEngine?
        do {
            let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/release.mkv"), dvModeAvailable: false)
            engine.installPlaylistShiftRelay(on: session, generation: engine.loadGeneration)
            released = session
            #expect(released != nil)
        }
        #expect(released == nil)
    }

    @Test("the credential refusal relay does not keep its store")
    func refusalRelayReleasesStore() throws {
        let engine = try AetherEngine()
        weak var released: RequestHeaderStore?
        do {
            let store = RequestHeaderStore(["Authorization": "Bearer a"])
            engine.relayCredentialRefusals(of: store)
            released = store
            #expect(released != nil)
        }
        #expect(released == nil)
    }

    @Test("a refusal on the current session's store still reaches the host, a replaced store's does not",
          .timeLimit(.minutes(3)))
    func refusalStillReachesTheHost() async throws {
        let engine = try AetherEngine()
        var received: [Int] = []
        let subscription = engine.sourceAuthorizationRefused.sink { received.append($0) }
        defer { subscription.cancel() }

        let current = RequestHeaderStore(["Authorization": "Bearer a"])
        engine.sessionRequestHeaders = current
        engine.relayCredentialRefusals(of: current)
        let replaced = RequestHeaderStore(["Authorization": "Bearer old"])
        engine.relayCredentialRefusals(of: replaced)

        // Both forwards hop to the main actor in this order: once the current one arrived, the replaced
        // one has had its turn.
        replaced.noteCredentialRefusal(status: 403, revision: 0)
        current.noteCredentialRefusal(status: 401, revision: 0)
        try await waitFor { !received.isEmpty }
        #expect(received == [401])
    }
}
