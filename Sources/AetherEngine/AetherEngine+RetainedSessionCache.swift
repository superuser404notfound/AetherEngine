import Foundation

public extension AetherEngine {

    /// Delete the segment cache a `stop()` kept for `LoadOptions.retainsSessionCacheAfterStop`
    /// (AE#1095), if there is one. For a host that knows the viewer will not come back to the title
    /// (signed out, switched profile, low on storage). A later load deletes it on its own when it
    /// names another source, so calling this is never required.
    nonisolated static func discardRetainedSessionCache() {
        ParkedSegmentSessionStore.shared.discard(reason: "the host discarded it")
    }

    /// Bytes on disk held by the kept segment cache, 0 when none is kept.
    nonisolated static var retainedSessionCacheBytes: Int {
        ParkedSegmentSessionStore.shared.parkedBytes
    }
}
