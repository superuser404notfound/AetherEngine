import Foundation

/// A file entry discovered in an ISO9660 directory.
struct DiscFile: Equatable, Sendable {
    let name: String      // version suffix (";1") and "." / ".." stripped
    let startSector: Int  // logical block address
    let length: Int       // bytes
}

enum DiscError: Error, Equatable {
    case notISO9660
    case notUDF
    case directoryNotFound(String)
    case malformed(String)
}

/// Read-only ISO9660 (ECMA-119) reader for the DVD-Video bridge filesystem.
/// Parses PVD and walks one directory level. Random-access via seekable IOReader.
final class ISO9660Reader {
    private let reader: IOReader
    let sectorSize: Int
    private let rootLBA: Int
    private let rootLength: Int

    init(reader: IOReader) throws {
        self.reader = reader
        // PVD is the 17th sector (index 16); always 2048 bytes regardless of logical block size.
        let pvd = try ISO9660Reader.readBytes(reader, at: 16 * 2048, count: 2048)
        guard pvd.count >= 190,
              pvd[1] == 0x43, pvd[2] == 0x44, pvd[3] == 0x30,   // "CD0"
              pvd[4] == 0x30, pvd[5] == 0x31 else {              // "01"
            throw DiscError.notISO9660
        }
        let bs = Int(pvd[128]) | (Int(pvd[129]) << 8)
        self.sectorSize = bs > 0 ? bs : 2048
        // Root directory record at PVD offset 156.
        guard let rootLBA = ISO9660Reader.le32(pvd, 156 + 2),
              let rootLength = ISO9660Reader.le32(pvd, 156 + 10) else {
            throw DiscError.malformed("truncated root directory record")
        }
        self.rootLBA = rootLBA
        self.rootLength = rootLength
        guard rootLength > 0 else { throw DiscError.malformed("empty root directory") }
    }

    func list(directory: String) throws -> [DiscFile] {
        let root = try readExtent(lba: rootLBA, length: rootLength)
        let entries = parseRecords(root)
        guard let dir = entries.first(where: { $0.isDir && $0.name == directory }) else {
            throw DiscError.directoryNotFound(directory)
        }
        let dirData = try readExtent(lba: dir.lba, length: dir.length)
        return parseRecords(dirData)
            .filter { !$0.isDir }
            .map { DiscFile(name: $0.name, startSector: $0.lba, length: $0.length) }
    }

    // MARK: - Record parsing

    private struct Record { let name: String; let isDir: Bool; let lba: Int; let length: Int }

    private func parseRecords(_ data: [UInt8]) -> [Record] {
        var out: [Record] = []
        var pos = 0
        while pos < data.count {
            let recLen = Int(data[pos])
            if recLen == 0 {
                // Zero length: rest of this 2048-block is padding. Jump to the
                // next block boundary; stop if that runs off the end.
                let next = ((pos / 2048) + 1) * 2048
                if next >= data.count { break }
                pos = next
                continue
            }
            guard pos + recLen <= data.count, recLen >= 34 else { break }
            let lenFI = Int(data[pos + 32])  // safe: recLen >= 34
            guard pos + 33 + lenFI <= data.count,
                  let lba = ISO9660Reader.le32(data, pos + 2),
                  let length = ISO9660Reader.le32(data, pos + 10) else { break }
            let flags = data[pos + 25]
            let isDir = (flags & 0x02) != 0
            let idBytes = Array(data[(pos + 33)..<(pos + 33 + lenFI)])
            pos += recLen
            if lenFI == 1, idBytes[0] <= 1 { continue }  // skip "." (0x00) and ".." (0x01)
            var name = String(decoding: idBytes, as: UTF8.self)
            if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
            out.append(Record(name: name, isDir: isDir, lba: lba, length: length))
        }
        return out
    }

    // MARK: - Raw IO

    private func readExtent(lba: Int, length: Int) throws -> [UInt8] {
        try ISO9660Reader.readBytes(reader, at: lba * sectorSize, count: length)
    }

    private static func readBytes(_ reader: IOReader, at offset: Int, count: Int) throws -> [UInt8] {
        guard reader.seek(offset: Int64(offset), whence: SEEK_SET) >= 0 else {
            throw DiscError.malformed("seek failed at \(offset)")
        }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        try buf.withUnsafeMutableBufferPointer { ptr in
            while got < count {
                let n = reader.read(ptr.baseAddress!.advanced(by: got), size: Int32(count - got))
                if n == 0 { break }            // EOF
                if n < 0 { throw DiscError.malformed("read error at \(offset + got)") }
                got += Int(n)
            }
        }
        if got < count { buf.removeLast(count - got) }
        return buf
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 3 < b.count else { return nil }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }
}
