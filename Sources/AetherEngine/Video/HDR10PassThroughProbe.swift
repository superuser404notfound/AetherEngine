import Foundation
import CoreMedia
import CoreVideo
#if !targetEnvironment(simulator)
import Metal
#endif

/// The HDR10 pass-through check (AE#957, step 2): whether the HDR10 metadata the engine attaches to its own
/// frames reaches the television. Tone mapping to a panel's real peak only pays off if it does, so this runs
/// before any tone-mapping shader exists.
///
/// Off unless `AETHER_HDR10_PROBE` is set, read at every software-path load. Modes:
///
/// | value | what happens to each decoded frame |
/// |---|---|
/// | `log` | nothing; the first frame's colour tags and HDR10 metadata are logged |
/// | `meta` | the decoder's buffer gets the probe's mastering display and content light level values |
/// | `chain` | the frame goes through `FrameChain` (`PassThroughStage`) into a buffer of our own, attachments copied |
/// | `chain+meta` | both: our own buffer, carrying the probe's values |
/// | `pulse` | as `meta`, but every 72 frames (3 s at 24p) the values switch to a 4000 nit set and back |
/// | `chain+pulse` | as `chain+meta`, with the same switching |
///
/// `AETHER_HDR10_PROBE_META` sets the values (`maxcll=345,maxfall=123,peak=777,min=0.005`, the default).
/// They are chosen to be unlike any real master, so a television's HDR info screen tells at a glance whose
/// metadata it got. `Probes/HDR10PassThrough` plays the arms on an Apple TV.
///
/// Only on the software path, never with an upscale plan or on the dual-layer decoder. Nothing here runs
/// unless the variable is set.
struct HDR10ProbeSettings: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case log
        case meta
        case chain
        case chainMeta = "chain+meta"
        case pulse
        case chainPulse = "chain+pulse"

        var runsChain: Bool { self == .chain || self == .chainMeta || self == .chainPulse }
        var setsMetadata: Bool { self != .log && self != .chain }
        /// The pixels stay as they are and only the metadata switches, so a television that uses it
        /// brightens and dims the highlights in step: visible by eye, no camera needed.
        var pulses: Bool { self == .pulse || self == .chainPulse }
    }

    var mode: Mode
    var metadata: HDR10StaticMetadata

    static let modeVariable = "AETHER_HDR10_PROBE"
    static let metadataVariable = "AETHER_HDR10_PROBE_META"

    /// Read with `getenv` at each call, not cached: a probe host switches modes between arms with `setenv`.
    static func fromEnvironment(
        _ read: (String) -> String? = { getenv($0).map { String(cString: $0) } }
    ) -> HDR10ProbeSettings? {
        guard let raw = read(modeVariable), !raw.isEmpty else { return nil }
        switch parse(mode: raw, metadata: read(metadataVariable)) {
        case let .success(settings):
            return settings
        case let .failure(error):
            EngineLog.emit("[HDR10Probe] ignored: \(error.message)", category: .swPlayback)
            return nil
        }
    }

    struct ParseError: Error, Equatable {
        let message: String
    }

    static func parse(mode raw: String, metadata: String?) -> Result<HDR10ProbeSettings, ParseError> {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let mode = Mode(rawValue: name) else {
            let known = Mode.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure(ParseError(message: "\(modeVariable)=\(raw) is not one of \(known)"))
        }
        guard let metadata, !metadata.isEmpty else {
            return .success(HDR10ProbeSettings(mode: mode, metadata: .probeDefault))
        }
        return HDR10StaticMetadata.parse(metadata).map { HDR10ProbeSettings(mode: mode, metadata: $0) }
    }
}

/// HDR10 static metadata as CoreVideo carries it: the mastering display colour volume and the content
/// light level, in the byte layout of the HEVC SEI messages (big endian).
struct HDR10StaticMetadata: Equatable, Sendable {
    var maxCLL: Int
    var maxFALL: Int
    var masteringPeakNits: Double
    var masteringMinNits: Double

    /// Unlike any real master (those say 1000 or 4000 nit), so a television's info screen shows whose it is.
    static let probeDefault = HDR10StaticMetadata(maxCLL: 345, maxFALL: 123, masteringPeakNits: 777,
                                                  masteringMinNits: 0.005)

    /// The other half of the pulse: a common real master (4000 nit), far from the probe's 345 / 777, so
    /// a television that tone-maps by it maps the highlights very differently.
    static let pulseAlternate = HDR10StaticMetadata(maxCLL: 4000, maxFALL: 1000, masteringPeakNits: 4000,
                                                    masteringMinNits: 0.005)

