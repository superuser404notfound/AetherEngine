import Foundation
import AetherLibavutil

/// Sodalite#236: film whose timestamps carry the 2:3 pulldown of a 59.94 Hz field clock, muxed onto
/// the 24p frame grid.
///
/// An encode that honours a DVD's soft-telecine flags (StaxRip / DGIndex with VFR timecodes, for
/// one) keeps the film's 23.976 progressive frames but stamps each one with the time its first
/// field would have appeared at 59.94 fields a second: frame durations alternate 3 and 2 fields,
/// 50 and 33 ms, averaging the film's 41.7. On a 23.976 Hz panel a 33 ms frame can fall between two
/// refreshes and never be shown, and whether it does depends on the phase between the video clock and
/// vsync, which every start and seek re-rolls. Measured on the reporter's clip: 25 of 40 phases drop
/// frames, up to every second one, so a pan stutters on one pass and plays clean on the next.
///
/// `CFRFrameGrid` leaves these frames alone on purpose (they lie 8 to 17 ms from a slot, far beyond
/// its one-tick tolerance). This retimer recognises the cadence itself and puts every frame on its
/// nearest 24p slot, so each one is held for exactly one refresh. It acts only while the recent
/// frames really are 2:3 film: every spacing two or three fields long, averaging two and a half.
/// Anything else (true 30p or 60p video, a constant-rate stretch) goes through `CFRFrameGrid.place`
/// as before. A cadence break (an edit that drops or repeats a field) moves the film by one field
/// against the grid; the retimer follows by re-centring, so audio never drifts more than about one
/// field (17 ms) from the source timing.
///
/// Fed in decode order. A frame is only moved where that keeps it strictly between its neighbours
/// in presentation order, checked against every recent placement; otherwise it re-anchors on the
/// frame or, failing that, passes it through untouched.
final class PulldownCadenceRetimer {
    /// What `place` did with the last packet, for the producer's finish-line counters.
    enum Outcome: Equatable { case retimed, gridded, passedThrough }

    let grid: CFRFrameGrid
    private let latch: PulldownCadenceLatch?
    /// One field in output ticks: two fifths of a frame.
    private let field: Double
    /// One source tick in output ticks, the measurement noise every comparison allows for.
    private let sourceTick: Double
    /// Slot 0 of the moving 24p grid, source axis, output ticks.
    private var origin: Int64
    /// Recent packets in decode order: source time and placed time, both source axis, output ticks.
    private var window: [(source: Int64, placed: Int64)] = []
    private var deviations: [Int64] = []
    private(set) var lastOutcome: Outcome = .passedThrough

    static let windowCapacity = 48
    /// Packets at each end of the sorted window left out of the cadence test: decode order leaves
    /// the newest frames' neighbours still to come and the oldest ones' already gone.
    static let windowEdge = 8
    static let minimumSpacings = 8

    /// Nil unless the grid is 24p film (23.976 or 24), the only rate 2:3 pulldown carries.
    init?(grid: CFRFrameGrid, latch: PulldownCadenceLatch? = nil) {
        let rate = Double(grid.outputTimeBase.den) / Double(grid.frameTicks)
        guard abs(rate - 24000.0 / 1001.0) < 0.01 || abs(rate - 24) < 0.01 else { return nil }
        self.grid = grid
        self.latch = latch
        self.field = Double(grid.frameTicks) * 2 / 5
        self.sourceTick = Double(max(grid.rescale(1) - grid.rescale(0), 1))
        self.origin = grid.rescale(grid.originPts)
    }

    /// Same contract as `CFRFrameGrid.place`: item-axis `pts` / `dts` in the source time base, nil
    /// when the packet keeps its own (rescaled) time.
    func place(pts: Int64, dts: Int64, duration: Int64, shift: Int64) -> (pts: Int64, dts: Int64, duration: Int64)? {
        guard pts != Int64.min else {
            lastOutcome = .passedThrough
            return grid.place(pts: pts, dts: dts, duration: duration, shift: shift)
        }
        let unshift = shift == Int64.min ? 0 : shift
        let source = grid.rescale(pts &+ unshift)
        let shiftOut = grid.rescale(unshift)

        if isFilmCadence() {
            latch?.confirm()
            if let placed = retime(source) {
                record(source: source, placed: placed)
                lastOutcome = .retimed
                var outDts = dts
                if dts != Int64.min {
                    outDts = min(slot(for: grid.rescale(dts &+ unshift)) &- shiftOut, placed &- shiftOut)
                }
                return (placed &- shiftOut, outDts, grid.frameTicks)
            }
            record(source: source, placed: source)
            lastOutcome = .passedThrough
            return nil
        }

        let gridded = grid.place(pts: pts, dts: dts, duration: duration, shift: shift)
        record(source: source, placed: gridded.map { $0.pts &+ shiftOut } ?? source)
        lastOutcome = gridded == nil ? .passedThrough : .gridded
        return gridded
    }

    /// The recent frames are 2:3 film: every spacing two or three fields, two and a half on average.
    /// Before the window holds enough, a session that has already seen film says so.
    private func isFilmCadence() -> Bool {
        let lowerEdge = window.count >= Self.windowCapacity ? Self.windowEdge : 0
        let sorted = window.map(\.source).sorted()
        guard sorted.count - lowerEdge - Self.windowEdge > Self.minimumSpacings else {
            return latch?.isConfirmed ?? false
        }
        let times = sorted[lowerEdge..<(sorted.count - Self.windowEdge)]
        var previous: Int64?
        for time in times {
            if let previous {
                let spacing = Double(time - previous)
                guard min(abs(spacing - 2 * field), abs(spacing - 3 * field)) <= sourceTick else { return false }
            }
            previous = time
        }
        let mean = Double(times.last! - times.first!) / Double(times.count - 1)
        return abs(mean - 2.5 * field) <= 0.3 * field
    }

    private func retime(_ source: Int64) -> Int64? {
        let candidate = slot(for: source)
        var placed: Int64?
        if Double(abs(source - candidate)) <= field + sourceTick, keepsOrder(source: source, placed: candidate) {
            placed = candidate
        } else if keepsOrder(source: source, placed: source) {
            origin = source
            deviations.removeAll()
            placed = source
        }
        guard let placed else { return nil }
        deviations.append(source - placed)
        if deviations.count > 8 { deviations.removeFirst() }
        let mean = Double(deviations.reduce(0, +)) / Double(deviations.count)
        if deviations.count >= 4, abs(mean) > field / 2 {
            origin += Int64(mean.rounded())
            deviations.removeAll()
        }
        return placed
    }

    private func slot(for source: Int64) -> Int64 {
        origin &+ CFRFrameGrid.roundedQuotient(source &- origin, grid.frameTicks) &* grid.frameTicks
    }

    /// `placed` keeps this frame strictly on the same side of every recent frame as its source time.
    private func keepsOrder(source: Int64, placed: Int64) -> Bool {
        window.allSatisfy { ($0.source < source) == ($0.placed < placed) && $0.placed != placed }
    }

    private func record(source: Int64, placed: Int64) {
        window.append((source, placed))
        if window.count > Self.windowCapacity { window.removeFirst() }
    }
}

/// Sodalite#236: one per session, so a producer that starts after a seek treats its first frames as
/// film instead of waiting for its own window to fill.
final class PulldownCadenceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed = false

    var isConfirmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return confirmed
    }

    func confirm() {
        lock.lock()
        confirmed = true
        lock.unlock()
    }
}
