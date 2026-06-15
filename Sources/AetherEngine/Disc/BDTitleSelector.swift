import Foundation

enum BDTitleSelector {
    static func selectMainTitle(_ playlists: [MPLSPlaylist]) -> MPLSPlaylist? {
        playlists.max { $0.durationTicks < $1.durationTicks }
    }
}
