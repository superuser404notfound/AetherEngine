import Foundation

/// What the epoch opening at one segment index left behind, in the two quantities a later reading
/// can ask it for.
///
/// They are the same number on a source whose timestamps start at zero, which is every fixture the
/// AE#418 and AE#481 rounds were measured on, and that is what hid PR #533 for nine rounds: a
/// landing that correctly read "this run has no placement offset left to carry" published a ZERO
/// axis into a session whose bytes carry a 600 s source origin, and the host clock went negative.
///
/// Measured on `tc-cues-lie.mkv` remuxed with `-output_ts_offset 600` (item axis 0-120 s, source
/// 600-720 s), resuming at 53 s: the gate re-aims 9 s and opens `actual=643000 desired=52000
/// pinnedTo=43000 shift=600000 presentedShift=591000`. Both numbers are right and they are 9 s
/// apart, because they answer different questions.
struct EpochAxis: Equatable, Sendable {
    /// What the epoch's FIRST segment shows against its ADVERTISED start. AVPlayer presents a placed
    /// segment at the position the PLAYLIST gives it, not at the tfdt the segment carries (AE#418),
    /// so a gate that opened 9 s below its boundary has that whole run presented 9 s late and this is
    /// the quantity a placement composes with.
    let presented: Double
    /// The source-to-item offset the epoch's BYTES were written with: the producer folded
    /// `pts - carried` into every packet of the run, so a segment it cut on its own boundary maps
    /// item time back onto the source with this and nothing else.
    let carried: Double
    /// AE#412: a re-cut opens below its boundary on purpose and AVPlayer places what it produces at
    /// its own tfdt inside the timeline it is already building (measured 3 of 3 with
    /// `play --picture-probe`, `axisErr` 0.000 at offsets of 1, 5 and 9 s), so it moves the axis by
    /// nothing and its bytes are read on the axis they were written with.
    let isRecut: Bool

    /// How far below its advertised boundary the gate opened. The backoff itself, on any source: the
    /// pin makes `carried` the plan anchor, so the difference drops the source origin out again.
    var gateBackoffSeconds: Double { presented - carried }

    /// What this epoch's first segment adds to AVPlayer's own DISPLACEMENT when AVPlayer places it,
    /// which is the quantity the composition works in. A re-cut adds nothing (AE#412).
    var placedOffset: Double { isRecut ? 0 : gateBackoffSeconds }

    /// The same placement in AXIS terms: what item time has to be read through to reach the source,
    /// for the epoch's OWN index, on a timeline that opened the run at that segment's playlist
    /// position. A re-cut sits at its own tfdt and so maps with the plain normalization; anything
    /// else sits at its advertised start, which is `gateBackoffSeconds` away from it.
    var openingSourceAxis: Double { carried + placedOffset }
}

/// AE#418 round 2: what each stored segment adds to AVPlayer's axis when AVPlayer PLACES it, and
/// what its bytes carry underneath that.
///
/// Only an epoch's FIRST segment can carry a non-zero PLACEMENT offset: a gate that had to open
/// below its boundary puts that much extra content into that one segment, and every segment the
/// epoch cuts after it starts exactly on its boundary. Keyed by index rather than kept as one pair,
/// because several epochs can leave such a segment in the cache at once; an epoch marching through
/// an index rewrites it axis-true, which is what `record` drops the entries above for.
///
/// The two quantities live in ONE table on purpose. PR #533 arrived as a second dictionary written
/// from the same call site under the same lock with the same pruning rule, which is a pair that has
/// to agree forever and nothing to make it.
struct EpochAxisTable: Equatable, Sendable {
    private var epochs: [Int: EpochAxis] = [:]

    var isEmpty: Bool { epochs.isEmpty }

    /// AE#1095: the epochs that cut segments below `index`, for a session that adopts those segments
    /// and starts its own first producer at `index`.
    func keeping(below index: Int) -> EpochAxisTable {
        var kept = EpochAxisTable()
        kept.epochs = epochs.filter { $0.key < index }
        return kept
    }

    /// AE#1095: a session that adopts parked segments hands AVPlayer a fresh item whose first segment
    /// usually sits inside a run, and only an opening publishes an axis. Measured on a source with a
    /// 600 s origin: without this the reopened clock read -557 s, because nothing published the 600 s
    /// the bytes carry. The segment was cut on its own boundary, so it opens with no backoff. Unlike
    /// `record`, the openings above it stay: each still begins a run of its own.
    mutating func markAdoptedStart(at index: Int) {
        guard epochs[index] == nil, let carried = carried(at: index) else { return }
        epochs[index] = EpochAxis(presented: carried, carried: carried, isRecut: false)
    }

    /// Record what the epoch beginning at `index` left, dropping every entry at or above it: a
    /// producer that starts writing there rewrites those segments on their own boundaries, so an
    /// older epoch's offset must stop being claimed for them.
    ///
    /// AE#448: an epoch worth NOTHING is recorded too, and that is not bookkeeping. Its bytes still
    /// carry the axis in force when AVPlayer places them, and they still take over the stretch from
    /// their own placement upward. Dropping the entry left that stretch to whatever seam sat below
    /// it, which after a backward seek is an older epoch's, so the clock folded a shift the picture
    /// there no longer had.
    mutating func record(_ axis: EpochAxis, at index: Int) {
        epochs = epochs.filter { $0.key < index }
        epochs[index] = axis
    }

    /// AE#448: the table answers "is this an epoch's FIRST segment", asked of one index. Every other
    /// index is cut on its own boundary inside a run that already carries an axis, and has nothing to
    /// say about where that run begins.
    func opening(at index: Int) -> EpochAxis? {
        return epochs[index]
    }

    /// The normalization alone for the bytes holding `index`, which is what an axis measured there has
    /// to be read through to leave AVPlayer's own displacement behind.
    func carried(at index: Int) -> Double? {
        guard let start = epochs.keys.filter({ $0 <= index }).max() else { return nil }
        return epochs[start]?.carried
    }

    /// PR #533: the source-to-item offset the bytes holding `index` were written with, as AVPlayer
    /// presents them on a timeline that opened their run at its own playlist position.
    ///
    /// nil when no epoch at or below `index` was recorded, and that refusal is deliberate: the run's
    /// normalization is then unknown, and the zero this used to fall back to is only ever right on a
    /// source whose timestamps start at zero, which is the defect and not the fix. A landing that
    /// cannot be read leaves the standing axis alone, which is what every session did before AE#481.
    func sourceAxis(at index: Int) -> Double? {
        guard let start = epochs.keys.filter({ $0 <= index }).max(),
              let epoch = epochs[start] else { return nil }
        return start == index ? epoch.openingSourceAxis : epoch.carried
    }
}
