import Combine
import Foundation
import CoreGraphics
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#628 (ijuniorfu): enabling a PGS track on a Blu-ray remux took the process past 100% CPU, with
/// `imageForSubtitleRect` the heaviest frame on the Main Thread under `subtitleDrainTick`.
///
/// Two halves. The blit expanded a full-canvas 1920x1080 indexed plane pixel by pixel, twice (alpha
/// bounding box, then RGBA), measured at 5 ms per display set in release and 211 ms in a debug build
/// on an M1; it now resolves the palette once into a lookup table. And the drain tick decoded on the
/// MainActor, including the selection and seek backfill of a whole 75 s window in one go; the decode
/// now runs off it and only the apply half comes back.
struct Issue628PGSOffMainDecodeTests {

    // MARK: - Blit

    /// The pre-#628 algorithm, kept verbatim as the reference the lookup-table blit must match byte
    /// for byte (the #146 same-geometry replacement keys on the crop, so the crop may not move).
    private static func referenceRGBA(pixels: [UInt8], palette: [UInt8], width: Int, height: Int,
                                      stride: Int) -> (rgba: [UInt8], x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where palette[Int(pixels[y * stride + x]) * 4 + 3] >= 8 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cropW = maxX - minX + 1, cropH = maxY - minY + 1
        var rgba = [UInt8](repeating: 0, count: cropW * cropH * 4)
        for cy in 0..<cropH {
            for cx in 0..<cropW {
                let p = Int(pixels[(minY + cy) * stride + minX + cx]) * 4
                let b = Int(palette[p]), g = Int(palette[p + 1]), r = Int(palette[p + 2])
                let a = Int(palette[p + 3])
                let o = (cy * cropW + cx) * 4
                rgba[o] = UInt8((r * a + 127) / 255)
                rgba[o + 1] = UInt8((g * a + 127) / 255)
                rgba[o + 2] = UInt8((b * a + 127) / 255)
                rgba[o + 3] = UInt8(a)
            }
        }
        return (rgba, minX, minY, cropW, cropH)
    }

    private static func bytes(of image: CGImage) -> [UInt8] {
        // A deferred ImageIO provider can expose straight-alpha pixels. Compare the actual
        // rendered premultiplied RGBA contract against the original palette algorithm.
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        out.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return out
    }

    @Test("the lookup-table blit is byte-identical to the per-pixel one, crop and premultiply included",
          arguments: [UInt64(1), 7, 628, 4096])
    func blitMatchesReference(seed: UInt64) throws {
        var rng = SplitMix(seed: seed)
        let width = 96, height = 40, stride = 112   // stride > width: the padding must never be read
        var palette = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            for c in 0..<4 { palette[i * 4 + c] = UInt8(truncatingIfNeeded: rng.next()) }
        }
        // Around the threshold on purpose: 7 is invisible, 8 is not.
        palette[0 * 4 + 3] = 0; palette[1 * 4 + 3] = 7; palette[2 * 4 + 3] = 8; palette[3 * 4 + 3] = 255
        var pixels = [UInt8](repeating: 0, count: stride * height)
        for y in 8..<30 {
            for x in 11..<83 { pixels[y * stride + x] = UInt8(truncatingIfNeeded: rng.next()) }
        }
        for y in 0..<height {
            for x in width..<stride { pixels[y * stride + x] = 3 }   // opaque, outside the plane
        }

