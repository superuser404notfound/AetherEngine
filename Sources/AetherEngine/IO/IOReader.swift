import Foundation

/// A custom byte source the engine can demux from, in place of a URL.
///
/// Implement this to play media from memory buffers, encrypted-at-rest
/// containers, proprietary archives, or anything else that is not a
/// plain `file://` / `http(s)://` URL. Pass an instance via
/// `MediaSource.custom(_:formatHint:)` to `AetherEngine.load(source:)`.
///
/// Threading: `read` and `seek` are called synchronously on the engine's
/// demux thread (NOT the main thread). Implementations must be safe to
/// call off-main; the `Sendable` conformance is enforced at compile time.
///
/// Lifecycle: the engine owns the bridging `AVIOContext`; you own this
/// object. `close()` is called exactly once, at final teardown. It is
/// never called between the engine's internal probe and playback opens.
public protocol IOReader: AnyObject, Sendable {
    /// Read up to `size` bytes into `buffer`. Return the number of bytes
    /// read, `0` on EOF, or a negative value on error. `buffer` is owned
    /// by the engine and is valid only for the duration of the call.
    /// The engine never passes a nil `buffer`; the optional type reflects the
    /// C import convention. Implementations may write to it without a nil-check.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32

    /// Reposition the source. `whence` is one of `SEEK_SET`, `SEEK_CUR`,
    /// `SEEK_END`, or `AVSEEK_SIZE (65536)` (return the total size, do not move).
    /// Return the new absolute position, or a negative value on error.
    /// A negative return signals either an I/O error or an unsupported seek
    /// direction (for example, forward-only sources reject `SEEK_SET` and
    /// `SEEK_END`). Such sources are supported on the software playback path
    /// only (see the engine documentation).
    func seek(offset: Int64, whence: Int32) -> Int64

    /// Release the underlying resource. Called exactly once at teardown.
    func close()

    /// Unblock a `read` that is currently blocked, so engine teardown does
    /// not hang. Default no-op (provided by an extension). Network-backed
    /// readers override this to cancel the in-flight request; memory/file
    /// readers can ignore it. For a reader the engine may reuse across an
    /// internal reload, `cancel()` must only unblock a pending read, not
    /// invalidate the reader.
    func cancel()

    /// Vend an independent reader over the same underlying source, with its
    /// own cursor, for concurrent access (embedded-subtitle side demuxer,
    /// scrub previews) while playback reads the primary reader. Return nil if
    /// the source cannot provide a second independent cursor (for example a
    /// one-shot stream); the engine then skips that concurrent feature. The
    /// returned reader is owned and closed by the engine. May be called
    /// off-main; the returned reader follows the same threading contract as
    /// the primary reader (its `read`/`seek` run on a demux thread). Default
    /// returns nil.
    func makeIndependentReader() -> IOReader?
}

public extension IOReader {
    func cancel() {}
    func makeIndependentReader() -> IOReader? { nil }
}

/// The source AetherEngine loads media from.
public enum MediaSource: Sendable {
    /// A `file://` or `http(s)://` URL handled by the engine's built-in I/O.
    case url(URL)
    /// A caller-supplied byte source. `formatHint` is an optional container
    /// short name (e.g. "mp4", "matroska", "mpegts") used to disambiguate
    /// probing when no filename is available; pass `nil` to probe from
    /// content only.
    case custom(IOReader, formatHint: String? = nil)
}
