import Foundation

public extension AetherEngine {

    /// Compile the Dolby Vision Profile 7 FEL composer's Metal shaders now, so the first composed frame
    /// does not wait for them.
    ///
    /// The composer compiles its shaders from source on the first FEL frame of a process: about 300 ms on
    /// an M4 Pro the first time (longer on an Apple TV), then about 0.4 ms from Metal's shader cache until an
    /// app update or a cache purge. A host that calls this at launch, or when a Profile 7 title is selected,
    /// spends that while the viewer is still in its UI. It runs off the cooperative pool at utility
    /// priority and returns when the shaders are ready.
    ///
    /// Safe to call any number of times, and concurrently with playback: the compile happens once per
    /// process, and a composition that starts while it runs waits for it rather than compiling again.
    ///
    /// - Returns: Whether the pipelines are ready. False without the `DualLayerDolbyVision` trait (there is
    ///   nothing to warm), with no Metal device, or when the shaders fail to compile; that failure is kept,
    ///   so the dual-layer route then plays the base layer exactly as it would have without the warm.
    @discardableResult
    nonisolated static func prewarmDualLayerDolbyVision() async -> Bool {
        #if DualLayerDolbyVision
        await BlockingWork.detached(priority: .utility) { DoviFelComposer.prewarmPipelines() }.value
        #else
        false
        #endif
    }

    /// The default number of source bytes a warm retains, 8 MB.
    ///
    /// A byte budget rather than a duration, because a duration would need the bitrate, and the
    /// bitrate is known only after the probe, which is the round trip the warm exists to remove.
    static var defaultPrewarmByteBudget: Int { SourcePrewarmFetcher.defaultByteBudget }

    /// Fetch the opening bytes of a source the engine is not playing, so that a later `load()` of
    /// the same URL starts without paying for them (#551).
    ///
    /// For a host whose UI knows what comes next: the next episode, the item under the cursor. A
    /// cold open is two to three sequential round trips before the first sample read on a
    /// non-fast-start MP4, and on a slow origin the first byte of the data connection is the whole
    /// perceived start time. Those are spendable in advance, and this is how a host spends them.
    ///
    /// `nonisolated` and `static`: warming needs no engine, no audio session and no layer, so a
    /// host warms while its player is still on the current item. Call it from a detached task.
    ///
    /// What it does: one ranged GET from byte zero for `byteBudget` bytes, plus a second one for
    /// the trailing object only where the head says a cold open would go looking for it (an MP4
    /// whose `moov` sits behind the media). The bytes are held in memory, keyed by the exact URL,
    /// and the first `load()` of that URL takes them. They do not survive the app, and they are not
    /// a download: this is a head start, not an offline copy.
    ///
    /// What it deliberately does not do:
    ///
    /// - **It never queues for the origin.** A warm takes a request slot only if one is free right
    ///   now, and declines when the origin is metered down to one request at a time or is pacing
    ///   the engine (#377). A prewarm that would have to wait for the playing session's uplink has
    ///   stopped helping, and the report says so.
    /// - **It does not apply to `LoadOptions.nativeRemoteHLS`.** On that route AVPlayer issues the
    ///   requests and the engine sees none of them, so there is nothing here to adopt.
    ///
    /// Cancelling the task cancels the fetch and stores nothing: a host that has moved on must not
    /// find half a source warm for a URL it left behind.
    ///
    /// - Parameters:
    ///   - url: The exact source URL a later `load()` will use. A signed URL warmed under one
    ///     signature is not adopted under another, which is the conservative reading and the only
    ///     one that cannot serve the wrong bytes.
    ///   - httpHeaders: The same headers the load will carry (`LoadOptions.httpHeaders`), for
    ///     origins that enforce Referer / User-Agent / Authorization.
    ///   - byteBudget: How many bytes to retain from the head. Defaults to
    ///     ``defaultPrewarmByteBudget``.
    /// - Returns: A ``SourcePrewarmReport`` naming what was retained, or why nothing was.
    @discardableResult
    nonisolated static func prewarm(url: URL,
                                    httpHeaders: [String: String] = [:],
                                    byteBudget: Int? = nil) async -> SourcePrewarmReport {
        await SourcePrewarmFetcher.warm(url: url,
                                        extraHeaders: httpHeaders,
                                        byteBudget: byteBudget ?? SourcePrewarmFetcher.defaultByteBudget)
    }

    /// Whether a source is warm right now, without consuming it.
    ///
    /// For a host that wants to skip re-warming an item it already warmed. The playing session's
    /// adoption is what empties it, so this answers false again after the load that used it.
    nonisolated static func isPrewarmed(url: URL) -> Bool {
        SourcePrewarmStore.shared.isWarm(for: url)
    }

    /// Drop every warmed source.
    ///
    /// For a host leaving the context the warms were made for (a user signing out, a server
    /// changing). Warmed bytes cost memory until they are adopted or displaced, and a host that
    /// knows they will never be adopted can say so.
    nonisolated static func discardPrewarmedSources() {
        SourcePrewarmStore.shared.clear()
    }
}
