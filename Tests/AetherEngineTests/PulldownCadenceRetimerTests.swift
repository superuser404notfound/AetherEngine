// Sodalite#236: film carrying 2:3 pulldown timing is muxed on the 24p grid, and its odd declared
// rate is measured from the packets.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("PulldownCadenceRetimer (Sodalite#236)")
struct PulldownCadenceRetimerTests {
    private static let ms = AVRational(num: 1, den: 1000)
    private static let film = AVRational(num: 24000, den: 1001)

    private func filmGrid() throws -> CFRFrameGrid {
        try #require(CFRFrameGrid.make(sourceTimeBase: Self.ms, frameRate: Self.film, startPts: 0))
    }

    /// Places every packet (decode order) and returns (source ms, output ticks, outcome) in decode order.
    private func run(_ retimer: PulldownCadenceRetimer, pts: [Int64], dts: [Int64?]? = nil)
        -> [(source: Int64, out: Int64, outcome: PulldownCadenceRetimer.Outcome)] {
        pts.enumerated().map { index, p in
            let d: Int64 = dts.flatMap { $0[index] } ?? Int64.min
            let placed = retimer.place(pts: p, dts: d, duration: 0, shift: 0)
            return (p, placed?.pts ?? retimer.grid.rescale(p), retimer.lastOutcome)
        }
    }

    /// Spacings of the output in presentation (source) order.
    private func presentationSpacings(_ placed: [(source: Int64, out: Int64, outcome: PulldownCadenceRetimer.Outcome)]) -> [Int64] {
        let ordered = placed.sorted { $0.source < $1.source }.map(\.out)
        return zip(ordered, ordered.dropFirst()).map { $1 - $0 }
    }

    /// Film stamped on a 59.94 field clock, rounded to Matroska's 1 ms, decode order with B-frames.
    /// `breakEvery` repeats a field count every so many frames, the way an edit breaks the cadence.
    private func pulldownStream(frames: Int, breakEvery: Int? = nil) -> [Int64] {
        var fields = 0
        var count = 3
        var presentation: [Int64] = []
        for k in 0..<frames {
            presentation.append(Int64((Double(fields) * 1001 / 60).rounded()))
            if let breakEvery, k > 0, k % breakEvery == 0 { count = 5 - count }
            fields += count
            count = 5 - count
        }
        return decodeOrder(presentation)
    }

    private func decodeOrder(_ presentation: [Int64]) -> [Int64] {
        stride(from: 0, to: presentation.count, by: 4).flatMap { start -> [Int64] in
            let group = Array(presentation[start..<min(start + 4, presentation.count)])
            return group.count > 1 ? [group.last!] + group.dropLast() : group
        }
    }

    @Test("The reporter's clip lands on exact 1001-tick steps, in order, within a field of its own time")
    func reporterClip() throws {
        let retimer = try #require(PulldownCadenceRetimer(grid: try filmGrid()))
        let placed = run(retimer, pts: Self.clipPts, dts: Self.clipDts)
        let spacings = presentationSpacings(placed)
        #expect(spacings.allSatisfy { $0 > 0 })
        // The first frames fill the window and one edit drops a field; everything else is one frame.
        #expect(spacings.filter { $0 != 1001 }.count <= 20)
        #expect(placed.filter { $0.outcome == .retimed }.count >= 590)
        #expect(placed.allSatisfy { abs($0.out - $0.source * 24) <= 424 })
    }

    @Test("Without the retimer the same clip holds 50 and 33 ms frames")
    func clipIsPulldown() {
        let ordered = Self.clipPts.sorted()
        let spacings = Set(zip(ordered, ordered.dropFirst()).map { $1 - $0 })
        #expect(spacings == [33, 34, 50, 51])
    }

    @Test("Long pulldown with cadence breaks stays ordered and within one field of the source")
    func longPulldownWithBreaks() throws {
        for breakEvery in [nil, 500, 50, 9] as [Int?] {
            let retimer = try #require(PulldownCadenceRetimer(grid: try filmGrid()))
            let placed = run(retimer, pts: pulldownStream(frames: 20_000, breakEvery: breakEvery))
            #expect(presentationSpacings(placed).allSatisfy { $0 > 0 }, "breakEvery=\(String(describing: breakEvery))")
            #expect(placed.allSatisfy { abs($0.out - $0.source * 24) <= 424 })
            #expect(placed.filter { $0.outcome == .passedThrough }.count <= 12)
        }
    }

