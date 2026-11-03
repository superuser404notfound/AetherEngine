import Foundation

/// AE#923: how a host asks the engine to shape decoded audio before it reaches the output: a ceiling
/// on the channel count, a lift for the dialogue, and dynamic-range compression ("night mode").
///
/// The default value shapes nothing, and a session whose shaping is inactive is byte-for-byte the
/// session it was before this existed: stream copy stays stream copy. Shaping needs PCM, so while it
/// is active a stream-copied track (Atmos and every lossless bitstream included) is decoded and
/// bridged instead, and it takes precedence over `LoadOptions.objectAudioRendering`, whose object
/// render never passes through a PCM stage the engine could shape. `AetherEngine.audioShapingState`
/// says whether a session is actually carrying it.
///
/// The channel work is a remix matrix handed to libswresample (`AudioShapingMatrix`); the stereo
/// dialogue lift and the dynamics are libavfilter's `dialoguenhance`, `acompressor` and `alimiter`
/// (`AudioShapingGraph`).
public struct AudioShaping: Sendable, Equatable, Hashable {

    /// Upper bound on the channels the session outputs; nil keeps the source's (today's behaviour).
    /// Brought into 1...8. A source with fewer channels is never upmixed.
    public var maxChannels: Int?

    /// Gain on the dialogue, in dB, clamped to 0...`maxDialogueGainDB`. On a source with a front
    /// centre channel that channel is raised wherever it lands (kept discrete, or folded into a
    /// downmix). A source without a centre that plays as stereo gets the dialogue extracted from
    /// the mix (libavfilter's `dialoguenhance`) and folded back onto both sides at this gain, which
    /// costs the audio a fixed latency the engine takes back out of the timeline. A mono source has
    /// nothing to separate dialogue from and is left alone.
    public var dialogueGainDB: Double

    /// Dynamic-range compression; nil is off.
    public var compressor: Compressor?

    public init(maxChannels: Int? = nil, dialogueGainDB: Double = 0, compressor: Compressor? = nil) {
        self.maxChannels = maxChannels
        self.dialogueGainDB = dialogueGainDB
        self.compressor = compressor
    }

    /// The largest dialogue lift the engine applies. Past it a centre channel stops sounding raised
    /// and starts sounding like a separate speaker.
    public static let maxDialogueGainDB: Double = 12

    /// A feed-forward compressor with a soft knee (libavfilter's `acompressor`, peak detection),
    /// linked across every channel so the stereo image and the surround field do not move when one
    /// channel is loud. A lookahead limiter at -1 dBFS (`alimiter`) runs after it whenever shaping is
    /// active, so neither the makeup gain nor the dialogue lift can clip.
    public struct Compressor: Sendable, Equatable, Hashable {
        /// Level above which the gain is reduced, in dBFS (clamped to -60...0).
        public var thresholdDB: Double
        /// Input dB above the threshold per output dB (clamped to 1...20).
        public var ratio: Double
        /// Gain added after compression, in dB (clamped to 0...24).
        public var makeupGainDB: Double
        /// How fast gain reduction engages, in milliseconds (clamped to 0.1...200).
        public var attackMilliseconds: Double
        /// How fast it lets go again, in milliseconds (clamped to 10...2000).
        public var releaseMilliseconds: Double
        /// Width of the soft knee around the threshold, in dB (clamped to 0...18, acompressor's range).
        public var kneeDB: Double

        public init(thresholdDB: Double, ratio: Double, makeupGainDB: Double = 0,
                    attackMilliseconds: Double = 10, releaseMilliseconds: Double = 250, kneeDB: Double = 6) {
            self.thresholdDB = thresholdDB
            self.ratio = ratio
            self.makeupGainDB = makeupGainDB
            self.attackMilliseconds = attackMilliseconds
            self.releaseMilliseconds = releaseMilliseconds
            self.kneeDB = kneeDB
        }

