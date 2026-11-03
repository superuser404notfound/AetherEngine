import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// The demuxer owns at most one timestamp repair, and the two defects it can be need the same
/// handover: take packets over, hand them back in the container's own order, re-anchor on a seek.
/// The protocol is the shape orut34iop proposed on PR #511; only the policies behind it differ.
protocol H264TimestampRepairSession: AnyObject {
    /// True once a verdict has been reached. Until then no consumer may read a timestamp axis off
    /// this demuxer, because the repair may still be about to move it.
    var isDecided: Bool { get }
    /// Ticks the container's own index has to move by to describe the same axis as the packets.
    var decodeTimestampOffset: Int64? { get }
    /// Ticks a delivered keyframe may sit before its index entry once `decodeTimestampOffset` is applied.
    var keyframeAdvanceTicks: Int64 { get }
    /// True when the packet was taken over and must not be emitted yet.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool
    func dequeue() -> UnsafeMutablePointer<AVPacket>?
    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>)
    func endOfStream()
    func noteSeek()
}

extension H264CompositionOffsetRepairSession: H264TimestampRepairSession {}

/// #511: a Matroska writer that hands its block timestamps out in coding order.
///
/// Matroska block timestamps ARE presentation timestamps, by specification, and the format has no
/// composition-offset table to lose. So a file whose slots rise packet by packet while its picture
/// order steps back has not lost anything the way an MP4 without `ctts` has: every presentation slot
/// is still in the file, each one just arrived attached to the picture that was DECODED at that
/// position rather than the one that is DISPLAYED there. Measured on the reporting asset: the first
/// slots are 0, 40, 73, 107, 140 and the decoder emitted them as 0, 73, 107, 140, 40, which is one
/// stepped-back presentation clock per mini-GOP, for the length of the file.
///
/// That makes the repair a permutation and not a reconstruction, and three things follow that the
/// ISO-BMFF case cannot claim.
///
/// The slots keep their own rounding. Nothing here fits a cadence, so a ladder quantized from a
/// fractional frame rate is reproduced exactly rather than to within a tick, and the one slot the
/// reporting asset's writer clamped onto its cluster origin (7 ticks below the 1001/30 lattice its
/// other 59 slots sit on) survives as written. That clamp is also why fitting a lattice would be the
/// wrong tool: the sample window it would have to be read from is 21 slots on the reporting asset's
/// own ladder before one phase reproduces it, and that figure moves with the phase and the cadence
/// rather than being a property of the frame rate (measured over generated ladders: 16 slots at
/// 30000/1001 on phase 0, 28 on phase 7, 50 at 60000/1001). Any of those is most of a GOP.
///
/// The decode timestamps are already right. libavformat derives them from the rising slot ladder, so
/// they are the decode order this stream really has, and the permutation cannot violate `PTS >= DTS`
/// while a picture is at most its own reorder delay behind its slot. Nothing moves them, and nothing
/// moves the container index either, which holds keyframe slots and a keyframe is the first picture
/// of its own sequence.
///
/// And the slot a picture needs is a packet away, not a plan away. A picture coded before the slot it
/// owns waits for the packet that carries that slot, which is the length of the mini-GOP that reorder
/// created: 3 video packets on the reporting asset. Nothing waits for the end of a sequence, so the
/// hold is bounded by the reorder the stream actually has rather than by its GOP length.
enum H264MatroskaSlotPermutation {

    typealias Sample = H264CompositionOffsetRepair.Sample

    /// Video pictures to sample before deciding, and the same held-packet ceilings the ISO-BMFF
    /// sample pays. Streams without an exact whole-tick cadence still exit on their first
    /// stepped-back slot, normally the third packet.
    static let sampleTarget = H264CompositionOffsetRepair.sampleTarget
    static let minimumSamples = H264CompositionOffsetRepair.minimumSamples
    static let sampleByteBudget = H264CompositionOffsetRepair.sampleByteBudget
    static let heldPacketCeiling = H264CompositionOffsetRepair.heldPacketCeiling

