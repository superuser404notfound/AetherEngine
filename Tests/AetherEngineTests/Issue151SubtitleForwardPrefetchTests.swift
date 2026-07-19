import Foundation
import Testing
import Libavcodec
@testable import AetherEngine

/// #151 (rrgomes): on direct-play sources the SubtitlePacketStore's forward frontier ends at the
/// producer's read position (park a few segments past AVPlayer's fetch), so the drainer's 60 s
/// forward window is empty in practice and a host-applied ADVANCE sync offset finds no cues, text
/// and bitmap alike. The fix is a subtitle-only forward prefetcher: a third side reader that fills
/// the session packet store up to playhead + subtitleDrainLeadSeconds independently of the
/// producer, parking on the subtitle PTS axis and following seeks via the drain tick's jump
/// detection. The drainer itself is untouched; it already decodes to +60 s once packets exist.
struct Issue151SubtitleForwardPrefetchTests {

    // MARK: - Writer-keyed split-set assembly

    /// The pump and the prefetcher can assemble split-PES PGS display sets for the SAME stream
    /// concurrently. Assembly state must be keyed per writer: a second writer's PCS landing while
    /// the first writer's set is open must not drop or swallow the first writer's segments.
    @Test("pump and prefetch writers assemble split display sets independently")
    func writerKeyedAssemblyIsolation() {
        let store = SubtitlePacketStore()
        let pcsA: [UInt8] = [0x16, 0x00, 0x04, 0xAA, 0xAA, 0xAA, 0xAA]
        let odsA: [UInt8] = [0x15, 0x00, 0x02, 0x0A, 0x0A]
        let pcsB: [UInt8] = [0x16, 0x00, 0x04, 0xBB, 0xBB, 0xBB, 0xBB]
        let odsB: [UInt8] = [0x15, 0x00, 0x02, 0x0B, 0x0B]
        let end: [UInt8] = [0x80, 0x00, 0x00]

        store.harvestChunk(streamIndex: 0, ptsSeconds: 10, durationSeconds: 0, flags: 0,
                           payload: Data(pcsA), assembleSplitDisplaySets: true, writer: .pump)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 20, durationSeconds: 0, flags: 0,
                           payload: Data(pcsB), assembleSplitDisplaySets: true, writer: .prefetch)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(odsA), assembleSplitDisplaySets: true, writer: .pump)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(odsB), assembleSplitDisplaySets: true, writer: .prefetch)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(end), assembleSplitDisplaySets: true, writer: .pump)
        store.harvestChunk(streamIndex: 0, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data(end), assembleSplitDisplaySets: true, writer: .prefetch)

        let entries = store.entries(streamIndex: 0, from: 0, through: 100)
        #expect(entries.count == 2)
        #expect(entries.first?.ptsSeconds == 10)
        #expect(entries.first?.payload == Data(pcsA + odsA + end))
        #expect(entries.last?.ptsSeconds == 20)
        #expect(entries.last?.payload == Data(pcsB + odsB + end))
    }

    /// The default writer stays `.pump` so every existing harvest call keeps its behavior.
    @Test("harvestChunk defaults to the pump writer")
    func defaultWriterIsPump() {
        let store = SubtitlePacketStore()
        store.harvestChunk(streamIndex: 3, ptsSeconds: 5, durationSeconds: 0, flags: 0,
                           payload: Data([0x16, 0x00, 0x01, 0x01]), assembleSplitDisplaySets: true)
        store.harvestChunk(streamIndex: 3, ptsSeconds: nil, durationSeconds: 0, flags: 0,
                           payload: Data([0x80, 0x00, 0x00]), assembleSplitDisplaySets: true,
                           writer: .pump)
        let entries = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(entries.count == 1)
        #expect(entries.first?.ptsSeconds == 5)
    }

    // MARK: - Prefetch read loop pacing

    /// The prefetch loop harvests every routed subtitle packet up to playhead + lead, then PARKS:
    /// nothing past the lead edge may be read while the playhead stands still, and advancing the
    /// playhead resumes the read through EOF.
    @Test("prefetch harvests to the lead edge, parks, resumes on playhead advance")
    func prefetchHarvestsToLeadAndParks() async throws {
        let fixture = MatroskaSubtitleFixture.make(
            durationMs: 130_000,
            events: [(ms: 2_000, durationMs: 1_000),
                     (ms: 30_000, durationMs: 1_000),
                     (ms: 55_000, durationMs: 1_000),
                     (ms: 90_000, durationMs: 1_000),
                     (ms: 120_000, durationMs: 1_000)])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: fixture), formatHint: "matroska")
        defer { demuxer.close() }

        let store = SubtitlePacketStore()
        let playhead = PlayheadBox(0)
        let task = Task {
            await SubtitleForwardPrefetcher.run(
                demuxer: demuxer, store: store,
                streamIndices: [0], assemblyIndices: [],
                leadSeconds: 60, parkPollNanoseconds: 10_000_000,
                playhead: { playhead.current })
        }

        // 2 / 30 / 55 s are inside the lead; 90 s is the packet whose read trips the park.
        let reachedPark = await Self.waitUntil { store.frontier(streamIndex: 0) == 90 }
        #expect(reachedPark, "prefetch never reached the park point (frontier=\(store.frontier(streamIndex: 0) ?? -1))")

        // Parked: the 120 s event must not be read while the playhead stays at 0.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.frontier(streamIndex: 0) == 90,
                "prefetch read past the lead edge while parked (frontier=\(store.frontier(streamIndex: 0) ?? -1))")

        // Advance the playhead: 120 s comes into the lead window, the loop resumes and hits EOF.
        playhead.set(65)
        let harvested = await task.value
        #expect(harvested == 5)
        let pts = store.entries(streamIndex: 0, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(pts == [2, 30, 55, 90, 120])
    }

    /// A vanished playhead provider (engine torn down mid-read) ends the loop instead of spinning.
    @Test("prefetch aborts when the playhead provider returns nil")
    func prefetchAbortsOnNilPlayhead() async throws {
        let fixture = MatroskaSubtitleFixture.make(
            durationMs: 200_000,
            events: [(ms: 1_000, durationMs: 500), (ms: 150_000, durationMs: 500)])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: fixture), formatHint: "matroska")
        defer { demuxer.close() }
        let store = SubtitlePacketStore()
        // The provider serves the initial snapshot (0), then vanishes. Both packets harvest
        // (harvest-then-park, matching the native readers); the 150 s packet trips the park,
        // whose playhead refresh gets nil and must end the loop instead of spinning.
        let provider = ExpiringPlayheadProvider(initial: 0)
        let harvested = await SubtitleForwardPrefetcher.run(
            demuxer: demuxer, store: store,
            streamIndices: [0], assemblyIndices: [],
            leadSeconds: 60, parkPollNanoseconds: 1_000_000,
            playhead: { provider.next() })
        #expect(harvested == 2)
    }

    // MARK: - Engine gating + re-anchor decisions

    @Test("prefetch runs only for VOD sessions with embedded drain targets and a source")
    func gatingRules() {
        #expect(AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: true))
        #expect(!AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: true, hasEmbeddedDrainTargets: true, hasSource: true))
        #expect(!AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: false, hasSource: true))
        #expect(!AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: false))
    }

    /// A drain-tick jump (seek) re-anchors the prefetcher; a fresh selection (no cursor yet) does
    /// not, because the selection path starts it itself; steady decode ticks never restart it.
    @Test("re-anchor fires on a jump with an existing cursor only")
    func reanchorDecision() {
        let jump = SubtitleOverlayDrainer.drainPlan(
            cursor: SubtitleDrainCursor(lastDecodedPts: 10, lastPlayhead: 10),
            playhead: 300, lead: 60, backscan: 15, jumpThreshold: 2.5)
        #expect(AetherEngine.subtitleForwardPrefetchNeedsReanchor(plan: jump, hadCursor: true))
        let fresh = SubtitleOverlayDrainer.drainPlan(
            cursor: nil, playhead: 10, lead: 60, backscan: 15, jumpThreshold: 2.5)
        #expect(!AetherEngine.subtitleForwardPrefetchNeedsReanchor(plan: fresh, hadCursor: false))
        let steady = SubtitleOverlayDrainer.drainPlan(
            cursor: SubtitleDrainCursor(lastDecodedPts: 10, lastPlayhead: 10),
            playhead: 10.5, lead: 60, backscan: 15, jumpThreshold: 2.5)
        #expect(!AetherEngine.subtitleForwardPrefetchNeedsReanchor(plan: steady, hadCursor: true))
    }

    // MARK: - Helpers

    private static func waitUntil(deadlineSeconds: Double = 5,
                                  _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// Returns the initial playhead exactly once, nil on every later call (engine torn down mid-read).
private final class ExpiringPlayheadProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    init(initial: Double) { value = initial }
    func next() -> Double? {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = nil
        return v
    }
}

