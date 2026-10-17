import Foundation
import AetherLibavcodec
import AetherLibavutil

/// How a stereoscopic (3D) source is presented. `LoadOptions.stereoPresentation`.
public enum StereoPresentation: Sendable, Equatable {
    /// What the source says: an MV-HEVC stream's second view, or the frame packing its container
    /// declares (Matroska `StereoMode` side by side or top-bottom). Anything else plays 2D. The default.
    case automatic
    /// 2D, whatever the source says: the base view of an MV-HEVC stream, a packed frame as it is.
    case mono
    /// Each frame holds the left and the right view side by side (full or half width; a host's per-title
    /// choice, for the many files that say so only in their name).
    case sideBySide
    /// Each frame holds the left view over the right one.
    case overUnder
}

/// What the session tells AVPlayer about a stereo source, resolved once per load (`resolve`).
///
/// - `multiview`: an MV-HEVC stream. The second layer's NAL units already travel in every sample; the
///   muxer marks the output stream `AV_DISPOSITION_MULTILAYER` so movenc writes the `lhvC` box beside
///   `hvcC` (without it AVPlayer sees a plain `hvc1` and decodes the base layer only), and the master
///   declares `REQ-VIDEO-LAYOUT="CH-STEREO"`.
/// - `framePacked`: both views in one coded frame. The init segment's sample entry gets Apple's
///   `vexu { eyes { stri }, pack { pkin } }` (the layout AVAssetWriter itself writes for
///   `kCMFormatDescriptionExtension_ViewPackingKind`; visionOS 26's frame-packing metadata), which
///   AVFoundation reads back as `ViewPackingKind` plus both eye views, and the master declares
///   `CH-STEREO`. No re-encode.
///
/// Measured on the visionOS 27 simulator and macOS 27 (AVPlayer over a local HLS, 2026-10-16): HEVC with
/// that box plays with `ViewPackingKind` read back under any REQ-VIDEO-LAYOUT, and an H.264 init with the
/// same box is refused (-12927, or -11848 "cannot be used on this device" under CH-STEREO) while the same
/// H.264 as a progressive MP4 plays. So frame packing is only signalled on HEVC; H.264 plays 2D as before.
/// A REQ- attribute needs EXT-X-VERSION 12 (under 7 the master is refused, -12642).
enum StereoVideoSignal: Equatable, Sendable {
    case multiview
    case framePacked(FramePacking)

