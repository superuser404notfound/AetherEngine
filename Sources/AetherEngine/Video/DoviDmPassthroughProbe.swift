// Only with the DualLayerDolbyVision trait (off by default): the digest reads RPUs with libdovi, which the dual-layer route links.
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo

/// Per-frame check that the display metadata attached to a frame still carries what the source RPU carried.
///
/// Off unless `AETHER_DM_DIGEST` is set (read once). When on:
/// - `noteSource` keeps the source RPU of each packet, by canonical PTS key, as the decoder saw it;
/// - `observe` runs at the hand-off point (`OrderedDelivery.emit`, right after the attach), reads the
///   `DolbyVisionRPUData` attachment BACK from the pixel buffer (not the bytes the decoder meant to attach),
///   reads both with libdovi and compares them field by field.
///
/// `AETHER_DM_DIGEST` values: `1` or `log` log one `[dm-digest]` line per frame; `hex` also puts the source and
/// attached RPU bytes on the line, so a capture from a device can be re-read with an independent tool.
/// `AETHER_DM_DIGEST_FILE=<path>` additionally appends one JSON object per frame (Mac use).
/// A frame's verdict is `pass`, `normalised` (the only extra differences are mode 2's reset of the colour matrices and
/// signal colour space to the Profile 8.1 constants, counted as passing but reported), `FAIL`, or one of
/// `no-attachment`, `attached-unreadable`, `no-source`.
/// A `[dm-digest] summary` line follows every 120 frames and at `flush()`.
///
/// It only reads. Nothing here changes what is attached or when.
final class DoviDmPassthroughProbe: @unchecked Sendable {

    static let shared = DoviDmPassthroughProbe()

    struct Frame: Sendable {
        let n: Int
        let ptsMs: Int64
        let attachedCrc: UInt32
        let attachedBytes: Int
        let sourceCrc: UInt32?
        let line: String
        let json: String
        /// Differences that mode 2 is not defined to make. Empty when the frame passes.
        let unexpected: [DoviDmDifference]
        /// Differences that are mode 2's reset of the colour matrices and signal colour space to the Profile 8.1
        /// constants (`DoviDmDigest.normalisedByModeTwo`). Reported, not a failure; empty when the source already
        /// carried those values.
        let normalised: [DoviDmDifference]
        /// Every difference, expected or not.
        let all: [DoviDmDifference]
    }

    struct Summary: Sendable {
        var frames = 0
        var withAttachment = 0
        var withSource = 0
        var passing = 0
        var unreadable = 0
        /// Frames whose only non-expected differences were normalisations (counted in `passing` too).
        var normalisedFrames = 0
        var normalisedFields: [String: Int] = [:]
        var levelFrames: [Int: Int] = [:]
        var unexpectedFields: [String: Int] = [:]
        var changedFields: [String: Int] = [:]
        var cmVersions: [String: Int] = [:]
    }

    enum Mode: Sendable { case off, log, hex }

    let mode: Mode
    private let filePath: String?
    private let lock = NSLock()
    private var sources: [Int64: [UInt8]] = [:]
    /// Keys in arrival order as a ring of at most `sourceCapacity`: `ringHead` is the oldest once it is full.
    private var sourceRing: [Int64] = []
    private var ringHead = 0
    private static let sourceCapacity = 4096
    private var fileHandle: FileHandle?
    private var counter = 0
    private var summary = Summary()
    /// Test hook: receives each frame result instead of (as well as) the log. Set once at init, so the delivery and
    /// decode queues read it without a race.
    private let sink: (@Sendable (Frame) -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, sink: (@Sendable (Frame) -> Void)? = nil) {
        self.sink = sink
        switch environment["AETHER_DM_DIGEST"] {
        case nil, "", "0": mode = .off
        case "hex": mode = .hex
        default: mode = .log
        }
        filePath = environment["AETHER_DM_DIGEST_FILE"]
    }

    var isOn: Bool { mode != .off || sink != nil }

    // MARK: Source side

    /// Remembers the source RPU (unspec62 NAL as demuxed) of the packet with this PTS key.
    func noteSource(key: Int64, rpu: [UInt8]?) {
        guard isOn, let rpu else { return }
        lock.lock(); defer { lock.unlock() }
        if sources[key] == nil {
            if sourceRing.count < Self.sourceCapacity {
                sourceRing.append(key)
            } else {
                sources[sourceRing[ringHead]] = nil
                sourceRing[ringHead] = key
                ringHead = (ringHead + 1) % Self.sourceCapacity
            }
        }
        sources[key] = rpu
    }

    // MARK: Hand-off side

