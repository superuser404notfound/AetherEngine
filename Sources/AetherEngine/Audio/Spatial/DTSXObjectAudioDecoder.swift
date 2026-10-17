// Only with the DTSXObjectAudio trait (off by default), which links LibDTSX.
#if DTSXObjectAudio
import Foundation
import DTSX

/// DTS:X decoder over the LibDTSX library (the Rust `dca` crate behind a C API): lossless decode of
/// the DTS-HD Master Audio stream DTS:X is carried on, returned the way `TrueHDObjectAudioDecoder`
/// returns an Atmos presentation. The library does the DTS-specific work: it removes the heights
/// and objects the encoder folded into the compatible 7.1 bed, so the bed, the four fixed heights
/// and any objects play side by side, and it places DTS:X's angular object positions in the room
/// coordinates this renderer and LibTrueHD use (x left→right and y front→back on 0...1, z 0 ear
/// level to 1 ceiling). What is left here is naming the channels.
final class DTSXObjectAudioDecoder: ObjectAudioDecoding {

    struct DecoderError: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "DTSXObjectAudioDecoder: status \(status) \(message)" }
    }

    /// What the first frames of a stream showed (see `verdict(feeding:)`).
    enum Verdict: Equatable {
        /// DTS:X the decoder renders, named by its layout ("7.1.4", "7.1.4+2").
        case renders(String)
        /// Not DTS:X, or DTS:X the library does not render; the message says which.
        case refused(String)
    }

    private let handle: OpaquePointer
    private var roles: [ObjectAudioRole] = []
    private var rolesSerial: UInt32?
    private var planes: [UnsafePointer<Float>] = []
    private(set) var selfResetCount = 0

    init() throws {
        guard let handle = dtsx_decoder_create() else {
            throw DecoderError(status: DTSX_ERR_INVALID_ARGUMENT, message: "create failed")
        }
        self.handle = handle
    }

    deinit { dtsx_decoder_destroy(handle) }

    /// Feeds one packet from the head of a stream and reports what it decodes, or nil while that is
    /// undecided. FFmpeg names only two of DTS:X's markers, so a track it labels plain DTS-HD MA can
    /// be DTS:X, and one it labels DTS:X can carry a presentation the library refuses: only a decoded
    /// frame tells. The library decides on the first frame and outputs from the third (the first two
    /// only rebuild the core's filter history), so a verdict takes three packets of DTS-HD. A stream
    /// counts as rendered once a block arrives whose DTS:X extension applied.
    func verdict(feeding bytes: UnsafeRawBufferPointer) -> Verdict? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var status = dtsx_decoder_push(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count, Int64.min)
        var block = DTSXBlock()
        while status == DTSX_OK {
            status = dtsx_decoder_pull(handle, &block)
            if status == DTSX_OK {
                // The renderer and the APAC encoder run at 48 kHz; the track's label said so, the
                // stream itself has the last word.
                guard block.sample_rate == 48000 else {
                    return .refused("\(block.sample_rate) Hz")
                }
                guard block.flags & DTSX_BLOCK_BED_AS_AUTHORED == 0 else {
                    return .refused("its DTS:X extension could not be applied (\(lastError))")
                }
                return .renders(String(cString: dtsx_presentation_name(block.presentation)))
            }
        }
        return status == DTSX_NEED_MORE_DATA ? nil : .refused(lastError)
    }

    func push(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let status = dtsx_decoder_push(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count, Int64.min)
        // BUFFER_FULL (8 MiB waiting) cannot happen behind the bridge, which drains every block after
        // each push; a panic resets for the same reason as in `nextBlock`.
        if status == DTSX_ERR_PANIC {
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == DTSX_OK else { throw error(status) }
    }

    func nextBlock() throws -> ObjectAudioDecodedBlock? {
        var block = DTSXBlock()
        let status = dtsx_decoder_pull(handle, &block)
        if status == DTSX_NEED_MORE_DATA { return nil }
        if status == DTSX_ERR_PANIC {
            // The handle refuses every call until it is reset. Reset it here, so the stream resumes
            // at the next frame instead of staying silent for the rest of the session.
            let failure = error(status)
            reset()
            selfResetCount += 1
            throw failure
        }
        guard status == DTSX_OK else { throw error(status) }

        let channels = Int(block.channel_count)
        if rolesSerial != block.layout_serial {
            rolesSerial = block.layout_serial
            roles = (0..<channels).map { Self.role(forSpeaker: block.speakers[$0]) }
        }
        planes.removeAll(keepingCapacity: true)
        for c in 0..<channels { planes.append(UnsafePointer(block.channels[c]!)) }

        var updates: [ObjectAudioMetadataUpdate] = []
        if block.flags & DTSX_BLOCK_METADATA_UPDATED != 0, let metadata = block.metadata {
            let md = metadata.pointee
            let count = min(Int(md.element_count), channels)
            for u in 0..<Int(md.update_count) {
                let update = md.updates[u]
                var states: [ObjectAudioElementState?] = []
                states.reserveCapacity(count)
                for e in 0..<count {
                    let element = update.elements[e]
                    states.append(element.flags & DTSX_ELEMENT_CHANGED != 0 ? Self.state(for: element) : nil)
                }
                updates.append(ObjectAudioMetadataUpdate(
                    frameOffset: Int(update.frame_offset), rampFrames: Int(update.ramp_frames), states: states))
            }
        }

        return ObjectAudioDecodedBlock(
            sampleRate: Int(block.sample_rate),
            frameCount: Int(block.frame_count),
            inputFrameOffset: Int64(block.input_frame_offset),
            configurationGeneration: Int(block.layout_serial),
            isDiscontinuity: block.flags & DTSX_BLOCK_DISCONTINUITY != 0,
            roles: roles,
            planes: planes,
            updates: updates)
    }

    func reset() {
        _ = dtsx_decoder_reset(handle)
    }

    private var lastError: String { String(cString: dtsx_decoder_last_error(handle)) }

    private func error(_ status: Int32) -> DecoderError {
        DecoderError(status: status, message: lastError)
    }

    // MARK: - Mapping

    /// The speaker codes are LibTrueHD's. A DTS:X bed is 7.1 (5.1 under one alternate presentation),
    /// its four fixed heights are the top front and top back pairs, and the codes beyond those only
    /// occur in beds no DTS:X stream tested had; each sits at its nominal position, as in
    /// `TrueHDObjectAudioDecoder`. Objects, and a bed speaker the API has no code for, are
    /// positioned by metadata.
    static func role(forSpeaker code: UInt8) -> ObjectAudioRole {
        switch code {
        case DTSX_SPEAKER_LFE, DTSX_SPEAKER_LFE2: return .lfe
        case DTSX_SPEAKER_L: return .bed(.left)
        case DTSX_SPEAKER_R: return .bed(.right)
        case DTSX_SPEAKER_C: return .bed(.center)
        case DTSX_SPEAKER_LS: return .bed(.sideLeft)
        case DTSX_SPEAKER_RS: return .bed(.sideRight)
        case DTSX_SPEAKER_LB: return .bed(.rearLeft)
        case DTSX_SPEAKER_RB: return .bed(.rearRight)
        case DTSX_SPEAKER_LW: return .bed(.wideLeft)
        case DTSX_SPEAKER_RW: return .bed(.wideRight)
        case DTSX_SPEAKER_TFL: return .bed(.topFrontLeft)
        case DTSX_SPEAKER_TFR: return .bed(.topFrontRight)
        case DTSX_SPEAKER_TSL: return .bed(.topMiddleLeft)
        case DTSX_SPEAKER_TSR: return .bed(.topMiddleRight)
        case DTSX_SPEAKER_TBL: return .bed(.topRearLeft)
        case DTSX_SPEAKER_TBR: return .bed(.topRearRight)
        case DTSX_SPEAKER_LSC: return .fixed(SIMD3(0.25, 0, 0))
        case DTSX_SPEAKER_RSC: return .fixed(SIMD3(0.75, 0, 0))
        case DTSX_SPEAKER_CB: return .fixed(SIMD3(0.5, 1, 0))
        case DTSX_SPEAKER_LSD: return .fixed(SpatialSpeaker.sideLeft.position)
        case DTSX_SPEAKER_RSD: return .fixed(SpatialSpeaker.sideRight.position)
        case DTSX_SPEAKER_TC: return .fixed(SIMD3(0.5, 0.5, 1))
        // On the front-top row, where LibTrueHD's TFC and the ceiling pair since #742 sit.
        case DTSX_SPEAKER_TFC: return .fixed(SIMD3(0.5, 0.25, 1))
        default: return .object
        }
    }

    /// DTS:X states no object gain, size or zone: an element is its room position.
    static func state(for element: DTSXElement) -> ObjectAudioElementState {
        let p = element.position
        return ObjectAudioElementState(
            position: SIMD3(p.0, p.1, max(0, p.2)),
            gain: element.flags & DTSX_ELEMENT_ACTIVE != 0 ? element.gain : 0)
    }
}
#endif
