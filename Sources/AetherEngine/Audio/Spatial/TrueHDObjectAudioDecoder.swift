// Only with the TrueHDObjectAudio trait (off by default), which links LibTrueHD.
#if TrueHDObjectAudio
import Foundation
import TrueHD

/// TrueHD object-presentation decoder over the LibTrueHD library (the Rust `truehd` crate behind
/// a C API): lossless decode of presentation 3, which for an Atmos stream is the bed plus up to 15
/// dynamic objects, together with the object audio metadata (OAMD) that positions them.
///
/// The library's coordinates are OAMD room coordinates (ETSI TS 103 420 4.2.1): x left→right and
/// y front→back on 0...1, z −1 floor, 0 ear level, +1 ceiling. That is the renderer's own room
/// model above ear level; home Atmos keeps objects at z ≥ 0, and anything below is clamped to the
/// ear-level plane, which is the lowest a home bed has.
final class TrueHDObjectAudioDecoder: ObjectAudioDecoding {

    struct DecoderError: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "TrueHDObjectAudioDecoder: status \(status) \(message)" }
    }

    private let handle: OpaquePointer
    private var roles: [ObjectAudioRole] = []
    private var rolesSerial: UInt32?
    private var planes: [UnsafePointer<Float>] = []
    private(set) var selfResetCount = 0
    /// Blocks between a reset and the first metadata, so objects play from the first frame (see
    /// `ObjectMetadataHold`), and the released block last handed out, whose planes it owns.
    private let hold = ObjectMetadataHold()
    private var lent: ObjectMetadataHold.Copy?

    init() throws {
        guard let handle = truehd_atmos_decoder_create(TRUEHD_ATMOS_PRESENTATION_HIGHEST) else {
            throw DecoderError(status: TRUEHD_ATMOS_ERR_INVALID_ARGUMENT, message: "create failed")
        }
        self.handle = handle
    }

    deinit { truehd_atmos_decoder_destroy(handle) }

    func push(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let status = truehd_atmos_decoder_push(
            handle, base.assumingMemoryBound(to: UInt8.self), bytes.count, Int64.min)
        // BUFFER_FULL (8 MiB waiting) cannot happen behind the bridge, which drains every block after
        // each push; a panic resets for the same reason as in `nextBlock`.
        if status == TRUEHD_ATMOS_ERR_PANIC {
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == TRUEHD_ATMOS_OK else { throw error(status) }
    }

    func nextBlock() throws -> ObjectAudioDecodedBlock? {
        lent = nil
        while true {
            if let released = hold.nextReleased() {
                lent = released
                return released.block
            }
            guard let (block, firstStates) = try pull() else { return nil }
            if let block = hold.admit(block, firstStates: firstStates) { return block }
        }
    }

    /// The library's next block, with every element's state as of its first metadata update.
    private func pull() throws -> (ObjectAudioDecodedBlock, [ObjectAudioElementState?]?)? {
        var block = TrueHDAtmosBlock()
        let status = truehd_atmos_decoder_pull(handle, &block)
        if status == TRUEHD_ATMOS_NEED_MORE_DATA { return nil }
        if status == TRUEHD_ATMOS_ERR_PANIC {
            // The handle refuses every call until it is reset. Reset it here, so the stream resumes
            // at the next major sync instead of staying silent for the rest of the session.
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == TRUEHD_ATMOS_OK else { throw error(status) }

        let channels = Int(block.channel_count)
        if rolesSerial != block.layout_serial {
            rolesSerial = block.layout_serial
            roles = (0..<channels).map { Self.role(forSpeaker: block.speakers[$0]) }
        }
        planes.removeAll(keepingCapacity: true)
        for c in 0..<channels { planes.append(UnsafePointer(block.channels[c]!)) }

        var updates: [ObjectAudioMetadataUpdate] = []
        var firstStates: [ObjectAudioElementState?]?
        if block.flags & TRUEHD_ATMOS_BLOCK_METADATA_UPDATED != 0, let metadata = block.metadata {
            let md = metadata.pointee
            let count = min(Int(md.element_count), channels)
            for u in 0..<Int(md.update_count) {
                let update = md.updates[u]
                if u == 0 { firstStates = (0..<count).map { Self.state(for: update.elements[$0]) } }
                var states: [ObjectAudioElementState?] = []
                states.reserveCapacity(count)
                for e in 0..<count {
                    let element = update.elements[e]
                    states.append(element.flags & TRUEHD_ATMOS_ELEMENT_CHANGED != 0
                                  ? Self.state(for: element) : nil)
                }
                updates.append(ObjectAudioMetadataUpdate(
                    frameOffset: Int(update.frame_offset), rampFrames: Int(update.ramp_frames), states: states))
            }
        }

        return (ObjectAudioDecodedBlock(
            sampleRate: Int(block.sample_rate),
            frameCount: Int(block.frame_count),
            inputFrameOffset: Int64(block.input_frame_offset),
            configurationGeneration: Int(block.layout_serial),
            isDiscontinuity: block.flags & TRUEHD_ATMOS_BLOCK_DISCONTINUITY != 0,
            roles: roles,
            planes: planes,
            updates: updates), firstStates)
    }

    func reset() {
        _ = truehd_atmos_decoder_reset(handle)
        hold.arm()
        lent = nil
    }

    func releaseHeldBlocks() {
        hold.releaseAll()
    }

    private func error(_ status: Int32) -> DecoderError {
        let message = truehd_atmos_decoder_last_error(handle).map { String(cString: $0) } ?? ""
        return DecoderError(status: status, message: message)
    }

    // MARK: - Mapping

    /// Bed speakers the renderer's room model names route discretely; the other speaker codes
    /// (screen, centre back, top centre, surround direct) sit at their nominal position, so a
    /// channel-based presentation without metadata still plays them. Objects and unlabelled
    /// channels are positioned by metadata.
    static func role(forSpeaker code: UInt8) -> ObjectAudioRole {
        switch code {
        case TRUEHD_ATMOS_SPEAKER_LFE, TRUEHD_ATMOS_SPEAKER_LFE2: return .lfe
        case TRUEHD_ATMOS_SPEAKER_L: return .bed(.left)
        case TRUEHD_ATMOS_SPEAKER_R: return .bed(.right)
        case TRUEHD_ATMOS_SPEAKER_C: return .bed(.center)
        case TRUEHD_ATMOS_SPEAKER_LS: return .bed(.sideLeft)
        case TRUEHD_ATMOS_SPEAKER_RS: return .bed(.sideRight)
        case TRUEHD_ATMOS_SPEAKER_LB: return .bed(.rearLeft)
        case TRUEHD_ATMOS_SPEAKER_RB: return .bed(.rearRight)
        case TRUEHD_ATMOS_SPEAKER_LW: return .bed(.wideLeft)
        case TRUEHD_ATMOS_SPEAKER_RW: return .bed(.wideRight)
        case TRUEHD_ATMOS_SPEAKER_TFL: return .bed(.topFrontLeft)
        case TRUEHD_ATMOS_SPEAKER_TFR: return .bed(.topFrontRight)
        case TRUEHD_ATMOS_SPEAKER_TSL: return .bed(.topMiddleLeft)
        case TRUEHD_ATMOS_SPEAKER_TSR: return .bed(.topMiddleRight)
        case TRUEHD_ATMOS_SPEAKER_TBL: return .bed(.topRearLeft)
        case TRUEHD_ATMOS_SPEAKER_TBR: return .bed(.topRearRight)
        case TRUEHD_ATMOS_SPEAKER_LSC: return .fixed(SIMD3(0.25, 0, 0))
        case TRUEHD_ATMOS_SPEAKER_RSC: return .fixed(SIMD3(0.75, 0, 0))
        case TRUEHD_ATMOS_SPEAKER_CB: return .fixed(SIMD3(0.5, 1, 0))
        case TRUEHD_ATMOS_SPEAKER_LSD: return .fixed(SpatialSpeaker.sideLeft.position)
        case TRUEHD_ATMOS_SPEAKER_RSD: return .fixed(SpatialSpeaker.sideRight.position)
        case TRUEHD_ATMOS_SPEAKER_TC: return .fixed(SIMD3(0.5, 0.5, 1))
        case TRUEHD_ATMOS_SPEAKER_TFC: return .fixed(SIMD3(0.5, 0.25, 1))
        default: return .object
        }
    }

    static func state(for element: TrueHDAtmosElement) -> ObjectAudioElementState {
        let active = element.flags & TRUEHD_ATMOS_ELEMENT_ACTIVE != 0
        var p = element.position
        var size = max(element.size.0, element.size.1, element.size.2)
        if element.kind == TRUEHD_ATMOS_ELEMENT_ISF {
            // The library does not decode ISF (intermediate spatial format) positions, and no home
            // content carrying them was found. Spread it over the room rather than pin it to
            // whatever position value is left in the struct.
            p = (0.5, 0.5, 0.5)
            size = 1
        } else if element.flags & TRUEHD_ATMOS_ELEMENT_SCREEN_REF != 0 {
            // Screen-anchored: x across the screen and z −1…1 over its height, while y stays room
            // depth (header, COORDINATES). A home room has no screen geometry to map that onto
            // exactly, so the screen spans the front wall's width and its top sits halfway up the
            // room rather than at the ceiling.
            p = (p.0, p.1, max(0, p.2) * 0.5)
        }
        var excluded = excludedSpeakers(zone: element.zone)
        if element.kind == TRUEHD_ATMOS_ELEMENT_OBJECT, element.flags & TRUEHD_ATMOS_ELEMENT_ELEVATION == 0 {
            excluded.formUnion(heights)
        }
        return ObjectAudioElementState(
            position: SIMD3(p.0, p.1, max(0, p.2)),
            gain: active ? element.gain : 0,
            size: size,
            snap: element.flags & TRUEHD_ATMOS_ELEMENT_SNAP != 0,
            excluded: excluded)
    }

    /// Built once: they run per changed element on every metadata update.
    private static let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
    /// A 5.1 layout's surrounds are in neither zone: TS 103 448 table 4 excludes nothing for those
    /// two masks on a 3/2 floor, and only screen-only takes the surrounds away.
    private static let noBack: Set<SpatialSpeaker> = [.rearLeft, .rearRight]
    private static let noSides: Set<SpatialSpeaker> = [.sideLeft, .sideRight, .wideLeft, .wideRight]
    private static let screenOnly = noSides.union(noBack).union([.surroundLeft, .surroundRight])
    private static let surroundOnly: Set<SpatialSpeaker> = [.left, .right, .center, .wideLeft, .wideRight]
    /// Centre and back zones only: off the front pair, the wides and the sides.
    private static let centerBack: Set<SpatialSpeaker> = [.left, .right, .wideLeft, .wideRight, .sideLeft, .sideRight]

    /// OAMD horizontal zone constraints (TS 103 420 table 20) as speakers the object may not use.
    static func excludedSpeakers(zone: UInt8) -> Set<SpatialSpeaker> {
        switch zone {
        case TRUEHD_ATMOS_ZONE_NO_BACK: return noBack
        case TRUEHD_ATMOS_ZONE_NO_SIDES: return noSides
        case TRUEHD_ATMOS_ZONE_CENTER_BACK: return centerBack
        case TRUEHD_ATMOS_ZONE_SCREEN_ONLY: return screenOnly
        case TRUEHD_ATMOS_ZONE_SURROUND_ONLY: return surroundOnly
        default: return []
        }
    }
}
#endif