    /// How far ahead of itself a picture may be coded before this is not the reorder structure the
    /// repair describes. x264 tops out at 16 B-frames, so twice that is a stream nobody encodes and a
    /// wait nobody should pay.
    static let lookaheadCeiling: Int64 = 32

    private static func timestamp(anchor: Int64, index: Int64, step: Int64) -> Int64? {
        let (offset, productOverflow) = index.multipliedReportingOverflow(by: step)
        let (value, sumOverflow) = anchor.addingReportingOverflow(offset)
        return productOverflow || sumOverflow ? nil : value
    }

    enum Verdict: Equatable, Sendable {
        /// The container presents in display order, which is what the format says it should do.
        case healthy
        /// Not this defect, or not enough evidence to act. Never permutes.
        case inconclusive(String)
        /// Ticks a picture order count advances per displayed picture, measured rather than assumed.
        case permute(pocStep: Int64)
        /// A CFR ladder whose B-picture timestamps were clamped forward onto their decode slots.
        case reconstruct(step: Int64, pocStep: Int64)
    }

    /// Fail-closed decision over the sampled head. Anything unproven returns `.inconclusive`, which
    /// leaves the stream exactly as the container delivered it.
    static func classify(samples: [Sample], videoDelay: Int, nominalStep: Int64? = nil) -> Verdict {
        guard videoDelay > 0, videoDelay <= 16 else {
            return .inconclusive("reorder delay \(videoDelay) outside 1...16")
        }
        let slots = samples.map(\.pts)
        if nominalStep == nil,
           zip(slots, slots.dropFirst()).contains(where: { $1 < $0 }) { return .healthy }
        guard samples.count >= minimumSamples else {
            return .inconclusive("only \(samples.count) sampled pictures")
        }
        guard slots.allSatisfy({ $0 != Int64.min }) else {
            return .inconclusive("presentation slots are not all stated")
        }
        guard let first = samples.first, first.isKeyframe, first.pictureOrderCount == 0 else {
            return .inconclusive("sample does not start on a picture-order origin")
        }
        // Without a picture-order regression the file presents in coding order, which is what a
        // stream with no reordering does, and there is nothing to repair whatever its delay claims.
        let pocs = samples.map(\.pictureOrderCount)
        guard zip(pocs, pocs.dropFirst()).contains(where: { $1 < $0 }) else {
            return .inconclusive("picture order never regresses")
        }
        guard pocs.allSatisfy({ $0 >= 0 }) else { return .inconclusive("negative picture order count") }

        // The step is measured, not assumed: frame coding advances the count by 2, but a stream that
        // uses a different increment stays repairable as long as it is consistent.
        var pocStep: Int64 = 0
        for value in pocs where value > 0 {
            pocStep = H264CompositionOffsetRepair.greatestCommonDivisor(pocStep, value)
        }
        guard pocStep > 0 else { return .inconclusive("picture order does not advance") }

        // The strongest available self-check: the display ranks the permutation would use must be a
        // bijection onto the sampled window. A wrong picture-order step or a stream this arithmetic
        // does not describe collapses two pictures onto one slot, and that is caught here rather than
        // on screen.
        var ranks: Set<Int64> = []
        for poc in pocs {
            guard poc % pocStep == 0 else {
                return .inconclusive("picture order is not a multiple of its step")
            }
            guard ranks.insert(poc / pocStep).inserted else {
                return .inconclusive("two pictures share display rank \(poc / pocStep)")
            }
        }
        // Distinct is not enough. A single picture order that is not on the common step drags the
        // measured step down, and the ranks that follow are then spread over twice the ladder while
        // still being distinct. Ranks have to FILL the window they came from, give or take the
        // pictures still in flight at its ragged edge.
        guard let highest = ranks.max(), let lowest = ranks.min(),
              highest - lowest + 1 <= Int64(samples.count + videoDelay + 1) else {
            return .inconclusive("display ranks do not fill the sampled window")
        }

        // Some Matroska writers preserve most CFR presentation slots but clamp a B picture whose
        // true PTS precedes its synthesized DTS forward onto that DTS. The result has paired duplicate
        // PTS/DTS slots and paired holes: decoded output alternates 0 and 2 frame intervals forever.
        // Reconstruct only when the container's declared rate is an exact whole-tick cadence, every
        // picture-order rank lands either on that lattice or on this precise forward clamp, and at
        // least two clamps corroborate the shape. A VFR ladder, one damaged packet, and #511's
        // coding-order-slot defect all fail closed.
        if let step = nominalStep, step > 0 {
            let anchor = first.pts
            var clamped = 0
            var reconstructable = true
            for (decodeIndex, sample) in samples.enumerated() {
                let rank = sample.pictureOrderCount / pocStep
                guard let expectedPTS = timestamp(anchor: anchor, index: rank, step: step),
                      let expectedDTS = timestamp(
                        anchor: anchor,
                        index: Int64(decodeIndex) - Int64(videoDelay), step: step)
                else {
                    reconstructable = false
                    break
                }
                // A reconstruction that would present a picture before it is decoded describes some
                // other stream, and handing it out would break the decoder instead of the cadence.
                guard expectedPTS >= expectedDTS else {
                    reconstructable = false
                    break
                }
                if sample.pts != expectedPTS {
                    let (forward, overflow) = sample.pts.subtractingReportingOverflow(expectedPTS)
                    guard !overflow, sample.pts == sample.dts, forward == step,
                          !slots.contains(expectedPTS),
                          slots.filter({ $0 == sample.pts }).count == 2 else {
                        reconstructable = false
                        break
                    }
                    clamped += 1
                }
                if sample.dts == Int64.min {
                    guard decodeIndex < videoDelay else {
                        reconstructable = false
                        break
                    }
                } else if sample.dts != expectedDTS {
                    let (forward, overflow) = sample.dts.subtractingReportingOverflow(expectedDTS)
                    guard !overflow, sample.pts != expectedPTS, sample.dts == sample.pts,
                          forward == step else {
                        reconstructable = false
                        break
                    }
                }
            }
            if reconstructable, clamped >= 2 {
                return .reconstruct(step: step, pocStep: pocStep)
            }
        }

        // One stepped-back slot is the container doing its job. `PTS != DTS` proves nothing here:
        // libavformat synthesizes a decode ladder from a rising presentation one just as readily as
        // from a reordered one, which is why the ISO-BMFF eligibility test cannot be reused.
        if zip(slots, slots.dropFirst()).contains(where: { $1 < $0 }) { return .healthy }
        guard !zip(slots, slots.dropFirst()).contains(where: { $1 == $0 }) else {
            return .inconclusive("two pictures share a presentation slot")
        }
        // The muxer invariant, checked on the window before a single packet is moved: a picture may
        // sit at most its own reorder delay behind the slot it owns, or its repaired presentation
        // time would land before the decode time the container states for it.
        for (index, poc) in pocs.enumerated() where Int64(index) - poc / pocStep > Int64(videoDelay) {
            return .inconclusive("picture \(index) is \(Int64(index) - poc / pocStep) slots behind "
                + "its own, past a reorder delay of \(videoDelay)")
        }
        return .permute(pocStep: pocStep)
    }

