// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Accelerate
import Foundation

/// What one signal in an object-audio presentation is.
enum ObjectAudioRole: Sendable, Equatable {
    /// A bed channel at a fixed speaker position. Rendered like a static object so a bed channel the
    /// target layout lacks (a 7.1.2 bed's top-middle pair on a 5.1.4 layout) still lands where it
    /// should, as a phantom between the speakers that bracket it.
    case bed(SpatialSpeaker)
    /// A bed channel at a fixed position the room model names no speaker for (screen, centre back,
    /// top centre). Rendered as a phantom from the moment the renderer exists, like a bed channel the
    /// layout lacks, so it plays in a presentation that never sends metadata.
    case fixed(SIMD3<Float>)
    /// The low-frequency effects channel. Routed to the layout's LFE, never panned.
    case lfe
    /// A dynamic object, positioned by metadata.
    case object
}

/// One element's rendering parameters as of a metadata update.
struct ObjectAudioElementState: Sendable, Equatable {
    /// Allocentric position (see `SpatialSpeaker`). Ignored for beds and LFE.
    var position: SIMD3<Float> = SIMD3(0.5, 0.5, 0)
    /// Linear gain.
    var gain: Float = 1
}

/// A metadata change taking effect partway through a block.
struct ObjectAudioMetadataUpdate: Sendable {
    /// Frame within the block at which the ramp towards the new state starts.
    var frameOffset: Int
    /// Frames over which gains move from their current values to the new ones. 0 jumps.
    var rampFrames: Int
    /// One entry per element, indexed like `ObjectAudioRenderer.roles`. Nil leaves that element
    /// alone, ramp included: encoders restate unchanged elements, and restarting their ramps on
    /// every restatement would stall anything still moving.
    var states: [ObjectAudioElementState?]
}

/// Element gains and positions as `ObjectAudioRenderer.snapshot` reads them, reused across blocks.
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

/// Renders object audio (beds + dynamic objects + metadata) into a `SpatialSpeakerLayout` bed.
///
/// Gains are computed once per metadata update and interpolated linearly across each update's
/// ramp, the way object metadata is defined to be applied. Between updates every element is a
/// constant gain per output channel, which is a single multiply-add over the block.
final class ObjectAudioRenderer {

    let layout: SpatialSpeakerLayout
    private(set) var roles: [ObjectAudioRole]

    /// Every element is a point source at its position, panned over the whole layout.
    private let panner: AllocentricPanner

    /// Per element, per output channel: the gains currently applied, the gains being ramped
    /// towards, and how many frames of that ramp remain.
    private var current: [[Float]]
    private var target: [[Float]]
    private var rampRemaining: [Int]
    private var rampTotal: [Int]
    /// Whether the element has had metadata since the renderer was built or reset. Its first
    /// update is applied as a jump whatever its ramp says: there is no earlier position to ramp
    /// from, and ramping from silence would fade every object in after each seek.
    private var hasMetadata: [Bool]

    /// Each object's latest state, for `snapshot`.
    private var objectStates: [ObjectAudioElementState?]

    private var scratch: [Float] = []
    private var rampScratch: [Float] = []

    init(layout: SpatialSpeakerLayout, roles: [ObjectAudioRole]) {
        self.layout = layout
        self.roles = roles
        panner = AllocentricPanner(layout: layout)
        let channels = layout.channelCount
        current = Array(repeating: [Float](repeating: 0, count: channels), count: roles.count)
        target = current
        rampRemaining = Array(repeating: 0, count: roles.count)
        rampTotal = rampRemaining
        hasMetadata = Array(repeating: false, count: roles.count)
        objectStates = Array(repeating: nil, count: roles.count)
        // Beds and LFE have gains the moment the renderer exists; objects wait for metadata and are
        // silent until their first update, rather than guessing at a position. The TrueHD decoder
        // holds the blocks before that update and gives the first of them its state at frame 0
        // (`ObjectMetadataHold`), so after a reset that wait costs nothing audible.
        for (index, role) in roles.enumerated() where role != .object {
            staticGains(for: role, state: ObjectAudioElementState(), into: &current[index])
            target[index] = current[index]
        }
    }

    /// Forget every ramp and object position: the next block starts from the same state a freshly
    /// built renderer would (seeks, producer restarts).
    func reset() {
        for index in roles.indices {
            rampRemaining[index] = 0
            hasMetadata[index] = false
            objectStates[index] = nil
            if roles[index] == .object {
                for c in current[index].indices { current[index][c] = 0 }
            } else {
                // A bed fade cut off by the reset would otherwise stay at the ramp's origin.
                staticGains(for: roles[index], state: ObjectAudioElementState(), into: &current[index])
            }
            target[index] = current[index]
        }
    }

    /// The source skipped audio (a damaged span the decoder resynchronised over). Objects hold where
    /// they are, any ramp stops where it has got to, and each element's next metadata is applied as
    /// a jump: it describes the far side of the gap, and sweeping there from the near side would be
    /// audible motion the programme never had.
    func markDiscontinuity() {
        for index in roles.indices {
            if rampRemaining[index] > 0 {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in current[index].indices {
                    current[index][c] += (target[index][c] - current[index][c]) * t
                }
                target[index] = current[index]
                rampRemaining[index] = 0
            }
            hasMetadata[index] = false
        }
    }