    /// Reads the attachment back from `buffer` and compares it with the source RPU noted for `key`.
    @discardableResult
    func observe(buffer: CVPixelBuffer, key: Int64, pts: CMTime) -> Frame? {
        guard isOn else { return nil }
        let attached = (CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data).map { [UInt8]($0) }
        lock.lock()
        let source = sources[key]
        counter += 1
        let n = counter
        lock.unlock()

        let ptsMs = pts.isNumeric ? Int64((pts.seconds * 1000).rounded()) : -1
        var unexpected: [DoviDmDifference] = []
        var normalised: [DoviDmDifference] = []
        var all: [DoviDmDifference] = []
        var out: DoviDmReading?
        var src: DoviDmReading?
        if let attached { out = DoviDmDigest.read(rpu: attached) }
        if let source { src = DoviDmDigest.read(rpu: source) }
        if let src, let out {
            all = DoviDmDigest.differences(source: src, output: out)
            for d in all where !DoviDmDigest.isExpectedChange(d.name) {
                if DoviDmDigest.isNormalisedChange(d) { normalised.append(d) } else { unexpected.append(d) }
            }
        }

        let attachedCrc = attached.map(DoviDmDigest.crc32)
        let sourceCrc = source.map(DoviDmDigest.crc32)
        let verdict: String
        if attached == nil { verdict = "no-attachment" }
        else if out == nil { verdict = "attached-unreadable" }
        else if src == nil { verdict = "no-source" }
        else { verdict = !unexpected.isEmpty ? "FAIL" : (normalised.isEmpty ? "pass" : "normalised") }

        var line = "[dm-digest] n=\(n) pts=\(ptsMs) \(verdict) out_crc=\(attachedCrc.map { String(format: "%08x", $0) } ?? "-") out_bytes=\(attached?.count ?? 0)"
        if let sourceCrc { line += " src_crc=\(String(format: "%08x", sourceCrc))" }
        if let out { line += " " + DoviDmDigest.compact(out) }
        line += " " + staticHDR(buffer)
        if !unexpected.isEmpty {
            line += " UNEXPECTED[" + unexpected.map { "\($0.name): \($0.source ?? "-") -> \($0.output ?? "-")" }.joined(separator: "; ") + "]"
        }
        if !normalised.isEmpty {
            line += " NORMALISED[" + normalised.map { "\($0.name): \($0.source ?? "-") -> \($0.output ?? "-")" }.joined(separator: "; ") + "]"
        }
        if !all.isEmpty { line += " changed=" + all.map(\.name).joined(separator: ",") }
        if mode == .hex {
            if let attached { line += " out_hex=" + hex(attached) }
            if let source { line += " src_hex=" + hex(source) }
        }

        // The JSON form is built only for a consumer: the file, or a test sink.
        let json = (filePath != nil || sink != nil)
            ? jsonLine(n: n, ptsMs: ptsMs, verdict: verdict, attached: attached, source: source, out: out, src: src,
                       unexpected: unexpected, normalised: normalised, all: all)
            : ""
        let frame = Frame(n: n, ptsMs: ptsMs, attachedCrc: attachedCrc ?? 0, attachedBytes: attached?.count ?? 0, sourceCrc: sourceCrc,
                          line: line, json: json, unexpected: unexpected, normalised: normalised, all: all)

        lock.lock()
        summary.frames += 1
        if attached != nil { summary.withAttachment += 1 }
        if source != nil { summary.withSource += 1 }
        if out == nil && attached != nil { summary.unreadable += 1 }
        if verdict == "pass" || verdict == "normalised" { summary.passing += 1 }
        if verdict == "normalised" { summary.normalisedFrames += 1 }
        if let out {
            for l in out.levels { summary.levelFrames[l, default: 0] += 1 }
            summary.cmVersions[DoviDmDigest.cmVersion(out), default: 0] += 1
        }
        for d in unexpected { summary.unexpectedFields[d.name, default: 0] += 1 }
        for d in normalised { summary.normalisedFields[d.name, default: 0] += 1 }
        for d in all { summary.changedFields[d.name, default: 0] += 1 }
        let due = summary.frames % 120 == 0
        lock.unlock()

        if mode != .off {
            EngineLog.emit(line, category: .swPlayback)
            if due { emitSummary() }
        }
        if filePath != nil { appendToFile(json) }
        sink?(frame)
        return frame
    }

    func currentSummary() -> Summary { lock.lock(); defer { lock.unlock() }; return summary }

    func emitSummary() {
        let s = currentSummary()
        let lv = s.levelFrames.sorted { $0.key < $1.key }.map { "L\($0.key)=\($0.value)" }.joined(separator: ",")
        let ch = s.changedFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let un = s.unexpectedFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let nf = s.normalisedFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let cm = s.cmVersions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        EngineLog.emit("[dm-digest] summary frames=\(s.frames) attached=\(s.withAttachment) source=\(s.withSource) pass=\(s.passing) normalised=\(s.normalisedFrames) unreadable=\(s.unreadable) levels{\(lv)} cm{\(cm)} unexpected{\(un.isEmpty ? "none" : un)} normalised{\(nf.isEmpty ? "none" : nf)} changed{\(ch.isEmpty ? "none" : ch)}", category: .swPlayback)
    }

    /// Emits the closing summary, closes the file and starts over: the summary, the frame counter and the source
    /// ring are cleared, so a second run or load in the same process does not add to the first.
    func flush() {
        if mode != .off { emitSummary() }
        lock.lock()
        try? fileHandle?.close(); fileHandle = nil
        summary = Summary()
        counter = 0
        sources.removeAll()
        sourceRing.removeAll()
        ringHead = 0
        lock.unlock()
    }

