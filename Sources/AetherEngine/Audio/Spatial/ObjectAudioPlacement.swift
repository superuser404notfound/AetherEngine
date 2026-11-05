// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation

/// What one signal in an object-audio presentation is.
enum ObjectAudioRole: Sendable, Equatable {
    /// A bed channel at a fixed speaker position. Placed like a static object so a bed channel the
    /// target layout lacks (a 7.1.2 bed's top-middle pair on a 5.1.4 layout) still lands where it
    /// should, as a phantom between the speakers that bracket it.
    case bed(SpatialSpeaker)
    /// A bed channel at a fixed position the room model names no speaker for (screen, centre back,
    /// top centre). Placed as a phantom from the moment the placement exists, like a bed channel the
    /// layout lacks, so it has gains in a presentation that never sends metadata.
    case fixed(SIMD3<Float>)
    /// The low-frequency effects channel. Routed to the layout's LFE, never panned.
    case lfe
    /// A dynamic object, positioned by metadata.
    case object
}

/// One element's placement as of a metadata update.
struct ObjectAudioElementState: Sendable, Equatable {
    /// Allocentric position (see `SpatialSpeaker`). Ignored for beds and LFE.
    var position: SIMD3<Float> = SIMD3(0.5, 0.5, 0)
    /// Linear gain.
    var gain: Float = 1
}

/// A metadata change taking effect partway through a block. It applies as a jump: metadata ramps
/// are not followed.
struct ObjectAudioMetadataUpdate: Sendable {
    /// Frame within the block at which the new state takes effect.
    var frameOffset: Int
    /// One entry per element, indexed like `ObjectAudioPlacement.roles`. Nil leaves that element
    /// where it is.
    var states: [ObjectAudioElementState?]
}

/// Element gains and positions as `ObjectAudioPlacement.snapshot` reads them, reused across blocks.
struct ObjectAudioGainSnapshot {
    var layoutGains: [Float] = []
    var positions: [SIMD3<Float>?] = []
    var gains: [Float] = []

    mutating func resize(elements: Int, channels: Int) {
        if layoutGains.count != elements * channels { layoutGains = [Float](repeating: 0, count: elements * channels) }
        if positions.count != elements {
            positions = Array(repeating: nil, count: elements)
            gains = [Float](repeating: 0, count: elements)
        }
    }
}

/// Where each element of an object-audio presentation sits in a `SpatialSpeakerLayout`: its gains
/// towards the layout's speakers, from its role and its latest metadata. It mixes no audio:
/// `BedRegression` reads these gains to build every output from the stream's own bed, and no
/// element signal is ever panned onto a speaker. Every element is a point source, and a metadata
/// update applies as a jump.
final class ObjectAudioPlacement {

    let layout: SpatialSpeakerLayout
    private(set) var roles: [ObjectAudioRole]

    /// Every element is a point source at its position, panned over the whole layout.
    private let panner: AllocentricPanner

    /// Per element, per layout channel: the gains as of its latest metadata.
    private var current: [[Float]]

    /// Each object's latest state, for `snapshot`.
    private var objectStates: [ObjectAudioElementState?]

    init(layout: SpatialSpeakerLayout, roles: [ObjectAudioRole]) {
        self.layout = layout
        self.roles = roles
        panner = AllocentricPanner(layout: layout)
        current = Array(repeating: [Float](repeating: 0, count: layout.channelCount), count: roles.count)
        objectStates = Array(repeating: nil, count: roles.count)
        // Beds and LFE have gains the moment the placement exists; objects wait for metadata and are
        // placed nowhere until their first update, rather than guessing at a position. The TrueHD
        // decoder holds the blocks before that update and gives the first of them its state at frame 0
        // (`ObjectMetadataHold`), so after a reset that wait costs nothing audible.
        for (index, role) in roles.enumerated() where role != .object {
            staticGains(for: role, state: ObjectAudioElementState(), into: &current[index])
        }
    }

