import Foundation

/// Custom byte source for `AetherEngine.load(source:)`. Use for memory buffers, encrypted containers, or anything not a plain URL. `read`/`seek` run on the engine's demux thread (not main); `close()` is called exactly once at teardown, never between probe and playback. The engine wraps every call into a reader in an autorelease pool, so a reader is free to use Foundation APIs that hand back autoreleased objects (`FileHandle`, `NSData`) without stranding one per read on a pump thread that runs for the length of the session.
public protocol IOReader: AnyObject, Sendable {
    /// Read up to `size` bytes into `buffer`. Return bytes read, `0` on EOF, or negative on error. The `buffer` optional reflects the C import convention; the engine never passes nil.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32

    /// Reposition the source. `whence`: `SEEK_SET`/`SEEK_CUR`/`SEEK_END` or `AVSEEK_SIZE` (65536, return total size without moving). Return new absolute position or negative on error/unsupported direction. Forward-only sources (AVIO live streams) are supported on the software path only.
    func seek(offset: Int64, whence: Int32) -> Int64

    func close()

    /// Unblock a pending `read` so teardown does not hang. Network readers cancel the in-flight request; memory/file readers can leave this as the default no-op. For readers the engine may reload: unblock only, do not invalidate.
    /// Controlled metadata probes also call this concurrently on cancellation/deadline, including during
    /// open and `seek`. Implementations with blocking I/O must promptly interrupt those operations and
    /// handle cancellation racing their start. A no-op implementation cannot provide an interruptible
    /// deadline; the synchronous probe still waits for the reader to return before releasing its state.
    func cancel()

    /// Return an independent reader with its own cursor over the same source for concurrent access (side demuxer, scrub previews). Return nil for one-shot streams; the engine skips that feature. The returned reader is owned and closed by the engine.
    func makeIndependentReader() -> IOReader?

    /// Whether the engine should inspect this custom byte source for an ISO/UDF disc image before
    /// opening it as an ordinary media container. Keep the default for raw disc images. Remote
    /// readers that already know they represent a regular media file can return `false` to avoid
    /// the sparse signature reads performed by disc recognition. Independent readers should
    /// preserve the same value. A `DiscDirectoryReader` is recognized as a disc whatever it returns.
    var discImageProbeEnabled: Bool { get }
}

/// Internal seam for a custom reader that pulls its bytes over the network and counts them, so a
/// session reading through it can report `LiveTelemetry.demuxerBytesFetched` like an `AVIOReader`
/// one does. The engine's own `HTTPDiscIOReader` counts; a host's reader is never asked, and its
/// sessions keep reporting 0 (`AVIOProvider.cumulativeBytesFetched`).
protocol SourceTransferCounting: AnyObject {
    /// Bytes received from the origin since the reader was created.
    var sourceBytesFetched: Int64 { get }
}

/// Internal seam for finite segmented sources whose natural seek axis is time,
/// not a synthetic concatenated byte offset.
protocol TimeSeekableIOReader: IOReader {
    /// Total media duration in seconds, from the source's own manifest.
    var mediaDuration: Double { get }

    /// Reposition to `seconds` of ELAPSED MEDIA TIME (0 = first byte the reader would deliver from a
    /// fresh open), never an absolute container PTS: the caller strips the source's PTS origin first
    /// (`Demuxer.repositionTimeSeekable`). Landing at or before the requested time is the contract;
    /// the demuxer's packet gate drops what precedes the exact target.
    func seek(to seconds: Double) -> Bool

    /// Elapsed media time in front of each of the source's own segments, ascending, starting at 0.
    /// These are the source's declared random-access points: the segment plan is built on them so
    /// every advertised boundary is one the producer's keyframe gate can actually open (AE#268).
    /// Empty when the reader has no segment structure to report.
    var segmentStartTimesSeconds: [Double] { get }
}

extension TimeSeekableIOReader {
    var segmentStartTimesSeconds: [Double] { [] }
}

public extension IOReader {
    func cancel() {}
    func makeIndependentReader() -> IOReader? { nil }
    var discImageProbeEnabled: Bool { true }
}

/// The source AetherEngine loads media from.
public enum MediaSource: Sendable {
    case url(URL)
    /// `formatHint`: optional libavformat demuxer name ("mp4", "matroska", "mpegts"). A known name
    /// skips content probing and opens with exactly that demuxer, so a wrong one fails the open
    /// instead of falling back. nil, or a name libavformat does not know, probes from content.
    case custom(IOReader, formatHint: String? = nil)
}
