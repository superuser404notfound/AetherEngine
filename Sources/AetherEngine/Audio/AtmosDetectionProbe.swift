import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Bounds (and optional track override) for `AetherEngine.probeDetectingAtmos`'s bounded EAC3/JOC decode pass.
///
/// This is entirely separate from `LoadOptions` / the lightweight `probe(url:)` path: it exists so a host can
/// opt into a strictly more expensive, decode-based Atmos check without ever touching the default probe's
/// behavior or performance. See `AetherEngine.probeDetectingAtmos` for the full contract.
///
/// Scope: E-AC-3 JOC only, which is what `TrackInfo.isAtmos` has always meant in this engine. TrueHD carrying
/// Atmos (MAT) is deliberately out of scope; that track keeps whatever the base probe reported.
public struct AtmosDetectionOptions: Sendable, Equatable {
    /// Explicit AVStream index (== `TrackInfo.id`) to test. `nil` resolves the demuxer's own default audio
    /// pick (`Demuxer.audioStreamIndex`), the same stream `probe(url:)` already reports via its container
    /// default. Set this when a host is badging a NON-default track the user explicitly selected (e.g. via
    /// `AetherEngine.selectAudioIndex`), so the decode targets the track that will actually play.
    public var targetTrackID: Int?

    /// Stop after this many packets have been offered to the decoder. Bounds both a malformed / truncated /
    /// silent stream and the JOC scan itself, which keeps decoding past non-JOC frames (see
    /// `AetherEngine.detectAtmos`). Default 64: roughly two seconds of E-AC-3 at ~1536 samples per frame,
    /// generous enough that a JOC track confirms well inside it while staying finite on an adversarial or
    /// empty-audio source.
    public var maxPackets: Int

    /// Maximum cumulative bytes offered to the decoder. A packet exceeding the remaining allowance is
    /// rejected before decode. This is not an input-read or native allocation ceiling. Default 8 MiB.
    public var maxBytes: Int64

    /// Soft wall-clock budget checked BETWEEN packet reads. This is NOT preemptive: a single blocking
    /// `av_read_frame()` call (e.g. a stalled remote socket) can still run past it before the next check
    /// fires -- the same AVIO-layer-only limitation `Demuxer.seekBounded` already documents for its deadline.
    /// Default 2 seconds.
    public var timeBudget: TimeInterval

    public init(
        targetTrackID: Int? = nil,
        maxPackets: Int = 64,
        maxBytes: Int64 = 8 * 1024 * 1024,
        timeBudget: TimeInterval = 2.0
    ) {
        self.targetTrackID = targetTrackID
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
        self.timeBudget = timeBudget
    }
}

/// Result of the bounded EAC3/JOC decode attempt run by `AetherEngine.detectAtmos`. Internal: hosts consume
/// the enriched `SourceProbe.audioTracks` from `probeDetectingAtmos` instead of this directly; it is exposed
/// at module-internal visibility purely so the stop-condition / authority logic is unit-testable without a
/// real decode (`@testable import AetherEngine`).
struct AtmosDetectionOutcome: Sendable, Equatable {
    enum StopReason: Sendable, Equatable {
        /// No audio stream at `targetIndex` (out of range, or the source has no audio at all).
        case noAudioTrack
        /// The target track's `codec_id` is not `AV_CODEC_ID_EAC3`. Per spec, only EAC3 JOC is ever Atmos --
        /// no other codec is decoded or inferred.
        case notEAC3
        /// `avcodec_find_decoder` / `avcodec_open2` failed (no EAC3 decoder built, or bad extradata).
        case decoderOpenFailed
        /// At least one frame was successfully decoded; `decodedProfile` carries the LAST post-decode
        /// `AVCodecContext.profile` the scan observed (the JOC one as soon as it appears, otherwise whatever
        /// the final decoded frame reported). See `detectAtmos` for why the scan does not stop at frame one.
        case frameDecoded
        /// `maxPackets` demuxed packets were read without ever decoding a frame for the target stream.
        case packetCap
        /// `maxBytes` cumulative packet bytes were read without ever decoding a frame.
        case byteCap
        /// `timeBudget` elapsed (checked between reads) without ever decoding a frame.
        case timeCap
        /// The demuxer reached EOF before a frame decoded (very short / audio-less-from-here source).
        case demuxEOF
        /// `Demuxer.readPacket()` threw (this is tolerated, never rethrown -- see `probeDetectingAtmos` doc).
        case demuxError
    }

