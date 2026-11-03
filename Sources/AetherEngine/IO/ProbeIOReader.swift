import Foundation

/// The accounting seam is below disc recognition/adaptation, so sparse reads and rereads count too.
final class ProbeIOReader: IOReader, @unchecked Sendable {
    private let reader: IOReader
    private let control: ProbeControl

    init(reader: IOReader, control: ProbeControl) {
        self.reader = reader
        self.control = control
        control.interrupt { reader.cancel() }
    }

    var discImageProbeEnabled: Bool { reader.discImageProbeEnabled }

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
