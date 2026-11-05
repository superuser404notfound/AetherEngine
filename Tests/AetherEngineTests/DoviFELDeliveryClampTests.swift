import Testing
import Foundation
import Dovi
import AetherLibavcodec
@_spi(Diagnostics) @testable import AetherEngine

@Suite(.serialized)
struct DoviFELDeliveryClampTests {
    @Test func explicitOptInAndControlArm() {
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: false, override: nil))
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: false, override: "1"))
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: true, override: "0"))
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: true, override: nil, enhancementLayerIsComposed: true))
        #if DualLayerDolbyVision
        #expect(DoviFELDeliveryClamp.shouldProbe(requested: true, override: nil))
        #expect(DoviFELDeliveryClamp.shouldProbe(requested: true, override: "1"))
        #else
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: true, override: nil))
        #expect(!DoviFELDeliveryClamp.shouldProbe(requested: true, override: "1"))
        #endif
        let defaults = LoadOptions()
        let optedIn = LoadOptions(alignFELDeliveryLuminance: true)
        #expect(!defaults.alignFELDeliveryLuminance)
        #expect(optedIn.alignFELDeliveryLuminance)
        #expect(defaults != optedIn)
        #expect(SessionOptionCorrection.refusedFields(from: defaults, to: optedIn).isEmpty)
    }

    private func remux(_ nal: [UInt8], clamp: DoviFELDeliveryClamp?) throws -> [UInt8] {
        let nals: [[UInt8]] = [[2, 1, 0xAA], nal, [126, 1, 0xBB]]
        var bytes: [UInt8] = []
        for n in nals {
            bytes += [UInt8(truncatingIfNeeded: n.count >> 24), UInt8(truncatingIfNeeded: n.count >> 16),
                      UInt8(truncatingIfNeeded: n.count >> 8), UInt8(truncatingIfNeeded: n.count)] + n
        }
        let packet = try #require(av_packet_alloc())
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
        #expect(av_new_packet(packet, Int32(bytes.count)) == 0)
        bytes.withUnsafeBytes { _ = memcpy(packet.pointee.data, $0.baseAddress!, $0.count) }
        #expect(DoviRpuConverter.convertPacketToProfile81(packet, framing: .lengthPrefixed(size: 4), deliveryClamp: clamp))
        var output: [UInt8]?
        var types: [UInt8] = []
        A53SEIParser.forEachNAL(packet.pointee.data!, Int(packet.pointee.size), .lengthPrefixed(size: 4)) { ptr, count in
            let type = (ptr[0] >> 1) & 63
            types.append(type)
            if type == 62 { output = Array(UnsafeBufferPointer(start: ptr, count: count)) }
        }
        #expect(types == [1, 62])
        return try #require(output)
    }

    #if DualLayerDolbyVision
    @Test func gatesAndCanonicalPQ() {
        #expect(DoviFELDeliveryClamp.pqCode(nits: 1000) == 3079)
        #expect(DoviFELDeliveryClamp.pqCode(nits: 4000) == 3696)
        let eligible = DoviFELDeliveryClamp.select(profile: 7, elType: "FEL", masteringNits: 1000, sourceMaxPQ: 3696, enabled: true)
        #expect(eligible?.targetPQ == 3079)
        for peak: Double? in [nil, 0, -1, .nan, .infinity, 1001] {
            #expect(DoviFELDeliveryClamp.select(profile: 7, elType: "FEL", masteringNits: peak, sourceMaxPQ: 4095, enabled: true) == nil)
        }
        #expect(DoviFELDeliveryClamp.select(profile: 8, elType: "FEL", masteringNits: 1000, sourceMaxPQ: 4095, enabled: true) == nil)
        #expect(DoviFELDeliveryClamp.select(profile: 7, elType: "MEL", masteringNits: 1000, sourceMaxPQ: 4095, enabled: true) == nil)
        #expect(DoviFELDeliveryClamp.select(profile: 7, elType: nil, masteringNits: 1000, sourceMaxPQ: 4095, enabled: true) == nil)
        #expect(DoviFELDeliveryClamp.select(profile: 7, elType: "FEL", masteringNits: 1000, sourceMaxPQ: 3695, enabled: true) == nil)
        #expect(DoviFELDeliveryClamp.select(profile: 7, elType: "FEL", masteringNits: 1000, sourceMaxPQ: 4095, enabled: false) == nil)
    }

    @Test func masteringSEIReadsNitsAndRejectsTruncation() {
        // ST2086 eight 16-bit chromaticities, then maximum and minimum luminance in 0.0001 nits.
        let payload = [UInt8](repeating: 1, count: 16) + [0, 0x98, 0x96, 0x80, 1, 1, 1, 1]
        let bytes: [UInt8] = [0, 0, 0, 1, 78, 1, 137, 24] + payload + [0x80]
        let peak = bytes.withUnsafeBufferPointer { DoviFELDeliveryClamp.masteringPeak($0.baseAddress!, $0.count, framing: .annexB) }
        #expect(peak == 1000)
        let truncated = Array(bytes.dropLast(4))
        #expect(truncated.withUnsafeBufferPointer { DoviFELDeliveryClamp.masteringPeak($0.baseAddress!, $0.count, framing: .annexB) } == nil)
    }

    @Test func firstCorruptRPUIsNotReplacedByALaterRPU() {
        let bad: [UInt8] = [0, 0, 0, 1, 124, 1, 0x19, 0x80]
        let good = [UInt8]([0, 0, 0, 1]) + DoviComposedFrameRpuTests.felNAL
        let bytes = bad + good
        let first = bytes.withUnsafeBufferPointer { DoviFELDeliveryClamp.firstRPU($0.baseAddress!, $0.count, framing: .annexB) }
        #expect(first.found)
        #expect(first.elType == nil)
        #expect(first.sourceMaxPQ == 0)
    }

    @Test func inheritedMetadataRPUSurvivesActiveClamp() throws {
        let nal = DoviRpuGuardTests.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]], residual: .fel)
        let clamp = DoviFELDeliveryClamp(targetNits: 1000, targetPQ: 3079)
        let control = try remux(nal, clamp: nil)
        #expect(try remux(nal, clamp: clamp) == control)
    }

    @Test func compressedMetadataClampsL6WithoutInventingSourceFields() throws {
        let nal = DoviRpuGuardTests.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]], residual: .fel,
            dm: .init(compressed: true, cmv29Block: (8, 6), cmv40Block: (10, 8)))
        let control = try remux(nal, clamp: nil)
        let result = try remux(nal, clamp: .init(targetNits: 1000, targetPQ: 3079))
        #expect(try level6(result) == [1000, 0, 0, 0])
        #if DualLayerDolbyVision
        let before = try #require(DoviDmDigest.read(rpu: control))
        let after = try #require(DoviDmDigest.read(rpu: result))
        #expect(before["L8[0]"] != nil)
        for (name, value) in before.fields where name != "L6" { #expect(after[name] == value) }
        #endif
    }

    private func level6(_ nal: [UInt8]) throws -> [UInt16] {
        try nal.withUnsafeBufferPointer { b in
            let rpu = try #require(DoviRpuGuard.parse(b.baseAddress!, b.count))
            defer { dovi_rpu_free(rpu) }
            let dm = try #require(dovi_rpu_get_vdr_dm_data(rpu))
            defer { dovi_rpu_free_vdr_dm_data(dm) }
            let l6 = try #require(dm.pointee.dm_data.level6).pointee
            return [l6.max_display_mastering_luminance, l6.min_display_mastering_luminance,
                    l6.max_content_light_level, l6.max_frame_average_light_level]
        }
    }

    @Test func clampChangesOnlyRequestedFieldsAndKeepsValidCRC() throws {
        let source = DoviComposedFrameRpuTests.felNAL
        let converted = try #require(DoviComposedFrameRpuTests.converted(source, mode: 2))
        let clamp = DoviFELDeliveryClamp(targetNits: 1000, targetPQ: 3079)
        let patched = try #require(converted.withUnsafeBufferPointer { clamp.rewrite($0.baseAddress!, count: $0.count) })
        let surveyBefore = try #require(converted.withUnsafeBufferPointer { DoviRpuSurvey.parse(nal: $0.baseAddress!, length: $0.count, frameIndex: 0) })
        let surveyAfter = try #require(patched.withUnsafeBufferPointer { DoviRpuSurvey.parse(nal: $0.baseAddress!, length: $0.count, frameIndex: 0) })
        #expect(surveyAfter.sourceMaxPQ == min(surveyBefore.sourceMaxPQ, 3079))
        #expect(surveyAfter.sourceMinPQ == surveyBefore.sourceMinPQ)
        #expect(surveyAfter.l1MaxPQ == min(surveyBefore.l1MaxPQ, 3079))
        #expect(surveyAfter.l1MinPQ == surveyBefore.l1MinPQ)
        #expect(surveyAfter.l1AvgPQ == surveyBefore.l1AvgPQ)
        #expect(patched.withUnsafeBufferPointer { DoviRpuGuard.crcIsValid($0.baseAddress!, $0.count) })
        #if DualLayerDolbyVision
        let before = try #require(DoviDmDigest.read(rpu: converted))
        let after = try #require(DoviDmDigest.read(rpu: patched))
        let allowed: Set<String> = ["dm.source_max_pq", "L1", "L6"]
        for (name, value) in before.fields where !allowed.contains(name) { #expect(after[name] == value, "Unexpected change to \(name)") }
        #endif
        let l6Before = try level6(converted)
        #expect(try level6(patched) == [1000, l6Before[1], min(l6Before[2], 1000), min(l6Before[3], 1000)])
        #expect(try remux(source, clamp: clamp) == patched)
        let twice = try #require(patched.withUnsafeBufferPointer { clamp.rewrite($0.baseAddress!, count: $0.count) })
        #expect(twice == patched)
    }
    @Test func compositionExtractionIgnoresDeliveryClamp() throws {
        func split(extractEL: Bool, extractParams: Bool, clamp: DoviFELDeliveryClamp?) throws
            -> (packet: [UInt8], converted: [UInt8]?, base: [UInt8]?, raw: [UInt8]?, el: [UInt8]?) {
            var bytes: [UInt8] = []
            for nal in [[2, 1, 0xAA], DoviComposedFrameRpuTests.felNAL, [126, 1, 0xBB]] {
                bytes += [UInt8(truncatingIfNeeded: nal.count >> 24), UInt8(truncatingIfNeeded: nal.count >> 16),
                          UInt8(truncatingIfNeeded: nal.count >> 8), UInt8(truncatingIfNeeded: nal.count)] + nal
            }
            let packet = try #require(av_packet_alloc())
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            #expect(av_new_packet(packet, Int32(bytes.count)) == 0)
            bytes.withUnsafeBytes { _ = memcpy(packet.pointee.data, $0.baseAddress!, $0.count) }
            let result = DoviRpuConverter.separateDualLayers(packet, extractEL: extractEL,
                extractParams: extractParams, deliveryClamp: clamp)
            defer { var el = result.elPacket; av_packet_free(&el) }
            #expect(result.success)
            #expect(result.isFEL)
            let el = result.elPacket.flatMap { p in p.pointee.data.map { Array(UnsafeBufferPointer(start: $0, count: Int(p.pointee.size))) } }
            return (Array(UnsafeBufferPointer(start: packet.pointee.data!, count: Int(packet.pointee.size))),
                    result.convertedRpu, result.baseLayerRpu, result.rpuData, el)
        }
        for (extractEL, extractParams) in [(true, false), (false, true), (true, true)] {
            let control = try split(extractEL: extractEL, extractParams: extractParams, clamp: nil)
            let optedIn = try split(extractEL: extractEL, extractParams: extractParams,
                clamp: .init(targetNits: 1000, targetPQ: 3079))
            #expect(optedIn.packet == control.packet)
            #expect(optedIn.converted == control.converted)
            #expect(optedIn.base == control.base)
            #expect(optedIn.raw == control.raw)
            #expect(optedIn.el == control.el)
        }
    }

    @Test func melTitleKeepsOrdinaryConversionUnchanged() throws {
        let mel = try #require(DoviComposedFrameRpuTests.converted(DoviComposedFrameRpuTests.felNAL, mode: 1))
        let packet = [UInt8]([0, 0, 0, 1]) + mel
        let first = packet.withUnsafeBufferPointer {
            DoviFELDeliveryClamp.firstRPU($0.baseAddress!, $0.count, framing: .annexB)
        }
        #expect(first.elType == "MEL")
        let selected = DoviFELDeliveryClamp.select(profile: 7, elType: first.elType,
            masteringNits: 1000, sourceMaxPQ: 4095, enabled: true)
        #expect(selected == nil)
        #expect(try remux(mel, clamp: selected) == remux(mel, clamp: nil))
    }
    #else
    @Test func traitOffKeepsOrdinaryFELConversionUnchanged() throws {
        let source = DoviComposedFrameRpuTests.felNAL
        #expect(try remux(source, clamp: .init(targetNits: 1000, targetPQ: 3079)) == remux(source, clamp: nil))
    }
    #endif

}