private final class PlayheadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ v: Double) { value = v }
    var current: Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ v: Double) {
        lock.lock(); value = v; lock.unlock()
    }
}

/// Minimal in-memory Matroska writer, the #145 fixture shape: one S_TEXT/UTF8 subtitle track, one
/// Cluster per event. Sizes are always 8-byte EBML vints so nesting needs no length backpatching.
private enum MatroskaSubtitleFixture {

    private static func vintSize(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) {
            bytes.append(UInt8((n >> shift) & 0xFF))
        }
        return bytes
    }

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        id + vintSize(payload.count) + payload
    }

    private static func uint(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = v
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return bytes
    }

    private static func float64(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) }
    }

    private static func string(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func make(durationMs: Int, events: [(ms: Int, durationMs: Int)]) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3],
                             element([0x42, 0x86], uint(1)) +          // EBMLVersion
                             element([0x42, 0xF7], uint(1)) +          // EBMLReadVersion
                             element([0x42, 0xF2], uint(4)) +          // EBMLMaxIDLength
                             element([0x42, 0xF3], uint(8)) +          // EBMLMaxSizeLength
                             element([0x42, 0x82], string("matroska")) +
                             element([0x42, 0x87], uint(4)) +          // DocTypeVersion
                             element([0x42, 0x85], uint(2)))           // DocTypeReadVersion

        let info = element([0x15, 0x49, 0xA9, 0x66],
                           element([0x2A, 0xD7, 0xB1], uint(1_000_000)) +      // TimestampScale: 1 ms
                           element([0x44, 0x89], float64(Double(durationMs))) +
                           element([0x4D, 0x80], string("aether-#151")) +
                           element([0x57, 0x41], string("aether-#151")))

        var trackFields: [UInt8] = []
        trackFields += element([0xD7], uint(1))          // TrackNumber
        trackFields += element([0x73, 0xC5], uint(1))    // TrackUID
        trackFields += element([0x83], uint(0x11))       // TrackType: subtitle
        trackFields += element([0x9C], uint(0))          // FlagLacing
        trackFields += element([0x86], string("S_TEXT/UTF8"))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], trackFields))

        var clusters: [UInt8] = []
        for event in events.sorted(by: { $0.ms < $1.ms }) {
            var body = element([0xE7], uint(event.ms))   // Cluster Timestamp
            let block: [UInt8] = [0x81, 0x00, 0x00, 0x00] + string("line @\(event.ms)ms")
            body += element([0xA0],                                     // BlockGroup
                            element([0xA1], block) +                    // Block
                            element([0x9B], uint(event.durationMs)))    // BlockDuration
            clusters += element([0x1F, 0x43, 0xB6, 0x75], body)
        }

        let segment = element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters)
        return Data(header + segment)
    }
}
