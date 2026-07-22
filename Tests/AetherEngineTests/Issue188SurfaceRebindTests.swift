import Testing
import Foundation
@testable import AetherEngine

/// #188: `AetherPlayerSurface.updateUIView` was empty, so it only called `bind(view:)` from
/// `makeUIView`. When a host replaces its `AetherEngine` instance at the same structural position
/// (a retry/reload flow), SwiftUI reuses the platform view and calls only `updateUIView`, so the
/// new engine's `bind(view:)` never ran: its `boundView` stayed nil, `presentCurrentLayer()`
/// no-oped, and the reused view kept displaying the previous engine's detached layer, black video
/// over working audio. The fix rebinds on every update; these tests lock the engine-level contract
/// that rebind relies on: a reused view taken over by a new engine shows the new engine's layer and
/// the old engine no longer owns it, and steady-state rebind of the same engine is a no-op swap.
@Suite("AetherPlayerSurface rebind on engine swap (#188)")
struct Issue188SurfaceRebindTests {

    @MainActor
    @Test("A view bound to a second engine takes over its layer; the first engine's layer is dropped")
    func rebindSwapsLayerOwnership() async throws {
        let engineA = try AetherEngine()
        try await engineA.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/a.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        let hostA = try #require(engineA.nativeHost)

        // Host embeds the surface: makeUIView binds engineA to the view.
        let view = AetherPlayerView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        engineA.bind(view: view)
        #expect(hostA.playerLayer.superlayer === view.layer)

        // Host swaps to a fresh engine at the same structural position. SwiftUI reuses `view` and
        // calls updateUIView, which now rebinds. Simulate exactly that: a second engine binds the
        // same view.
        let engineB = try AetherEngine()
        try await engineB.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/b.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        let hostB = try #require(engineB.nativeHost)

        engineB.bind(view: view)

        #expect(hostB.playerLayer.superlayer === view.layer,
                "the reused view must display the new engine's layer after rebind")
        #expect(hostA.playerLayer.superlayer !== view.layer,
                "the previous engine's layer must be detached from the reused view")
    }

    @MainActor
    @Test("Rebinding the same engine to the same view is an idempotent no-op swap")
    func steadyStateRebindIsIdempotent() async throws {
        let engine = try AetherEngine()
        try await engine.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/live.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        let host = try #require(engine.nativeHost)

        let view = AetherPlayerView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        engine.bind(view: view)
        #expect(host.playerLayer.superlayer === view.layer)

        // updateUIView fires repeatedly during steady-state layout; each call rebinds. The hosted
        // layer identity must not churn (attach short-circuits on the same layer).
        engine.bind(view: view)
        engine.bind(view: view)

        #expect(host.playerLayer.superlayer === view.layer)
    }
}
