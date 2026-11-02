import Foundation
import AetherLibavcodec
import AetherLibavutil

/// AVI MPEG-4's decode-order repair deliberately withholds packet PTS. Keep the packet unchanged;
/// qualify a separate presentation axis against frames emitted by that SAME decoder. Parsing owns
/// no pixels and runs only on the read-ahead producer. The short metadata lock never covers parsing.
final class SoftwarePacketCacheTiming: SoftwarePacketCacheTimingSource, @unchecked Sendable {
    private struct Entry {
        let position: Int64
        let size: Int
        let duration: Int64
        let key: Bool
        let cursor: SoftwarePacketDiskFIFO.Cursor
        var codecTick: Int64?
        var decodedTick: Int64?
        var paired = false
    }
    private let lock = NSLock()
    private let numerator: Int32
    private let denominator: Int32
    private let extradata: Data
    private let maximumEntries: Int
    private var epoch: UInt64?
    private var entries: [Int64: Entry] = [:]
    private var positions: [Int64: Int64] = [:]
    private var order: [Int64] = []
    private var published = 0
    private var metadataFloor: UInt64?
    private var discardedOffsetLimit: Int64 = 0
    private var invalid = false
    private var candidateOffset: Int64?
    private var calibrated = false
    private var pairs = 0
    private var keyPictures = 0
    private var sawKey = false
    // Producer-only state. Epoch changes are applied here, never by a main-thread seek.
    private var parserEpoch: UInt64?
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var byteOffset: Int64 = 0

    init(numerator: Int32, denominator: Int32, extradata: Data = Data(), maximumEntries: Int = 65_536) {
        self.numerator = numerator
        self.denominator = denominator
        self.extradata = extradata
        self.maximumEntries = max(16, maximumEntries)
    }

    deinit { releaseParser() }

    private func releaseParser() {
        if let parser { av_parser_close(parser) }
        parser = nil
        avcodec_free_context(&context)
    }

