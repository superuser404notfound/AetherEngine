import Foundation
import Libavcodec
import Libavutil

/// #151: subtitle-only forward side reader. The producer pump harvests subtitle packets only as
/// far as its own forward park (#102), so the drainer's 60 s lead window (`subtitleDrainLeadSeconds`)
/// is empty beyond a few seconds on direct-play sources and a host-applied ADVANCE sync offset
/// finds no cues, text and bitmap alike. This reader fills the same session SubtitlePacketStore
/// up to playhead + lead independently of the producer: it reads every embedded subtitle stream
/// (all other streams discarded, #104), parks on the subtitle PTS axis, and resumes as the
/// playhead advances. Overlapping packets dedupe by PTS in the store; split-PES PGS sets assemble
/// under the `.prefetch` writer key so the pump's in-flight set is never corrupted.
///
/// This is the loop half only; positioning (bounded seek + byte-estimate fallback), lifecycle,
/// and seek re-anchoring live on the engine (`AetherEngine.startSubtitleForwardPrefetcher`),
/// mirroring the native subtitle readers (memory rule: all side readers share positioning fixes).
enum SubtitleForwardPrefetcher {

    /// Read/harvest until EOF, error, cancellation, or a nil playhead (engine gone). Returns the
    /// number of routed subtitle packets harvested. The demuxer must be positioned by the caller.
    /// Harvest-then-park: the packet whose PTS crosses `playhead + leadSeconds` is stored before
    /// the loop parks, so the store may hold one packet past the lead edge (harmless; the drainer
    /// window decides what decodes). The playhead is snapshot at start and refreshed only inside
    /// the park loop, matching the native readers: no MainActor hop per packet during a backfill
    /// burst.
    static func run(
        demuxer: Demuxer,
        store: SubtitlePacketStore,
        streamIndices: Set<Int32>,
        assemblyIndices: Set<Int32>,
        leadSeconds: Double,
        parkPollNanoseconds: UInt64,
        playhead: @Sendable () async -> Double?
    ) async -> Int {
        guard var playheadSnapshot = await playhead() else { return 0 }
        var harvested = 0
        var timeBaseCache: [Int32: AVRational] = [:]
        readLoop: while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else { break }
            let streamIdx = pkt.pointee.stream_index
            guard streamIndices.contains(streamIdx) else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                continue
            }
            let tb: AVRational
            if let cached = timeBaseCache[streamIdx] {
                tb = cached
            } else {
                tb = demuxer.stream(at: streamIdx)?.pointee.time_base ?? AVRational(num: 0, den: 1)
                timeBaseCache[streamIdx] = tb
            }
            store.harvest(streamIndex: streamIdx, packet: pkt, timeBase: tb,
                          assembleSplitDisplaySets: assemblyIndices.contains(streamIdx),
                          writer: .prefetch)
            harvested += 1
            let rawTS = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            // Park once the read passes the lead edge; a packet without a usable PTS (split-set
            // continuation chunks) never parks, its set's PCS anchor already did the pacing.
            guard rawTS != Int64.min, tb.num > 0, tb.den > 0 else { continue }
            let pktSeconds = Double(rawTS) * Double(tb.num) / Double(tb.den)
            while !Task.isCancelled, pktSeconds > playheadSnapshot + leadSeconds {
                guard let fresh = await playhead() else { break readLoop }
                playheadSnapshot = fresh
                if pktSeconds <= playheadSnapshot + leadSeconds { break }
                do { try await Task.sleep(nanoseconds: parkPollNanoseconds) } catch { break readLoop }
            }
        }
        return harvested
    }
}
