import Foundation

/// Lossless packet envelope for the software VOD read-ahead store. No decoded pixels or
/// source URL is retained. In particular DTS, duration and side data must survive a cache hit.
struct SoftwareStoredPacket: Sendable, Equatable {
    struct SideData: Sendable, Equatable {
        let type: UInt32
        let bytes: Data
    }
    // Consumer-only identity for decoder observations. Never encoded into the session spool.
    var cacheTimingEpoch: UInt64? = nil
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let position: Int64
    let streamIndex: Int32
    let flags: Int32
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let bytes: Data
    let sideData: [SideData]

    enum EnvelopeError: Error {
        case unknownVersion(UInt8)
        case truncated
        case trailingBytes(Int)
    }

    // AE#592: a fixed little-endian header followed by the raw bytes. The binary property list
    // this replaced uniqued every object through a Set, hashing the whole payload of every packet,
    // and that was the largest single cost of the software route's producer. The spool lives only
    // for its session, so the layout carries a version byte and no compatibility promise.
    //
    //   u8 version | i64 pts, dts, duration, position | i32 streamIndex, flags, tbNum, tbDen
    //   | u32 sideDataCount | u64 payloadCount | payload | per side data: u32 type, u64 count, bytes
    static let version: UInt8 = 1
    static let headerBytes = 1 + 4 * 8 + 4 * 4 + 4 + 8
    static let sideDataHeaderBytes = 4 + 8

    func encoded() throws -> Data {
        let total = sideData.reduce(Self.headerBytes + bytes.count) {
            $0 + Self.sideDataHeaderBytes + $1.bytes.count
        }
        var out = Data(capacity: total)
        out.append(Self.version)
        for value in [pts, dts, duration, position] { Self.append(value, to: &out) }
        for value in [streamIndex, flags, timeBaseNumerator, timeBaseDenominator] { Self.append(value, to: &out) }
        Self.append(UInt32(sideData.count), to: &out)
        Self.append(UInt64(bytes.count), to: &out)
        out.append(bytes)
        for entry in sideData {
            Self.append(entry.type, to: &out)
            Self.append(UInt64(entry.bytes.count), to: &out)
            out.append(entry.bytes)
        }
        return out
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = Reader(data: data)
        let version: UInt8 = try reader.read()
        guard version == Self.version else { throw EnvelopeError.unknownVersion(version) }
        let pts: Int64 = try reader.read()
        let dts: Int64 = try reader.read()
        let duration: Int64 = try reader.read()
        let position: Int64 = try reader.read()
        let streamIndex: Int32 = try reader.read()
        let flags: Int32 = try reader.read()
        let timeBaseNumerator: Int32 = try reader.read()
        let timeBaseDenominator: Int32 = try reader.read()
        let sideDataCount: UInt32 = try reader.read()
        let payload = try reader.bytes(count: try reader.read() as UInt64)
        var sideData: [SideData] = []
        sideData.reserveCapacity(Int(min(sideDataCount, 64)))
        for _ in 0..<sideDataCount {
            let type: UInt32 = try reader.read()
            sideData.append(SideData(type: type, bytes: try reader.bytes(count: try reader.read() as UInt64)))
        }
        guard reader.remaining == 0 else { throw EnvelopeError.trailingBytes(reader.remaining) }
        return SoftwareStoredPacket(
            pts: pts, dts: dts, duration: duration, position: position,
            streamIndex: streamIndex, flags: flags,
            timeBaseNumerator: timeBaseNumerator, timeBaseDenominator: timeBaseDenominator,
            bytes: payload, sideData: sideData)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var remaining: Int { data.endIndex - offset }

        mutating func read<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard remaining >= size else { throw EnvelopeError.truncated }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { raw in
                data.copyBytes(to: raw.bindMemory(to: UInt8.self), from: offset..<offset + size)
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func bytes(count: UInt64) throws -> Data {
            guard count <= UInt64(remaining) else { throw EnvelopeError.truncated }
            let end = offset + Int(count)
            // Audit PERF-109: a view of the record, not a copy; the caller copies once into its AVPacket.
            let slice = data[offset..<end]
            offset = end
            return slice
        }
    }
}