    @Test("Unbroken pulldown is one frame a step once the first window fills")
    func unbrokenPulldown() throws {
        let retimer = try #require(PulldownCadenceRetimer(grid: try filmGrid()))
        let spacings = presentationSpacings(run(retimer, pts: pulldownStream(frames: 5_000)))
        #expect(spacings.filter { $0 != 1001 }.count <= 24)
    }

    @Test("True 29.97 and 59.94 video is never retimed onto a film grid")
    func videoRatesAreLeftAlone() throws {
        for frameMs in [1001.0 / 30, 1001.0 / 60] {
            let retimer = try #require(PulldownCadenceRetimer(grid: try filmGrid()))
            let pts = decodeOrder((0..<6_000).map { Int64((Double($0) * frameMs).rounded()) })
            #expect(!run(retimer, pts: pts).contains { $0.outcome == .retimed })
        }
    }

    @Test("Constant-rate 23.976 places exactly as CFRFrameGrid does")
    func constantRateMatchesGrid() throws {
        let grid = try filmGrid()
        let retimer = try #require(PulldownCadenceRetimer(grid: grid))
        let pts = decodeOrder((0..<6_000).map { Int64((Double($0) * 1001 / 24).rounded()) })
        for p in pts {
            let placed = retimer.place(pts: p, dts: Int64.min, duration: 42, shift: 0)
            #expect(placed?.pts == grid.place(pts: p, dts: Int64.min, duration: 42, shift: 0)?.pts)
            #expect(retimer.lastOutcome == .gridded)
        }
    }

    @Test("A producer started after a seek retimes from its first frame once the session has seen film")
    func latchCarriesAcrossProducers() throws {
        let latch = PulldownCadenceLatch()
        let first = try #require(PulldownCadenceRetimer(grid: try filmGrid(), latch: latch))
        _ = run(first, pts: Array(Self.clipPts.prefix(100)))
        #expect(latch.isConfirmed)
        let second = try #require(PulldownCadenceRetimer(grid: try filmGrid(), latch: latch))
        // A producer starts at a keyframe: decode index 245 is the clip's second one (10.227 s).
        let tail = Array(Self.clipPts.dropFirst(245).prefix(40))
        #expect(run(second, pts: tail).allSatisfy { $0.outcome == .retimed })
    }

    @Test("Only a 24p grid gets a retimer")
    func onlyFilmGrids() throws {
        let rate = { (num: Int32, den: Int32) in
            CFRFrameGrid.make(sourceTimeBase: Self.ms, frameRate: AVRational(num: num, den: den), startPts: 0)
                .flatMap { PulldownCadenceRetimer(grid: $0) } != nil
        }
        #expect(rate(24000, 1001))
        #expect(rate(24, 1))
        #expect(!rate(30000, 1001))
        #expect(!rate(60000, 1001))
    }

    @Test("A retimed packet's DTS never passes its PTS and its duration is one frame")
    func dtsAndDuration() throws {
        let retimer = try #require(PulldownCadenceRetimer(grid: try filmGrid()))
        for (index, p) in Self.clipPts.enumerated() {
            guard let placed = retimer.place(pts: p, dts: Self.clipDts[index] ?? Int64.min, duration: 50, shift: 0),
                  retimer.lastOutcome == .retimed else { continue }
            #expect(placed.duration == 1001)
            if Self.clipDts[index] != nil { #expect(placed.dts <= placed.pts) }
        }
    }
}

@Suite("SourceFrameRateMeasurement (Sodalite#236)")
struct SourceFrameRateMeasurementTests {
    private let ms = AVRational(num: 1, den: 1000)

    @Test("The reporter's clip declares 20 fps and measures 23.976")
    func reporterClip() {
        let head = Array(PulldownCadenceRetimerTests.clipPts.prefix(SourceFrameRateMeasurement.targetFrames))
        let rate = SourceFrameRateMeasurement.measuredRate(
            declared: AVRational(num: 20, den: 1), videoPts: head, timeBase: ms)
        #expect(rate?.num == 24000 && rate?.den == 1001)
    }