    let stopReason: StopReason
    let packetsRead: Int
    let bytesRead: Int64
    /// Post-decode `AVCodecContext.profile`. Only meaningful when `stopReason == .frameDecoded`.
    let decodedProfile: Int32?

    /// EAC3 profile 30 (FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS`, `defs.h`) observed on a successfully decoded
    /// frame. This is the ONLY authoritative signal the whole feature produces -- everything else on this
    /// type is diagnostic. A plain (non-JOC) EAC3 track that decodes cleanly reports `frameDecoded` with a
    /// `decodedProfile` other than 30, so `confirmedAtmos` is correctly `false`.
    var confirmedAtmos: Bool {
        stopReason == .frameDecoded && decodedProfile == AtmosDetectionOutcome.eac3JOCProfile
    }

    /// EAC3 profile 30 = Dolby Digital Plus JOC (Atmos). Mirrors FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS` macro
    /// (`defs.h`) as a literal: simple `#define` integer constants are not guaranteed to bridge into Swift,
    /// and `Demuxer.trackInfo`'s existing pre-decode check already hardcodes this same literal.
    static let eac3JOCProfile: Int32 = 30
}

extension AetherEngine {
    /// How many total demuxed packets to tolerate per unit of decode budget before giving up, when a
    /// demuxer ignores `AVDISCARD_ALL` and keeps yielding foreign streams.
    nonisolated static let foreignPacketFuseMultiplier = 8

    /// Budget for the queue-discarding seek `probeDetectingAtmos` runs between the base probe and the
    /// decode pass. Bounded like every other engine seek so a stalled remote source cannot park here.
    nonisolated static let atmosProbeFlushSeekTimeout: TimeInterval = 5

    /// Budget for the seek back to the start that ends a load-time packet probe (the el_type walk, the
    /// interlace sample), which the session's own demuxer is reused after. Bounded for the same reason.
    nonisolated static let probeRewindSeekTimeout: TimeInterval = 5

    /// Pure stop-condition check for the bounded decode loop: given how much work has been done, which cap
    /// (if any) has been hit. Extracted so the cap-selection PRIORITY (packets, then bytes, then time) is
    /// unit-testable without a real demuxer/decoder. Returns `nil` while still within all three budgets.
    nonisolated static func atmosDecodeCapReached(
        packetsRead: Int,
        bytesRead: Int64,
        elapsed: TimeInterval,
        options: AtmosDetectionOptions
    ) -> AtmosDetectionOutcome.StopReason? {
        if packetsRead >= options.maxPackets { return .packetCap }
        if bytesRead >= options.maxBytes { return .byteCap }
        if elapsed >= options.timeBudget { return .timeCap }
        return nil
    }

    /// Resolve which AVStream index the decode pass should target: an explicit `targetTrackID` always wins
    /// (even if it does not (yet) name a real stream -- the caller finds out via `.noAudioTrack`); otherwise
    /// the demuxer's own default audio pick. Pure so the override-vs-default precedence is unit-testable.
    ///
    /// An id outside `Int32` (a synthetic or garbage host value) folds to -1 rather than trapping: the
    /// documented contract is that a non-existent track degrades to `.noAudioTrack`, not that it crashes.
    nonisolated static func atmosDecodeTargetIndex(options: AtmosDetectionOptions, defaultAudioStreamIndex: Int32) -> Int32 {
        if let explicit = options.targetTrackID {
            return Int32(exactly: explicit) ?? -1
        }
        return defaultAudioStreamIndex
    }

