import Foundation

/// Recovery-point SEI is not an IDR NAL. A muxer's container key flag must not
/// erase that distinction when selecting Apple's independently decodable HLS path.
enum H264RecoveryPoint {
    /// Narrow, bounded recognizer for recovery_frame_cnt=0 and exact_match_flag=1.
    /// Unknown/malformed SEI is not evidence for changing the playback route.
    static func isImmediateExactRecovery(seiNAL: [UInt8]) -> Bool {
        guard seiNAL.count > 3, seiNAL.count <= 4096,
              seiNAL[0] & 0x80 == 0, seiNAL[0] & 31 == 6 else { return false }
        var body: [UInt8] = []
        var zeros = 0
        for byte in seiNAL.dropFirst() {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            body.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        var index = 0
        func extendedValue() -> Int? {
            var value = 0
            while index < body.count {
                let byte = body[index]
                index += 1
                value += Int(byte)
                if byte != 255 { return value }
            }
            return nil
        }
        while index < body.count {
            if index == body.count - 1 && body[index] == 0x80 { break }
            guard let type = extendedValue(), let size = extendedValue(),
                  size <= body.count - index else { return false }
            // ue(0) is the single bit 1; followed by exact_match_flag=1,
            // broken_link_flag and two changing_slice_group_idc bits (5 bits).
            if type == 6, size >= 1, body[index] & 0xc0 == 0xc0 { return true }
            index += size
        }
        return false
    }

    struct Evidence {
        private(set) var recoveryKeys = 0
        mutating func observe(containerKey: Bool, hasIDR: Bool, immediateExactRecovery: Bool) {
            if containerKey && !hasIDR && immediateExactRecovery { recoveryKeys += 1 }
        }
        /// Repeated actual recovery points, never a codec name, filename, frame
        /// rate, missing IDR alone, or a malformed sample, select compatibility.
        var requiresCompatibilityPath: Bool { recoveryKeys >= 3 }
    }
}