    struct CFRRewriter {
        let step: Int64
        let pocStep: Int64
        let videoDelay: Int
        private(set) var brokenReason: String?
        private var anchorPTS: Int64?
        private var decodeIndex: Int64 = 0

        // Spelled out: before Swift 6.4 the private stored properties made the memberwise init private (#787).
        init(step: Int64, pocStep: Int64, videoDelay: Int) {
            self.step = step
            self.pocStep = pocStep
            self.videoDelay = videoDelay
        }

        mutating func noteSeek() {
            anchorPTS = nil
            decodeIndex = 0
            brokenReason = nil
        }

        mutating func rewrite(
            pts: Int64, dts: Int64, pictureOrderCount: Int64?, isKeyframe: Bool
        ) -> (pts: Int64, dts: Int64)? {
            guard brokenReason == nil else { return nil }
            if isKeyframe, pictureOrderCount == 0 {
                anchorPTS = nil
                decodeIndex = 0
                if pts != Int64.min { anchorPTS = pts }
            }
            guard let anchorPTS else {
                return nil
            }
            defer { decodeIndex += 1 }
            guard let pictureOrderCount, pictureOrderCount >= 0, pocStep > 0,
                  pictureOrderCount % pocStep == 0 else {
                brokenReason = "a picture carries no usable picture order"
                return nil
            }
            guard let expectedPTS = H264MatroskaSlotPermutation.timestamp(
                    anchor: anchorPTS, index: pictureOrderCount / pocStep, step: step),
                  let expectedDTS = H264MatroskaSlotPermutation.timestamp(
                    anchor: anchorPTS, index: decodeIndex - Int64(videoDelay), step: step)
            else {
                brokenReason = "timestamp reconstruction overflowed"
                return nil
            }
            guard expectedPTS >= expectedDTS else {
                brokenReason = "reconstructed pts=\(expectedPTS) precedes dts=\(expectedDTS)"
                return nil
            }

            let ptsForward = pts.subtractingReportingOverflow(expectedPTS)
            let dtsForward = dts.subtractingReportingOverflow(expectedDTS)
            let unsetDTS = dts == Int64.min
            let ptsFits = pts == expectedPTS
                || (!ptsForward.overflow && ptsForward.partialValue == step)
            let dtsFits = dts == expectedDTS
                || unsetDTS
                || (!dtsForward.overflow && dtsForward.partialValue == step)
            guard ptsFits, dtsFits else {
                brokenReason = "the timestamp ladder changed shape "
                    + "(pts=\(pts)/\(expectedPTS) dts=\(dts)/\(expectedDTS))"
                return nil
            }
            return (expectedPTS, expectedDTS)
        }
    }

