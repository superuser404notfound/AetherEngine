// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation
import simd

/// Speaker gains for a position in the allocentric room cube (see `SpatialSpeaker`).
///
/// Dual-balance panning, the scheme ITU-R BS.2127 specifies for Cartesian ("allocentric") objects
/// and the one Atmos home renderers are built around: the room is a stack of speaker planes (floor,
/// ceiling), each plane a set of rows front to back, each row a set of speakers left to right.
/// A position is balanced between the two planes that bracket its height, then inside each plane
/// between the two rows that bracket its depth, then inside each row between the two speakers that
/// bracket its width. Every balance is constant-power, so the result always has unit power and an
/// object moving across the room never changes loudness.
///
/// Rows and planes are whatever the layout has: a 7.1.2 ceiling is one row, a 5.1 floor has no
/// side row, and a bed with no ceiling at all folds every height onto the floor, which is what a
/// renderer is supposed to do with height content it has nowhere to put.
struct AllocentricPanner: Sendable {

    let layout: SpatialSpeakerLayout
    private let planes: [Plane]
    private let channelCount: Int

    private struct Column: Sendable {
        let x: Float
        let channel: Int
    }

    private struct Row: Sendable {
        let y: Float
        let columns: [Column]  // sorted by x
    }

    private struct Plane: Sendable {
        let z: Float
        let rows: [Row]  // sorted by y
    }

    /// `excluded` removes speakers from consideration (object zone masks). A mask that removes
    /// every positional speaker is ignored, because silencing an object is never what it asks for.
    init(layout: SpatialSpeakerLayout, excluded: Set<SpatialSpeaker> = []) {
        self.layout = layout
        self.channelCount = layout.channelCount
        let usable = layout.speakers.enumerated().filter { !$0.element.isLFE }
        let kept = usable.filter { !excluded.contains($0.element) }
        let speakers = kept.isEmpty ? usable : kept

        var byZ: [Float: [Float: [(Float, Int)]]] = [:]
        for (channel, speaker) in speakers {
            let p = speaker.position
            byZ[p.z, default: [:]][p.y, default: []].append((p.x, channel))
        }
        planes = byZ.keys.sorted().map { z in
            let rows = byZ[z]!.keys.sorted().map { y in
                Row(y: y, columns: byZ[z]![y]!.sorted { $0.0 < $1.0 }.map { Column(x: $0.0, channel: $0.1) })
            }
            return Plane(z: z, rows: rows)
        }
    }

    // MARK: - Point source

    /// Unit-power gains for a point at `p`, written into `gains` (resized to the layout's channel
    /// count, LFE always 0). Coordinates outside the cube are clamped to it.
    func pointGains(_ p: SIMD3<Float>, into gains: inout [Float]) {
        if gains.count != channelCount { gains = [Float](repeating: 0, count: channelCount) }
        for i in gains.indices { gains[i] = 0 }
        accumulatePoint(clamp(p), weight: 1, into: &gains)
    }

    /// Adds `weight` × the point's gains to `gains`. Split out so extent sampling can accumulate
    /// power over many points without allocating.
    private func accumulatePoint(_ p: SIMD3<Float>, weight: Float, into gains: inout [Float]) {
        Self.balance(planes, value: p.z, key: \.z) { plane, planeGain in
            Self.balance(plane.rows, value: p.y, key: \.y) { row, rowGain in
                Self.balance(row.columns, value: p.x, key: \.x) { column, columnGain in
                    gains[column.channel] += weight * planeGain * rowGain * columnGain
                }
            }
        }
    }

    /// Constant-power balance of `value` between the two sorted elements that bracket it. Outside
    /// the range the nearest element takes everything.
    private static func balance<T>(
        _ items: [T], value: Float, key: KeyPath<T, Float>, _ body: (T, Float) -> Void
    ) {
        guard let first = items.first, let last = items.last else { return }
        if items.count == 1 || value <= first[keyPath: key] { body(first, 1); return }
        if value >= last[keyPath: key] { body(last, 1); return }
        var upper = 1
        while items[upper][keyPath: key] < value { upper += 1 }
        let a = items[upper - 1], b = items[upper]
        let lo = a[keyPath: key], hi = b[keyPath: key]
        let t = hi > lo ? (value - lo) / (hi - lo) : 0
        let angle = t * .pi / 2
        body(a, cos(angle))
        body(b, sin(angle))
    }

    // MARK: - Object

    /// Gains for an object: point panning, or power-summed panning over a grid spanning `size` in
    /// every direction (Atmos object size is 0 for a point up to 1 for the whole room), or the single
    /// nearest speaker when the object asks to snap. Unit power in every case.
    func objectGains(position: SIMD3<Float>, size: Float, snap: Bool, into gains: inout [Float]) {
        if gains.count != channelCount { gains = [Float](repeating: 0, count: channelCount) }
        for i in gains.indices { gains[i] = 0 }
        let p = clamp(position)

        if snap, let nearest = nearestChannel(to: p) {
            gains[nearest] = 1
            return
        }
        let extent = min(max(size, 0), 1)
        guard extent > 0.001 else {
            accumulatePoint(p, weight: 1, into: &gains)
            return
        }

        // Power sum over an n³ grid. Squared gains are accumulated in `power` and square-rooted at
        // the end, so overlapping contributions add as uncorrelated energy, not as amplitude.
        let steps = extent < 0.2 ? 3 : 5
        var power = [Float](repeating: 0, count: channelCount)
        var point = [Float](repeating: 0, count: channelCount)
        var samples = 0
        for ix in 0..<steps {
            for iy in 0..<steps {
                for iz in 0..<steps {
                    let offset = SIMD3<Float>(
                        Float(ix) / Float(steps - 1) * 2 - 1,
                        Float(iy) / Float(steps - 1) * 2 - 1,
                        Float(iz) / Float(steps - 1) * 2 - 1) * extent
                    for i in point.indices { point[i] = 0 }
                    accumulatePoint(clamp(p + offset), weight: 1, into: &point)
                    for i in point.indices { power[i] += point[i] * point[i] }
                    samples += 1
                }
            }
        }
        let norm = 1 / Float(samples)
        for i in gains.indices { gains[i] = (power[i] * norm).squareRoot() }
    }

    private func nearestChannel(to p: SIMD3<Float>) -> Int? {
        var best: (channel: Int, distance: Float)?
        for plane in planes {
            for row in plane.rows {
                for column in row.columns {
                    let d = simd_distance_squared(SIMD3(column.x, row.y, plane.z), p)
                    if best == nil || d < best!.distance { best = (column.channel, d) }
                }
            }
        }
        return best?.channel
    }

    private func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(p, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
#endif
