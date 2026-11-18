import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Sodalite#245: when the forced Profile 5 route (`LoadOptions.forceDolbyVisionOnNonDVDisplay`) steps aside
/// for a source's own HDR10+ (`LoadOptions.preferHDR10PlusOverForcedDolbyVision`).
///
/// The route is fixed before the segment producer reads a single packet, and the producer is where HDR10+
/// is otherwise first seen (`handleHDR10PlusDetected`). So the load asks the question itself, at the head
/// of the video stream, and only when the answer can change the route.
enum ForcedDolbyVisionHDR10Plus {

    /// Video packets to inspect before giving up. HDR10+ is per frame, so a carrying source answers on the
    /// first one; the slack is for a stream that opens on frames without the SEI.
    static let headPacketBudget = 8

    /// Whether a load should read the head of the source before the route is fixed. Everything here is a
    /// condition under which the forced route would be taken at all, plus what the scan itself needs: a
    /// rewind, so the session that reuses this demuxer starts where it would have.
    static func scansHead(
        forceDolbyVisionOnNonDVDisplay: Bool,
        preferHDR10Plus: Bool,
        displayTakesDolbyVision: Bool,
        dolbyVisionHandling: DolbyVisionHandling,
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBLCompatID: Int?,
        isLive: Bool,
        isSourceSeekable: Bool
    ) -> Bool {
        guard forceDolbyVisionOnNonDVDisplay, preferHDR10Plus, !displayTakesDolbyVision,
              dolbyVisionHandling == .automatic, codecID == AV_CODEC_ID_HEVC,
              !isLive, isSourceSeekable else { return false }
        switch dvProfile {
        case 7:
            return true
        case 8:
            // 8.4 has an HLG base and 8.2 an SDR one; the forced route covers neither.
            return dvBLCompatID != 4 && dvBLCompatID != 2
        default:
            return false
        }
    }

    /// Whether the forced route yields for this session.
    static func yieldsToHDR10Plus(preferHDR10Plus: Bool, sourceCarriesHDR10Plus: Bool) -> Bool {
        preferHDR10Plus && sourceCarriesHDR10Plus
    }

    /// Bounded walk over the head of `streamIndex`, true once one packet carries validated ST 2094-40.
    ///
    /// No AVDISCARD on the other streams: the session reuses this demuxer and would inherit it. The
    /// ceilings are the Dolby Vision record audit's (`DolbyVisionRecordAudit.walkExhausted`), which bound
    /// the foreign packets and the bytes read below the demuxer.
    static func headCarriesHDR10Plus(
        demuxer: Demuxer, streamIndex: Int32, packetBudget: Int = headPacketBudget
    ) -> Bool {
        guard let stream = demuxer.stream(at: streamIndex), let codecpar = stream.pointee.codecpar else {
            return false
        }
        demuxer.beginInputByteBudget(Int64(DolbyVisionRecordAudit.walkByteBudget))
        defer { demuxer.endInputByteBudget() }

        var walked = 0
        var packetsRead = 0
        var bytesRead = 0
        while walked < packetBudget {
            guard !DolbyVisionRecordAudit.walkExhausted(
                packetsRead: packetsRead, bytesRead: bytesRead, packetBudget: packetBudget)
            else { return false }
            guard let packet = (try? demuxer.readPacket()) ?? nil else { return false }
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            packetsRead += 1
            bytesRead += Int(max(packet.pointee.size, 0))
            guard packet.pointee.stream_index == streamIndex else { continue }
            walked += 1
            if HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecParameters: codecpar) { return true }
        }
        return false
    }
}
