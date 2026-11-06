import Testing
import Foundation
import CoreMedia
import AudioToolbox
@testable import AetherEngine
import AetherLibavformat
import AetherLibavcodec

private enum JOCDecoderGate {
    /// GitHub's macOS runner VMs have no Atmos decoder: the `ec+3` converter refuses to open there
    /// ('fmt?') even after the primer, so one real open decides.
    @MainActor static func systemDecodesJOC() async -> Bool {
        await AtmosDecoderPrimer.shared.ensurePrimed()
        let demuxer = Demuxer()
        defer { demuxer.close() }
        guard (try? demuxer.open(url: AtmosOutputActivator.silentAtmosStream)) != nil,
              let index = (0..<Int32(8)).first(where: { i in
                  demuxer.stream(at: i)?.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_EAC3
              }),
              let entry = SoftwarePlaybackHost.firstEAC3Entry(demuxer: demuxer, streamIndex: index).entry,
              let stream = demuxer.stream(at: index)
        else { return false }
        do {
            try SoftwareEAC3AtmosDecoder(stream: stream, entry: entry, layout: .l714).close()
            return true
        } catch {
            print("[JOCDecoderGate] the system cannot open ec+3 here (\(error)), skipping")
            return false
        }
    }
}

/// The system-decoder route for E-AC-3 JOC (AE#995), driven with the silent Atmos stream the engine
/// ships for `AtmosOutputActivator`: a real JOC stream with a `dec3` box, so the converter opens in its
/// `ec+3` form exactly as on the device. On macOS that form needs the Atmos decoder registered first.
@Suite(.serialized, .timeLimit(.minutes(3)),
       .enabled("needs the system's Atmos decoder") { await JOCDecoderGate.systemDecodesJOC() })
@MainActor
struct SoftwareEAC3AtmosDecoderTests {

    private struct Opened {
        let demuxer: Demuxer
        let streamIndex: Int32
        let decoder: SoftwareEAC3AtmosDecoder
    }

    private func open(layout: SpatialSpeakerLayout = .l714) async throws -> Opened {
        await AtmosDecoderPrimer.shared.ensurePrimed()
        let demuxer = Demuxer()
        try demuxer.open(url: AtmosOutputActivator.silentAtmosStream)
        let index = try #require((0..<Int32(8)).first { i in
            demuxer.stream(at: i)?.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_EAC3
        })
        let entry = try #require(SoftwarePlaybackHost.firstEAC3Entry(demuxer: demuxer, streamIndex: index).entry)
        #expect(entry.carriesJOC)
        let stream = try #require(demuxer.stream(at: index))
        let decoder = try SoftwareEAC3AtmosDecoder(stream: stream, entry: entry, layout: layout)
        return Opened(demuxer: demuxer, streamIndex: index, decoder: decoder)
    }

    /// Every buffer the decoder produces for the stream's packets, the packet stamps shifted by
    /// `shift(packetNumber)` seconds.
    private func decodeAll(_ o: Opened, shift: (Int) -> Double = { _ in 0 }) throws -> (buffers: [CMSampleBuffer], packets: Int, firstPTS: Double) {
        var buffers: [CMSampleBuffer] = []
        var packets = 0
        var firstPTS = Double.nan
        let tb = try #require(o.demuxer.stream(at: o.streamIndex)).pointee.time_base
        while let packet = try o.demuxer.readPacket() {
            defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
            guard packet.pointee.stream_index == o.streamIndex else { continue }
            let offset = Int64((shift(packets) * Double(tb.den) / Double(tb.num)).rounded())
            packet.pointee.pts += offset
            packet.pointee.dts += offset
            if packets == 0 { firstPTS = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den) }
            packets += 1
            buffers += o.decoder.decode(packet: packet)
        }
        buffers += o.decoder.endOfStream()
        return (buffers, packets, firstPTS)
    }

    @Test("JOC decodes into the asked bed as 48 kHz PCM, one access unit of frames per packet, stamped back to back")
    func decodesIntoBed() async throws {
        let o = try await open()
        defer { o.decoder.close(); o.demuxer.close() }
        let run = try decodeAll(o)
        #expect(run.packets > 0)
        let first = try #require(run.buffers.first)
        let format = try #require(CMSampleBufferGetFormatDescription(first))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        #expect(asbd.mChannelsPerFrame == 12)
        #expect(asbd.mSampleRate == 48_000)
        // The converter trims its lead-in off the first packet's output; every later packet is one
        // access unit of frames.
        let perPacket = SoftwareEAC3AtmosDecoder.framesPerPacket
        #expect(CMSampleBufferGetNumSamples(first) < perPacket)
        #expect(run.buffers.dropFirst().allSatisfy { CMSampleBufferGetNumSamples($0) == perPacket })
        // The first stamp sits the converter's lead-in after the first packet, and each buffer starts where
        // the one before it ended.
        let lead = Double(SoftwareEAC3AtmosDecoder.leadingFrameOffset) / 48_000
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(first).seconds - (run.firstPTS + lead)) < 0.0005)
        for (a, b) in zip(run.buffers, run.buffers.dropFirst()) {
            let end = CMSampleBufferGetPresentationTimeStamp(a).seconds + Double(CMSampleBufferGetNumSamples(a)) / 48_000
            #expect(abs(CMSampleBufferGetPresentationTimeStamp(b).seconds - end) < 0.0005)
        }
    }

    @Test("a jump in the source's stamps moves the run's anchor by the jump")
    func jumpReanchors() async throws {
        let o = try await open()
        defer { o.decoder.close(); o.demuxer.close() }
        let jumpAt = 20
        let run = try decodeAll(o) { $0 >= jumpAt ? 5 : 0 }
        try #require(run.packets > jumpAt + 4)
        let last = try #require(run.buffers.last)
        let lastEnd = CMSampleBufferGetPresentationTimeStamp(last).seconds
            + Double(CMSampleBufferGetNumSamples(last)) / 48_000
        let lead = Double(SoftwareEAC3AtmosDecoder.leadingFrameOffset) / 48_000
        let frames = run.buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
        let expected = run.firstPTS + lead + Double(frames) / 48_000 + 5
        #expect(abs(lastEnd - expected) < 0.0005)
        // Before the jump the run is untouched.
        let early = run.buffers[1]
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(early).seconds
            - (run.firstPTS + lead + Double(CMSampleBufferGetNumSamples(run.buffers[0])) / 48_000)) < 0.0005)
    }

    @Test("a flush starts a new run on the next packet's stamp")
    func flushReanchors() async throws {
        let o = try await open()
        defer { o.decoder.close(); o.demuxer.close() }
        let epoch = o.decoder.feedEpoch
        var fed = 0
        var afterFlush: [CMSampleBuffer] = []
        var flushPTS = Double.nan
        let tb = try #require(o.demuxer.stream(at: o.streamIndex)).pointee.time_base
        while let packet = try o.demuxer.readPacket() {
            defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
            guard packet.pointee.stream_index == o.streamIndex else { continue }
            fed += 1
            if fed == 10 {
                o.decoder.flush()
                flushPTS = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
            }
            let out = o.decoder.decode(packet: packet)
            if fed >= 10 { afterFlush += out }
        }
        #expect(o.decoder.feedEpoch == epoch &+ 1)
        let first = try #require(afterFlush.first)
        let lead = Double(SoftwareEAC3AtmosDecoder.leadingFrameOffset) / 48_000
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(first).seconds - (flushPTS + lead)) < 0.0005)
    }
}