    /// One coded video sequence, as the container hands it out. Values only, so the permutation is
    /// testable without FFmpeg.
    struct Sequence {
        let pocStep: Int64
        let videoDelay: Int
        /// Presentation slots in the order they arrived, which for this defect is decode order. The
        /// slot a picture owns is the one at its DISPLAY rank, so this is the whole lookup table.
        private(set) var slots: [Int64] = []
        /// Slot positions already spoken for in this sequence: a rank handed out, or the coding
        /// position of a picture that goes out on its own slot.
        private var claimed: Set<Int64> = []
        private(set) var repairedPictures = 0
        private(set) var unrepairedPictures = 0
        /// A seek leaves the sequence behind; only an IDR starts a new one. A landing that is not one
        /// cannot be placed at all, because a display rank is counted from an origin this reader has
        /// not seen, and inventing that origin is how a picture ends up a whole GOP away from itself.
        private(set) var awaitingSequenceStart = true
        /// Set when the stream stopped being the shape the verdict was reached on. The session then
        /// hands everything back untouched rather than permuting half a sequence.
        private(set) var brokenReason: String?

        init(pocStep: Int64, videoDelay: Int) {
            self.pocStep = pocStep
            self.videoDelay = videoDelay
        }

        mutating func noteSeek() {
            slots.removeAll(keepingCapacity: true)
            claimed.removeAll(keepingCapacity: true)
            awaitingSequenceStart = true
        }

        /// Audit BIT-3: the slots of this sequence no picture has claimed, in display order. When an
        /// IDR closes the sequence these are the only slots the pictures still waiting on it can own;
        /// the next sequence's slots belong to its own pictures.
        func unclaimedSlots() -> [Int64] {
            slots.indices.filter { !claimed.contains(Int64($0)) }.map { slots[$0] }
        }