    @Test("A standard declared rate is trusted without measuring")
    func standardRateStands() {
        let pts = PulldownCadenceRetimerTests.clipPts
        #expect(SourceFrameRateMeasurement.measuredRate(
            declared: AVRational(num: 24000, den: 1001), videoPts: pts, timeBase: ms) == nil)
        #expect(SourceFrameRateMeasurement.measuredRate(
            declared: AVRational(num: 25, den: 1), videoPts: pts, timeBase: ms) == nil)
    }

    @Test("24 and 23.976 are told apart over the measured head")
    func filmRatesApart() {
        for (num, den) in [(24, 1), (24000, 1001)] as [(Int32, Int32)] {
            let frame = 1000.0 * Double(den) / Double(num)
            let pts = (0..<SourceFrameRateMeasurement.targetFrames).map { Int64((Double($0) * frame).rounded()) }
            let rate = SourceFrameRateMeasurement.measuredRate(
                declared: AVRational(num: 20, den: 1), videoPts: pts, timeBase: ms)
            #expect(rate?.num == num && rate?.den == den)
        }
    }

    @Test("Too few frames or a rate that is not standard leaves the declared rate alone")
    func inconclusive() {
        let few = (0..<20).map { Int64($0 * 42) }
        #expect(SourceFrameRateMeasurement.measuredRate(
            declared: AVRational(num: 20, den: 1), videoPts: few, timeBase: ms) == nil)
        let odd = (0..<200).map { Int64($0 * 55) }
        #expect(SourceFrameRateMeasurement.measuredRate(
            declared: AVRational(num: 20, den: 1), videoPts: odd, timeBase: ms) == nil)
    }
}

extension PulldownCadenceRetimerTests {
    /// Video packet PTS of the reporter's clip (Sodalite#236, `reba - s01e07 clipped.mkv`), decode order, ms.
    static let clipPts: [Int64] = [
        0, 134, 50, 84, 251, 167, 217, 501, 384, 301, 334, 417, 468, 751, 634, 551, 584, 668, 718, 1001, 885,
        801, 835, 918, 968, 1252, 1135, 1051, 1085, 1168, 1218, 1502, 1385, 1302, 1335, 1418, 1469, 1752,
        1635, 1552, 1585, 1669, 1719, 2002, 1886, 1802, 1836, 1919, 1969, 2253, 2136, 2052, 2086, 2169, 2219,
        2503, 2386, 2303, 2336, 2419, 2470, 2753, 2636, 2553, 2586, 2670, 2720, 3003, 2887, 2803, 2837, 2920,
        2970, 3254, 3137, 3053, 3087, 3170, 3220, 3504, 3387, 3304, 3337, 3420, 3471, 3754, 3637, 3554, 3587,
        3671, 3721, 4004, 3888, 3804, 3838, 3921, 3971, 4255, 4138, 4054, 4088, 4171, 4221, 4505, 4388, 4305,
        4338, 4421, 4472, 4755, 4638, 4555, 4588, 4672, 4722, 5005, 4889, 4805, 4839, 4922, 4972, 5256, 5139,
        5055, 5089, 5172, 5222, 5506, 5389, 5306, 5339, 5422, 5473, 5756, 5639, 5556, 5589, 5673, 5723, 6006,
        5890, 5806, 5840, 5923, 5973, 6257, 6140, 6056, 6090, 6173, 6223, 6507, 6390, 6307, 6340, 6423, 6474,
        6640, 6557, 6590, 6891, 6757, 6674, 6724, 6807, 6841, 7141, 7007, 6924, 6974, 7057, 7091, 7258, 7174,
        7224, 7558, 7391, 7308, 7341, 7424, 7475, 7508, 7758, 7641, 7591, 7675, 7725, 8058, 7892, 7808, 7842,
        7925, 7975, 8008, 8259, 8142, 8092, 8175, 8225, 8392, 8309, 8342, 8642, 8509, 8425, 8476, 8559, 8592,
        8893, 8759, 8676, 8726, 8809, 8843, 9143, 9009, 8926, 8976, 9059, 9093, 9393, 9260, 9176, 9226, 9310,
        9343, 9643, 9510, 9426, 9477, 9560, 9593, 9810, 9727, 9677, 9760, 10010, 9894, 9844, 9927, 9977,
        10177, 10094, 10060, 10144, 10227, 10344, 10261, 10311, 10594, 10478, 10394, 10427, 10511, 10561,
        10845, 10728, 10644, 10678, 10761, 10811, 11095, 10978, 10895, 10928, 11011, 11061, 11262, 11178,
        11145, 11228, 11479, 11345, 11312, 11395, 11428, 11729, 11595, 11512, 11562, 11645, 11679, 11979,
        11846, 11762, 11812, 11896, 11929, 12096, 12012, 12062, 12146, 12346, 12229, 12179, 12263, 12313,
        12396, 12596, 12480, 12429, 12513, 12563, 12847, 12730, 12646, 12680, 12763, 12813, 13063, 12930,
        12897, 12980, 13013, 13314, 13180, 13097, 13147, 13230, 13264, 13514, 13397, 13347, 13430, 13481,
        13764, 13647, 13564, 13597, 13681, 13731, 13814, 13848, 14014, 13931, 13898, 13981, 14231, 14098,
        14064, 14148, 14181, 14431, 14315, 14265, 14348, 14398, 14732, 14565, 14482, 14515, 14598, 14648,
        14682, 15015, 14849, 14765, 14815, 14899, 14932, 14982, 15316, 15149, 15065, 15099, 15182, 15232,
        15266, 15583, 15432, 15349, 15399, 15483, 15516, 15549, 15883, 15716, 15633, 15666, 15749, 15799,
        15833, 16133, 16000, 15916, 15966, 16050, 16083, 16217, 16167, 16383, 16300, 16250, 16333, 16550,
        16467, 16417, 16500, 16584, 16667, 16634, 16750, 16717, 16800, 16884, 16834, 16917, 16967, 17001,
        17051, 17134, 17084, 17384, 17251, 17168, 17218, 17301, 17334, 17635, 17501, 17418, 17468, 17551,
        17585, 17751, 17668, 17718, 17885, 17801, 17835, 18135, 18002, 17918, 17968, 18052, 18085, 18252,
        18169, 18219, 18502, 18385, 18302, 18335, 18419, 18469, 18802, 18636, 18552, 18586, 18669, 18719,
        18752, 19003, 18886, 18836, 18919, 18969, 19086, 19053, 19136, 19386, 19253, 19170, 19220, 19303,
        19336, 19637, 19503, 19420, 19470, 19553, 19587, 19887, 19753, 19670, 19720, 19803, 19837, 20137,
        20004, 19920, 19970, 20054, 20087, 20387, 20254, 20171, 20221, 20304, 20337, 20638, 20504, 20421,
        20471, 20554, 20588, 20888, 20754, 20671, 20721, 20804, 20838, 21138, 21005, 20921, 20971, 21055,
        21088, 21388, 21255, 21172, 21222, 21305, 21338, 21639, 21505, 21422, 21472, 21555, 21589, 21889,
        21755, 21672, 21722, 21805, 21839, 22139, 22006, 21922, 21972, 22056, 22089, 22389, 22256, 22173,
        22223, 22306, 22339, 22640, 22506, 22423, 22473, 22556, 22590, 22756, 22673, 22723, 22890, 22806,
        22840, 23140, 23007, 22923, 22973, 23057, 23090, 23390, 23257, 23174, 23224, 23307, 23340, 23474,
        23424, 23507, 23757, 23641, 23557, 23591, 23674, 23724, 24008, 23891, 23807, 23841, 23924, 23974,
        24258, 24141, 24058, 24091, 24175, 24225, 24341, 24308, 24508, 24425, 24391, 24475, 24642, 24558,
        24592, 24842, 24725, 24675, 24758, 24808, 25009, 24925, 24892, 24975, 25142, 25059, 25092, 25259,
        25176, 25226
    ]

