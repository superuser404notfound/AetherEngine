import CoreGraphics
import Foundation

/// Learns a title's `PictureArea` from keyframe stills (Sodalite#118).
///
/// Twelve samples spread over the runtime only catch passages longer than their spacing, about eight
/// minutes on a two-hour film, so a single five-minute IMAX sequence would be missed often and a zoom
/// would crop real picture there. After the first pass the host keeps calling `advance(playhead:)`,
/// which samples one grid point at a time in a window ahead of the playhead. The area only ever
/// grows, so a zoom only ever shrinks, and it shrinks before the wider passage is on screen.
public actor PictureAreaScanner {
    public static let firstPassSamples = 12
    public static let firstPassSpan: ClosedRange<Double> = 0.1...0.9
    public static let lookAheadSpacing: Double = 30
    public static let lookAheadWindow: Double = 180

    private let source: any StillSource
    private let duration: Double
    private let displayAspect: Double
    private let retryDelay: Duration
    private let seed: PictureArea?
    private var readings: [PictureAreaReading] = []
    private var sampledMillis: Set<Int64> = []
    private var samplesAsked = 0
    public private(set) var current: PictureArea?

    public init(source: any StillSource, duration: Double, displayAspect: Double,
                seed: PictureArea? = nil, retryDelay: Duration = .seconds(2)) {
        self.source = source
        self.duration = duration
        self.displayAspect = displayAspect
        self.seed = seed
        self.retryDelay = retryDelay
        self.current = seed
    }

    /// The first estimate, or nil when too few usable frames came back (or the task was cancelled).
    /// A seeded scanner returns its seed without sampling.
    public func firstPass() async -> PictureArea? {
        if seed != nil { return current }
        guard duration.isFinite, duration > 0 else { return nil }
        let start = Date()
        let n = Self.firstPassSamples
        let lo = Self.firstPassSpan.lowerBound, hi = Self.firstPassSpan.upperBound
        var pending = (0..<n).map { duration * (lo + (hi - lo) * Double($0) / Double(n - 1)) }
        while !pending.isEmpty {
            if Task.isCancelled { return nil }
            var yielded: [Double] = []
            for t in pending {
                if Task.isCancelled { return nil }
                if await sample(at: t) == .yielded { yielded.append(t) }
            }
            pending = yielded
            if !pending.isEmpty {
                do { try await Task.sleep(for: retryDelay) } catch { return nil }
            }
        }
        current = recompute()
        log("first pass", elapsed: Date().timeIntervalSince(start))
        return current
    }

    /// Samples at most one grid point ahead of `playhead`. Returns the area when it changed (it can
    /// only widen, or appear once enough usable frames exist), nil otherwise.
    public func advance(playhead: Double) async -> PictureArea? {
        guard current?.isFullFrame != true, duration.isFinite, duration > 0, playhead.isFinite else { return nil }
        let end = min(playhead + Self.lookAheadWindow, duration)
        var k = (playhead / Self.lookAheadSpacing).rounded(.down) + 1
        var target: Double?
        while k * Self.lookAheadSpacing <= end {
            let t = k * Self.lookAheadSpacing
            if !sampledMillis.contains(Self.key(t)) { target = t; break }
            k += 1
        }
        guard let target, await sample(at: target) != .yielded else { return nil }
        let updated = recompute()
        guard let updated, Self.differs(updated, current) else { return nil }
        current = updated
        log("look-ahead at \(Int(target))s", elapsed: nil)
        return updated
    }

    private enum SampleResult { case usable, unusable, yielded }

    private func sample(at t: Double) async -> SampleResult {
        samplesAsked += 1
        switch await source.thumbnailOutcome(at: t, maxWidth: PictureAreaDetector.analysisWidth) {
        case .yielded:
            return .yielded
        case .unavailable:
            sampledMillis.insert(Self.key(t))
            return .unusable
        case .image(let image):
            sampledMillis.insert(Self.key(t))
            guard let reading = PictureAreaDetector.reading(of: image) else { return .unusable }
            readings.append(reading)
            return .usable
        }
    }

    private func recompute() -> PictureArea? {
        guard let seed else { return PictureAreaDetector.combine(readings, displayAspect: displayAspect) }
        guard !readings.isEmpty else { return seed }
        return PictureAreaDetector.combine(rects: [seed.rect] + readings.map(\.rect), displayAspect: displayAspect)
    }

    /// Snapping recomputes a rect from its ratio, so an unchanged union can come back a few ulps off.
    private static func differs(_ a: PictureArea, _ b: PictureArea?) -> Bool {
        guard let b else { return true }
        let e: CGFloat = 0.001
        return abs(a.rect.minX - b.rect.minX) > e || abs(a.rect.minY - b.rect.minY) > e
            || abs(a.rect.maxX - b.rect.maxX) > e || abs(a.rect.maxY - b.rect.maxY) > e
    }

    private static func key(_ t: Double) -> Int64 { Int64((t * 1000).rounded()) }

    private func log(_ what: String, elapsed: TimeInterval?) {
        let area = current.map { a -> String in
            let r = a.rect
            let ratio = a.snappedRatio.map { String(format: "%.2f", $0) } ?? "measured"
            return String(format: "rect=(%.3f,%.3f,%.3f,%.3f) ratio=", r.minX, r.minY, r.width, r.height)
                + (a.isFullFrame ? "full" : ratio)
        } ?? "none"
        let took = elapsed.map { String(format: " took=%.1fs", $0) } ?? ""
        EngineLog.emit("[PictureArea] \(what): samples=\(samplesAsked) usable=\(readings.count) \(area)\(took)",
                       category: .engine)
    }
}
