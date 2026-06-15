import Foundation

struct MPLSPlaylist: Equatable {
    let clipIDs: [String]
    let durationTicks: UInt64
}

enum MPLSParser {
    static func parse(_ data: [UInt8]) -> MPLSPlaylist? {
        guard data.count >= 16,
              Array(data[0..<4]) == Array("MPLS".utf8) else { return nil }
        let plStart = be32(data, 8)
        guard plStart + 10 <= data.count else { return nil }
        let count = be16(data, plStart + 6)
        var pos = plStart + 10
        var clips: [String] = []
        var ticks: UInt64 = 0
        for _ in 0..<count {
            guard pos + 2 <= data.count else { return nil }
            let itemLen = be16(data, pos)
            let body = pos + 2
            guard body + 22 <= data.count, body + itemLen <= data.count else { return nil }
            let clip = String(decoding: data[body..<(body+5)], as: UTF8.self)
            let inT = UInt64(be32(data, body + 12))
            let outT = UInt64(be32(data, body + 16))
            clips.append(clip)
            if outT >= inT { ticks += (outT - inT) }
            pos = body + itemLen
        }
        guard !clips.isEmpty else { return nil }
        return MPLSPlaylist(clipIDs: clips, durationTicks: ticks)
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
