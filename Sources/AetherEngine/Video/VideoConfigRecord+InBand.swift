import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// HEVC sources whose parameter sets live in-band (`hev1` written with `xps_inband`, the common
/// Dolby Vision MP4 recipes) ship an hvcC with `numOfArrays = 0`. AVPlayer reads the parameter sets
/// out of the samples, but every consumer that builds a format description from the record alone
/// cannot: the hardware-decode probe, `HardwareVideoDecoder`, and the dual-layer decoder's
/// picture-order seed. The native path rebuilds the record for its init.mp4 (#19); these helpers are
/// that rebuild, shared, plus an in-place completion of the demuxer's own record for the
/// software route.
extension VideoConfigRecord {

    /// The VPS / SPS / PPS an in-band scan collects, first of each.
    struct HEVCParameterSets {
        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?

        var isComplete: Bool { vps != nil && sps != nil && pps != nil }

        /// Walk one length-prefixed packet and keep the first VPS / SPS / PPS seen. Only top-level
        /// NAL units count: a Profile 7 enhancement layer's parameter sets travel inside `unspec63`
        /// (type 63) wrappers and are never mistaken for the base layer's.
        mutating func collect(from data: UnsafePointer<UInt8>, size: Int, naluLengthSize: Int = 4) {
            var offset = 0
            while offset + naluLengthSize <= size {
                var nalLen = 0
                for i in 0..<naluLengthSize {
                    nalLen = (nalLen << 8) | Int(data[offset + i])
                }
                offset += naluLengthSize
                if nalLen == 0 || offset + nalLen > size { break }
                let nalType = (Int(data[offset]) >> 1) & 0x3F  // HEVC NAL type: bits 1..6 of byte 0
                switch nalType {
                case 32 where vps == nil: vps = Array(UnsafeBufferPointer(start: data + offset, count: nalLen))
                case 33 where sps == nil: sps = Array(UnsafeBufferPointer(start: data + offset, count: nalLen))
                case 34 where pps == nil: pps = Array(UnsafeBufferPointer(start: data + offset, count: nalLen))
                default: break
                }
                offset += nalLen
            }
        }
    }

    /// The source record's 22-byte header with `numOfArrays = 3` and one array each for the VPS,
    /// SPS and PPS (1-byte type, 2-byte numNalus = 1, 2-byte nalUnitLength, NAL bytes).
    static func hevcRecord(header: UnsafePointer<UInt8>, vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        var hvcC: [UInt8] = []
        hvcC.reserveCapacity(22 + 1 + 5 * 3 + vps.count + sps.count + pps.count)
        for i in 0..<22 { hvcC.append(header[i]) }
        hvcC.append(3)
        func appendArray(nalUnitType: UInt8, nal: [UInt8]) {
            hvcC.append(0x80 | (nalUnitType & 0x3F))
            hvcC.append(0); hvcC.append(1)
            let nl = UInt16(nal.count)
            hvcC.append(UInt8(nl >> 8)); hvcC.append(UInt8(nl & 0xFF))
            hvcC.append(contentsOf: nal)
        }
        appendArray(nalUnitType: 32, nal: vps)
        appendArray(nalUnitType: 33, nal: sps)
        appendArray(nalUnitType: 34, nal: pps)
        return hvcC
    }

    /// Input the in-band scan may read in total, foreign streams included. Parameter sets sit at the
    /// first IRAP, so a few packets find them; this only caps a stream that never carries any.
    static let inBandScanByteBudget = 16 * 1024 * 1024

    static func scanMayContinue(packetsRead: Int, videoPackets: Int, bytesRead: Int,
                                packetBudget: Int, readBudget: Int, byteBudget: Int) -> Bool {
        packetsRead < readBudget && videoPackets < packetBudget && bytesRead < byteBudget
    }

