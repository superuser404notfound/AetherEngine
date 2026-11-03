import Foundation

/// AE#860: what an origin's `Content-Type` says about a source whose URL has no disc-image extension.
///
/// A HINT, never a verdict. It sends the open to the disc adapter, and `DiscReader.wrap` decides from
/// the ISO 9660 / UDF structure whether there is a disc there at all; a mislabelled response falls
/// back to the streaming reader. A URL that did turn out to be a disc is remembered, so the paths
/// that gate on `Demuxer.isDiscImageURL` before any byte is read (request-header updates, the probe
/// reader, the next open of the same item) treat it like an `.iso` without asking the origin again.
enum DiscImageMediaType {

    /// `application/x-iso9660-image` is what most servers send for `.iso`, `application/x-cd-image`
    /// is the freedesktop alias, `application/vnd.efi.iso` the IANA registration, and
    /// `application/x-raw-disk-image` the freedesktop type for `.img`, which the extension gate accepts.
    static let mediaTypes: Set<String> = [
        "application/x-iso9660-image",
        "application/x-cd-image",
        "application/vnd.efi.iso",
        "application/x-udf-image",
        "application/x-raw-disk-image",
    ]

    /// Parameters dropped, case folded: `Application/X-ISO9660-Image; charset=binary` is the same type.
    static func isDiscImage(contentType: String?) -> Bool {
        essence(of: contentType).map(mediaTypes.contains) ?? false
    }

    /// `application/octet-stream` says nothing about the body, so it never routes on its own. A body
    /// served that way is checked for a volume signature instead (`bodyCarriesVolumeSignature`).
    static func isGeneric(contentType: String?) -> Bool {
        essence(of: contentType) == "application/octet-stream"
    }

    private static func essence(of contentType: String?) -> String? {
        guard let contentType,
              let essence = contentType.split(separator: ";", omittingEmptySubsequences: false).first
        else { return nil }
        return essence.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The volume descriptor identifier of sector 16: `CD001` for ISO 9660 (bridge discs included),
    /// `BEA01` opening a UDF volume recognition sequence, `NSR02` / `NSR03` for its UDF descriptor.
    static let volumeSignatureOffset = 16 * 2048 + 1
    static let volumeSignatureEnd = volumeSignatureOffset + 5
    private static let volumeSignatures: Set<[UInt8]> = Set(["CD001", "BEA01", "NSR02", "NSR03"].map { Array($0.utf8) })

    /// A hint like the declared type: the disc readers still decide whether a playable disc is there.
    static func bodyCarriesVolumeSignature(_ prefix: [UInt8]) -> Bool {
        guard prefix.count >= volumeSignatureEnd else { return false }
        return volumeSignatures.contains(Array(prefix[volumeSignatureOffset..<volumeSignatureEnd]))
    }

    /// What the open learned, as one verdict: a declared disc type, or a generic type over a body
    /// with a volume signature at sector 16.
    static func suggestsDiscImage(contentType: String?, prefix: [UInt8]) -> Bool {
        isDiscImage(contentType: contentType)
            || (isGeneric(contentType: contentType) && bodyCarriesVolumeSignature(prefix))
    }

    private static let knownLock = NSLock()
    nonisolated(unsafe) private static var known: [URL] = []

    static func isKnownDiscImage(_ url: URL) -> Bool {
        knownLock.withLock { known.contains(url) }
    }

    static func noteDiscImage(_ url: URL) {
        knownLock.withLock {
            known.removeAll { $0 == url }
            known.append(url)
            if known.count > 32 { known.removeFirst() }
        }
    }

    static func forgetDiscImage(_ url: URL) {
        knownLock.withLock { known.removeAll { $0 == url } }
    }
}
