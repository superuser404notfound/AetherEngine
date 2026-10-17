// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The enhancement-layer restamp on real profile 7 files. One of the test clips codes its EL with B-frames
/// and its BL without, so 2822 of its access units carry an EL picture of another frame
/// (counting from the decoded POCs gives 2823: that also counts the last unit, whose EL is a lone IDR
/// that pairs with its own BL picture but ranks two places off because two EL-less units precede it);
/// the others share one GOP.
@Suite(.offCooperativePoolOneLane)
struct DualLayerPictureAlignmentTests {

    struct Walk {
        var units: [(pts: Int64, el: Int64?)] = []
        var reordered = 0
    }

    static func walk(_ name: String, seekTo seconds: Double? = nil, limit: Int = .max) throws -> Walk {
        let demuxer = Demuxer()
        try demuxer.open(url: DoviFelRealFileTests.url(name))
        defer { demuxer.close() }
        let index = demuxer.videoStreamIndex
        let par = try #require(demuxer.stream(at: index)?.pointee.codecpar?.pointee)
        var alignment = DualLayerPictureAlignment()
        if let ed = par.extradata, par.extradata_size > 23, ed[0] == 1 {
            alignment.seedBaseParameterSets(parseHVCCParameterSets(ed, Int(par.extradata_size)))
        }
        if let seconds {
            try #require(demuxer.seek(to: seconds), "seek failed")
            alignment.reset()
        }
        var out = Walk()
        while out.units.count < limit, let pkt = try demuxer.readPacket() {
            defer { av_packet_unref(pkt); var o: UnsafeMutablePointer<AVPacket>? = pkt; trackedPacketFree(&o) }
            guard pkt.pointee.stream_index == Int32(index), let data = pkt.pointee.data else { continue }
            var hasEL = false
            A53SEIParser.forEachNAL(data, Int(pkt.pointee.size), .lengthPrefixed(size: 4)) { nal, _ in
                if (nal[0] >> 1) & 0x3F == 63 { hasEL = true }
            }
            let el = alignment.enhancementPTS(data, Int(pkt.pointee.size), framing: .lengthPrefixed(size: 4), pts: pkt.pointee.pts)
            out.units.append((pkt.pointee.pts, hasEL ? el : nil))
        }
        out.reordered = alignment.reorderedUnits
        return out
    }

    /// Every restamped EL picture lands on exactly one base-layer picture's time (within 3 ms).
    static func unmatched(_ w: Walk, base basePTS: [Int64]? = nil) -> (missing: Int, shared: Int) {
        let base = (basePTS ?? w.units.map(\.pts)).sorted()
        var used = Set<Int>()
        var missing = 0, shared = 0
        for case let el? in w.units.map(\.el) {
            var lo = 0, hi = base.count
            while lo < hi { let mid = (lo + hi) / 2; if base[mid] < el { lo = mid + 1 } else { hi = mid } }
            let near = [lo - 1, lo].filter { base.indices.contains($0) }.min { abs(base[$0] - el) < abs(base[$1] - el) }
            guard let i = near, abs(base[i] - el) <= 3 else { missing += 1; continue }
            if !used.insert(i).inserted { shared += 1 }
        }
        return (missing, shared)
    }

    /// The two clips whose layers share one GOP, when present.
    static let sharedGOPClips = [
        "fel-clip-b.mkv",
        "fel-clip-c.mp4",
    ].filter(DoviFelRealFileTests.available)

    @Test("an EL coded with B-frames over a BL without is paired by POC",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips))
    func reorderedEnhancementLayer() throws {
        let name = DoviFelRealFileTests.fixtures[0]
        let w = try Self.walk(name)
        #expect(w.reordered == 2822)
        let moved = w.units.compactMap { u in u.el.map { $0 - u.pts } }.filter { $0 != 0 }
        #expect(moved.count == 2822)
        #expect(moved.allSatisfy { abs($0) <= 3 * 42 }, "offsets beyond two frames")
        let m = Self.unmatched(w)
        #expect(m.missing == 0 && m.shared == 0, "\(m)")
    }

    @Test("after a seek the layers realign at the first IRAP",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips))
    func realignsAfterSeek() throws {
        let name = DoviFelRealFileTests.fixtures[0]
        let w = try Self.walk(name, seekTo: 90, limit: 600)
        #expect(w.reordered > 0)
        // Until the EL's first sequence-opening IRAP after the seek, each EL picture keeps its own unit's
        // time (access-unit pairing), and the first restamped pictures can then land on base slots those
        // units already took (on this clip, two). That stretch is short. From the first restamp on, every EL
        // picture lands on exactly one base picture. The last few may belong to base frames past the window.
        let firstRestamp = try #require(w.units.firstIndex { $0.el != nil && $0.el != $0.pts })
        #expect(firstRestamp < 30, "access-unit pairing lasted \(firstRestamp) units")
        #expect(w.units.prefix(firstRestamp).allSatisfy { $0.el == nil || $0.el == $0.pts })
        let realigned = Walk(units: Array(w.units[firstRestamp...].dropLast(3)), reordered: 0)
        let m = Self.unmatched(realigned, base: w.units.map(\.pts))
        #expect(m.missing == 0 && m.shared == 0, "\(m)")
        // That clip's EL opens a sequence roughly every 100 units, so by the second half of the window it has
        // realigned: from there each stamp is the one an unbroken walk from the start gives the same unit.
        let linear = Dictionary(try Self.walk(name).units.map { ($0.pts, $0.el) }, uniquingKeysWith: { a, _ in a })
        let late = w.units.dropFirst(300).dropLast(3)
        #expect(late.count > 200, "too few units left to compare")
        let differing = late.filter { linear[$0.pts] != .some($0.el) }.count
        #expect(differing == 0, "\(differing) of \(late.count) units stamped unlike the linear walk")
    }

    @Test("layers with one GOP keep their access unit's time",
          .enabled(if: !DualLayerPictureAlignmentTests.sharedGOPClips.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DualLayerPictureAlignmentTests.sharedGOPClips)
    func sharedGOPUntouched(name: String) throws {
        let w = try Self.walk(name)
        #expect(w.units.contains { $0.el != nil }, "no EL found")
        #expect(w.reordered == 0)
        #expect(w.units.allSatisfy { $0.el == nil || $0.el == $0.pts })
    }

    @Test("extrapolating from crafted timestamps declines instead of trapping")
    func extremeTimestampsDoNotOverflow() {
        // Ordinary case still extrapolates: 10 ticks per slot, three slots ahead.
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, 0), latest: (4, 40), slot: 7) == 70)

        let big = Int64.max
        let small = Int64.min + 1
        // latest.pts - origin.pts overflows.
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, small), latest: (4, big), slot: 6) == nil)
        // The slot distances overflow.
        #expect(DualLayerPictureAlignment.extrapolate(origin: (Int.min, 0), latest: (Int.max, 10), slot: 0) == nil)
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, 0), latest: (1, 10), slot: Int.min) == nil)
        // The extrapolated offset does not fit an Int64, and neither does the sum.
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, 0), latest: (1, big / 2), slot: Int.max) == nil)
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, 0), latest: (1, big - 5), slot: 3) == nil)
        // Time running backwards or standing still has no rate to extrapolate.
        #expect(DualLayerPictureAlignment.extrapolate(origin: (0, 100), latest: (4, 40), slot: 6) == nil)
        #expect(DualLayerPictureAlignment.extrapolate(origin: (3, 0), latest: (3, 40), slot: 6) == nil)
    }
}
#endif
