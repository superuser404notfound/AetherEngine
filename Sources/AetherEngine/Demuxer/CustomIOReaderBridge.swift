import Foundation
import AetherLibavformat
import AetherLibavutil

/// Bridges an `IOReader` into `AVIOContext` via avio_alloc_context callbacks,
/// mirroring AVIOReader's lifecycle at the same Demuxer seam.
/// @unchecked Sendable: isClosed is a benign-race plain Bool (read callback
/// only needs to eventually observe it); context written once under teardown ordering.
final class CustomIOReaderBridge: AVIOProvider, @unchecked Sendable {
    private let reader: IOReader
    /// AE#460 follow-up: whether this open must leave the reader's cursor alone. See `open()`.
    private let preservesSourcePosition: Bool
    private static let bufferSize: Int32 = 256 * 1024  // matches AVIOReader.avioBufferSize
    private var buffer: UnsafeMutablePointer<UInt8>?
    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var isClosed = false
    private var isFullyClosed = false
    private(set) var isSeekable: Bool = true

    var timeSeekableReader: TimeSeekableIOReader? {
        reader as? TimeSeekableIOReader
    }

    /// [MovieClaw P19] 交给解复用器的字节数，当作「已从源拉取」上报（加载速度、带宽估计都靠它）。自定义读取器自己
    /// 不报网络字节，原来这里写死 0：光盘镜像、原盘目录经 HTTP 直推时顶栏加载速度恒为「0 KB/s」、带宽估计也是空的
    /// （真机《蜘蛛侠：英雄无归》UHD 原盘）。光盘是顺序流式读，读取器的小块缓存只在识别盘结构时起作用，
    /// 播放期间交出去的字节就是从网络拉来的字节
    var cumulativeBytesFetched: Int64 {
        deliveredLock.lock(); defer { deliveredLock.unlock() }
        return deliveredBytes
    }
    private let deliveredLock = NSLock()
    private var deliveredBytes: Int64 = 0

    /// #112 round 9: same demux-thread-only contract as AVIOReader's deadline. Armed by
    /// `Demuxer.seekBounded` around a positioning seek; `performRead` checks it between callbacks, so
    /// an index-less remote disc's read_timestamp binary search aborts within one chunk fetch instead
    /// of parking for minutes (ijuniorfu round 9, remote ISO: one seek sat wedged ~230 s).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    private(set) var readDeadlineFired = false

    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    private var readByteBudget = ReadByteBudget()
    var readByteBudgetExhausted: Bool { readByteBudget.exhausted }
    func beginReadByteBudget(_ bytes: Int64) { readByteBudget.begin(bytes) }
    func endReadByteBudget() { readByteBudget.end() }

    /// #112 round 9: the byte axis libavformat sees through this bridge (for a disc adapter, the
    /// virtual concat stream length via AVSEEK_SIZE), backing the byte-estimate seek fallback.
    var resolvedByteSize: Int64? {
        let size = callingHost { reader.seek(offset: 0, whence: 65536) }  // AVSEEK_SIZE: report length, don't move
        return size > 0 ? size : nil
    }

    /// AE#445: every call into the host's reader goes through here.
    ///
    /// The pump is a bare `Thread` (`HLSSegmentProducer.start`) and FFmpeg's read callback reaches the
    /// host from inside its loop, so nothing on that thread ever drains an autorelease pool. A host
    /// reader built on Foundation (`FileHandle.readData`, anything handed back +0) therefore strands
    /// one object per call for the life of the session, which on a live source that never EOFs is one
    /// leaked byte per byte played: the reporter's `phys_footprint` tracked his 1.7 MB/s mux rate to
    /// jetsam at ~11.5 min while every itemized bucket on the memprobe stayed flat.
    ///
    /// The engine had already learned this twice and both times fixed it one reader down, in
    /// `FileIOReader.read` (#243) and `HTTPDiscIOReader.rangeGet`. Those pools cover the engine's own
    /// readers and can never cover a reader the HOST wrote, and a host cannot be asked to know which
    /// of the engine's threads its callback lands on. The seam is the engine's, so the pool is too.
    private func callingHost<T>(_ body: () -> T) -> T {
        autoreleasepool { body() }
    }

    init(reader: IOReader, preservesSourcePosition: Bool = false) {
        self.reader = reader
        self.preservesSourcePosition = preservesSourcePosition
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.bufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.bufferSize,
            0,                       // read-only (write_flag = 0)
            opaque,
            customBridgeReadCallback,
            nil,                     // no write
            customBridgeSeekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }
        context = ctx