    /// The DTS libavformat derives for the same packets (nil where it has none).
    static let clipDts: [Int64?] = [
        nil, nil, 0, 50, 84, 134, 167, 217, 251, 301, 334, 384, 417, 468, 501, 551, 584, 634, 668, 718, 751,
        801, 835, 885, 918, 968, 1001, 1051, 1085, 1135, 1168, 1218, 1252, 1302, 1335, 1385, 1418, 1469,
        1502, 1552, 1585, 1635, 1669, 1719, 1752, 1802, 1836, 1886, 1919, 1969, 2002, 2052, 2086, 2136, 2169,
        2219, 2253, 2303, 2336, 2386, 2419, 2470, 2503, 2553, 2586, 2636, 2670, 2720, 2753, 2803, 2837, 2887,
        2920, 2970, 3003, 3053, 3087, 3137, 3170, 3220, 3254, 3304, 3337, 3387, 3420, 3471, 3504, 3554, 3587,
        3637, 3671, 3721, 3754, 3804, 3838, 3888, 3921, 3971, 4004, 4054, 4088, 4138, 4171, 4221, 4255, 4305,
        4338, 4388, 4421, 4472, 4505, 4555, 4588, 4638, 4672, 4722, 4755, 4805, 4839, 4889, 4922, 4972, 5005,
        5055, 5089, 5139, 5172, 5222, 5256, 5306, 5339, 5389, 5422, 5473, 5506, 5556, 5589, 5639, 5673, 5723,
        5756, 5806, 5840, 5890, 5923, 5973, 6006, 6056, 6090, 6140, 6173, 6223, 6257, 6307, 6340, 6390, 6423,
        6474, 6507, 6557, 6590, 6640, 6674, 6724, 6757, 6807, 6841, 6891, 6924, 6974, 7007, 7057, 7091, 7141,
        7174, 7224, 7258, 7308, 7341, 7391, 7424, 7475, 7508, 7558, 7591, 7641, 7675, 7725, 7758, 7808, 7842,
        7892, 7925, 7975, 8008, 8058, 8092, 8142, 8175, 8225, 8259, 8309, 8342, 8392, 8425, 8476, 8509, 8559,
        8592, 8642, 8676, 8726, 8759, 8809, 8843, 8893, 8926, 8976, 9009, 9059, 9093, 9143, 9176, 9226, 9260,
        9310, 9343, 9393, 9426, 9477, 9510, 9560, 9593, 9643, 9677, 9727, 9760, 9810, 9844, 9894, 9927, 9977,
        10010, 10060, 10094, 10144, 10177, 10227, 10261, 10311, 10344, 10394, 10427, 10478, 10511, 10561,
        10594, 10644, 10678, 10728, 10761, 10811, 10845, 10895, 10928, 10978, 11011, 11061, 11095, 11145,
        11178, 11228, 11262, 11312, 11345, 11395, 11428, 11479, 11512, 11562, 11595, 11645, 11679, 11729,
        11762, 11812, 11846, 11896, 11929, 11979, 12012, 12062, 12096, 12146, 12179, 12229, 12263, 12313,
        12346, 12396, 12429, 12480, 12513, 12563, 12596, 12646, 12680, 12730, 12763, 12813, 12847, 12897,
        12930, 12980, 13013, 13063, 13097, 13147, 13180, 13230, 13264, 13314, 13347, 13397, 13430, 13481,
        13514, 13564, 13597, 13647, 13681, 13731, 13764, 13814, 13848, 13898, 13931, 13981, 14014, 14064,
        14098, 14148, 14181, 14231, 14265, 14315, 14348, 14398, 14431, 14482, 14515, 14565, 14598, 14648,
        14682, 14732, 14765, 14815, 14849, 14899, 14932, 14982, 15015, 15065, 15099, 15149, 15182, 15232,
        15266, 15316, 15349, 15399, 15432, 15483, 15516, 15549, 15583, 15633, 15666, 15716, 15749, 15799,
        15833, 15883, 15916, 15966, 16000, 16050, 16083, 16133, 16167, 16217, 16250, 16300, 16333, 16383,
        16417, 16467, 16500, 16550, 16584, 16634, 16667, 16717, 16750, 16800, 16834, 16884, 16917, 16967,
        17001, 17051, 17084, 17134, 17168, 17218, 17251, 17301, 17334, 17384, 17418, 17468, 17501, 17551,
        17585, 17635, 17668, 17718, 17751, 17801, 17835, 17885, 17918, 17968, 18002, 18052, 18085, 18135,
        18169, 18219, 18252, 18302, 18335, 18385, 18419, 18469, 18502, 18552, 18586, 18636, 18669, 18719,
        18752, 18802, 18836, 18886, 18919, 18969, 19003, 19053, 19086, 19136, 19170, 19220, 19253, 19303,
        19336, 19386, 19420, 19470, 19503, 19553, 19587, 19637, 19670, 19720, 19753, 19803, 19837, 19887,
        19920, 19970, 20004, 20054, 20087, 20137, 20171, 20221, 20254, 20304, 20337, 20387, 20421, 20471,
        20504, 20554, 20588, 20638, 20671, 20721, 20754, 20804, 20838, 20888, 20921, 20971, 21005, 21055,
        21088, 21138, 21172, 21222, 21255, 21305, 21338, 21388, 21422, 21472, 21505, 21555, 21589, 21639,
        21672, 21722, 21755, 21805, 21839, 21889, 21922, 21972, 22006, 22056, 22089, 22139, 22173, 22223,
        22256, 22306, 22339, 22389, 22423, 22473, 22506, 22556, 22590, 22640, 22673, 22723, 22756, 22806,
        22840, 22890, 22923, 22973, 23007, 23057, 23090, 23140, 23174, 23224, 23257, 23307, 23340, 23390,
        23424, 23474, 23507, 23557, 23591, 23641, 23674, 23724, 23757, 23807, 23841, 23891, 23924, 23974,
        24008, 24058, 24091, 24141, 24175, 24225, 24258, 24308, 24341, 24391, 24425, 24475, 24508, 24558,
        24592, 24642, 24675, 24725, 24758, 24808, 24842, 24892, 24925, 24975, 25009, 25059, 25092, 25142,
        25176
    ]
}
