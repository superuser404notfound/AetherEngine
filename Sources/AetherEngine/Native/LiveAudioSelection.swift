import Foundation

/// AE#1100: the audio track the software live feeder plays, swappable while the feeder runs.
///
/// The live reader stores every audio track of the source in the DVR ring, so an audio pick does not
/// reopen the source: the host swaps the decoder here and reseeds the feeder at the playhead. The
/// rebuild it replaces reopened the URL, and an origin whose live URL replays the session from its
/// start when opened twice (HDHomeRun with the same SessionID) put the viewer back at the tune-in.
///
/// The feeder takes one snapshot per packet. A packet already inside the old decoder when the swap
/// lands finishes there, and the reseed's audio flush retires what it produces.
final class LiveAudioSelection: @unchecked Sendable {

    struct Snapshot {
        let streamIndex: Int32
        let decoder: (any SoftwareAudioProducing)?
        let timeBaseSeconds: Double
    }

    private let lock = NSLock()
    private var current: Snapshot

    init(streamIndex: Int32, decoder: (any SoftwareAudioProducing)?, timeBaseSeconds: Double) {
        current = Snapshot(streamIndex: streamIndex, decoder: decoder, timeBaseSeconds: timeBaseSeconds)
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func replace(streamIndex: Int32, decoder: (any SoftwareAudioProducing)?, timeBaseSeconds: Double) {
        lock.lock()
        current = Snapshot(streamIndex: streamIndex, decoder: decoder, timeBaseSeconds: timeBaseSeconds)
        lock.unlock()
    }

    /// The audio tracks besides `reference` the live reader stores, with their time bases in seconds.
    /// A track without a usable time base has no position in the ring and is left out.
    nonisolated static func alternateStreams(
        audioTracks: [(index: Int32, timeBaseSeconds: Double)], reference: Int32
    ) -> [Int32: Double] {
        guard reference >= 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for track in audioTracks where track.index != reference && track.timeBaseSeconds > 0 {
            out[track.index] = track.timeBaseSeconds
        }
        return out
    }
}
