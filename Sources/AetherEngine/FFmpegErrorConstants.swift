import Foundation
import AetherLibavutil

/// FFmpeg error sentinels whose C macros (`AVERROR_EOF`, `AVERROR(EAGAIN)`, `AVERROR_INVALIDDATA`) Swift cannot import directly.
enum FFmpegErr {
    /// `AVERROR_EOF` = FFERRTAG('E','O','F',' ') = -0x20464F45 = -541478725.
    static let eof: Int32 = -0x20464F45
    /// `AVERROR(EAGAIN)`; EAGAIN is POSIX 35 on Apple platforms.
    static let eagain: Int32 = -35
    /// `AVERROR_INVALIDDATA` = FFERRTAG('I','N','D','A') = -0x41444E49.
    static let invalidData: Int32 = -0x41444E49
    /// `AVERROR_EXIT` = FFERRTAG('E','X','I','T') = -0x54495845: "immediate exit was requested", what
    /// libavformat answers when its interrupt callback fires.
    static let exit: Int32 = -0x54495845
    /// `AVERROR(EINVAL)`; EINVAL is POSIX 22 on Apple platforms. Some decoders (notably `dca` on a
    /// DTS-HD MA XLL frame that residual-codes channels without a usable core) reject a single packet
    /// with this while staying usable for the next one (#64).
    static let einval: Int32 = -22
    /// `AVERROR(EIO)`; EIO is POSIX 5. "The source is lost", as distinct from `eof`, which every
    /// consumer reads as played-to-the-end and deliberately never retries.
    static let eio: Int32 = -5
    /// `AVERROR(ENOMEM)`; ENOMEM is POSIX 12.
    static let enomem: Int32 = -12
    /// `AVERROR(ENOSPC)`; ENOSPC is POSIX 28. The volume a write went to is full.
    static let enospc: Int32 = -28

    /// FFmpeg's own text for an AVERROR code, with the raw number appended so a report never loses it
    /// ("Invalid data found when processing input (-1094995529)"). Falls back to the bare number when
    /// libavutil has no string for the code.
    static func text(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard av_strerror(code, &buffer, buffer.count) == 0 else { return "\(code)" }
        let message = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return message.isEmpty ? "\(code)" : "\(message) (\(code))"
    }
}
