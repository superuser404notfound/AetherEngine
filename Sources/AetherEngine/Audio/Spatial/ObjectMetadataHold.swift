// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation

/// Holds the blocks an object decoder returns between a reset and the stream's first object metadata.
///
/// After a reset (a seek, a producer restart) TrueHD decoding resumes at the next major sync, but the
/// first OAMD payload follows it only 0 to 38 access units later (up to 32 ms on measured films).
/// The renderer has no position for an object until then, so rendered as they came, those blocks
/// played every object as silence: after a seek the APAC carried the LFE alone for 21 to 24 ms on
/// Nature's Fury. Held here instead, they are released when the payload arrives, the first of them
/// carrying that payload's first state as a jump at frame 0, so they play where the stream puts the
/// objects next. Only blocks with objects are held, at most `maxHeldFrames` of them, and none from the
/// first metadata until the next reset or configuration change, so steady-state blocks pass straight
/// through, uncopied.
final class ObjectMetadataHold {

    /// Payloads come every 1536 frames on measured streams. A stream that sends none this long after
    /// a reset is released as it is, with its objects silent until their metadata, as without the hold.
    static let maxHeldFrames = 4_800

    /// An owned copy of a block, whose planes live as long as it does.
    final class Copy {
        private(set) var block: ObjectAudioDecodedBlock
        private let storage: UnsafeMutablePointer<Float>

        init(_ source: ObjectAudioDecodedBlock) {
            let frames = source.frameCount
            storage = .allocate(capacity: max(1, source.planes.count * frames))
            block = source
            block.planes = source.planes.enumerated().map { channel, plane in
                let copy = storage + channel * frames
                copy.update(from: plane, count: frames)
                return UnsafePointer(copy)
            }
        }

        deinit { storage.deallocate() }

        fileprivate func prepend(_ update: ObjectAudioMetadataUpdate) {
            block.updates.insert(update, at: 0)
        }
    }

    private var armed = true
    private var generation: Int?
    private var held: [Copy] = []
    private var heldFrames = 0
    private var released: [Copy] = []

    /// Hold again from the next block: the decoder was reset.
    func arm() {
        armed = true
        held = []
        heldFrames = 0
        released = []
    }

    /// Takes the decoder's next block. Returns it straight back when nothing is held or queued, and
    /// nil when it was held or queued behind released blocks, which `nextReleased()` then hands out.
    /// `firstStates` is every element's state as of the block's first metadata update, nil when the
    /// block carries no metadata.
    func admit(_ block: ObjectAudioDecodedBlock, firstStates: [ObjectAudioElementState?]?) -> ObjectAudioDecodedBlock? {
        // A new configuration gets a new renderer, which starts without positions as well: what was
        // held for the old one goes out as it is, and the hold starts again.
        if let generation, generation != block.configurationGeneration {
            releaseHeld()
            armed = true
        }
        generation = block.configurationGeneration
        guard armed else {
            if released.isEmpty { return block }
            released.append(Copy(block))
            return nil
        }
        let hasObjects = block.roles.contains(.object)
        held.append(Copy(block))
        heldFrames += block.frameCount
        if hasObjects, let firstStates {
            held[0].prepend(ObjectAudioMetadataUpdate(frameOffset: 0, rampFrames: 0, states: firstStates))
            armed = false
            releaseHeld()
        } else if !hasObjects || heldFrames > Self.maxHeldFrames {
            armed = false
            releaseHeld()
        }
        return nil
    }

    /// End of input or a segment cut: what is held goes out as it is, and nothing more is held until
    /// the next reset. With nothing held it changes nothing, so a cut before the first audio after a
    /// reset leaves the hold armed.
    func releaseAll() {
        guard !held.isEmpty else { return }
        armed = false
        releaseHeld()
    }

    /// The next released block, in decode order.
    func nextReleased() -> Copy? {
        released.isEmpty ? nil : released.removeFirst()
    }

    private func releaseHeld() {
        released += held
        held = []
        heldFrames = 0
    }
}
#endif