        /// Records a video picture and returns the display rank whose slot it should carry, or nil
        /// when it has to go out exactly as it arrived. The slot is recorded either way: it belongs
        /// to whichever picture owns this coding position, and that picture may still be coming.
        mutating func admit(
            slot: Int64,
            pictureOrderCount: Int64?,
            isKeyframe: Bool
        ) -> Int64? {
            guard brokenReason == nil else { return nil }
            if isKeyframe, pictureOrderCount == nil {
                // A keyframe whose picture order could not be read may or may not open a sequence,
                // and guessing either way misplaces every picture after it.
                brokenReason = "a keyframe carries no readable picture order"
                return nil
            }
            if isKeyframe, pictureOrderCount == 0 {
                slots = [slot]
                claimed = [0]
                awaitingSequenceStart = false
                repairedPictures += 1
                return 0
            }
            guard !awaitingSequenceStart, let last = slots.last else {
                unrepairedPictures += 1
                return nil
            }
            guard slot > last else {
                brokenReason = "the slot ladder stopped rising"
                return nil
            }
            slots.append(slot)
            let codingIndex = Int64(slots.count - 1)
            guard let pictureOrderCount, pictureOrderCount >= 0,
                  pictureOrderCount % pocStep == 0 else {
                unrepairedPictures += 1
                claimed.insert(codingIndex)
                return nil
            }
            let rank = pictureOrderCount / pocStep
            // Behind its own slot by more than the reorder delay would put the picture before its
            // stated decode time; further ahead than the ceiling is not a mini-GOP any more.
            guard codingIndex - rank <= Int64(videoDelay),
                  rank - codingIndex <= H264MatroskaSlotPermutation.lookaheadCeiling else {
                unrepairedPictures += 1
                claimed.insert(codingIndex)
                return nil
            }
            repairedPictures += 1
            claimed.insert(rank)
            return rank
        }

        /// The slot a display rank owns, once the container has stated it. nil means the packet that
        /// carries it has not arrived yet, and the picture waiting for it waits with it.
        func slot(forRank rank: Int64) -> Int64? {
            guard rank >= 0, rank < Int64(slots.count) else { return nil }
            return slots[Int(rank)]
        }
    }
}

/// Samples the head of a Matroska stream, and from the verdict on, hands each picture the slot its
/// own display rank owns. Every packet is held, not just video, so the interleaving the container
/// chose survives; a picture coded ahead of its slot waits for the packet carrying that slot and the
/// interleave waits with it, which is one mini-GOP and not one sequence.
final class H264MatroskaSlotPermutationSession: H264TimestampRepairSession {

    enum Phase: Equatable { case sampling, permuting, reconstructing, off }

    private struct Entry {
        let packet: UnsafeMutablePointer<AVPacket>
        let isPicture: Bool
        /// Read once per packet, on the way in: the parser is stateful and every picture has to pass
        /// through it exactly once, in order.
        let pictureOrderCount: Int64?
        /// nil for anything that is not a picture of the repaired stream, or for a picture that has
        /// to go out untouched. Both are emitted as soon as they reach the head of the queue.
        var rank: Int64?
    }

    private(set) var phase: Phase = .sampling
    private let streamIndex: Int32
    private let videoDelay: Int
    private let reader: H264PictureOrderReader
    private var samples: [H264CompositionOffsetRepair.Sample] = []
    private var pending: [Entry] = []
    private var ready: [UnsafeMutablePointer<AVPacket>] = []
    private var pendingBytes = 0
    private var sequence: H264MatroskaSlotPermutation.Sequence?
    private var cfrRewriter: H264MatroskaSlotPermutation.CFRRewriter?
    private let nominalStep: Int64?
    private var verdictDescription = "sampling"