    /// BT.2020 primaries in the SEI's order (green, blue, red), then the D65 white point, in 0.00002 units.
    static let bt2020Chromaticities: [UInt16] = [8500, 39850, 6550, 2300, 35400, 14600, 15635, 16450]

    /// `kCVImageBufferMasteringDisplayColorVolumeKey`: 24 bytes, BT.2020 primaries, luminance in 0.0001 nit.
    var masteringDisplayColorVolume: Data {
        var bytes: [UInt8] = []
        for value in Self.bt2020Chromaticities { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        for nits in [masteringPeakNits, masteringMinNits] {
            let units = UInt32((nits * 10_000).rounded())
            bytes += [UInt8(units >> 24), UInt8((units >> 16) & 0xFF), UInt8((units >> 8) & 0xFF), UInt8(units & 0xFF)]
        }
        return Data(bytes)
    }

    /// `kCVImageBufferContentLightLevelInfoKey`: MaxCLL then MaxFALL, two bytes each.
    var contentLightLevel: Data {
        Data([UInt8(maxCLL >> 8), UInt8(maxCLL & 0xFF), UInt8(maxFALL >> 8), UInt8(maxFALL & 0xFF)])
    }

    /// `maxcll=345,maxfall=123,peak=777,min=0.005`; keys left out keep `probeDefault`'s value.
    static func parse(_ text: String) -> Result<HDR10StaticMetadata, HDR10ProbeSettings.ParseError> {
        var result = probeDefault
        for item in text.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let value = Double(pair[1]), value.isFinite else {
                return .failure(.init(message: "\(HDR10ProbeSettings.metadataVariable): cannot read '\(item)'"))
            }
            switch pair[0].lowercased() {
            case "maxcll": result.maxCLL = Int(value)
            case "maxfall": result.maxFALL = Int(value)
            case "peak": result.masteringPeakNits = value
            case "min": result.masteringMinNits = value
            default:
                return .failure(.init(message: "\(HDR10ProbeSettings.metadataVariable): unknown key '\(pair[0])'"))
            }
        }
        guard (1...65535).contains(result.maxCLL), (1...65535).contains(result.maxFALL),
              result.maxFALL <= result.maxCLL else {
            return .failure(.init(message: "maxcll and maxfall must be 1...65535 with maxfall <= maxcll"))
        }
        guard result.masteringPeakNits >= 1, result.masteringPeakNits <= 10_000,
              result.masteringMinNits >= 0, result.masteringMinNits < result.masteringPeakNits else {
            return .failure(.init(message: "peak must be 1...10000 nit and min 0 up to below peak"))
        }
        return .success(result)
    }

    /// "peak 777 min 0.0050" from mastering display bytes, nil when they are not 24 bytes.
    static func describe(masteringDisplayColorVolume data: Data?) -> String? {
        guard let data, data.count == 24 else { return nil }
        let b = [UInt8](data)
        func u32(_ i: Int) -> Double {
            Double(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
        }
        return String(format: "peak %g min %.4f", u32(16) / 10_000, u32(20) / 10_000)
    }

    /// "345/123" (MaxCLL/MaxFALL) from content light level bytes, nil when they are not 4 bytes.
    static func describe(contentLightLevel data: Data?) -> String? {
        guard let data, data.count == 4 else { return nil }
        let b = [UInt8](data)
        return "\(Int(b[0]) << 8 | Int(b[1]))/\(Int(b[2]) << 8 | Int(b[3]))"
    }
}

/// Runs one `HDR10ProbeSettings` on the software path's decoded frames. `process` returns the frame to
/// deliver, nil to deliver the input unchanged. A chain that fails three frames in a row switches the
/// stage off (frames then pass through) and says so once.
final class HDR10ProbeStage: @unchecked Sendable {

    let settings: HDR10ProbeSettings
    static let timingWindow = 48
    static let timingLines = 10
    static let maxConsecutiveFailures = 3
    /// Frames per pulse phase: 3 s at 23.976, 1.2 s at 59.94.
    static let pulseFrames = 72
    static let pulseSwitchLines = 4

    private let lock = NSLock()
    private var frames = 0
    private var firstFrameLogged = false
    private var windowGPUms: [Double] = []
    private var timingLinesLogged = 0
    private var consecutiveFailures = 0
    private var disabled = false
    private var lastNote: String?
    private var pulseSwitchesLogged = 0
    #if !targetEnvironment(simulator)
    /// A `FrameChain`, typed loosely because the class needs OS 26.
    private var chain: AnyObject?
    private var chainSize: (Int, Int)?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    #endif