    /// Replace a video stream's empty hvcC with one rebuilt from the parameter sets at the head of the
    /// source, so the hardware-decode verdict and `HardwareVideoDecoder` see the record AVPlayer would
    /// have reconstructed for itself. Returns true when the record was replaced.
    ///
    /// Seekable sources only: the scan reads from the head and seeks back to 0, which is where every
    /// caller starts playback from anyway (the start position is applied later). A forward-only
    /// source is left alone, and keeps today's route. Runs off the main actor; it reads packets.
    ///
    /// The scan is bounded in packets and in bytes: a stream that carries no parameter sets, or one
    /// whose packets are very large, ends it at `inBandScanByteBudget` of input rather than reading
    /// until the packet count runs out, and leaves the record as it was.
    @discardableResult
    static func completeHEVCRecordFromInBandParameterSets(
        demuxer: Demuxer, streamIndex: Int32, byteBudget: Int = inBandScanByteBudget
    ) -> Bool {
        // Stream access goes through `withStream`, never a pointer held across the packet reads: a
        // stop() closes the demuxer from another thread and frees its streams.
        let needsRebuild = demuxer.withStream(at: streamIndex) { stream -> Bool in
            guard let par = stream.pointee.codecpar,
                  par.pointee.codec_id == AV_CODEC_ID_HEVC,
                  let extradata = par.pointee.extradata else { return false }
            return HLSVideoEngine.configRecordNeedsInBandRebuild(extradata, size: Int(par.pointee.extradata_size))
        } ?? false
        guard needsRebuild, demuxer.isSourceSeekable else { return false }

        // Same budgets as the native rebuild: parameter sets are guaranteed at the first IRAP.
        let packetBudget = 16
        let readBudget = 512
        var sets = HEVCParameterSets()
        var videoPackets = 0
        var packetsRead = 0
        var bytesRead = 0
        demuxer.seek(to: 0)
        // The ceiling is also armed on the input, so one oversized read cannot spend more than the
        // budget between two checks of the loop.
        demuxer.beginInputByteBudget(Int64(byteBudget))
        // Scoped so the ceiling is disarmed before the rewind below, which it would otherwise refuse.
        do {
            defer { demuxer.endInputByteBudget() }
            while scanMayContinue(packetsRead: packetsRead, videoPackets: videoPackets, bytesRead: bytesRead,
                                  packetBudget: packetBudget, readBudget: readBudget, byteBudget: byteBudget),
                  !sets.isComplete {
                guard let pkt = try? demuxer.readPacket() else { break }
                var toFree: UnsafeMutablePointer<AVPacket>? = pkt
                defer { trackedPacketFree(&toFree) }
                packetsRead += 1
                bytesRead += Int(max(pkt.pointee.size, 0))
                guard pkt.pointee.stream_index == streamIndex else { continue }
                videoPackets += 1
                if let data = pkt.pointee.data {
                    sets.collect(from: data, size: Int(pkt.pointee.size))
                }
            }
        }
        demuxer.seek(to: 0)

        guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps else {
            EngineLog.emit(
                "[VideoConfigRecord] in-band parameter-set scan found none: packets=\(videoPackets) bytes=\(bytesRead) "
                + "vps=\(sets.vps != nil) sps=\(sets.sps != nil) pps=\(sets.pps != nil)",
                category: .engine
            )
            return false
        }
        let installed = demuxer.withStream(at: streamIndex) { stream -> (Int32, Int)? in
            guard let par = stream.pointee.codecpar,
                  let extradata = par.pointee.extradata,
                  HLSVideoEngine.configRecordNeedsInBandRebuild(extradata, size: Int(par.pointee.extradata_size))
            else { return nil }
            let record = hevcRecord(header: extradata, vps: vps, sps: sps, pps: pps)
            let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            guard let buf = av_malloc(record.count + pad) else { return nil }
            let typed = buf.assumingMemoryBound(to: UInt8.self)
            record.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { memcpy(typed, base, record.count) }
            }
            memset(typed + record.count, 0, pad)
            let oldSize = par.pointee.extradata_size
            av_freep(&par.pointee.extradata)
            par.pointee.extradata = typed
            par.pointee.extradata_size = Int32(record.count)
            return (oldSize, record.count)
        } ?? nil
        guard let (oldSize, newSize) = installed else { return false }
        EngineLog.emit(
            "[VideoConfigRecord] completed hvcC from in-band parameter sets: \(oldSize) B → \(newSize) B",
            category: .engine
        )
        return true
    }
}
