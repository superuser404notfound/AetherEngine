import Foundation

/// What a live recording is doing. Published by `AetherEngine.recordingState`.
///
/// The two reporting channels are deliberately disjoint: a condition a host can act on BEFORE
/// anything is written is thrown out of `startRecording(to:)`, and a condition that can only be
/// discovered while writing arrives here as `.failed`. One failure is never reported twice.
public enum RecordingState: Sendable, Equatable {
    case idle
    case recording(RecordingProgress)
    case ended(RecordingEndReason)
    case failed(RecordingFailure)
}

/// Progress of a running recording. Republished at 1 Hz, not per packet: a host binding a label to
/// a per-packet publisher would re-render thousands of times a second.
public struct RecordingProgress: Sendable, Equatable {
    public let url: URL
    public let startedAt: Date
    public let bytesWritten: Int64
    public let durationSeconds: Double

    public init(url: URL, startedAt: Date, bytesWritten: Int64, durationSeconds: Double) {
        self.url = url
        self.startedAt = startedAt
        self.bytesWritten = bytesWritten
        self.durationSeconds = durationSeconds
    }
}

/// Why a recording stopped without failing. The file is closed and playable in every case.
public enum RecordingEndReason: Sendable, Equatable {
    /// `stopRecording()`.
    case stoppedByHost
    /// `liveSourceReset` fired, or the host reloaded. A reset can bring back different codecs or a
    /// different program, so the recording ends rather than writing past the seam.
    case sourceReset
    /// `stop()`, or a new `load()`. A recording never outlives its session.
    case sessionEnded
}

/// Why a recording could not start, or could not continue.
public enum RecordingFailure: Sendable, Equatable, Error {
    /// The session's route has no engine-owned byte path. `.remoteBypass` means AVFoundation holds
    /// the source connection and the engine never sees a packet; reload with
    /// `LoadOptions.nativeRemoteHLS = false` to move the session onto the ingest reader.
    case unsupportedRoute(VideoRoute)
    /// The session was not loaded with `LoadOptions(isLive: true)`.
    case notLive
    /// A recording is already running to this URL.
    case alreadyRecording(URL)
    case cannotCreateFile(String)
    case diskFull(bytesWritten: Int64)
    case writeFailed(String)
    /// The writer could not keep up and the queue hit its ceiling. The engine drops the recording
    /// rather than the picture.
    case writeTooSlow(bytesWritten: Int64, queuedBytesDropped: Int64)
    /// Nothing in the source can be stream-copied.
    case noStreamsToCopy
}
