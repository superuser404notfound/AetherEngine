import AVFAudio
import Foundation

/// One synchronous, read-only borrow of the encoder's reusable PCM storage. Its serial owner
/// cannot mutate that storage until `convert` returns. That lifetime guarantee does not require
/// Sendable input-block invocations to be non-overlapping: the lock protects exactly-once removal
/// of the pending reference even if they overlap. The holder never changes samples and is cleared
/// before the encoder resumes. This does not make arbitrary mutable audio buffers Sendable.
final class APACConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) { pending = buffer }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    func clear() { lock.withLock { pending = nil } }
}
