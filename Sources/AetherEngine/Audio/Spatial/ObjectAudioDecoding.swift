// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation

/// One block of decoded object audio, borrowed from the decoder: `planes` stay valid only until the
/// decoder's next `push`, `nextBlock` or `reset`.
struct ObjectAudioDecodedBlock {
    var sampleRate: Int
    var frameCount: Int
    /// Frames of input pushed since the last reset that precede this block's first frame, decodable
    /// or not. After a reset the decoder can only start at a major sync, so the first block of a
    /// session usually starts some way into what it was given; this is how far.
    var inputFrameOffset: Int64
    /// Changes whenever `roles` does, so the renderer can be rebuilt for the new configuration.
    var configurationGeneration: Int
    /// The decoder dropped data before this block (reset, damage, resync). The next metadata is a
    /// complete restatement to apply as a jump, not a continuation of what came before.
    var isDiscontinuity: Bool = false
    var roles: [ObjectAudioRole]
    /// One plane per role, `frameCount` frames each.
    var planes: [UnsafePointer<Float>]
    /// Metadata taking effect inside this block, sorted by frame offset.
    var updates: [ObjectAudioMetadataUpdate]
}

/// A decoder that turns an object-audio bitstream (TrueHD with Atmos, DTS:X) into signals plus the
/// metadata that positions them. Kept separate from the bridge so the bridge's timeline, renderer
/// and encoder handling can be exercised with a synthetic decoder.
protocol ObjectAudioDecoding: AnyObject {
    /// Queue demuxed bytes. Any chunking.
    func push(_ bytes: UnsafeRawBufferPointer) throws
    /// The next complete block, or nil when more input is needed.
    func nextBlock() throws -> ObjectAudioDecodedBlock?
    /// Drop all state; decoding resumes at the next major sync (TrueHD) or frame (DTS:X).
    func reset()
    /// Blocks the decoder still holds back come out of the next `nextBlock` calls as they are, and it
    /// holds nothing more until the next reset. The bridge asks at end of input and before a segment
    /// cut, where that audio belongs.
    func releaseHeldBlocks()
    /// How often the decoder has reset ITSELF after an internal failure. Its input offsets count from
    /// zero again afterwards, so the caller has to re-anchor its timeline.
    var selfResetCount: Int { get }
}

extension ObjectAudioDecoding {
    var selfResetCount: Int { 0 }
    func releaseHeldBlocks() {}
}
#endif