    init(settings: HDR10ProbeSettings) {
        self.settings = settings
        EngineLog.emit("[HDR10Probe] on: mode=\(settings.mode.rawValue)"
                       + (settings.mode.setsMetadata ? " " + Self.describe(settings.metadata) : "")
                       + (settings.mode.pulses ? " alternating every \(Self.pulseFrames) frames with "
                          + Self.describe(.pulseAlternate) : ""),
                       category: .swPlayback)
    }

    static func describe(_ m: HDR10StaticMetadata) -> String {
        String(format: "maxCLL=%d maxFALL=%d mastering=%g/%.4f nit", m.maxCLL, m.maxFALL,
               m.masteringPeakNits, m.masteringMinNits)
    }

    func process(_ input: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return nil }
        var output = input
        var gpuMs: Double?
        if settings.mode.runsChain {
            switch runChain(input) {
            case let .success((buffer, ms)):
                output = buffer
                gpuMs = ms
                consecutiveFailures = 0
            case let .failure(skip):
                notePassThrough(skip.message)
                if skip.counts {
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.maxConsecutiveFailures {
                        disabled = true
                        EngineLog.emit("[HDR10Probe] off: \(consecutiveFailures) chain failures in a row, last: "
                                       + skip.message, category: .swPlayback)
                    }
                }
                return nil
            }
        }
        if settings.mode.setsMetadata {
            let metadata = metadata(forFrame: frames, pts: pts)
            CVBufferSetAttachment(output, kCVImageBufferMasteringDisplayColorVolumeKey,
                                  metadata.masteringDisplayColorVolume as CFData, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferContentLightLevelInfoKey,
                                  metadata.contentLightLevel as CFData, .shouldPropagate)
        }
        frames += 1
        if !firstFrameLogged {
            firstFrameLogged = true
            EngineLog.emit("[HDR10Probe] first frame: in " + Self.describe(input)
                           + (output === input ? "" : "; out " + Self.describe(output))
                           + "; format description " + Self.describeFormatDescription(of: output),
                           category: .swPlayback)
        }
        if let gpuMs { noteTiming(gpuMs, pts: pts) }
        // `meta` alone changed the input's own attachments, so delivering the input is right there too.
        return output === input ? nil : output
    }

    /// The values for frame `index` (counted from 0): the settings' own, or in a pulse mode the
    /// alternate set in every other phase of `pulseFrames`. Logs the first few switches.
    func metadata(forFrame index: Int, pts: CMTime) -> HDR10StaticMetadata {
        guard settings.mode.pulses else { return settings.metadata }
        let phase = index / Self.pulseFrames
        if index > 0, index % Self.pulseFrames == 0, pulseSwitchesLogged < Self.pulseSwitchLines {
            pulseSwitchesLogged += 1
            EngineLog.emit(String(format: "[HDR10Probe] pulse: frame %d, pts %.2f s, now %@", index,
                                  CMTimeGetSeconds(pts), phase % 2 == 1 ? "the 4000 nit set" : "the probe's set"),
                           category: .swPlayback)
        }
        return phase % 2 == 1 ? .pulseAlternate : settings.metadata
    }

    private struct Note: Error {
        let message: String
        /// False for a frame the chain cannot take by design (format, size), which is no failure.
        let counts: Bool
    }

