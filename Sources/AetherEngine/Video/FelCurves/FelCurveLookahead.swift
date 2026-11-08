// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CoreMedia
import CoreVideo
import Dovi
import Foundation

/// Folds a Profile 7 FEL source's enhancement layer into the luma curve of its Profile 8.1 RPU, per scene.
///
/// Sits between the demuxer and the segment producer and holds back one GOP at a time: every packet read
/// (video and audio, in read order) is buffered until the next video keyframe, so each scene that starts
/// inside the GOP can be fitted from its first picture before any of its frames is written. The packets
/// then come out in exactly the order they were read, the video ones converted to Profile 8.1 with the
/// stream's own mapping kept (MMR chroma included, applied by the platform decoder) and the enhancement
/// layer dropped.
///
/// A scene's luma residual comes from one picture pair: the base and enhancement layers are decoded from
/// the GOP's keyframe up to the scene's first frame, sampled (`FelCurveSampler`) and fitted (`FelCurveFit`).
/// It is then added to every frame's own luma polynomial for the whole scene, also across GOPs. A scene
/// without a usable residual (`disable_residual_flag`, an MEL RPU), or whose picture could not be decoded,
/// keeps the stream's mapping as it is.
final class FelCurveLookahead {
    /// A GOP longer than this many packets is released without a fit for the scenes that start in it.
    static let maxBufferedPackets = 1_200

    private let videoStreamIndex: Int32
    private let stream: UnsafeMutablePointer<AVStream>
    private let framing: VideoNALFraming
    private let timeBase: AVRational

    private var buffered: [UnsafeMutablePointer<AVPacket>] = []
    private var bufferedHasVideo = false
    private var ready: [UnsafeMutablePointer<AVPacket>] = []
    private var readyIndex = 0
    /// The curves in force at the end of the last GOP released, carried into the next one.
    private var carried: SceneFold?
    private var carriedValid = false
    /// Latched once any RPU raises `scene_refresh_flag`. Until then the stream says nothing about its scenes
    /// (some discs never set the flag, and their L1 does not move either), so every GOP is refitted at its
    /// keyframe, which costs one decoded picture pair.
    private var streamMarksScenes = false

    private var baseDecoder: HardwareVideoDecoder?
    private var enhancementDecoder: HardwareVideoDecoder?
    private var baseDecoderFailed = false
    private let pictures = PictureStore()

    /// Decided on the first video packet: true for a FEL source, which is then folded; false for anything
    /// else (MEL, no RPU), whose packets pass through untouched for the caller's own conversion.
    private(set) var isFolding: Bool?

    private(set) var scenesFitted = 0
    private(set) var scenesWithoutResidual = 0
    private(set) var scenesFailed = 0
    private(set) var conversionFailures = 0

    init(videoStreamIndex: Int32, stream: UnsafeMutablePointer<AVStream>, framing: VideoNALFraming) {
        self.videoStreamIndex = videoStreamIndex
        self.stream = stream
        self.framing = framing
        self.timeBase = stream.pointee.time_base
    }

    deinit {
        reset()
        baseDecoder?.close()
        enhancementDecoder?.close()
    }

    /// The next packet in read order, or nil at the end of the source. `read` is the demuxer's own read.
    func next(read: () throws -> UnsafeMutablePointer<AVPacket>?) throws -> UnsafeMutablePointer<AVPacket>? {
        while true {
            if readyIndex < ready.count {
                let packet = ready[readyIndex]
                readyIndex += 1
                if readyIndex == ready.count {
                    ready.removeAll(keepingCapacity: true)
                    readyIndex = 0
                }
                return packet
            }
            guard let packet = try read() else {
                guard !buffered.isEmpty else { return nil }
                release()
                continue
            }
            let isVideo = packet.pointee.stream_index == videoStreamIndex
            if isVideo, isFolding == nil {
                isFolding = Self.rpuElementType(packet, framing: framing) == "FEL"
                if isFolding == true {
                    EngineLog.emit("[FelCurves] FEL source: mapping kept in the Profile 8.1 RPU, enhancement-layer "
                                   + "luma residual folded into its luma curve per scene", category: .session)
                }
            }
            if isFolding == false || (!isVideo && buffered.isEmpty) {
                return packet
            }
            if isVideo, packet.pointee.flags & AV_PKT_FLAG_KEY != 0, bufferedHasVideo {
                release()
            }
            buffered.append(packet)
            if isVideo { bufferedHasVideo = true }
            if buffered.count >= Self.maxBufferedPackets { release() }
        }
    }