    /// Packet ceiling for the AVDISCARD_ALL fuse, saturating instead of trapping: `maxPackets` is a public
    /// option and `Int.max` is a plausible "no limit" value for a host to pass (`forwardBufferSegments`
    /// takes exactly that), which would overflow a plain multiply.
    /// Source bytes the probe may consume across every stream. With the other streams at AVDISCARD_ALL
    /// the demuxer reads and drops a video run inside one `av_read_frame`, where neither `maxBytes` nor
    /// the packet fuse sees it. Wider than the HDR10+ budget because the audio sits behind interleaved
    /// UHD video here: 16 x `maxBytes`, at least 64 MiB. Saturating: `maxBytes` is public.
    nonisolated static func atmosInputByteBudget(maxBytes: Int64) -> Int64 {
        let (product, overflowed) = max(0, maxBytes).multipliedReportingOverflow(by: 16)
        return overflowed ? .max : max(product, 64 * 1024 * 1024)
    }

    nonisolated static func atmosForeignPacketFuse(maxPackets: Int) -> Int {
        let (product, overflowed) = maxPackets.multipliedReportingOverflow(by: foreignPacketFuseMultiplier)
        return overflowed ? Int.max : product
    }

    /// Bounded EAC3/JOC decode attempt. Opens ONE audio decoder for `targetIndex`, reads packets from
    /// `demuxer` (skipping any not addressed to that stream), and stops as soon as a decoded frame reports
    /// the JOC profile, or when whichever cap in `options` is hit first. No video decode, no HLS server, no
    /// playback. The decoder context, `AVPacket`, and `AVFrame` are all freed before returning on every path,
    /// including early-outs and thrown-away errors -- this never leaves FFmpeg resources alive past the call.
    ///
    /// The scan deliberately does NOT stop at the first decoded frame. `libavcodec/ac3dec.c` assigns the
    /// profile per frame (`avctx->profile = eac3_extension_type_a == 1 ? ATMOS : UNKNOWN`), and the flag it
    /// keys off lives in the dependent substream's additional bitstream info, so a frame whose packet did
    /// not carry that substream actively resets the field to unknown. Reading the field after frame one
    /// would make the answer depend on packet one being representative of the track. Continuing costs at
    /// most the existing packet budget (64 EAC3 frames is roughly two seconds of audio) and a confirmed
    /// track still usually exits on the first frame.
    ///
    /// A cap or EOF reached AFTER at least one frame decoded still reports `.frameDecoded` with the last
    /// observed profile: the caps only mean "stopped looking", while a decoded non-JOC frame is a real
    /// observation. The cap reasons therefore keep their literal meaning of "no frame ever decoded".
    ///
    /// Tolerates a malformed / no-audio / non-EAC3 source: each of those degrades to a distinct
    /// non-`frameDecoded` `stopReason` rather than throwing or hanging. `Demuxer.readPacket()` failures are
    /// caught and folded into `.demuxError`, never rethrown -- an unreadable stream simply fails to confirm
    /// Atmos instead of failing the whole probe.
    nonisolated static func detectAtmos(
        demuxer: Demuxer,
        targetIndex: Int32,
        options: AtmosDetectionOptions
    ) -> AtmosDetectionOutcome {
        guard targetIndex >= 0, let stream = demuxer.stream(at: targetIndex) else {
            return AtmosDetectionOutcome(stopReason: .noAudioTrack, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            return AtmosDetectionOutcome(stopReason: .noAudioTrack, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        // Only EAC3 ever carries JOC. Every other codec (including plain AC-3/TrueHD/DTS) is left untouched --
        // never inferred, never decoded on this path.
        guard codecpar.pointee.codec_id == AV_CODEC_ID_EAC3 else {
            return AtmosDetectionOutcome(stopReason: .notEAC3, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        guard let codec = avcodec_find_decoder(AV_CODEC_ID_EAC3),
              let ctx = avcodec_alloc_context3(codec) else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&mutableCtx) }

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0,
              avcodec_open2(ctx, codec, nil) >= 0 else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        let start = DispatchTime.now()
        var packetsRead = 0
        var bytesRead: Int64 = 0
        // Demuxed-but-discarded packets still cost wall clock and I/O, so they need their own fuse --
        // but they must NOT consume the decode budget (see below).
        var packetsSeen = 0
        var framesDecoded = 0
        var lastProfile: Int32?
        let fuse = Self.atmosForeignPacketFuse(maxPackets: options.maxPackets)

        // A cap or EOF after a real decode is still a real observation, so it reports .frameDecoded with
        // what the scan saw rather than discarding it as "gave up".
        func stopped(_ reason: AtmosDetectionOutcome.StopReason) -> AtmosDetectionOutcome {
            guard framesDecoded == 0 else {
                return AtmosDetectionOutcome(
                    stopReason: .frameDecoded, packetsRead: packetsRead, bytesRead: bytesRead,
                    decodedProfile: lastProfile)
            }
            return AtmosDetectionOutcome(
                stopReason: reason, packetsRead: packetsRead, bytesRead: bytesRead, decodedProfile: nil)
        }

        // Tell the demuxer to drop every other stream. Without this the caps are a budget over the whole
        // INTERLEAVED container rather than over the audio we care about: on the exact content this
        // feature targets (a UHD remux carrying an E-AC-3 JOC track) a few hundred-KB-to-MB video packets
        // exhaust the 8 MiB byte cap in well under a second of container data, and the probe returns
        // .byteCap having fed the decoder nothing -- reporting "not Atmos" for genuinely Atmos media.
        demuxer.discardAllStreamsExcept([targetIndex])
        demuxer.beginInputByteBudget(Self.atmosInputByteBudget(maxBytes: options.maxBytes))
        defer { demuxer.endInputByteBudget() }

        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            if let cap = Self.atmosDecodeCapReached(
                packetsRead: packetsRead, bytesRead: bytesRead,
                elapsed: elapsed, options: options
            ) {
                return stopped(cap)
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                return stopped(demuxer.inputByteBudgetExhausted ? .byteCap : .demuxError)
            }
            guard let pkt = packet else {
                return stopped(demuxer.inputByteBudgetExhausted ? .byteCap : .demuxEOF)
            }
            let afterRead = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            if afterRead >= options.timeBudget {
                av_packet_unref(pkt)
                av_packet_free_safe(pkt)
                return stopped(.timeCap)
            }

            var confirmed = false
            packetsSeen += 1
            if pkt.pointee.stream_index == targetIndex {
                guard Int64(pkt.pointee.size) <= options.maxBytes - bytesRead else {
                    av_packet_unref(pkt)
                    av_packet_free_safe(pkt)
                    return stopped(.byteCap)
                }
                // Charge the decode budget only for packets actually offered to the decoder, so a coarse
                // interleave or a large leading video run can never starve the probe of audio.
                packetsRead += 1
                bytesRead += Int64(pkt.pointee.size)
                if avcodec_send_packet(ctx, pkt) >= 0 {
                    // Drain every frame this packet produced: the profile is per frame, so the JOC one can
                    // sit behind a plain frame the same send emitted.
                    while avcodec_receive_frame(ctx, f) >= 0 {
                        framesDecoded += 1
                        lastProfile = ctx.pointee.profile
                        if lastProfile == AtmosDetectionOutcome.eac3JOCProfile {
                            confirmed = true
                            break
                        }
                    }
                }
            }
            av_packet_unref(pkt)
            av_packet_free_safe(pkt)

            if confirmed {
                // A decoded JOC frame is evidence the pass already paid for. The wall-clock budget bounds
                // what this pass SPENDS, so an overrun retires the pass, it does not retract its answer:
                // a caller cannot tell a withheld confirmation apart from a source that carries no Atmos.
                return AtmosDetectionOutcome(
                    stopReason: .frameDecoded, packetsRead: packetsRead, bytesRead: bytesRead,
                    decodedProfile: lastProfile
                )
            }

            // Independent fuse: AVDISCARD_ALL is honoured by most demuxers but is advisory, so a container
            // that keeps handing back foreign packets still terminates.
            if packetsSeen >= fuse {
                return stopped(.packetCap)
            }
        }
    }
}
