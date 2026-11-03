import Foundation
import Testing
@testable import AetherEngine

/// AE#921 (davidkean): a bitmap sidecar was decoded whole on selection and kept every cue's RGBA
/// picture for the session (a film-length PGS track: 14.1 MB of file, 170.5 MB of pictures), and
/// its first picture showed only once the whole file was decoded. It is now read into packets and
/// drained around the playhead like an embedded track.
@Suite("#921 bitmap sidecar drains from packets")
struct Issue921SidecarBitmapDrainTests {

    /// A raw `.sup`: one epoch-start display set every `spacing` seconds from `start`, each cleared
    /// `shown` seconds later. Every segment carries its own `PG` header, the shape the sup demuxer
    /// hands over one segment per packet.
    static func makeSup(sets: Int, start: Double = 10, spacing: Double = 4, shown: Double = 2,
                        objectWidth: Int = 400, objectHeight: Int = 60) -> Data {
        func segment(_ pts: Double, _ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let ticks = UInt32(pts * 90_000)
            var out: [UInt8] = [0x50, 0x47]
            out += withUnsafeBytes(of: ticks.bigEndian, Array.init)
            out += [0, 0, 0, 0, type, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
            return out + payload
        }
        func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func pcs(_ number: Int, state: UInt8, objects: Bool) -> [UInt8] {
            var p = be16(1920) + be16(1080) + [0x10] + be16(number) + [state, 0x00, 0x00, objects ? 1 : 0]
            if objects { p += be16(0) + [0x00, 0x00] + be16(760) + be16(900) }
            return p
        }
        let wds = [1, 0] + be16(760) + be16(900) + be16(objectWidth) + be16(objectHeight)
        let pds: [UInt8] = [0, 0, 1, 0xEB, 0x80, 0x80, 0xFF]
        // One RLE line: `objectWidth` pixels of colour 1, then end of line.
        var rle: [UInt8] = []
        for _ in 0..<objectHeight {
            rle += [0x00, 0xC0 | UInt8(objectWidth >> 8), UInt8(objectWidth & 0xFF), 0x01, 0x00, 0x00]
        }
        let dataLength = rle.count + 4
        let ods = be16(0) + [0, 0xC0]
            + [UInt8(dataLength >> 16), UInt8((dataLength >> 8) & 0xFF), UInt8(dataLength & 0xFF)]
            + be16(objectWidth) + be16(objectHeight) + rle
        var out: [UInt8] = []
        for i in 0..<sets {
            let on = start + Double(i) * spacing
            out += segment(on, 0x16, pcs(i * 2, state: 0x80, objects: true))
            out += segment(on, 0x17, wds)
            out += segment(on, 0x14, pds)
            out += segment(on, 0x15, ods)
            out += segment(on, 0x80, [])
            let off = on + shown
            out += segment(off, 0x16, pcs(i * 2 + 1, state: 0x00, objects: false))
            out += segment(off, 0x17, wds)
            out += segment(off, 0x80, [])
        }
        return Data(out)
    }

    static func writeSup(sets: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue921-\(UUID().uuidString).sup")
        try makeSup(sets: sets).write(to: url)
        return url
    }

    @Test("a .sup read for packets carries no cues, one stored entry per display set")
    func readsPackets() async throws {
        let url = try Self.writeSup(sets: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await SubtitleDecoder.decodeFile(url: url, keepsBitmapPackets: true)
        #expect(result.cues.isEmpty)
        let source = try #require(result.bitmapSource)
        let packets = source.packets
        #expect(packets.count == 40)
        #expect(abs((packets.first?.ptsSeconds ?? 0) - 10) < 0.001)
        #expect(abs((packets.last?.ptsSeconds ?? 0) - 88) < 0.001)
        // The whole file was read, so no span of it can be mistaken for a harvest hole.
        #expect(source.store.hasReadSpan(from: -100, through: 10_000))
    }

    @Test("the whole-file decode is unchanged when packets are not asked for")
    func wholeFileDecodeStillWorks() async throws {
        let url = try Self.writeSup(sets: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await SubtitleDecoder.decodeFile(url: url)
        #expect(result.bitmapSource == nil)
        #expect(result.cues.count == 5)
    }

    @Test("decoded batches end every composition at its clear, never holding more than a batch")
    func decodedBatches() async throws {
        let url = try Self.writeSup(sets: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(try await SubtitleDecoder.decodeFile(
            url: url, keepsBitmapPackets: true).bitmapSource)
        var batches: [[SubtitleCue]] = []
        await source.forEachDecodedBatch(batchSize: 4) { batches.append($0) }
        #expect(batches.map(\.count) == [4, 4, 2])
        let cues = batches.flatMap { $0 }
        for (i, cue) in cues.enumerated() {
            guard case .image = cue.body else {
                Issue.record("non-image cue")
                continue
            }
            #expect(abs(cue.startTime - (10 + Double(i) * 4)) < 0.001)
            #expect(abs(cue.endTime - (12 + Double(i) * 4)) < 0.001)
        }
    }

    @MainActor
    private func drain(_ engine: AetherEngine) async {
        while let tick = engine.subtitleDrainTickInFlight { await tick.value }
    }

    @Test("selection decodes only the window around the playhead, and a backward seek restores it")
    @MainActor
    func drainsAroundThePlayhead() async throws {
        let url = try Self.writeSup(sets: 200)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(try await SubtitleDecoder.decodeFile(
            url: url, keepsBitmapPackets: true).bitmapSource)
        let engine = try AetherEngine()
        defer { engine.stopSubtitleDrainer(reason: .sessionStopped) }
        engine.isSubtitleActive = true
        engine.clock.sourceTime = 411   // set 100 shows 410...412
        engine.installSidecarBitmapSource(source, channel: .primary)
        await drain(engine)

        #expect(engine.subtitleDrainTargets[.primary] == SidecarBitmapSource.streamKey)
        #expect(engine.embeddedSubtitleDrainTargets.isEmpty)
        let active = engine.subtitleCues.filter { $0.startTime <= 411 && 411 < $0.endTime }
        #expect(active.count == 1)
        #expect(abs((active.first?.startTime ?? 0) - 410) < 0.001)
        // A window of 75 s holds about 19 sets, not the file's 200.
        #expect(engine.subtitleCues.count < 30)

        engine.clock.sourceTime = 51   // set 10 shows 50...52
        engine.requestSubtitleDrainTick()
        await drain(engine)
        let landed = engine.subtitleCues.filter { $0.startTime <= 51 && 51 < $0.endTime }
        #expect(landed.count == 1)
        #expect(abs((landed.first?.startTime ?? 0) - 50) < 0.001)
    }

    @Test("subtitles off and a new sidecar selection release the packets")
    @MainActor
    func releasesTheSource() async throws {
        let url = try Self.writeSup(sets: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stopSubtitleDrainer(reason: .sessionStopped) }
        engine.isSubtitleActive = true
        let first = try #require(try await SubtitleDecoder.decodeFile(
            url: url, keepsBitmapPackets: true).bitmapSource)
        engine.installSidecarBitmapSource(first, channel: .primary)
        await drain(engine)
        engine.cancelSidecarTask()
        #expect(engine.sidecarBitmapSources.isEmpty)
        #expect(engine.subtitleDrainTargets.isEmpty)

        let second = try #require(try await SubtitleDecoder.decodeFile(
            url: url, keepsBitmapPackets: true).bitmapSource)
        engine.installSidecarBitmapSource(second, channel: .secondary)
        await drain(engine)
        engine.clearSecondarySubtitle()
        #expect(engine.sidecarBitmapSources.isEmpty)
        #expect(engine.subtitleDrainTargets.isEmpty)
    }
}