    /// Drops everything held, for a demuxer that has just been repositioned.
    func reset() {
        for i in readyIndex..<ready.count {
            var p: UnsafeMutablePointer<AVPacket>? = ready[i]
            trackedPacketFree(&p)
        }
        ready.removeAll()
        readyIndex = 0
        for packet in buffered {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        buffered.removeAll()
        bufferedHasVideo = false
        carried = nil
        carriedValid = false
    }

    // MARK: - One GOP

    /// One scene's luma residual on the pivots of its first frame, and that frame's luma with it added, which
    /// stands in for a frame whose own luma curve has other pivots.
    private struct SceneFold {
        let residual: FelCurve
        let fallbackLuma: FelCurve

        func luma(for own: FelCurve?) -> FelCurve {
            own.flatMap { $0.adding(residual) } ?? fallbackLuma
        }
    }

    private struct Frame {
        let packet: UnsafeMutablePointer<AVPacket>
        let pts: Int64
        let info: FelRpuInfo?
    }

    private func release() {
        let frames = buffered.compactMap { packet -> Frame? in
            guard packet.pointee.stream_index == videoStreamIndex else { return nil }
            let pts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
            return Frame(packet: packet, pts: pts, info: Self.rpuInfo(packet, framing: framing))
        }
        let assignment = folds(for: frames)
        for (frame, fold) in zip(frames, assignment) {
            let luma = fold?.luma(for: frame.info?.luma)
            // A refused RPU is dropped and the packet rebuilt without its enhancement layer, as on the plain
            // route: the frame shows its HDR10 base. Logged once, since the producer skips its own conversion.
            if !DoviRpuConverter.convertPacketToProfile81KeepingMapping(
                frame.packet, framing: framing, rewrite: luma.map { curve in { curve.apply(to: $0, component: 0) } }) {
                conversionFailures += 1
                if conversionFailures == 1 {
                    EngineLog.emit("[FelCurves] DV P7->8.1 conversion failed for a packet; dropped the RPU, "
                                   + "degrading affected frames to the HDR10 base", category: .session)
                }
            }
        }
        ready.append(contentsOf: buffered)
        buffered.removeAll(keepingCapacity: true)
        bufferedHasVideo = false
    }

    /// The scene fold of each frame, in the order given (decode order); nil keeps the stream's mapping.
    private func folds(for frames: [Frame]) -> [SceneFold?] {
        guard !frames.isEmpty else { return [] }
        let display = frames.indices.sorted { frames[$0].pts < frames[$1].pts }
        // A scene starts at a frame whose RPU raises scene_refresh_flag, and at the first frame shown at all.
        var starts: [Int] = display.filter { frames[$0].info?.sceneRefresh == true }
        if !starts.isEmpty { streamMarksScenes = true }
        if !carriedValid, let first = display.first, starts.first != first {
            starts.insert(first, at: 0)
        }
        // Without scene marks the GOP's keyframe (first in decode order) opens a curve of its own.
        if !streamMarksScenes, !starts.contains(0) {
            starts.append(0)
        }

        var fitted: [Int: SceneFold?] = [:]
        let needPictures = starts.filter { frames[$0].info?.carriesResidual == true && frames[$0].info?.luma != nil }
        let decoded = needPictures.isEmpty ? [:] : decode(frames, wanted: Set(needPictures.map { frames[$0].pts }))
        for index in starts {
            guard let info = frames[index].info else {
                fitted[index] = .some(nil)
                scenesFailed += 1
                continue
            }
            guard let nlq = info.nlq?.first, let luma = info.luma else {
                fitted[index] = .some(nil)
                scenesWithoutResidual += 1
                continue
            }
            if let pair = decoded[frames[index].pts],
               let samples = FelCurveSampler.samples(base: pair.base, enhancement: pair.enhancement,
                                                     nlq: nlq, elBits: info.elBits) {
                let residual = FelCurveFit.lumaResidual(samples, pivots: luma.pivots, vdrBits: info.vdrBits)
                fitted[index] = luma.adding(residual).map { SceneFold(residual: residual, fallbackLuma: $0) }
                scenesFitted += 1
            } else {
                fitted[index] = .some(nil)
                scenesFailed += 1
            }
        }

        var result = [SceneFold?](repeating: nil, count: frames.count)
        var current = carried
        let startSet = Set(starts)
        for index in display {
            if startSet.contains(index), let curves = fitted[index] { current = curves }
            result[index] = current
        }
        carried = current
        carriedValid = true
        return result
    }

    // MARK: - Decoding

    private struct PicturePair {
        let base: CVPixelBuffer
        let enhancement: CVPixelBuffer
    }

    /// Decodes both layers in decode order until every wanted picture has come out of both decoders.
    private func decode(_ frames: [Frame], wanted: Set<Int64>) -> [Int64: PicturePair] {
        guard let base = openBaseDecoder() else { return [:] }
        let sorted = frames.map(\.pts).sorted()
        let gaps: [Int64] = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        let spacing: Int64 = gaps.min() ?? 1
        pictures.begin(wanted: wanted, timeBase: timeBase, frameSpacing: spacing)
        defer { pictures.end() }
        let lastNeeded = frames.lastIndex { wanted.contains($0.pts) } ?? (frames.count - 1)
        for frame in frames[...lastNeeded] {
            guard let copy = av_packet_clone(frame.packet) else { break }
            var owned: UnsafeMutablePointer<AVPacket>? = copy
            defer { trackedPacketFree(&owned) }
            let layers = DoviRpuConverter.separateDualLayers(copy, framing: framing, extractEL: true, extractParams: false)
            var el = layers.elPacket
            defer { if el != nil { trackedPacketFree(&el) } }
            base.decode(packet: copy)
            if let el, let decoder = enhancementDecoder ?? openEnhancementDecoder(from: el) {
                decoder.decode(packet: el)
            }
        }
        base.flushKeepingEpoch()
        enhancementDecoder?.flushKeepingEpoch()
        return pictures.pairs()
    }

    private func openBaseDecoder() -> HardwareVideoDecoder? {
        if let baseDecoder { return baseDecoder }
        guard !baseDecoderFailed else { return nil }
        let decoder = HardwareVideoDecoder()
        let store = pictures
        do {
            try decoder.open(stream: stream) { buffer, time, _ in store.put(buffer, at: time, layer: 0) }
        } catch {
            baseDecoderFailed = true
            EngineLog.emit("[FelCurves] base-layer decoder failed to open: \(error); scenes keep the mode 2 mapping",
                           category: .session)
            return nil
        }
        baseDecoder = decoder
        return decoder
    }

    /// The enhancement-layer decoder opens on the in-band parameter sets of its first keyframe.
    private func openEnhancementDecoder(from el: UnsafeMutablePointer<AVPacket>) -> HardwareVideoDecoder? {
        guard let data = el.pointee.data else { return nil }
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        A53SEIParser.forEachNAL(data, Int(el.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch (nal[0] >> 1) & 0x3F {
            case 32: vps = bytes
            case 33: sps = bytes
            case 34: pps = bytes
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        let decoder = HardwareVideoDecoder()
        let store = pictures
        do {
            try decoder.open(parameterSets: [vps, sps, pps], timeBase: timeBase) { buffer, time, _ in
                store.put(buffer, at: time, layer: 1)
            }
        } catch {
            return nil
        }
        enhancementDecoder = decoder
        return decoder
    }

    /// Collects the decoders' output for the wanted presentation times; written from VideoToolbox's
    /// callback queue, read on the pump thread after both decoders have been drained.
    private final class PictureStore: @unchecked Sendable {
        private let lock = NSLock()
        private var wanted: [Int64] = []
        private var tolerance: Double = 0
        private var seconds: Double = 0
        private var layers: [[Int64: CVPixelBuffer]] = [[:], [:]]

        func begin(wanted: Set<Int64>, timeBase: AVRational, frameSpacing: Int64) {
            lock.withLock {
                self.wanted = Array(wanted)
                seconds = av_q2d(timeBase)
                tolerance = 0.45 * Double(frameSpacing) * seconds
                layers = [[:], [:]]
            }
        }

        func put(_ buffer: CVPixelBuffer, at time: CMTime, layer: Int) {
            let t = CMTimeGetSeconds(time)
            lock.withLock {
                guard t.isFinite,
                      let pts = wanted.first(where: { abs(Double($0) * seconds - t) < tolerance }) else { return }
                layers[layer][pts] = buffer
            }
        }

        func pairs() -> [Int64: PicturePair] {
            lock.withLock {
                var out: [Int64: PicturePair] = [:]
                for (pts, base) in layers[0] {
                    if let el = layers[1][pts] { out[pts] = PicturePair(base: base, enhancement: el) }
                }
                return out
            }
        }

        func end() {
            lock.withLock { layers = [[:], [:]]; wanted = [] }
        }
    }

    // MARK: - RPU

    private static func rpuElementType(_ packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming) -> String? {
        DoviRpuConverter.enhancementLayerType(UnsafePointer(packet), framing: framing)
    }

    private static func rpuInfo(_ packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming) -> FelRpuInfo? {
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return nil }
        var info: FelRpuInfo?
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, len in
            guard info == nil, (nal[0] >> 1) & 0x3F == 62 else { return }
            guard let rpu = DoviRpuGuard.parse(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            info = FelRpuInfo.read(rpu)
        }
        return info
    }
}
#endif