    /// Forget every object position: the next block starts from the state a freshly built placement
    /// would (seeks, producer restarts).
    func reset() {
        for index in roles.indices {
            objectStates[index] = nil
            if roles[index] == .object {
                for c in current[index].indices { current[index][c] = 0 }
            } else {
                staticGains(for: roles[index], state: ObjectAudioElementState(), into: &current[index])
            }
        }
    }

    /// Apply a block's metadata, in order.
    func apply(_ updates: [ObjectAudioMetadataUpdate]) {
        for update in updates { apply(update) }
    }

    /// Every element's gains towards the layout, and where it sits: `layoutGains` holds
    /// `roles.count` rows of `layout.channelCount`; `positions` is nil for the LFE and for an object
    /// without metadata yet; `gains` is the element gain.
    func snapshot(into snapshot: inout ObjectAudioGainSnapshot) {
        let channels = layout.channelCount
        snapshot.resize(elements: roles.count, channels: channels)
        for index in roles.indices {
            let row = index * channels
            for c in 0..<channels { snapshot.layoutGains[row + c] = current[index][c] }
            switch roles[index] {
            case .object:
                snapshot.positions[index] = objectStates[index]?.position
                snapshot.gains[index] = objectStates[index]?.gain ?? 0
            case .bed(let speaker):
                snapshot.positions[index] = speaker.position
                snapshot.gains[index] = 1
            case .fixed(let position):
                snapshot.positions[index] = position
                snapshot.gains[index] = 1
            case .lfe:
                snapshot.positions[index] = nil
                snapshot.gains[index] = 0
            }
        }
    }

    // MARK: - Metadata

    private func apply(_ update: ObjectAudioMetadataUpdate) {
        let count = min(update.states.count, roles.count)
        for index in 0..<count {
            guard let state = update.states[index] else { continue }
            switch roles[index] {
            case .object:
                objectStates[index] = state
                panner.pointGains(state.position, into: &current[index])
                if state.gain != 1 { for c in current[index].indices { current[index][c] *= state.gain } }
            case .bed, .lfe, .fixed:
                staticGains(for: roles[index], state: state, into: &current[index])
            }
        }
    }

    private func staticGains(for role: ObjectAudioRole, state: ObjectAudioElementState, into gains: inout [Float]) {
        if gains.count != layout.channelCount { gains = [Float](repeating: 0, count: layout.channelCount) }
        switch role {
        case .lfe:
            for c in gains.indices { gains[c] = 0 }
            gains[layout.lfeIndex] = state.gain
        case .bed(let speaker):
            if let direct = layout.speakers.firstIndex(of: speaker) ?? Self.downmixTarget(speaker, in: layout) {
                for c in gains.indices { gains[c] = 0 }
                gains[direct] = state.gain
            } else {
                panner.pointGains(speaker.position, into: &gains)
                if state.gain != 1 { for c in gains.indices { gains[c] *= state.gain } }
            }
        case .fixed(let position):
            panner.pointGains(position, into: &gains)
            if state.gain != 1 { for c in gains.indices { gains[c] *= state.gain } }
        case .object:
            break
        }
    }

    /// Where a speaker-anchored bed channel the layout lacks goes when panning it would be wrong. A
    /// 7.1 bed's side and rear surrounds both belong on a 5.1 layout's surround pair, the way a 7.1 to
    /// 5.1 downmix folds them, and a 5.1 bed's surrounds on a 7.1 layout's sides, which sit where
    /// TS 103 448 puts the 5.1 surrounds. Panned by position, a 5.1 surround would split between a
    /// 7.1 layout's sides and rears.
    static func downmixTarget(_ speaker: SpatialSpeaker, in layout: SpatialSpeakerLayout) -> Int? {
        let speakers = layout.speakers
        switch speaker {
        case .sideLeft, .rearLeft: return speakers.firstIndex(of: .surroundLeft)
        case .sideRight, .rearRight: return speakers.firstIndex(of: .surroundRight)
        case .surroundLeft: return speakers.firstIndex(of: .sideLeft)
        case .surroundRight: return speakers.firstIndex(of: .sideRight)
        default: return nil
        }
    }
}
#endif
