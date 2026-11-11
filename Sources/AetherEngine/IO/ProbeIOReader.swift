import Foundation

/// The accounting seam is below disc recognition/adaptation, so sparse reads and rereads count too.
final class ProbeIOReader: IOReader, @unchecked Sendable {
    private let reader: IOReader
    private let control: ProbeControl
    private let closesReader: Bool

    /// `closesReader` for a reader the probe opened itself, whose caller closes this wrapper instead.
    init(reader: IOReader, control: ProbeControl, closesReader: Bool = false) {
        self.reader = reader
        self.control = control
        self.closesReader = closesReader
        control.interrupt { reader.cancel() }
    }

    var discImageProbeEnabled: Bool { reader.discImageProbeEnabled }

    /// The wrapped source when it is a disc folder, which the demuxer recognizes by conformance (AE#1028).
    var discDirectory: DiscDirectoryReader? { reader as? DiscDirectoryReader }

    /// `other` counted against the same control; its cancel replaces the wrapped reader's as the interrupt.
    func counting(_ other: IOReader) -> IOReader { ProbeIOReader(reader: other, control: control) }

    /// The folder with the files its recognition scan opens counted against the same control (AE#1033).
    func countingScan(of folder: DiscDirectoryReader) -> ProbeDiscDirectory {
        ProbeDiscDirectory(folder: folder, control: control)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        do {
            let allowed = try control.inputAllowance(size)
            let count = autoreleasepool { reader.read(buffer, size: allowed) }
            try control.consumedInput(count, requested: allowed)
            return count
        } catch {
            // The orchestrator rethrows the control's typed failure after the native call unwinds.
            return -1
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        guard !control.isStopped else { return -1 }
        let result = autoreleasepool { reader.seek(offset: offset, whence: whence) }
        return control.isStopped ? -1 : result
    }

    // A synchronous probe has no in-flight read at normal teardown, and never owns a host reader.
    func cancel() {}
    func close() { if closesReader { reader.close() } }
}

/// A disc folder as a controlled probe sees it (AE#1033). The playlists, IFOs and clip infos that
/// recognition opens count against the probe's limits, and a stopped probe opens no further file.
/// `endScan()` hands the clips back uncounted: the demuxer counts their joined stream as one source,
/// whose cancel reaches every open clip, where a per-file wrapper would count them twice.
final class ProbeDiscDirectory: DiscDirectoryReader, @unchecked Sendable {
    private let folder: DiscDirectoryReader
    private let control: ProbeControl
    private let lock = NSLock()
    private var scanning = true

    init(folder: DiscDirectoryReader, control: ProbeControl) {
        self.folder = folder
        self.control = control
    }

    var discFiles: [(path: String, size: Int64)] { folder.discFiles }
    var preferredPlaylist: String? { folder.preferredPlaylist }

    func endScan() { lock.withLock { scanning = false } }

    func openDiscFile(_ path: String) -> IOReader? {
        guard lock.withLock({ scanning }) else { return folder.openDiscFile(path) }
        guard !control.isStopped, let file = folder.openDiscFile(path) else { return nil }
        return ProbeIOReader(reader: file, control: control, closesReader: true)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    func close() {}
}

/// Reuses the engine HTTP transport with speculation disabled; no playback transport policy changes.
/// Its AVIO allocation stays owned here, separate from the bridge FFmpeg uses for the counted input.
/// A metadata probe's sequential ranges grow from 64 KiB to `rangeCeiling` (AE#927); a preview's
/// bounded window keeps them at 64 KiB, since its reads are a seek and one keyframe.
final class ProbeHTTPReader: IOReader, @unchecked Sendable {
    static let rangeCeiling = 4 * 1024 * 1024
    private let reader: AVIOReader
    private let isDiscImageURL: Bool
    /// AE#860: an extensionless URL counts once its response declared a disc image type, or served
    /// `application/octet-stream` over a volume signature; the disc readers still decide.
    var discImageProbeEnabled: Bool {
        isDiscImageURL || reader.openSuggestsDiscImage
            || DiscImageMediaType.isDiscImage(contentType: reader.openResponseContentType)
    }

    init(url: URL, headers: [String: String], control: ProbeControl,
         boundedWindowBytes: Int? = nil) {
        isDiscImageURL = Demuxer.isDiscImageURL(url)
        reader = AVIOReader(
            url: url, extraHeaders: headers, label: "probe",
            chunkSize: 64 * 1024, prefetchEnabled: false,
            chunkRequestTimeout: 2, chunkMaxRetries: 1,
            boundedInitialFetch: boundedWindowBytes.map { Int64($0) },
            windowHighWater: boundedWindowBytes, probeControl: control,
            probeRangeCeiling: boundedWindowBytes == nil ? Self.rangeCeiling : nil)
    }

    func open() throws { try reader.open() }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer else { return -1 }
        let count = reader.read(into: buffer, size: size)
        return count == FFmpegErr.eof ? 0 : count
    }
    func seek(offset: Int64, whence: Int32) -> Int64 { reader.seek(offset: offset, whence: whence) }
    func cancel() { reader.markClosed() }
    func close() {
        reader.markClosed()
        reader.finishProbeTransfers()
        reader.close()
    }
}
