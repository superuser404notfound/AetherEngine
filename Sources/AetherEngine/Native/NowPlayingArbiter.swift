import Foundation

/// An engine that publishes to the shared Now-Playing centers and has to share them.
@MainActor
protocol SharedNowPlayingClient: AnyObject {
    func sharedNowPlayingOwnershipChanged(isOwner: Bool)
}

/// Decides which engine in the process holds the shared Now-Playing surface.
///
/// `MPNowPlayingInfoCenter.default()` and `MPRemoteCommandCenter.shared()` exist once per process, so two
/// engines publishing there at once would overwrite each other's card and both answer every command (a
/// toggle would fire twice and cancel itself). Several primary engines in one process is ordinary on
/// macOS, one per player window. The holder is the engine that claimed last: an engine claims when it
/// starts playing and when the host calls `claimNowPlaying()` (a window becoming key). An engine that
/// enlists while another holds the surface waits behind it, and when the holder leaves, the most recent
/// claimant still waiting takes over.
///
/// Engines that publish through an `MPNowPlayingSession` do not enlist: the system arbitrates between
/// sessions itself, and each session has its own command center.
@MainActor
final class NowPlayingArbiter {
    static let shared = NowPlayingArbiter()

    private struct Entry {
        weak var client: (any SharedNowPlayingClient)?
    }

    /// Oldest claim first; the holder is the last live entry.
    private var entries: [Entry] = []

    init() {}

    var owner: (any SharedNowPlayingClient)? {
        prune()
        return entries.last?.client
    }

    func isOwner(_ client: any SharedNowPlayingClient) -> Bool {
        owner === client
    }

    /// Joins without taking the surface from a current holder. Returns whether `client` holds it.
    @discardableResult
    func enlist(_ client: any SharedNowPlayingClient) -> Bool {
        prune()
        if !contains(client) {
            entries.insert(Entry(client: client), at: 0)
        }
        return isOwner(client)
    }

    /// Takes the surface.
    func claim(_ client: any SharedNowPlayingClient) {
        let previous = owner
        entries.removeAll { $0.client === client }
        entries.append(Entry(client: client))
        guard previous !== client else { return }
        previous?.sharedNowPlayingOwnershipChanged(isOwner: false)
        client.sharedNowPlayingOwnershipChanged(isOwner: true)
    }

    /// Leaves; the most recent claimant still waiting takes over.
    func release(_ client: any SharedNowPlayingClient) {
        let wasOwner = isOwner(client)
        entries.removeAll { $0.client === client }
        guard wasOwner, let next = owner else { return }
        next.sharedNowPlayingOwnershipChanged(isOwner: true)
    }

    private func contains(_ client: any SharedNowPlayingClient) -> Bool {
        entries.contains { $0.client === client }
    }

    private func prune() {
        entries.removeAll { $0.client == nil }
    }
}