        let reference = try #require(Self.referenceRGBA(pixels: pixels, palette: palette,
                                                        width: width, height: height, stride: stride))
        let image = try pixels.withUnsafeMutableBufferPointer { px in
            try palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.x = 100; rect.y = 200
                rect.w = Int32(width); rect.h = Int32(height)
                rect.linesize.0 = Int32(stride)
                rect.data.0 = px.baseAddress
                rect.data.1 = pal.baseAddress
                return try #require(withUnsafeMutablePointer(to: &rect) {
                    EmbeddedSubtitleDecoder.imageForSubtitleRect($0, videoWidth: 1920, videoHeight: 1080)
                })
            }
        }
        #expect(image.cgImage.width == reference.w)
        #expect(image.cgImage.height == reference.h)
        #expect(Self.bytes(of: image.cgImage) == reference.rgba)
        #expect(Int((image.position.origin.x * 1920).rounded()) == 100 + reference.x)
        #expect(Int((image.position.origin.y * 1080).rounded()) == 200 + reference.y)
    }

    @Test("a plane with nothing above the alpha threshold yields no image")
    func invisiblePlaneYieldsNil() {
        var pixels = [UInt8](repeating: 1, count: 16 * 4)
        var palette = [UInt8](repeating: 255, count: 256 * 4)
        palette[1 * 4 + 3] = 7
        let image = pixels.withUnsafeMutableBufferPointer { px in
            palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.w = 16; rect.h = 4; rect.linesize.0 = 16
                rect.data.0 = px.baseAddress
                rect.data.1 = pal.baseAddress
                return withUnsafeMutablePointer(to: &rect) {
                    EmbeddedSubtitleDecoder.imageForSubtitleRect($0, videoWidth: 1920, videoHeight: 1080)
                }
            }
        }
        #expect(image == nil)
    }

    // MARK: - Drain tick

    /// The #587 fixture's SubRip stream: two cues, at 1 s and 3 s.
    private static let subripStreamIndex: Int32 = 1

    @MainActor
    private func engineWithHarvestedSubRip() throws -> (AetherEngine, SubtitlePacketStore, Demuxer) {
        let data = try #require(Data(base64Encoded: Issue587PreserveASSMarkupCodecGateTests.base64.joined()))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        let store = SubtitlePacketStore()
        let stream = try #require(demuxer.stream(at: Self.subripStreamIndex))
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == Self.subripStreamIndex {
                store.harvest(streamIndex: Self.subripStreamIndex, packet: pkt,
                              timeBase: stream.pointee.time_base)
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = store
        engine.isSubtitleActive = true
        engine.subtitleDrainTargets[.primary] = Self.subripStreamIndex
        engine.subtitleDrainDecoderFactoryForTesting = { index in
            guard let stream = demuxer.stream(at: index) else { return nil }
            return EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 16, sourceVideoHeight: 16)
        }
        engine.clock.sourceTime = 1.5
        return (engine, store, demuxer)
    }

    @MainActor
    @Test("a requested drain tick decodes off the MainActor and applies when it lands")
    func requestedTickDecodesOffMain() async throws {
        let (engine, _, demuxer) = try engineWithHarvestedSubRip()
        defer { demuxer.close() }

        engine.requestSubtitleDrainTick()
        // Nothing decoded on the caller's stack: the batch is in flight, not applied.
        let inFlight = try #require(engine.subtitleDrainTickInFlight)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.subtitleDrainCursors[.primary] == nil)

        await inFlight.value
        #expect(engine.subtitleDrainTickInFlight == nil)
        #expect(engine.subtitleCues.map(\.startTime) == [1, 3])
        #expect(engine.subtitleDrainCursors[.primary] != nil)
    }

    /// Every publish of `subtitleCues`, stamped with the drain tick that was current when it happened.
    @MainActor
    private final class CuePublications {
        var stamps: [(serial: UInt64, starts: [Double])] = []
    }

    @MainActor
    @Test("a batch whose channel was re-selected while it decoded is dropped, and the tick runs again")
    func reselectionDropsTheStaleBatch() async throws {
        let (engine, _, demuxer) = try engineWithHarvestedSubRip()
        defer { demuxer.close() }
        // Observed per publish rather than sampled after the await: the queued tick starts inside the
        // stale batch's landing and its own decode can land before this test resumes, so "still in
        // flight" and "nothing published yet" are scheduler outcomes, not the engine's (a CI run took
        // 65 s and caught the rerun already finished).
        let publications = CuePublications()
        let observation = engine.$subtitleCues.dropFirst().sink { cues in
            MainActor.assumeIsolated {
                publications.stamps.append((engine.subtitleDrainTickSerial, cues.map(\.startTime)))
            }
        }
        defer { observation.cancel() }

        engine.requestSubtitleDrainTick()
        let stale = try #require(engine.subtitleDrainTickInFlight)
        let staleSerial = engine.subtitleDrainTickSerial
        // What a selection does to the channel (selectSubtitleTrack): a fresh decoder and cursor.
        engine.subtitleDrainDecoders[.primary] = nil
        engine.subtitleDrainCursors[.primary] = nil
        engine.subtitleDrainTick()   // arrives while the stale batch is in flight: queued, not run
        #expect(engine.subtitleDrainTickRequested)

        await stale.value
        // The landing dropped its batch and started the queued tick, whether or not that one has
        // landed by now.
        #expect(engine.subtitleDrainTickSerial == staleSerial &+ 1)
        #expect(!engine.subtitleDrainTickRequested)
        if let rerun = engine.subtitleDrainTickInFlight { await rerun.value }
        #expect(!publications.stamps.contains { $0.serial == staleSerial },
                "the stale batch published nothing")
        #expect(engine.subtitleCues.map(\.startTime) == [1, 3])
    }

    @MainActor
    @Test("stopping the drainer while a batch decodes discards it")
    func stopDiscardsTheInFlightBatch() async throws {
        let (engine, _, demuxer) = try engineWithHarvestedSubRip()
        defer { demuxer.close() }

        engine.requestSubtitleDrainTick()
        let inFlight = try #require(engine.subtitleDrainTickInFlight)
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .subtitlesCleared)
        #expect(engine.subtitleDrainTickInFlight == nil)

        await inFlight.value
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.subtitleDrainCursors.isEmpty)
    }
}

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