    private func resetProducer(_ token: UInt64) {
        releaseParser()
        byteOffset = 0
        parserEpoch = token
        parser = av_parser_init(Int32(AV_CODEC_ID_MPEG4.rawValue))
        context = avcodec_alloc_context3(nil)
        if let parser, let context {
            parser.pointee.flags |= PARSER_FLAG_USE_CODEC_TS
            if !extradata.isEmpty, extradata.count < Int(Int32.max) - 64,
               let raw = av_mallocz(extradata.count + 64) {
                context.pointee.extradata = raw.assumingMemoryBound(to: UInt8.self)
                context.pointee.extradata_size = Int32(extradata.count)
                extradata.copyBytes(to: context.pointee.extradata, count: extradata.count)
            }
        }
        lock.lock()
        epoch = token
        entries.removeAll(keepingCapacity: true); positions.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true); published = 0
        metadataFloor = nil; discardedOffsetLimit = 0
        invalid = parser == nil || context == nil || numerator <= 0 || denominator <= 0
        candidateOffset = nil; calibrated = false; pairs = 0; keyPictures = 0; sawKey = false
        lock.unlock()
    }

    func append(_ packet: SoftwareStoredPacket, cursor: SoftwarePacketDiskFIFO.Cursor, epoch token: UInt64) {
        if parserEpoch != token { resetProducer(token) }
        guard let parser, let context else { return }
        let start = byteOffset
        let (end, overflow) = start.addingReportingOverflow(Int64(packet.bytes.count))
        lock.lock()
        if entries.count >= maximumEntries {
            // Published records already live in ReadAhead's coverage, per-chunk residency and
            // keyframe indexes. Retiring a temporary parser/decoder pairing is NOT byte eviction.
            // Never advance metadataFloor here: doing so made a paused cache bar slide forward
            // as a fast source crossed this cap, although every earlier packet was still retained.
            if calibrated, published > 0 {
                removePrefixLocked(min(published, 1024))
            } else {
                // Qualification backpressure normally prevents this. If one unqualified GOP
                // exceeds the hard bound, fail closed instead of guessing or growing forever.
                invalid = true
            }
        }
        if overflow || packet.position < 0 || packet.bytes.isEmpty || packet.bytes.count > Int(Int32.max) - 64
            || positions[packet.position] != nil {
            invalid = true
        }
        let allowed = !invalid
        if allowed, cursor.chunkID >= (metadataFloor ?? 0) {
            entries[start] = Entry(position: packet.position, size: packet.bytes.count,
                duration: packet.duration, key: packet.flags & 1 != 0, cursor: cursor)
            positions[packet.position] = start; order.append(start)
        } else if allowed {
            discardedOffsetLimit = max(discardedOffsetLimit, end)
        }
        lock.unlock()
        guard allowed else { return }
        byteOffset = end
        var padded = packet.bytes
        padded.append(contentsOf: repeatElement(UInt8(0), count: 64))
        var outputs: [(Int64, Int64, Int)] = []
        var failed = false
        padded.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var consumed = 0
            var attempts = 0
            while consumed < packet.bytes.count {
                attempts += 1
                if attempts > 16 { failed = true; break }
                var output: UnsafeMutablePointer<UInt8>?
                var size: Int32 = 0
                let count = av_parser_parse2(parser, context, &output, &size,
                    base.advanced(by: consumed), Int32(packet.bytes.count - consumed),
                    Int64.min, Int64.min, start + Int64(consumed))
                guard count >= 0, count <= packet.bytes.count - consumed,
                      count > 0 || size > 0 else { failed = true; break }
                if size > 0 { outputs.append((parser.pointee.frame_offset, parser.pointee.pts, Int(size))) }
                consumed += Int(count)
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard epoch == token else { return }
        if failed { invalid = true }
        for (offset, pts, size) in outputs {
            if offset < discardedOffsetLimit { continue }
            // Never guess ownership for split/packed/dummy packets. A one-picture, whole-record
            // mapping is qualified; anything else leaves this epoch conservatively uncovered.
            guard var entry = entries[offset], entry.size == size, entry.codecTick == nil,
                  pts != Int64.min, let ticks = codecTicks(pts) else { invalid = true; continue }
            entry.codecTick = ticks; entries[offset] = entry
            pairLocked(offset)
        }
    }

    private func codecTicks(_ pts: Int64) -> Int64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let value = (Double(pts) * Double(denominator) / (1_200_000 * Double(numerator))).rounded()
        guard value.isFinite, abs(value) < 9e18 else { return nil }
        return Int64(value)
    }

    /// Called before filtering/render scheduling, with the decoder's repaired frame PTS and its
    /// COPY_OPAQUE packet identity. Duplicate/multi-picture ownership is deliberately refused.
    func observe(epoch token: UInt64, position: Int64, pts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == token, !invalid, pts != Int64.min,
              let offset = positions[position], var entry = entries[offset] else { return }
        if entry.decodedTick != nil {
            // A retained cached seek decodes the same record again. An identical result is harmless.
            if entry.decodedTick != pts { invalid = true }
            return
        }
        entry.decodedTick = pts; entries[offset] = entry
        pairLocked(offset)
    }

    private func pairLocked(_ offset: Int64) {
        guard var entry = entries[offset], !entry.paired,
              let codec = entry.codecTick, let decoded = entry.decodedTick else { return }
        entry.paired = true; entries[offset] = entry
        let (delta, overflow) = decoded.subtractingReportingOverflow(codec)
        guard !overflow else { invalid = true; return }
        if let candidateOffset, candidateOffset != delta { invalid = true; return }
        candidateOffset = delta
        if entry.key { keyPictures += 1; sawKey = true }
        if sawKey { pairs += 1 }
        if !calibrated, entry.key, keyPictures >= 2, pairs >= 16 {
            calibrated = true
            EngineLog.emit("[SWCacheClock] calibrated=1 offsetTicks=\(delta) pairs=\(pairs)", category: .swPlayback)
        }
    }

    func drain(epoch token: UInt64) -> SoftwarePacketCacheTimingBatch {
        lock.lock(); defer { lock.unlock() }
        guard epoch == token else { return .init(invalid: false, records: []) }
        guard !invalid, calibrated, let delta = candidateOffset else {
            return .init(invalid: invalid, records: [], oldestUsableChunk: metadataFloor,
                         calibrationPressure: !invalid && entries.count >= min(4096, maximumEntries / 2))
        }
        var result: [SoftwarePacketCacheTimingRecord] = []
        while published < order.count, result.count < 512 {
            let offset = order[published]
            guard let entry = entries[offset] else { published += 1; continue }
            guard let ticks = entry.codecTick else { break }
            let (pts, overflow) = ticks.addingReportingOverflow(delta)
            guard !overflow, pts != Int64.min else { invalid = true; break }
            result.append(.init(pts: pts, duration: entry.duration, key: entry.key, cursor: entry.cursor))
            published += 1
        }
        return .init(invalid: invalid, records: result, oldestUsableChunk: metadataFloor)
    }

    func seconds(position: Int64, epoch token: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard epoch == token, !invalid, calibrated, let delta = candidateOffset,
              let offset = positions[position], let tick = entries[offset]?.codecTick else { return nil }
        let (pts, overflow) = tick.addingReportingOverflow(delta)
        guard !overflow else { return nil }
        return Double(pts) * Double(numerator) / Double(denominator)
    }

    func evict(before chunk: UInt64, epoch token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == token else { return }
        discardLocked(before: chunk)
    }

    private func discardLocked(before chunk: UInt64) {
        metadataFloor = max(metadataFloor ?? 0, chunk)
        var count = 0
        for offset in order {
            guard let entry = entries[offset], entry.cursor.chunkID < chunk else { break }
            count += 1
        }
        removePrefixLocked(count)
    }

    private func removePrefixLocked(_ count: Int) {
        guard count > 0 else { return }
        for offset in order.prefix(count) {
            guard let entry = entries.removeValue(forKey: offset) else { continue }
            discardedOffsetLimit = max(discardedOffsetLimit, offset + Int64(entry.size))
            positions.removeValue(forKey: entry.position)
        }
        order.removeFirst(count)
        published = max(0, published - count)
    }
}
