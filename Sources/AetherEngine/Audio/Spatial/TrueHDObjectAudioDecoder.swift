// Only with the TrueHDObjectAudio trait (off by default), which links LibTrueHD.
#if TrueHDObjectAudio
import Foundation
import TrueHD

/// TrueHD object-presentation decoder over the LibTrueHD library (the Rust `truehd` crate behind
/// a C API), for the engine's bed regression (see `BedRegression`).
///
/// Every block carries the stream's channel-based presentation (Dolby's own lossless 7.1 or 5.1
/// rendering of the mix) and, from the same access unit, presentation 3: the bed elements and up to
/// 15 dynamic objects with the object audio metadata (OAMD) that positions them. Presentation 3 is
/// decoded without matrix interpolation: the library leaves the interpolating decode out (LibTrueHD
/// 3.2.0) and the handle discards the values as well, so on a stream that interpolates the element
/// signals are approximate. They never reach an output: the bridge builds every output from the
/// channel presentation and takes the elements only as statistics. Elements are point sources at
/// their position with their gain; size, snap, zones, screen anchoring and the elevation switch
/// are not read, and every update applies as it stands, without the ramp towards it.
///
/// The library's coordinates are OAMD room coordinates (ETSI TS 103 420 4.2.1): x left→right and
/// y front→back on 0...1, z −1 floor, 0 ear level, +1 ceiling. That is the engine's own room
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
    private var bedRoles: [ObjectAudioRole] = []
    private var bedRolesSerial: UInt32?
    private var bedPlanes: [UnsafePointer<Float>] = []
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
        _ = truehd_atmos_decoder_set_bed_companion(handle, true)
        _ = truehd_atmos_decoder_set_ignore_interpolation(handle, true)
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

        var bed: ObjectAudioBed?
        let bedChannels = Int(block.bed_channel_count)
        if bedChannels > 0, let channels = block.bed_channels, let speakers = block.bed_speakers {
            if bedRolesSerial != block.layout_serial || bedRoles.count != bedChannels {
                bedRolesSerial = block.layout_serial
                bedRoles = (0..<bedChannels).map { Self.role(forSpeaker: speakers[$0]) }
            }
            bedPlanes.removeAll(keepingCapacity: true)
            for c in 0..<bedChannels { bedPlanes.append(UnsafePointer(channels[c]!)) }
            bed = ObjectAudioBed(roles: bedRoles, planes: bedPlanes)
        }

        var updates: [ObjectAudioMetadataUpdate] = []
        var firstStates: [ObjectAudioElementState?]?
        if block.flags & TRUEHD_ATMOS_BLOCK_METADATA_UPDATED != 0, let metadata = block.metadata {
            let md = metadata.pointee
            let count = min(Int(md.element_count), channels)
            for u in 0..<Int(md.update_count) {
                let update = md.updates[u]
                if u == 0 { firstStates = (0..<count).map { Self.pointSource(for: update.elements[$0]) } }
                var states: [ObjectAudioElementState?] = []
                states.reserveCapacity(count)
                for e in 0..<count {
                    let element = update.elements[e]
                    states.append(element.flags & TRUEHD_ATMOS_ELEMENT_CHANGED != 0
                                  ? Self.pointSource(for: element) : nil)
                }
                updates.append(ObjectAudioMetadataUpdate(
                    frameOffset: Int(update.frame_offset),
                    // Splitting the bed, each update is taken as it stands, without the ramp towards it.
                    states: states))
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
            updates: updates,
            bed: bed), firstStates)
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

    /// Bed speakers the engine's room model names route discretely; the other speaker codes
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

    /// An element as a point at its position: no size, snap, zone exclusion, screen anchoring or
    /// elevation switch. ISF elements, whose positions the library does not decode, sit in the room's
    /// centre.
    static func pointSource(for element: TrueHDAtmosElement) -> ObjectAudioElementState {
        let active = element.flags & TRUEHD_ATMOS_ELEMENT_ACTIVE != 0
        let p = element.kind == TRUEHD_ATMOS_ELEMENT_ISF ? (Float(0.5), Float(0.5), Float(0.5)) : element.position
        return ObjectAudioElementState(position: SIMD3(p.0, p.1, max(0, p.2)), gain: active ? element.gain : 0)
    }
}
#endif
