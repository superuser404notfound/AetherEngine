import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// #921: a bitmap sidecar (a PGS `.sup`, VobSub) held as its compressed packets rather than as
/// decoded pictures. Decoding a whole sidecar up front kept every cue's RGBA image for the session
/// (a film-length PGS track: 14.1 MB of file, 170.5 MB of pictures) and showed nothing until the
/// last one was done. Its packets go into a packet store of their own instead, and the overlay
/// drainer decodes them around the playhead exactly as it does an embedded track, so the sidecar
/// gets the embedded track's bitmap byte budget and backscan for free.
///
/// The store is the sidecar's own, not the session's: the file is read whole, so nothing here is
/// ever a harvest hole, and the session store's per-stream and aggregate caps (sized for a window
/// of a stream the pump is still reading) would evict the start of a track nothing re-reads.
final class SidecarBitmapSource: @unchecked Sendable {
    /// The drain target key of a channel fed by a sidecar. Negative, so it can never name an
    /// embedded stream in the code that looks drain targets up in `subtitleTracks`.
    static let streamKey: Int32 = -2

    /// Cap on the retained compressed bytes. The file itself is the real bound; this only stops a
    /// crafted one from growing without limit. A film-length 4K PGS track is a fraction of it.
    static let byteCap = 256 * 1024 * 1024

    let store: SubtitlePacketStore
    let codecID: AVCodecID
    private var codecpar: UnsafeMutablePointer<AVCodecParameters>?

    /// Copies the stream's parameters, so the source outlives the container it was read from.
    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let source = stream.pointee.codecpar,
              EmbeddedSubtitleDecoder.isBitmapCodec(source.pointee.codec_id),
              let copy = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(copy, source) >= 0 else {
            var local: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&local)
            return nil
        }
        codecpar = copy
        codecID = source.pointee.codec_id
        store = SubtitlePacketStore(perStreamByteCap: Self.byteCap, aggregateByteCap: Self.byteCap)
        store.setProtectedStreams([Self.streamKey])
        // The read below runs from the first packet to EOF, so the whole timeline is read ground.
        store.noteHarvestAnchor(.pump, at: -.greatestFiniteMagnitude)
    }

    deinit {
        avcodec_parameters_free(&codecpar)
    }

    /// Store one demuxed packet. A raw `.sup` hands every PGS segment over as its own packet, which
    /// is the split shape MPEG-TS has, so it goes through the same display-set reassembly.
    func harvest(packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        store.harvest(streamIndex: Self.streamKey, packet: packet, timeBase: timeBase,
                      assembleSplitDisplaySets: codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
    }

    /// The file has been read to its end.
    func finishReading() {
        store.noteHarvestReach(.pump, through: .greatestFiniteMagnitude)
    }

    var packets: [StoredSubtitlePacket] {
        store.entries(streamIndex: Self.streamKey, from: -.greatestFiniteMagnitude,
                      through: .greatestFiniteMagnitude)
    }

    var retainedBytes: Int { store.totalRetainedBytes }

    /// A fresh decoder for the sidecar's stream. PGS takes its canvas from each composition; the
    /// video size is only the fallback for a codec that does not carry one.
    func makeDecoder(sourceVideoWidth: Int32 = 1920,
                     sourceVideoHeight: Int32 = 1080) -> EmbeddedSubtitleDecoder? {
        guard let codecpar else { return nil }
        return EmbeddedSubtitleDecoder(codecpar: codecpar, sourceVideoWidth: sourceVideoWidth,
                                       sourceVideoHeight: sourceVideoHeight)
    }

    /// Every cue of the sidecar, decoded in file order and handed over in batches of `batchSize`,
    /// so a consumer that needs each picture once (the OCR fill) never holds more than a batch.
    /// A composition is ended by the next stored packet on the stream, its own clear or the next
    /// set, the rule the drainer applies (#362).
    func forEachDecodedBatch(batchSize: Int = 32,
                             isCancelled: () -> Bool = { false },
                             _ body: ([SubtitleCue]) async -> Void) async {
        guard let decoder = makeDecoder() else { return }
        let entries = packets
        var batch: [SubtitleCue] = []
        for (index, entry) in entries.enumerated() {
            if isCancelled() { return }
            guard let event = AetherEngine.decodeStoredSubtitlePacket(entry, with: decoder) else { continue }
            let nextPTS = index + 1 < entries.count ? entries[index + 1].ptsSeconds : nil
            for cue in event.cues {
                guard let nextPTS, nextPTS > cue.startTime, nextPTS < cue.endTime else {
                    batch.append(cue)
                    continue
                }
                batch.append(cue.with(endTime: nextPTS))
            }
            if batch.count >= batchSize {
                await body(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty, !isCancelled() { await body(batch) }
    }
}
