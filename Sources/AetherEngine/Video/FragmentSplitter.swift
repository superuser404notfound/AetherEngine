import Foundation

/// Streaming ISOBMFF box parser that splits the mp4 muxer's output
/// into "header" (ftyp + moov) and "fragment" (moof + mdat) portions.
///
/// The per-segment mp4 muxer pattern produces:
///
/// ```
/// ftyp │ moov │ moof │ mdat │ (mfra)
///  ─┬─ │ ─┬─  │ ─────┬───── │ ─┬─
///   └──── header ──┘ │  one fragment   │  trailing
///                                          (discard)
/// ```
///
/// Each per-segment muxer emits its own ftyp+moov pair byte-identical
/// to every other segment's (the muxer state is fresh, codec params
/// are the same, mvhd creation_time is the only drift and we work
/// around it by pre-building init.mp4 once at session start). The
/// splitter captures the header once, hands it to a callback, then
/// streams every subsequent byte through the fragment callback until
/// the muxer is torn down.
///
/// ISOBMFF box format reminder:
///
/// ```
/// [4 byte size][4 byte type ASCII][... body ...]
/// ```
///
/// If size == 1, an 8-byte largesize follows the type (used for mdat
/// when fragments exceed 4 GB; we still handle it defensively).
/// Size == 0 means "to end of file", treated as discard.
final class FragmentSplitter {

    /// Called once when the moov box closes. Carries the complete
    /// ftyp + moov byte sequence (= init.mp4 content). Caller can
    /// dedupe against a pre-built init or cache the first occurrence.
    let onHeaderComplete: (Data) -> Void

    /// Called for every byte that belongs to a fragment box (moof,
    /// mdat, or any defensive styp / sidx if the muxer ever emits
    /// those). Receives raw bytes including the box headers themselves
    /// — the caller can write directly to a segment file without
    /// reconstructing box framing.
    let onFragmentBytes: (UnsafePointer<UInt8>, Int) -> Void

    private enum Phase {
        case awaitingBoxHeader
        case awaitingLargeSize(boxType: String)
        case insideHeaderBox(boxType: String, bytesRemaining: Int)
        case insideFragmentBox(boxType: String, bytesRemaining: Int)
        case insideDiscardBox(boxType: String, bytesRemaining: Int)
    }
    private var phase: Phase = .awaitingBoxHeader

    /// Partial 8-byte box header accumulator. Boxes can land split
    /// across feed() calls if the muxer's avio buffer flush boundary
    /// lands mid-header. Buffered here until we have all 8 bytes
    /// (size + type) and can switch to the appropriate inside-box state.
    private var pendingHeaderBytes: [UInt8] = []

    /// Captured init.mp4 content. Accumulates while phase is
    /// .insideHeaderBox(ftyp) or .insideHeaderBox(moov). Flushed via
    /// `onHeaderComplete` when moov ends. Reset to empty after.
    private var headerBuffer = Data()

    init(onHeaderComplete: @escaping (Data) -> Void,
         onFragmentBytes: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
        self.onHeaderComplete = onHeaderComplete
        self.onFragmentBytes = onFragmentBytes
        self.pendingHeaderBytes.reserveCapacity(16)
    }

