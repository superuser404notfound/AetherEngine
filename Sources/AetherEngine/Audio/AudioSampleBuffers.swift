import Foundation
import CoreMedia
import AudioToolbox

/// The CMSampleBuffer the software audio producers hand the renderer: one block of bytes copied out
/// of the caller's storage, stamped at `seconds`.
enum AudioSampleBuffers {

    /// `compressedPacket` describes the bytes as one packet of `sampleCount` (1) samples, which is
    /// how a compressed E-AC-3 or APAC packet goes in; PCM is described per frame and passes
    /// `false`. The bytes are copied, so the caller's packet or scratch buffer may go as soon as
    /// this returns.
    static func make(
        bytes: UnsafeRawBufferPointer, seconds: Double, formatDescription: CMAudioFormatDescription,
        sampleCount: Int, compressedPacket: Bool
    ) -> CMSampleBuffer? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: bytes.count) == noErr else { return nil }
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        var sample: CMSampleBuffer?
        let status = withUnsafeMutablePointer(to: &description) { pointer in
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
                sampleCount: sampleCount, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90_000),
                packetDescriptions: compressedPacket ? pointer : nil, sampleBufferOut: &sample)
        }
        return status == noErr ? sample : nil
    }
}