    /// nil unless this stream is the shape the defect needs: Matroska, H.264, and a bitstream that
    /// declares reordered pictures. Everything else never sees a parser or a held packet.
    init?(
        containerFormatName: String?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32
    ) {
        let containers = containerFormatName?.split(separator: ",") ?? []
        guard containers.contains("matroska") else { return nil }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              codecpar.pointee.video_delay > 0,
              let reader = H264PictureOrderReader(
                codecParameters: codecpar, timeBase: stream.pointee.time_base)
        else { return nil }
        self.streamIndex = streamIndex
        self.videoDelay = Int(codecpar.pointee.video_delay)
        self.reader = reader
        let rate = stream.pointee.avg_frame_rate.num > 0 && stream.pointee.avg_frame_rate.den > 0
            ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        let numerator = Int64(stream.pointee.time_base.den) * Int64(rate.den)
        let denominator = Int64(stream.pointee.time_base.num) * Int64(rate.num)
        nominalStep = denominator > 0 && numerator > 0 && numerator % denominator == 0
            ? numerator / denominator : nil
    }

    deinit { releasePending() }

    var isDecided: Bool { phase != .sampling }

    /// Always nil, and for the reason the permutation exists: Matroska's index is keyframe slots, a
    /// keyframe is the first picture of its own sequence, and a permutation leaves that slot exactly
    /// where the container wrote it. The index and the packets already describe one axis.
    var decodeTimestampOffset: Int64? { nil }
    var keyframeAdvanceTicks: Int64 { 0 }

    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard phase != .off else { return false }
        let isPicture = packet.pointee.stream_index == streamIndex
        let pictureOrderCount = isPicture ? reader.pictureOrderCount(for: packet) : nil
        if phase == .sampling {
            if isPicture {
                samples.append(
                    H264CompositionOffsetRepair.Sample(
                        dts: packet.pointee.dts,
                        pts: packet.pointee.pts,
                        pictureOrderCount: pictureOrderCount ?? -1,
                        isKeyframe: isKeyframe(packet)
                    )
                )
            }
            append(packet, isPicture: isPicture, pictureOrderCount: pictureOrderCount, rank: nil)
            if samples.count >= H264MatroskaSlotPermutation.sampleTarget
                || pendingBytes >= H264MatroskaSlotPermutation.sampleByteBudget
                || pending.count >= H264MatroskaSlotPermutation.heldPacketCeiling
                || (nominalStep == nil && earlyHealthyVerdict) {
                decide()
            }
            return true
        }
        if phase == .reconstructing {
            if isPicture, var rewriter = cfrRewriter {
                applyCFRRepair(
                    to: packet, pictureOrderCount: pictureOrderCount,
                    using: &rewriter
                )
                cfrRewriter = rewriter
                if let reason = rewriter.brokenReason {
                    verdictDescription = "stopped (\(reason))"
                    EngineLog.emit(
                        "[Demuxer] Matroska H.264 CFR reconstruction stopped on stream "
                        + "\(streamIndex): \(reason)", category: .demux)
                    phase = .off
                    cfrRewriter = nil
                }
            }
            return false
        }
        let rank = isPicture ? admit(packet, pictureOrderCount: pictureOrderCount) : nil
        append(packet, isPicture: isPicture, pictureOrderCount: pictureOrderCount, rank: rank)
        drain()
        return true
    }

    private func append(
        _ packet: UnsafeMutablePointer<AVPacket>,
        isPicture: Bool,
        pictureOrderCount: Int64?,
        rank: Int64?
    ) {
        pending.append(
            Entry(
                packet: packet, isPicture: isPicture,
                pictureOrderCount: pictureOrderCount, rank: rank))
        pendingBytes += Int(max(0, packet.pointee.size))
    }

    private func admit(
        _ packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?
    ) -> Int64? {
        let pictureOrderCount = packet.pointee.pts == Int64.min ? nil : pictureOrderCount
        let keyframe = isKeyframe(packet)
        if keyframe, pictureOrderCount == 0 { settleRanksOfClosingSequence() }
        return sequence?.admit(slot: packet.pointee.pts, pictureOrderCount: pictureOrderCount, isKeyframe: keyframe)
    }

    /// Audit BIT-3: a rank means something only on the ladder it was counted against, and an IDR is
    /// about to replace that ladder. Every held picture still carrying a rank gets its slot from the
    /// closing sequence now: the one its rank owns when the container stated it, else one of the
    /// slots no picture claimed, in display order. Left pending, the lookup answered from the NEW
    /// sequence and two pictures shared one presentation time.
    private func settleRanksOfClosingSequence() {
        guard let sequence, sequence.brokenReason == nil else { return }
        var waiting: [(index: Int, rank: Int64)] = []
        for index in pending.indices {
            guard let rank = pending[index].rank else { continue }
            if let slot = sequence.slot(forRank: rank) {
                pending[index].packet.pointee.pts = slot
            } else {
                waiting.append((index, rank))
            }
            pending[index].rank = nil
        }
        guard !waiting.isEmpty else { return }
        var free = sequence.unclaimedSlots()[...]
        for entry in waiting.sorted(by: { $0.rank < $1.rank }) {
            guard let slot = free.popFirst() else { break }
            pending[entry.index].packet.pointee.pts = slot
        }
    }

    /// Hands out everything at the head of the queue whose slot is known. A picture still waiting for
    /// the packet that carries its slot stops the drain, because the container's order is the one the
    /// demuxer has to deliver.
    private func drain() {
        while let entry = pending.first {
            var placed = true
            if let rank = entry.rank {
                if let slot = sequence?.slot(forRank: rank) {
                    entry.packet.pointee.pts = slot
                } else {
                    placed = false
                }
            }
            guard placed else { break }
            ready.append(entry.packet)
            pendingBytes -= Int(max(0, entry.packet.pointee.size))
            pending.removeFirst()
        }
        // A stream that stopped being the shape the verdict was reached on, or a wait no mini-GOP
        // explains, gives the packets back exactly as they arrived. The judder comes back with them,
        // which is the outcome this file had before the repair existed, and a session that plays is
        // worth more than one that is right up to the packet it stops on.
        if sequence?.brokenReason != nil
            || pending.count >= H264MatroskaSlotPermutation.heldPacketCeiling
            || pendingBytes >= H264MatroskaSlotPermutation.sampleByteBudget {
            let reason = sequence?.brokenReason ?? "the lookahead outgrew its ceiling"
            EngineLog.emit(
                "[Demuxer] #511 Matroska slot permutation stopped on stream \(streamIndex): "
                + "\(reason) (repaired=\(sequence?.repairedPictures ?? 0))",
                category: .demux)
            verdictDescription = "stopped (\(reason))"
            flushPendingUntouched()
            phase = .off
            sequence = nil
        }
    }

    private func flushPendingUntouched() {
        ready.append(contentsOf: pending.map(\.packet))
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    /// A well-formed MKV with B-frames proves itself on the packet that steps back, which is normally
    /// the third one. Exact whole-tick CFR candidates keep sampling so duplicate slots can be checked.
    private var earlyHealthyVerdict: Bool {
        guard samples.count >= 2 else { return false }
        let last = samples[samples.count - 1]
        let previous = samples[samples.count - 2]
        return last.pts != Int64.min && previous.pts != Int64.min && last.pts < previous.pts
    }

    private func decide() {
        let verdict = H264MatroskaSlotPermutation.classify(
            samples: samples, videoDelay: videoDelay, nominalStep: nominalStep)
        switch verdict {
        case .permute(let pocStep):
            verdictDescription = "permute pocStep=\(pocStep)"
            phase = .permuting
            sequence = H264MatroskaSlotPermutation.Sequence(
                pocStep: pocStep, videoDelay: videoDelay)
            EngineLog.emit(
                "[Demuxer] #511 Matroska H.264 slots in coding order confirmed on stream "
                + "\(streamIndex): \(verdictDescription) samples=\(samples.count) "
                + "slots=\(samples.first?.pts ?? 0)...\(samples.last?.pts ?? 0)",
                category: .demux)
            // The sample is re-read through the permutation so the packets it held leave on the same
            // axis as everything after them. Their picture orders were read on the way in: the parser
            // is stateful and must see each picture exactly once.
            for index in pending.indices where pending[index].isPicture {
                let entry = pending[index]
                // Bound first: admitting an IDR settles the ranks already held in `pending`.
                let rank = admit(entry.packet, pictureOrderCount: entry.pictureOrderCount)
                pending[index].rank = rank
            }
            drain()
        case .reconstruct(let step, let pocStep):
            verdictDescription = "reconstruct step=\(step) pocStep=\(pocStep)"
            phase = .reconstructing
            var rewriter = H264MatroskaSlotPermutation.CFRRewriter(
                step: step, pocStep: pocStep, videoDelay: videoDelay)
            for entry in pending where entry.isPicture {
                applyCFRRepair(
                    to: entry.packet, pictureOrderCount: entry.pictureOrderCount,
                    using: &rewriter
                )
            }
            cfrRewriter = rewriter
            flushPendingUntouched()
            EngineLog.emit(
                "[Demuxer] Matroska H.264 clamped CFR timestamps confirmed on stream "
                + "\(streamIndex): \(verdictDescription) samples=\(samples.count)",
                category: .demux)
        case .healthy:
            verdictDescription = "healthy"
            disarm()
        case .inconclusive(let reason):
            verdictDescription = "inconclusive (\(reason))"
            EngineLog.emit(
                "[Demuxer] #511 Matroska slot probe on stream \(streamIndex) left the stream "
                + "untouched: \(reason) (samples=\(samples.count))",
                category: .demux)
            disarm()
        }
        samples.removeAll(keepingCapacity: false)
    }

    private func disarm() {
        phase = .off
        flushPendingUntouched()
        sequence = nil
    }

    private func isKeyframe(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
    }

    /// EOF during sampling or with pictures still waiting for a slot that is not coming. Both have to
    /// resolve now or the held packets would never be delivered.
    func endOfStream() {
        if phase == .sampling { decide() }
        flushPendingUntouched()
    }

    func noteSeek() {
        // The held packets belong to the position that was abandoned, in EVERY phase and in BOTH
        // queues: a settled verdict leaves its sample behind and `dequeue()` hands that out ahead of
        // anything read after the seek, which republishes pictures a producer has already emitted.
        releasePending()
        reader.reset()
        if phase == .sampling { samples.removeAll(keepingCapacity: true) }
        sequence?.noteSeek()
        cfrRewriter?.noteSeek()
    }

    private func releasePending() {
        for packet in pending.map(\.packet) + ready {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        pending.removeAll(keepingCapacity: true)
        ready.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>) {
        ready.insert(packet, at: 0)
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        ready.isEmpty ? nil : ready.removeFirst()
    }

    var summary: String {
        "phase=\(phase) verdict=\(verdictDescription) "
            + "repaired=\(sequence?.repairedPictures ?? 0) "
            + "unrepaired=\(sequence?.unrepairedPictures ?? 0)"
    }

    private func applyCFRRepair(
        to packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?,
        using rewriter: inout H264MatroskaSlotPermutation.CFRRewriter
    ) {
        if let repaired = rewriter.rewrite(
            pts: packet.pointee.pts, dts: packet.pointee.dts,
            pictureOrderCount: pictureOrderCount, isKeyframe: isKeyframe(packet)) {
            packet.pointee.pts = repaired.pts
            packet.pointee.dts = repaired.dts
        }
    }
}