    /// Feed `count` bytes of muxer output into the splitter. The
    /// splitter classifies each byte into header / fragment / discard
    /// and routes it via the appropriate callback. Safe to call with
    /// any chunk size; boxes can span multiple feed() calls.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        var offset = 0
        while offset < count {
            switch phase {
            case .awaitingBoxHeader:
                offset = consumeBoxHeader(bytes, offset: offset, count: count)

            case .awaitingLargeSize(let boxType):
                offset = consumeLargeSize(bytes, offset: offset, count: count, boxType: boxType)

            case .insideHeaderBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                headerBuffer.append(bytes.advanced(by: offset), count: take)
                let newRemaining = remaining - take
                offset += take
                if newRemaining == 0 {
                    if boxType == "moov" {
                        onHeaderComplete(headerBuffer)
                        headerBuffer = Data()
                    }
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideHeaderBox(boxType: boxType, bytesRemaining: newRemaining)
                }

            case .insideFragmentBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                onFragmentBytes(bytes.advanced(by: offset), take)
                let newRemaining = remaining - take
                offset += take
                if newRemaining == 0 {
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideFragmentBox(boxType: boxType, bytesRemaining: newRemaining)
                }

            case .insideDiscardBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                offset += take
                let newRemaining = remaining - take
                if newRemaining == 0 {
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideDiscardBox(boxType: boxType, bytesRemaining: newRemaining)
                }
            }
        }
    }

    // MARK: - Box header parsing

    private func consumeBoxHeader(_ bytes: UnsafePointer<UInt8>, offset: Int, count: Int) -> Int {
        var offset = offset
        let needed = 8 - pendingHeaderBytes.count
        let available = count - offset
        let take = min(needed, available)
        for i in 0..<take {
            pendingHeaderBytes.append(bytes[offset + i])
        }
        offset += take
        guard pendingHeaderBytes.count == 8 else { return offset }

        let size = UInt32(pendingHeaderBytes[0]) << 24
            | UInt32(pendingHeaderBytes[1]) << 16
            | UInt32(pendingHeaderBytes[2]) << 8
            | UInt32(pendingHeaderBytes[3])
        let typeBytes = Array(pendingHeaderBytes[4..<8])
        let boxType = String(bytes: typeBytes, encoding: .ascii) ?? "????"
        let headerBytes = pendingHeaderBytes
        pendingHeaderBytes.removeAll(keepingCapacity: true)

        if size == 1 {
            // 64-bit largesize follows. Stash the 8 header bytes we
            // already saw via the same dispatch path as the largesize
            // continuation, then enter the awaitingLargeSize state.
            pendingHeaderBytes = headerBytes
            phase = .awaitingLargeSize(boxType: boxType)
            return offset
        }
        if size == 0 {
            // "To end of file" — only valid on the final box. Treat
            // as discard; route the 8 header bytes to fragment if
            // it's a fragment box, otherwise drop.
            startBox(type: boxType, headerBytes: headerBytes, bodySize: Int.max)
            return offset
        }
        let bodySize = max(0, Int(size) - 8)
        startBox(type: boxType, headerBytes: headerBytes, bodySize: bodySize)
        return offset
    }

    private func consumeLargeSize(_ bytes: UnsafePointer<UInt8>, offset: Int, count: Int, boxType: String) -> Int {
        var offset = offset
        // pendingHeaderBytes already holds the 8 initial header bytes
        // (size=1 marker + type). We need 8 more for the largesize.
        let needed = 16 - pendingHeaderBytes.count
        let available = count - offset
        let take = min(needed, available)
        for i in 0..<take {
            pendingHeaderBytes.append(bytes[offset + i])
        }
        offset += take
        guard pendingHeaderBytes.count == 16 else { return offset }

        var largesize: UInt64 = 0
        for i in 8..<16 {
            largesize = (largesize << 8) | UInt64(pendingHeaderBytes[i])
        }
        let headerBytes = pendingHeaderBytes
        pendingHeaderBytes.removeAll(keepingCapacity: true)

        // clamping: a corrupt 64-bit box size above Int.max would trap in
        // the plain Int() initializer and take down the whole byte path.
        let bodySize = max(0, Int(clamping: largesize) - 16)
        startBox(type: boxType, headerBytes: headerBytes, bodySize: bodySize)
        return offset
    }

    /// Classify the just-parsed box header by type and switch to the
    /// matching inside-box state. The header bytes themselves are
    /// routed through the appropriate channel (header accumulator or
    /// fragment callback) before the body starts streaming through.
    private func startBox(type: String, headerBytes: [UInt8], bodySize: Int) {
        switch type {
        case "ftyp", "moov":
            headerBuffer.append(contentsOf: headerBytes)
            phase = .insideHeaderBox(boxType: type, bytesRemaining: bodySize)

        case "moof", "mdat", "styp", "sidx":
            headerBytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                onFragmentBytes(base, headerBytes.count)
            }
            phase = .insideFragmentBox(boxType: type, bytesRemaining: bodySize)

        default:
            // mfra, free, skip, udta, unknown — discard. The mp4
            // muxer can emit these around trailer time; none are
            // part of the segment AVPlayer needs.
            phase = .insideDiscardBox(boxType: type, bytesRemaining: bodySize)
        }
    }
}