    struct FramePacking: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case sideBySide, overUnder }
        let kind: Kind
        /// The right view comes first (Matroska `right_left` / `bottom_top`): `stri`'s eye_views_reversed.
        let reversed: Bool
    }

    /// The master's REQ-VIDEO-LAYOUT for a stereo session.
    static let videoLayout = "CH-STEREO"

    /// Only visionOS presents stereo; everywhere else the session stays exactly as it was (2D).
    static var systemPresentsStereo: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    /// The signal for one source, and the reason, for the load's log line.
    /// `containerStereo` is the stream's `AV_PKT_DATA_STEREO3D` (Matroska StereoMode, an MP4's `st3d`
    /// or `vexu`), `multilayer` its `AV_DISPOSITION_MULTILAYER` (the MP4 demuxer sets it from `lhvC`).
    static func resolve(
        presentation: StereoPresentation,
        codecID: AVCodecID,
        multilayer: Bool,
        containerStereo: (type: AVStereo3DType, inverted: Bool)?,
        systemPresentsStereo: Bool = Self.systemPresentsStereo
    ) -> (signal: StereoVideoSignal?, reason: String) {
        guard systemPresentsStereo else { return (nil, "2D: this system presents video in 2D") }
        let packing: FramePacking
        switch presentation {
        case .mono:
            return (nil, "2D: the host asked for 2D")
        case .sideBySide:
            packing = FramePacking(kind: .sideBySide, reversed: false)
        case .overUnder:
            packing = FramePacking(kind: .overUnder, reversed: false)
        case .automatic:
            if multilayer {
                guard codecID == AV_CODEC_ID_HEVC else { return (nil, "2D: a multilayer stream that is not HEVC") }
                return (.multiview, "MV-HEVC: second view kept (lhvC, CH-STEREO)")
            }
            switch containerStereo?.type {
            case AV_STEREO3D_SIDEBYSIDE?:
                packing = FramePacking(kind: .sideBySide, reversed: containerStereo?.inverted ?? false)
            case AV_STEREO3D_TOPBOTTOM?:
                packing = FramePacking(kind: .overUnder, reversed: containerStereo?.inverted ?? false)
            default:
                return (nil, "2D: the source declares no stereo")
            }
        }
        guard codecID == AV_CODEC_ID_HEVC else {
            return (nil, "2D: frame-packed stereo is only signalled on HEVC (AVPlayer refuses it on H.264 over HLS)")
        }
        let name = packing.kind == .sideBySide ? "side by side" : "over-under"
        return (.framePacked(packing), "frame-packed \(name)\(packing.reversed ? ", right view first" : "") (vexu, CH-STEREO)")
    }

    /// The stream's stereo3d side data, as `resolve` takes it.
    static func containerStereo(_ codecpar: UnsafePointer<AVCodecParameters>) -> (type: AVStereo3DType, inverted: Bool)? {
        let nb = Int(codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = codecpar.pointee.coded_side_data else { return nil }
        for i in 0..<nb {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_STEREO3D, let raw = item.data,
                  item.size >= MemoryLayout<AVStereo3D>.size else { continue }
            let stereo = raw.withMemoryRebound(to: AVStereo3D.self, capacity: 1) { $0.pointee }
            return (stereo.type, (stereo.flags & AV_STEREO3D_FLAG_INVERT) != 0)
        }
        return nil
    }

    /// Apple's `vexu` box for a packed frame: `eyes { stri }` with both eye views (and the reversed bit),
    /// then `pack { pkin }` with `side` or `over`. Byte for byte what AVAssetWriter writes for
    /// ViewPackingKind + HasLeftStereoEyeView + HasRightStereoEyeView (macOS 27, 2026-10-16).
    static func viewPackingBox(_ packing: FramePacking) -> [UInt8] {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            bigEndian(UInt32(8 + payload.count)) + Array(type.utf8) + payload
        }
        let stri = box("stri", [0, 0, 0, 0, (packing.reversed ? 0x08 : 0) | 0x03])
        let pkin = box("pkin", [0, 0, 0, 0] + Array((packing.kind == .sideBySide ? "side" : "over").utf8))
        return box("vexu", box("eyes", stri) + box("pack", pkin))
    }

    /// `initBytes` with `viewPackingBox(packing)` appended to the video track's visual sample entry, or nil
    /// when the init has no video track with one sample entry to extend (the caller then forwards the init
    /// unchanged: the film plays 2D instead of failing). A `vexu` or `st3d` already in the entry is replaced,
    /// so the source's own partial claim (movenc writes `st3d` from a Matroska StereoMode) never sits beside it.
    static func installingViewPacking(_ packing: FramePacking, in initBytes: Data) -> Data? {
        let b = [UInt8](initBytes)
        let n = b.count
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= n else { return nil }
            return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        func fourcc(_ o: Int) -> String? {
            guard o >= 0, o + 4 <= n else { return nil }
            return String(bytes: b[o..<o + 4], encoding: .ascii)
        }
        struct Box { let start: Int; let type: String; let payload: Int; let end: Int }
        func boxes(_ start: Int, _ end: Int) -> [Box] {
            var out: [Box] = []
            var o = start
            while o + 8 <= end {
                guard let size = u32(o), size != 1, let t = fourcc(o + 4) else { break }
                let boxSize = size == 0 ? (end - o) : Int(size)
                guard boxSize >= 8, o + boxSize <= end else { break }
                out.append(Box(start: o, type: t, payload: o + 8, end: o + boxSize))
                o += boxSize
            }
            return out
        }
        func child(_ parent: Box, _ type: String) -> Box? {
            boxes(parent.payload, parent.end).first { $0.type == type }
        }

        guard let moov = boxes(0, n).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(moov.payload, moov.end) where trak.type == "trak" {
            guard let mdia = child(trak, "mdia"),
                  let hdlr = child(mdia, "hdlr"),
                  fourcc(hdlr.payload + 8) == "vide",   // hdlr: version/flags(4) + pre_defined(4) + handler_type
                  let minf = child(mdia, "minf"),
                  let stbl = child(minf, "stbl"),
                  let stsd = child(stbl, "stsd"),
                  // stsd: version/flags(4) + entry_count(4), then the entries.
                  let entry = boxes(stsd.payload + 8, stsd.end).first,
                  // A VisualSampleEntry's fixed fields take 78 bytes after its header; its boxes follow.
                  entry.payload + 78 <= entry.end
            else { continue }

            let kept = boxes(entry.payload + 78, entry.end).filter { $0.type != "vexu" && $0.type != "st3d" }
            var children: [UInt8] = []
            for box in kept { children += b[box.start..<box.end] }
            children += viewPackingBox(packing)
            let newEntry = bigEndian(UInt32(78 + 8 + children.count)) + Array(b[entry.start + 4..<entry.payload + 78])
                + children
            var out = Array(b[0..<entry.start]) + newEntry + Array(b[entry.end..<n])
            let delta = newEntry.count - (entry.end - entry.start)
            // Every ancestor's header precedes the entry, so its offset is the same in `out`.
            for ancestor in [stsd, stbl, minf, mdia, trak, moov] {
                let old = Int(u32(ancestor.start)!)
                if old == 0 { continue }   // "to the end of the file" stays true
                out.replaceSubrange(ancestor.start..<ancestor.start + 4, with: bigEndian(UInt32(old + delta)))
            }
            return Data(out)
        }
        return nil
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
