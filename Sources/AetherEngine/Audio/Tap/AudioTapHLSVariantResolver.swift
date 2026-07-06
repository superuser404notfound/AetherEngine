import Foundation

/// #95 follow-up: chooses which media playlist the remote-HLS tap should decode. A separate
/// EXT-X-MEDIA audio rendition is cheapest (usually the one AVPlayer already fetches, so edge
/// cached); otherwise the lowest-bandwidth variant caps the extra bytes since low-bitrate audio
/// is fine for speech and Shazam. Pure; the caller resolves the returned URI against the master URL.
enum AudioTapHLSVariantResolver {
    static func pickAudioURI(from playlist: HLSPlaylist) -> String? {
        guard case .master(let master) = playlist else { return nil }
        if let best = master.variants.min(by: { $0.bandwidth < $1.bandwidth }),
           let group = best.audioGroupID, master.demuxedAudioGroupIDs.contains(group) {
            let renditions = master.audioRenditions.filter { $0.groupID == group }
            if let rendition = renditions.first(where: { $0.isDefault }) ?? renditions.first {
                return rendition.uri
            }
        }
        return master.variants.min(by: { $0.bandwidth < $1.bandwidth })?.uri
    }
}