        /// The engine's night-mode setting: everything above -30 dBFS is compressed 4:1 and the
        /// result is lifted 10 dB, so a whisper at -40 dBFS comes up to -30 and a full-scale
        /// explosion comes down to about -12.5 before the limiter.
        public static let night = Compressor(thresholdDB: -30, ratio: 4, makeupGainDB: 10,
                                             attackMilliseconds: 5, releaseMilliseconds: 250, kneeDB: 6)

        /// Every field brought into the range the processor carries; a non-finite value takes the
        /// field's neutral end.
        public var clamped: Compressor {
            Compressor(thresholdDB: Self.clamp(thresholdDB, -60, 0, fallback: 0),
                       ratio: Self.clamp(ratio, 1, 20, fallback: 1),
                       makeupGainDB: Self.clamp(makeupGainDB, 0, 24, fallback: 0),
                       attackMilliseconds: Self.clamp(attackMilliseconds, 0.1, 200, fallback: 10),
                       releaseMilliseconds: Self.clamp(releaseMilliseconds, 10, 2000, fallback: 250),
                       kneeDB: Self.clamp(kneeDB, 0, 18, fallback: 0))
        }

        static func clamp(_ v: Double, _ lo: Double, _ hi: Double, fallback: Double) -> Double {
            guard v.isFinite else { return fallback }
            return min(max(v, lo), hi)
        }
    }

    /// The value with every field brought into range. What the engine stores and applies, so a host
    /// reading `AetherEngine.audioShaping` back sees what is in force rather than what it typed.
    public var clamped: AudioShaping {
        AudioShaping(maxChannels: maxChannels.map { min(max($0, 1), 8) },
                     dialogueGainDB: Compressor.clamp(dialogueGainDB, 0, Self.maxDialogueGainDB, fallback: 0),
                     compressor: compressor?.clamped)
    }

    /// Whether this value asks for anything at all. An inactive value leaves every route as it was.
    /// A cap of 8 is no cap: nothing the engine carries has more.
    public var isActive: Bool {
        let c = clamped
        return (c.maxChannels ?? 8) < 8 || c.dialogueGainDB > 0 || c.compressor != nil
    }

    /// The channel count a source of `sourceChannels` is shaped into. Never above the source.
    func outputChannels(forSource sourceChannels: Int32) -> Int32 {
        guard let cap = clamped.maxChannels else { return sourceChannels }
        return min(sourceChannels, Int32(cap))
    }

    /// Linear gain the dialogue gets.
    var dialogueGain: Double { pow(10, clamped.dialogueGainDB / 20) }

    /// One line naming what is in force ("off", "max 2 ch, dialogue +6.0 dB, ..."), the wording the
    /// engine's own log uses.
    public var summary: String {
        let c = clamped
        var parts: [String] = []
        if let cap = c.maxChannels { parts.append("max \(cap) ch") }
        if c.dialogueGainDB > 0 { parts.append(String(format: "dialogue %+.1f dB", c.dialogueGainDB)) }
        if let k = c.compressor {
            parts.append(String(format: "compressor %.0f dB %.1f:1 makeup %+.1f dB", k.thresholdDB, k.ratio, k.makeupGainDB))
        }
        return parts.isEmpty ? "off" : parts.joined(separator: ", ")
    }
}

/// AE#923: whether the session's audio is being shaped, for a host to show next to its settings.
public enum AudioShapingState: String, Sendable, Equatable, CaseIterable {
    /// No shaping asked for, or no session.
    case off
    /// The session's audio is decoded and shaped as asked.
    case applied
    /// Shaping is asked for and this session cannot carry it: AVPlayer owns the audio
    /// (`.remoteBypass`, the native audio-only host) or the session plays no audio. The value stands
    /// and applies to the next session that can.
    case unavailable

    static func derive(shaping: AudioShaping, pipelineApplies: Bool?) -> AudioShapingState {
        guard shaping.isActive, let pipelineApplies else { return .off }
        return pipelineApplies ? .applied : .unavailable
    }
}