    /// Render `frameCount` frames of `inputs` (one plane per role) into `outputs` (one plane per
    /// layout channel, overwritten). `updates` must be sorted by `frameOffset`.
    func render(
        inputs: [UnsafePointer<Float>],
        frameCount: Int,
        updates: [ObjectAudioMetadataUpdate],
        outputs: [UnsafeMutablePointer<Float>]
    ) {
        for out in outputs { vDSP_vclr(out, 1, vDSP_Length(frameCount)) }
        // A block from a configuration this renderer was not built for renders as silence rather than
        // trapping: the bridge rebuilds on `configurationGeneration`, and a mismatch here is a stream
        // that changed shape without saying so.
        guard inputs.count == roles.count, outputs.count == layout.channelCount else { return }

        var cursor = 0
        var pending = updates[...]
        while cursor < frameCount {
            while let next = pending.first, next.frameOffset <= cursor {
                apply(next)
                pending = pending.dropFirst()
            }
            // Every update at or before `cursor` has been applied, so the next one is strictly later.
            let end = min(frameCount, pending.first?.frameOffset ?? frameCount)
            mix(inputs: inputs, from: cursor, count: end - cursor, outputs: outputs)
            cursor = end
        }
        // Updates stamped at or past the end of the block still take effect, for the next block.
        for update in pending { apply(update) }
    }

    /// Take `frameCount` frames of metadata and ramps forward without mixing any audio: what
    /// `render` does to the gains, for a caller that reads them through `snapshot` instead.
    func advance(frameCount: Int, updates: [ObjectAudioMetadataUpdate]) {
        var cursor = 0
        var pending = updates[...]
        while cursor < frameCount {
            while let next = pending.first, next.frameOffset <= cursor {
                apply(next)
                pending = pending.dropFirst()
            }
            let end = min(frameCount, pending.first?.frameOffset ?? frameCount)
            for index in roles.indices where rampRemaining[index] > 0 {
                rampRemaining[index] -= min(rampRemaining[index], end - cursor)
                if rampRemaining[index] == 0 { current[index] = target[index] }
            }
            cursor = end
        }
        for update in pending { apply(update) }
    }

    /// Every element's gains towards the layout as they stand now (mid-ramp included), and where
    /// it sits: `layoutGains` holds `roles.count` rows of `layout.channelCount`; `positions` is nil
    /// for the LFE and for an object without metadata yet; `gains` is the element gain.
    func snapshot(into snapshot: inout ObjectAudioGainSnapshot) {
        let channels = layout.channelCount
        snapshot.resize(elements: roles.count, channels: channels)
        for index in roles.indices {
            let row = index * channels
            if rampRemaining[index] > 0 {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in 0..<channels {
                    snapshot.layoutGains[row + c] = current[index][c] + (target[index][c] - current[index][c]) * t
                }
            } else {
                for c in 0..<channels { snapshot.layoutGains[row + c] = current[index][c] }
            }
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
            if roles[index] == .object { objectStates[index] = state }
            let jump = update.rampFrames <= 0 || !hasMetadata[index]
            hasMetadata[index] = true
            var gains = [Float](repeating: 0, count: layout.channelCount)
            switch roles[index] {
            case .object:
                panner.pointGains(state.position, into: &gains)
                if state.gain != 1 { for c in gains.indices { gains[c] *= state.gain } }
            case .bed, .lfe, .fixed:
                staticGains(for: roles[index], state: state, into: &gains)
            }
            // A ramp still in flight restarts from where it has got to, not from its origin.
            if rampRemaining[index] > 0, !jump {
                let t = Float(rampTotal[index] - rampRemaining[index]) / Float(rampTotal[index])
                for c in gains.indices {
                    current[index][c] += (target[index][c] - current[index][c]) * t
                }
            }
            target[index] = gains
            if !jump {
                rampRemaining[index] = update.rampFrames
                rampTotal[index] = update.rampFrames
            } else {
                current[index] = gains
                rampRemaining[index] = 0
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

    // MARK: - Mixing

    private func mix(
        inputs: [UnsafePointer<Float>], from start: Int, count: Int, outputs: [UnsafeMutablePointer<Float>]
    ) {
        let n = vDSP_Length(count)
        for index in roles.indices {
            let input = inputs[index] + start
            let ramp = min(rampRemaining[index], count)
            if ramp > 0 {
                if rampScratch.count < count { rampScratch = [Float](repeating: 0, count: count) }
                let total = Float(rampTotal[index])
                let done = Float(rampTotal[index] - rampRemaining[index])
                for c in 0..<layout.channelCount {
                    let from = current[index][c], to = target[index][c]
                    if from == 0 && to == 0 { continue }
                    // Linear per-frame gain: frame i of the ramp (0-based) plays at (i + 1) / total of
                    // the way, so the ramp's last frame lands exactly on the target. Constant after it.
                    var startGain = from + (to - from) * ((done + 1) / total)
                    var step = (to - from) / total
                    let g1 = from + (to - from) * ((done + Float(ramp)) / total)
                    rampScratch.withUnsafeMutableBufferPointer { buf in
                        vDSP_vramp(&startGain, &step, buf.baseAddress!, 1, vDSP_Length(ramp))
                        vDSP_vma(input, 1, buf.baseAddress!, 1, outputs[c] + start, 1, outputs[c] + start, 1,
                                 vDSP_Length(ramp))
                    }
                    if ramp < count {
                        var hold = g1
                        vDSP_vsma(input + ramp, 1, &hold, outputs[c] + start + ramp, 1,
                                  outputs[c] + start + ramp, 1, vDSP_Length(count - ramp))
                    }
                }
                // `current` stays the ramp's origin until it completes; progress lives in rampRemaining.
                rampRemaining[index] -= ramp
                if rampRemaining[index] == 0 { current[index] = target[index] }
            } else {
                for c in 0..<layout.channelCount {
                    var g = current[index][c]
                    if g == 0 { continue }
                    vDSP_vsma(input, 1, &g, outputs[c] + start, 1, outputs[c] + start, 1, n)
                }
            }
        }
    }
}
#endif