    private func runChain(_ input: CVPixelBuffer) -> Result<(CVPixelBuffer, Double), Note> {
        #if targetEnvironment(simulator)
        return .failure(Note(message: "the frame chain is not built for the simulator", counts: false))
        #else
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) else {
            return .failure(Note(message: "the frame chain needs OS 26", counts: false))
        }
        let format = CVPixelBufferGetPixelFormatType(input)
        guard FrameChain.supportedFormats.contains(format) else {
            return .failure(Note(message: "pixel format \(format) is not 8 or 10-bit 4:2:0", counts: false))
        }
        let picture = FrameUpscaler.pictureRegion(of: input)
        guard picture.width % 2 == 0, picture.height % 2 == 0 else {
            return .failure(Note(message: "picture \(picture.width)x\(picture.height) is odd", counts: false))
        }
        do {
            let built: FrameChain
            if let existing = chain as? FrameChain, chainSize.map({ $0 == (picture.width, picture.height) }) == true {
                built = existing
            } else {
                if device == nil {
                    device = MTLCreateSystemDefaultDevice()
                    queue = device?.makeCommandQueue()
                }
                guard let device, let queue else {
                    return .failure(Note(message: "no Metal device", counts: true))
                }
                built = try FrameChain(device: device, queue: queue, sourceWidth: picture.width,
                                       sourceHeight: picture.height, targetWidth: picture.width,
                                       targetHeight: picture.height, stages: [PassThroughStage()])
                chain = built
                chainSize = (picture.width, picture.height)
                EngineLog.emit("[HDR10Probe] chain built for \(picture.width)x\(picture.height)", category: .swPlayback)
            }
            let (output, ms) = try built.process(input, picture: picture)
            Self.copyAttachments(from: input, to: output)
            return .success((output, ms))
        } catch {
            return .failure(Note(message: "chain: \(error)", counts: true))
        }
        #endif
    }

    /// Everything the decoder attached, minus the keys that describe the input's geometry: the chain's
    /// output is the picture region alone, so a clean aperture would crop it a second time.
    static func copyAttachments(from input: CVPixelBuffer, to output: CVPixelBuffer) {
        CVBufferRemoveAllAttachments(output)
        guard let attachments = CVBufferCopyAttachments(input, .shouldPropagate) as? [String: Any] else { return }
        let dropped: Set<String> = [
            kCVImageBufferCleanApertureKey as String, kCVImageBufferPreferredCleanApertureKey as String,
            kCVImageBufferFieldCountKey as String, kCVImageBufferFieldDetailKey as String,
            kCVImageBufferDisplayDimensionsKey as String,
        ]
        CVBufferSetAttachments(output, attachments.filter { !dropped.contains($0.key) } as CFDictionary, .shouldPropagate)
    }

    private func notePassThrough(_ message: String) {
        guard message != lastNote else { return }
        lastNote = message
        EngineLog.emit("[HDR10Probe] passing frames through: \(message)", category: .swPlayback)
    }

    private func noteTiming(_ ms: Double, pts: CMTime) {
        windowGPUms.append(ms)
        guard windowGPUms.count == Self.timingWindow else { return }
        defer { windowGPUms.removeAll() }
        guard timingLinesLogged < Self.timingLines else { return }
        timingLinesLogged += 1
        let mean = windowGPUms.reduce(0, +) / Double(windowGPUms.count)
        EngineLog.emit(String(format: "[HDR10Probe] chain gpu %.2f ms mean, %.2f ms max over %d frames (frame %d, pts %.2f s)",
                              mean, windowGPUms.max() ?? 0, windowGPUms.count, frames, pts.seconds),
                       category: .swPlayback)
    }

    /// "x420 3840x2160 tf=SMPTE_ST_2084_PQ prim=ITU_R_2020 mtx=ITU_R_2020 mdcv=peak 1000 min 0.0050 cll=1000/400".
    static func describe(_ buffer: CVPixelBuffer) -> String {
        func tag(_ key: CFString) -> String { (CVBufferCopyAttachment(buffer, key, nil) as? String) ?? "-" }
        func bytes(_ key: CFString) -> Data? { CVBufferCopyAttachment(buffer, key, nil) as? Data }
        return "\(fourCC(CVPixelBufferGetPixelFormatType(buffer))) "
            + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
            + "tf=\(tag(kCVImageBufferTransferFunctionKey)) prim=\(tag(kCVImageBufferColorPrimariesKey)) "
            + "mtx=\(tag(kCVImageBufferYCbCrMatrixKey)) "
            + "mdcv=\(HDR10StaticMetadata.describe(masteringDisplayColorVolume: bytes(kCVImageBufferMasteringDisplayColorVolumeKey)) ?? "-") "
            + "cll=\(HDR10StaticMetadata.describe(contentLightLevel: bytes(kCVImageBufferContentLightLevelInfoKey)) ?? "-")"
    }

    /// What a format description made from the buffer carries, which is what the renderer hands the
    /// display layer: the renderer builds its description the same way (`createSampleBuffer`).
    static func describeFormatDescription(of buffer: CVPixelBuffer) -> String {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return "not created" }
        func ext(_ key: CFString) -> Data? { CMFormatDescriptionGetExtension(description, extensionKey: key) as? Data }
        let mdcv = HDR10StaticMetadata.describe(
            masteringDisplayColorVolume: ext(kCMFormatDescriptionExtension_MasteringDisplayColorVolume)) ?? "-"
        let cll = HDR10StaticMetadata.describe(
            contentLightLevel: ext(kCMFormatDescriptionExtension_ContentLightLevelInfo)) ?? "-"
        return "mdcv=\(mdcv) cll=\(cll)"
    }

    private static func fourCC(_ code: OSType) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> UInt32($0)) & 0xFF))) }
        return String(chars)
    }
}