    // MARK: Output

    /// The HDR10 static metadata and colour tags that ride on the buffer next to the Dolby Vision attachment:
    /// mastering display volume (hex), content light level (MaxCLL/MaxFALL) and primaries/transfer/matrix.
    /// Reported, not compared: the source of these is the stream's SEI / the container, not the RPU.
    private func staticHDR(_ buffer: CVPixelBuffer) -> String {
        func data(_ key: CFString) -> [UInt8]? { (CVBufferCopyAttachment(buffer, key, nil) as? Data).map { [UInt8]($0) } }
        func str(_ key: CFString) -> String { (CVBufferCopyAttachment(buffer, key, nil) as? String) ?? "-" }
        let mdcv = data(kCVImageBufferMasteringDisplayColorVolumeKey).map(hex) ?? "-"
        var cll = "-"
        if let c = data(kCVImageBufferContentLightLevelInfoKey), c.count >= 4 {
            cll = "\(Int(c[0]) << 8 | Int(c[1]))/\(Int(c[2]) << 8 | Int(c[3]))"
        }
        return "hdr10{mdcv=\(mdcv) cll=\(cll) prim=\(str(kCVImageBufferColorPrimariesKey)) tf=\(str(kCVImageBufferTransferFunctionKey)) mtx=\(str(kCVImageBufferYCbCrMatrixKey))}"
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private func hex(_ b: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: b.count * 2)
        for (i, byte) in b.enumerated() {
            out[2 * i] = Self.hexDigits[Int(byte >> 4)]
            out[2 * i + 1] = Self.hexDigits[Int(byte & 0x0F)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func appendToFile(_ json: String) {
        guard let filePath else { return }
        lock.lock(); defer { lock.unlock() }
        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: filePath) { FileManager.default.createFile(atPath: filePath, contents: nil) }
            fileHandle = FileHandle(forWritingAtPath: filePath)
            _ = try? fileHandle?.seekToEnd()
        }
        fileHandle?.write(Data((json + "\n").utf8))
    }

    private func jsonLine(n: Int, ptsMs: Int64, verdict: String, attached: [UInt8]?, source: [UInt8]?, out: DoviDmReading?, src: DoviDmReading?,
                          unexpected: [DoviDmDifference], normalised: [DoviDmDifference], all: [DoviDmDifference]) -> String {
        func fields(_ r: DoviDmReading?) -> [String: String]? {
            guard let r else { return nil }
            return Dictionary(uniqueKeysWithValues: r.fields.map { ($0.name, $0.value) })
        }
        var obj: [String: Any] = ["n": n, "pts_ms": ptsMs, "verdict": verdict]
        if let attached { obj["out_hex"] = hex(attached) }
        if let source { obj["src_hex"] = hex(source) }
        if let f = fields(out) { obj["out"] = f }
        if let f = fields(src) { obj["src"] = f }
        obj["unexpected"] = unexpected.map(\.name)
        obj["normalised"] = normalised.map(\.name)
        obj["changed"] = all.map(\.name)
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// What `aetherctl dmpass` reads back after a probe run with the digest on.
@_spi(Diagnostics)
public struct DmPassthroughReport: Sendable {
    public let frames: Int
    public let withAttachment: Int
    public let withSource: Int
    public let passing: Int
    public let unreadable: Int
    /// Frames whose only non-expected differences were mode 2's reset of the colour matrices and signal colour
    /// space to the Profile 8.1 constants (these are counted in `passing` too).
    public let normalisedFrames: Int
    /// Frames per level number that carried it in the ATTACHED RPU.
    public let levelFrames: [Int: Int]
    /// Frames per CM version label ("v2.9", "v4.0", "none") of the attached RPU.
    public let cmVersions: [String: Int]
    /// Fields that differed where mode 2 is not defined to change them, with frame counts.
    public let unexpectedFields: [String: Int]
    /// Fields mode 2 normalised to the Profile 8.1 constants (YCC to RGB, RGB to LMS, signal colour space), with frame counts.
    public let normalisedFields: [String: Int]
    /// Fields that differed at all (expected changes included), with frame counts.
    public let changedFields: [String: Int]
}

extension AetherEngine {
    @_spi(Diagnostics)
    public nonisolated static func dmPassthroughReport() -> DmPassthroughReport {
        let s = DoviDmPassthroughProbe.shared.currentSummary()
        DoviDmPassthroughProbe.shared.flush()
        return DmPassthroughReport(frames: s.frames, withAttachment: s.withAttachment, withSource: s.withSource, passing: s.passing,
                                   unreadable: s.unreadable, normalisedFrames: s.normalisedFrames, levelFrames: s.levelFrames,
                                   cmVersions: s.cmVersions, unexpectedFields: s.unexpectedFields, normalisedFields: s.normalisedFields,
                                   changedFields: s.changedFields)
    }
}
#endif