        // A fresh AVIOContext always starts its byte axis at 0, so the reader's cursor and that
        // axis have to be made to agree. There are two ways to do it and the source decides which:
        //
        //  - Ordinary opens rewind the reader to 0. Load-bearing, not incidental: a VOD reopen
        //    (the probe pass, an audio-track switch) has to re-read the container header, and the
        //    reader is wherever the previous open left it.
        //  - A LIVE open leaves the reader where it is and `Demuxer.openWithProvider` moves the
        //    axis to the cursor instead. Same invariant from the other end, and the only one that
        //    is right for a source that has kept receiving: the rewind put a host's live spool
        //    back to its base and asked it to re-deliver the whole delivered window (AE#460
        //    follow-up, measured: playhead 41.5 s -> 1.9 s, 15 MB re-read).
        //
        // Either way the seek doubles as the seekability probe: seeking a source to where it is
        // already meant to be is a no-op for a seekable reader and refused by a forward-only one.
        // A time-seekable reader is repositioned by time, never by bytes, and is not probed at all.
        if timeSeekableReader != nil {
            isSeekable = true
            return
        }
        let here = preservesSourcePosition
            ? callingHost { reader.seek(offset: 0, whence: 1) }  // SEEK_CUR 0: report position
            : -1
        let landed = callingHost { reader.seek(offset: max(0, here), whence: 0) }
        isSeekable = landed >= 0
        // AE#460 round 3: the probe hands the reported position straight back as a `SEEK_SET`, so a
        // reader that reports on one axis and takes `SEEK_SET` on another is MOVED by a probe whose
        // whole point is that it moves nothing, and the live alignment that follows repeats the
        // round trip at the same offset. A conforming reader answers with the position it was asked
        // for, so the comparison is free: no extra callback, and it fires on every live open,
        // including every in-place rebuild. Named rather than corrected, because the axis a host
        // means is not knowable from here (`docs/formats.md`, custom byte sources).
        if preservesSourcePosition, here > 0, landed >= 0, landed != here {
            EngineLog.emit(
                "[Demuxer] custom source: the reader reported byte \(here) and answered a seek back "
                + "to it with \(landed), so its position report and its SEEK_SET argument are not on "
                + "the same axis; the source has been repositioned by the seekability probe",
                category: .demux)
        }
    }

    /// AE#460 follow-up: where the host's reader currently sits, or nil when it will not say.
    ///
    /// A fresh `AVIOContext` starts its byte axis at 0 no matter where the reader is, which is
    /// right for a first open and wrong for a live reopen: it makes libavformat read the source
    /// from the host's base. `Demuxer.openWithProvider` aligns the axis to this instead, so a live
    /// rebuild resumes where the session already was.
    var currentSourceOffset: Int64? {
        let here = callingHost { reader.seek(offset: 0, whence: 1) }  // SEEK_CUR 0
        return here >= 0 ? here : nil
    }

    /// The bridge does not own the reader (see `close()`), so a rebuild reopens onto a source that
    /// has kept reading position, and on a live host has kept receiving.
    var sourceSurvivesReopen: Bool { true }

    func markClosed() {
        // AE#460 follow-up: cancel the reader ONCE. The bridge does not own it, and on an in-place
        // rebuild the engine hands the same reader to a successor bridge while this one is still
        // being torn down (`stopInternal` marks it closed, the demuxer's own `close()` marks it
        // again a moment later, sometimes after the new pump is already reading). A second cancel
        // can therefore only reach the successor's read, which on a live source is parked at the
        // edge and comes back -1: the rebuilt pump exits with `readError(-1)` and the session dies
        // just after reporting itself playing. One cancel is also all that is needed: after
        // `isClosed` no further read reaches the host, so nothing new can park.
        guard !isClosed else { return }
        isClosed = true
        callingHost { reader.cancel() }
    }

    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer (not original av_malloc ptr: FFmpeg may
            // realloc via ffio_set_buf_size).
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        // Bridge does NOT own the reader; engine/side-path owns lifetime.
    }

    func performRead(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        // -1 = forced abort (not EOF); mirrors AVIOReader.read so FFmpeg doesn't run EOS handling.
        guard !isClosed else { return -1 }
        if isPastReadDeadline { readDeadlineFired = true; return -1 }
        guard let allowed = readByteBudget.allowance(size) else { return -1 }
        let n = callingHost { reader.read(buf, size: allowed) }
        if n == 0 { return FFmpegErr.eof }  // IOReader uses 0 for EOF; avio expects AVERROR_EOF.
        readByteBudget.consumed(n)
        if n > 0 {
            deliveredLock.lock(); deliveredBytes += Int64(n); deliveredLock.unlock()
        }
        return n
    }

    func performSeek(offset: Int64, whence: Int32) -> Int64 {
        guard !isClosed else { return -1 }
        return callingHost { reader.seek(offset: offset, whence: whence) }
    }
}

// MARK: - C Callbacks


private func customBridgeReadCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performRead(into: buf, size: size)
}

private func customBridgeSeekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performSeek(offset: offset, whence: whence)
}
