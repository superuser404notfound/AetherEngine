// Only with the TrueHDObjectAudio or DTSXObjectAudio trait: the renderer is not built without one.
#if TrueHDObjectAudio || DTSXObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// After a seek the TrueHD decoder returns blocks before the stream's first object metadata. Rendered
/// as they came, every object in them was silent; the hold plays them at the first metadata's state.
@Suite("Object audio before the first metadata after a reset")
struct ObjectMetadataHoldTests {

    /// Synthetic decoded blocks: one LFE and one object plane, each frame holding its block number.
    final class Blocks {
        private var buffers: [UnsafeMutablePointer<Float>] = []
        deinit { buffers.forEach { $0.deallocate() } }

        func block(_ number: Int, frames: Int = 40, roles: [ObjectAudioRole] = [.lfe, .object],
                   generation: Int = 1, updateAt: Int? = nil) -> ObjectAudioDecodedBlock {
            let planes: [UnsafePointer<Float>] = roles.map { _ in
                let plane = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                plane.initialize(repeating: Float(number), count: frames)
                buffers.append(plane)
                return UnsafePointer(plane)
            }
            let updates = updateAt.map {
                [ObjectAudioMetadataUpdate(frameOffset: $0, rampFrames: 1536, states: [nil, Self.state])]
            } ?? []
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: frames, inputFrameOffset: Int64(number * frames),
                configurationGeneration: generation, roles: roles, planes: planes, updates: updates)
        }

        static let state = ObjectAudioElementState(position: SIMD3(0, 0, 1))
    }

    /// The released copies, which own the planes their blocks point into, and those blocks.
    private func drain(_ hold: ObjectMetadataHold) -> (copies: [ObjectMetadataHold.Copy], blocks: [ObjectAudioDecodedBlock]) {
        var copies: [ObjectMetadataHold.Copy] = []
        while let copy = hold.nextReleased() { copies.append(copy) }
        return (copies, copies.map(\.block))
    }

    private func firstStates(_ block: ObjectAudioDecodedBlock) -> [ObjectAudioElementState?]? {
        block.updates.isEmpty ? nil : [nil, Blocks.state]
    }

    @Test("blocks before the first metadata are held, then released in order with its state from frame 0")
    func heldUntilMetadata() throws {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        for n in 0..<3 { #expect(hold.admit(blocks.block(n), firstStates: nil) == nil) }
        #expect(hold.nextReleased() == nil)
        let carrier = blocks.block(3, updateAt: 23)
        #expect(hold.admit(carrier, firstStates: firstStates(carrier)) == nil)

        let (copies, out) = drain(hold)
        #expect(out.map(\.inputFrameOffset) == [0, 40, 80, 120])
        #expect(out.map { $0.planes[1][39] } == [0, 1, 2, 3], "audio copied intact")
        withExtendedLifetime(copies) {}
        let prime = try #require(out.first?.updates.first)
        #expect(prime.frameOffset == 0 && prime.rampFrames == 0)
        #expect(prime.states[1] == Blocks.state)
        #expect(out[3].updates.map(\.frameOffset) == [23], "the stream's own update stays where it was")
    }

    @Test("metadata inside the first block still plays the frames before it")
    func primesTheCarrierItself() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        let carrier = blocks.block(0, updateAt: 11)
        #expect(hold.admit(carrier, firstStates: firstStates(carrier)) == nil)
        #expect(drain(hold).blocks.first?.updates.map(\.frameOffset) == [0, 11])
    }

    @Test("once metadata has arrived, blocks pass straight through, uncopied, until the next reset")
    func steadyStatePassesThrough() throws {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        let carrier = blocks.block(0, updateAt: 0)
        _ = hold.admit(carrier, firstStates: firstStates(carrier))
        _ = drain(hold)
        let next = blocks.block(1)
        let passed = try #require(hold.admit(next, firstStates: nil))
        #expect(passed.planes[1] == next.planes[1])

        hold.arm()
        #expect(hold.admit(blocks.block(2), firstStates: nil) == nil, "held again after a reset")
    }

    @Test("a presentation without objects is never held")
    func bedOnlyPassesThrough() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        #expect(hold.admit(blocks.block(0, roles: [.lfe, .bed(.left)]), firstStates: nil) == nil)
        #expect(drain(hold).blocks.count == 1)
        #expect(hold.admit(blocks.block(1, roles: [.lfe, .bed(.left)]), firstStates: nil) != nil)
    }

    @Test("a stream that sends no metadata within the limit is released as it is")
    func releasedWithoutMetadataAtTheLimit() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        let count = ObjectMetadataHold.maxHeldFrames / 40 + 1
        for n in 0..<count { _ = hold.admit(blocks.block(n), firstStates: nil) }
        let out = drain(hold).blocks
        #expect(out.count == count)
        #expect(out.allSatisfy { $0.updates.isEmpty })
    }

    @Test("a new configuration after the first metadata is held again, since its renderer starts without positions")
    func configurationChangeRearms() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        let carrier = blocks.block(0, generation: 1, updateAt: 0)
        _ = hold.admit(carrier, firstStates: firstStates(carrier))
        _ = drain(hold)
        #expect(hold.admit(blocks.block(1, generation: 1), firstStates: nil) != nil)
        #expect(hold.admit(blocks.block(2, generation: 2), firstStates: nil) == nil)
        let next = blocks.block(3, generation: 2, updateAt: 5)
        _ = hold.admit(next, firstStates: firstStates(next))
        let out = drain(hold).blocks
        #expect(out.map(\.inputFrameOffset) == [80, 120])
        #expect(out[0].updates.first?.frameOffset == 0)
    }

    @Test("at the end of input, held blocks go out as they are")
    func endOfInputReleasesHeld() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        for n in 0..<2 { _ = hold.admit(blocks.block(n), firstStates: nil) }
        hold.releaseAll()
        let out = drain(hold).blocks
        #expect(out.map(\.inputFrameOffset) == [0, 40])
        #expect(out.allSatisfy { $0.updates.isEmpty })
    }

    @Test("a release with nothing held keeps the hold armed for the audio after it")
    func emptyReleaseKeepsHolding() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        hold.releaseAll()
        #expect(hold.admit(blocks.block(0), firstStates: nil) == nil, "still held after an empty release")
        #expect(hold.nextReleased() == nil)
    }

    @Test("a configuration change releases what was held for the old one, unprimed")
    func configurationChangeReleasesHeld() {
        let blocks = Blocks(), hold = ObjectMetadataHold()
        _ = hold.admit(blocks.block(0, generation: 1), firstStates: nil)
        let carrier = blocks.block(1, generation: 2, updateAt: 0)
        _ = hold.admit(carrier, firstStates: firstStates(carrier))
        let out = drain(hold).blocks
        #expect(out.map(\.configurationGeneration) == [1, 2])
        #expect(out[0].updates.isEmpty)
        #expect(out[1].updates.first?.frameOffset == 0)
    }
}
#endif
