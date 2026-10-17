// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
#if DEBUG
import Foundation
import Dovi

/// Arms the on-device Dolby Vision consumption test: pins the attached RPU to one captured frame's
/// metadata, optionally toggling back to the live RPU on a fixed period.
///
/// ## What the test proves
/// Everything up to the `CVPixelBuffer` is verified on the host: the attachment is set, it carries
/// the right bytes, it propagates to the `IOSurface`, it survives into the `CMSampleBuffer`. What no
/// host test can reach is the last link: whether the tvOS compositor *reads* it off a client-supplied
/// buffer on the `AVSampleBufferDisplayLayer` path (see `dolby-vision-fel.md §4.1`).
///
/// So: hold the pixels constant and change only the metadata. This substitution happens after the GPU
/// composer has already run and *only* touches the attachment: `rpuCache`, the reshaping
/// coefficients, the composed frame itself are all untouched, so the decoded pixels stay bit-identical
/// whichever phase the toggle is in. Any brightness or saturation shift visible on the panel therefore
/// came from the metadata and nothing else. Pinned to a frame with extreme L1 statistics, the darkest
/// or brightest frame in the title, which `aetherctl dvsurvey` finds, the TV's display mapping is
/// told the wrong thing about the scene and should visibly misjudge it.
///
/// A steady, in-sync 2-second pulse on the panel while the pixels are provably unchanged is the
/// consumption proof. A flat picture across both phases means the attachment is being ignored.
///
/// ## Arming it
/// `AetherEngine.armDolbyVisionPinTest(_:)` from the host app (a debug menu), or `aetherctl play
/// --dv-pin`. Grammar is comma-separated `key:value`, in any order:
///
/// - `darkest:N` / `brightest:N`: watch the first `N` frames, keep the one with the lowest
///   (`darkest`) or highest (`brightest`) L1 `avg_pq`, pin to it. Self-calibrating and robust to
///   starting playback anywhere in the title.
/// - `avgpq<=V` / `avgpq>=V` / `maxpq<=V` / `maxpq>=V`: pin to the first frame whose L1 `avg_pq`
///   or `max_pq` crosses `V` (a 12-bit PQ code). Use when `dvsurvey` has already told you the
///   title's range and you want a specific frame. Gives up after `thresholdScanLimit` frames
///   without a match.
/// - `period:S`: seconds per phase, alternating pinned/live. `period:0` pins permanently. Defaults
///   to 2. A positive value below `minimumPeriod` (a pulse faster than a panel can show) is raised
///   to it, and a value that is not a finite number is ignored.
///
/// `darkest:240,period:2` is the usual starting point: scan ten seconds, pin the
/// darkest frame found, pulse every two seconds.
///
/// Never reachable in Release: the whole file is `#if DEBUG`, and a private-framework-adjacent
/// diagnostic that rewrites what the display sees has no business in a shipping build.
///
/// The state lives in a `DoviPinTest` instance. The engine uses one process-wide instance
/// (`DoviDisplayMetadataDebug.shared`); a test makes its own with a local log sink, so it neither
/// arms the shared one (which every decoder in the process feeds) nor needs `EngineLog.handler`.
final class DoviPinTest: @unchecked Sendable {

    /// Log sink. The default writes to `EngineLog`; it is only ever called with the lock released.
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void = { EngineLog.emit($0, category: .engine) }) {
        self.emit = emit
    }

    /// Shortest phase `period:` may name. Below this the toggle is not visible on a panel anyway, and
    /// a tiny value would only make `elapsed / period` overflow an `Int`.
    static let minimumPeriod: TimeInterval = 0.1

    /// Frames a threshold rule (`avgpq<=V` and friends) scans before it gives up. Without it a value
    /// the title never reaches parses every frame for the rest of the session. 7200 is five minutes
    /// at 24 fps.
    static let thresholdScanLimit = 7200
    /// Longest phase `period:` may name (an hour); beyond it the pulse would never be seen.
    static let maximumPeriod: TimeInterval = 3600

    // MARK: - Configuration

    enum Capture: Equatable {
        /// Scan `frames` attachments, keep the one with the lowest L1 `avg_pq`.
        case darkest(frames: Int)
        /// Scan `frames` attachments, keep the one with the highest L1 `avg_pq`.
        case brightest(frames: Int)
        /// Keep the first frame whose L1 field is at or below this 12-bit PQ code.
        case atMost(Field, UInt16)
        /// Keep the first frame whose L1 field is at or above this 12-bit PQ code.
        case atLeast(Field, UInt16)

        /// Which L1 statistic a threshold rule tests. `avg_pq` anchors the display-mapping curve's
        /// mid-tone and usually has the widest range across a title, so it is the stronger lever;
        /// `max_pq` drives highlight roll-off.
        enum Field: String, Equatable {
            case avgPQ = "avgpq"
            case maxPQ = "maxpq"
        }
    }

    struct Config: Equatable {
        var capture: Capture
        /// Seconds per phase. Zero pins permanently once captured.
        var period: TimeInterval = 2
    }

    /// Arms or disarms the test. Passing `nil` disarms and drops any captured pin.
    func configure(_ config: Config?) {
        lock.lock()
        state = config.map { State(config: $0) }
        lock.unlock()
        if let config {
            emit("dv-pin: armed \(config.capture), period \(config.period)s")
        } else {
            emit("dv-pin: disarmed")
        }
    }

    /// True once a pin has been captured and substitution is live.
    var isPinned: Bool {
        lock.lock(); defer { lock.unlock() }
        return state?.pinned != nil
    }

    /// True while the pin test is armed (scanning or actively substituting).
    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return state != nil
    }

    // MARK: - The substitution

    /// Returns the RPU NAL that should actually be attached to this frame.
    ///
    /// Called on the decode thread for every emitted frame. Returns `nal` unchanged, the only
    /// behaviour that exists in an unarmed build, until a pin has been captured and the toggle is in
    /// its pinned phase.
    func substitute(_ nal: [UInt8]?) -> [UInt8]? {
        // Lines are collected under the lock and emitted after it: a log handler is arbitrary host
        // code, and `EngineLog.emit` must not run while this lock is held.
        var logs: [String] = []
        lock.lock()
        let result = substituteLocked(nal, logs: &logs)
        lock.unlock()
        for line in logs { emit(line) }
        return result
    }

    private func substituteLocked(_ nal: [UInt8]?, logs: inout [String]) -> [UInt8]? {
        guard var st = state else { return nal }

        if st.pinned == nil {
            if let nal { considerForCapture(nal, into: &st) }
            logs.append(contentsOf: st.pendingLogs)
            st.pendingLogs.removeAll()
            if st.isDisarmed {
                state = nil
            } else {
                state = st
            }
            return nal
        }
        defer { state = st }
        guard let pinned = st.pinned else { return nal }

        // A frame with no RPU stays without one. Substituting into a gap would attach metadata to a
        // frame the stream says has none, which is a different bug's symptom, not this test's signal.
        guard nal != nil else { return nil }

        let usePin: Bool
        if st.config.period <= 0 {
            usePin = true
        } else {
            let elapsed = CFAbsoluteTimeGetCurrent() - st.armedAt
            // `period` is clamped to `minimumPeriod` or more when parsed; a `Config` built by hand
            // gets the same floor here, so the division cannot overflow an `Int`.
            let phases = elapsed / max(st.config.period, Self.minimumPeriod)
            usePin = phases.isFinite && Int(phases) % 2 == 1
        }
        if usePin != st.lastPhaseWasPinned {
            st.lastPhaseWasPinned = usePin
            let pinDesc = st.pinnedL1.map { "frame \(st.pinnedSourceIndex), L1 max \($0.max) avg \($0.avg)" } ?? "frame \(st.pinnedSourceIndex)"
            logs.append("dv-pin: phase -> \(usePin ? "PINNED (\(pinDesc))" : "LIVE")")
        }
        return usePin ? pinned : nal
    }

    // MARK: - Capture

    private func considerForCapture(_ nal: [UInt8], into st: inout State) {
        st.scanned += 1
        guard let l1 = Self.parseL1(ofNAL: nal) else {
            st.unparseableCount += 1
            switch st.config.capture {
            case .darkest(let frames), .brightest(let frames):
                if st.scanned >= frames { commit(&st) }
            case .atMost, .atLeast:
                if (st.unparseableCount >= 300 && st.bestL1 == nil) || st.scanned >= Self.thresholdScanLimit {
                    commit(&st)
                }
            }
            return
        }

        func keep() { st.best = nal; st.bestL1 = l1; st.bestIndex = st.scanned - 1 }
        func field(_ f: Capture.Field) -> UInt16 { f == .avgPQ ? l1.avg : l1.max }

        switch st.config.capture {
        case .darkest(let frames):
            if st.bestL1 == nil || l1.avg < st.bestL1!.avg { keep() }
            if st.scanned >= frames { commit(&st) }
        case .brightest(let frames):
            if st.bestL1 == nil || l1.avg > st.bestL1!.avg { keep() }
            if st.scanned >= frames { commit(&st) }
        case .atMost(let f, let v):
            if field(f) <= v { keep(); commit(&st) } else if st.scanned >= Self.thresholdScanLimit { commit(&st) }
        case .atLeast(let f, let v):
            if field(f) >= v { keep(); commit(&st) } else if st.scanned >= Self.thresholdScanLimit { commit(&st) }
        }
    }

    private func commit(_ st: inout State) {
        guard let best = st.best, let l1 = st.bestL1 else {
            let found = st.unparseableCount < st.scanned ? "no frame matching the rule" : "no parseable L1"
            st.pendingLogs.append("dv-pin: scan of \(st.scanned) frame(s) (\(st.unparseableCount) unparseable) found \(found); test not armed")
            st.isDisarmed = true
            return
        }
        st.pinned = best
        st.pinnedL1 = l1
        st.pinnedSourceIndex = st.bestIndex
        st.armedAt = CFAbsoluteTimeGetCurrent()
        st.pendingLogs.append(String(format: "dv-pin: captured frame %d after %d scanned, L1 min %d max %d avg %d (%.1f / %.1f nits max/avg), %d byte NAL; toggling every %.1fs",
                              st.bestIndex, st.scanned, Int(l1.min), Int(l1.max), Int(l1.avg),
                              DoviRpuSurvey.pqCodeToNits(l1.max), DoviRpuSurvey.pqCodeToNits(l1.avg),
                              best.count, st.config.period))
    }

    struct L1: Equatable { let min: UInt16; let max: UInt16; let avg: UInt16 }

    /// L1 statistics out of an `unspec62` NAL. Only called during the capture scan, which ends
    /// after at most `frames` parses; the steady state does no libdovi work per frame.
    private static func parseL1(ofNAL nal: [UInt8]) -> L1? {
        nal.withUnsafeBufferPointer { buf -> L1? in
            guard let base = buf.baseAddress else { return nil }
            guard let rpu = DoviRpuGuard.parse(base, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
            defer { dovi_rpu_free_vdr_dm_data(dm) }
            guard let l1 = dm.pointee.dm_data.level1 else { return nil }
            return L1(min: l1.pointee.min_pq, max: l1.pointee.max_pq, avg: l1.pointee.avg_pq)
        }
    }

    // MARK: - State

    private struct State {
        let config: Config
        var scanned = 0
        var unparseableCount = 0
        var isDisarmed = false
        var best: [UInt8]?
        var bestL1: L1?
        var bestIndex = 0
        var pinned: [UInt8]?
        var pinnedL1: L1?
        var pinnedSourceIndex = 0
        var armedAt: CFAbsoluteTime = 0
        var lastPhaseWasPinned = false
        /// Lines to emit once the lock is released.
        var pendingLogs: [String] = []
    }

    private let lock = NSLock()
    private var state: State?

    // MARK: - Spec

    /// Parses the pin-test grammar above. Returns nil if no capture rule is present, which is what
    /// makes a typo fail loudly-ish (nothing arms) rather than silently pinning something arbitrary.
    static func parse(spec: String) -> Config? {
        var capture: Capture?
        var period: TimeInterval = 2

        for rawField in spec.split(separator: ",") {
            let field = rawField.trimmingCharacters(in: .whitespaces)
            if let v = value(of: field, after: "darkest:"), let n = Int(v) {
                capture = .darkest(frames: max(1, n))
            } else if let v = value(of: field, after: "brightest:"), let n = Int(v) {
                capture = .brightest(frames: max(1, n))
            } else if let v = value(of: field, after: "maxpq<="), let n = UInt16(v) {
                capture = .atMost(.maxPQ, n)
            } else if let v = value(of: field, after: "maxpq>="), let n = UInt16(v) {
                capture = .atLeast(.maxPQ, n)
            } else if let v = value(of: field, after: "avgpq<="), let n = UInt16(v) {
                capture = .atMost(.avgPQ, n)
            } else if let v = value(of: field, after: "avgpq>="), let n = UInt16(v) {
                capture = .atLeast(.avgPQ, n)
            } else if let v = value(of: field, after: "period:"), let s = TimeInterval(v) {
                guard s.isFinite else { continue }
                period = s <= 0 ? 0 : min(max(s, minimumPeriod), maximumPeriod)
            }
        }
        guard let capture else { return nil }
        return Config(capture: capture, period: period)
    }

    private static func value(of field: String, after prefix: String) -> String? {
        guard field.lowercased().hasPrefix(prefix) else { return nil }
        return String(field.dropFirst(prefix.count))
    }
}

/// The engine's process-wide pin test, the one `DoviDisplayMetadata.attach` consults for every frame.
enum DoviDisplayMetadataDebug {
    static let shared = DoviPinTest()

    static func configure(_ config: DoviPinTest.Config?) { shared.configure(config) }
    static var isPinned: Bool { shared.isPinned }
    static var isArmed: Bool { shared.isArmed }
    static func substitute(_ nal: [UInt8]?) -> [UInt8]? { shared.substitute(nal) }
    static func parse(spec: String) -> DoviPinTest.Config? { DoviPinTest.parse(spec: spec) }
}
#endif
#endif
