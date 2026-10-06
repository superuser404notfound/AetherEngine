import Foundation

/// Where the SW demux loop anchors the synchronizer clock when the first decoded
/// sample arrives (#107).
///
/// Normal files and resumes deliver their first sample at (or within head-of-stream
/// offset of) the load-time anchor, so the anchor is kept verbatim and intrinsic
/// A/V lead-in offsets survive untouched. A mid-stream-joined source (live tuner
/// MPEG-TS opened without `isLive`, live without a DVR ring, or a capture file cut
/// mid-broadcast) delivers first samples hours past the anchor; anchoring at the
/// sample PTS is the only way they ever present. `sessionZeroSeconds` is the offset
/// the host subtracts from the raw synchronizer clock so the published position
/// stays session-relative; the raw clock itself remains the source/subtitle axis.
enum SWClockAnchorPolicy {
    /// Tolerance below which the first sample is considered aligned with the load
    /// anchor. Head-of-stream offsets are a few hundred ms; mid-stream joins are
    /// minutes to hours. Seconds.
    static let toleranceSeconds: Double = 2.0

    struct Resolution: Equatable {
        let anchorSeconds: Double
        let sessionZeroSeconds: Double
    }

    static func resolve(initialSeconds: Double,
                        firstSampleSeconds: Double,
                        toleranceSeconds: Double = SWClockAnchorPolicy.toleranceSeconds) -> Resolution {
        // [MovieClaw P13] 只有首个样本「晚于」起播点才算中途加入。早于起播点是粗粒度定位落在了前面（DVD 时间表
        // 16 秒一格、长 GOP 的关键帧），时钟仍锚在起播点、之前的帧跳过；原来一律按首个样本锚，《聪明的一休》
        // 续播落在 12 秒前，画面要等时钟真的走到起播点才出，起播 8.9 秒
        guard firstSampleSeconds.isFinite,
              firstSampleSeconds - initialSeconds > toleranceSeconds else {
            return Resolution(anchorSeconds: initialSeconds, sessionZeroSeconds: 0)
        }
        return Resolution(anchorSeconds: firstSampleSeconds,
                          sessionZeroSeconds: max(0, firstSampleSeconds - initialSeconds))
    }

    /// [MovieClaw P35] 点播片源在装载时就定下的 session zero：容器起点明显不为 0（超过容差）时取起点，否则 0。
    ///
    /// 软件通路原来只在首个样本「晚于」起播点时才得出 session zero（给直播中途加入用）。时间戳从几百秒起的
    /// 点播片源（《戴珍珠耳环》VC-1 原盘 raw 从 600 秒起），从头播时首样本 600 对起播点 0 会触发、时间轴对；
    /// 续播到 600 时首样本 600 对起播点 600 不触发，于是整条时间轴按 raw 发布：续播点差 600 秒，
    /// 跳到 600 秒之前落在第一个包之前、时钟等不到画面，永远卡住（真机每批必现）。主力通路按 AE#270
    /// 以容器起点为 0，这里对齐同一口径。容差内的小起点（DVD、B 帧 MP4）照旧按 raw，行为不变。
    static func vodSessionZero(sourceOriginSeconds: Double, isLive: Bool) -> Double {
        guard !isLive, sourceOriginSeconds.isFinite, sourceOriginSeconds > toleranceSeconds else { return 0 }
        return sourceOriginSeconds
    }

    /// Converts a session-axis position into the source axis.
    ///
    /// The host publishes positions session-relative (`raw - sessionZero`), but the
    /// demuxer, the packet store, the decoder's skip threshold and the synchronizer
    /// clock all speak the source's own timestamps. A seek arrives on the session
    /// axis and has to be carried back over before it reaches any of them; for a
    /// zero-based source the two axes coincide and this is the identity.
    ///
    /// Without it, a mid-stream-joined source seeks to a timestamp that lies before
    /// its own first packet (which the demuxer clamps to the start of the file),
    /// and the packet store's reservoir, measured as `storedPacketSeconds - clock`,
    /// reads as the whole offset. On a capture whose first PTS is six hours in, the
    /// producer sees six hours of buffer, stops reading, and the consumer starves
    /// with nothing to report.
    static func sourceSeconds(forSession seconds: Double, sessionZeroSeconds: Double) -> Double {
        guard seconds.isFinite, sessionZeroSeconds.isFinite, sessionZeroSeconds > 0 else {
            return seconds
        }
        return seconds + sessionZeroSeconds
    }

    /// Whether a video packet parked on renderer back-pressure has to anchor the clock itself
    /// (#337).
    ///
    /// Both feed loops gate video on `renderer.isReadyForMoreMediaData`, and the renderer only
    /// drains while the synchronizer clock runs, so a park entered with an unarmed clock cannot
    /// end on its own: the combined demux loop is the single reader, and every packet that could
    /// arm the clock is behind the park; the live feeder has a second reader, but once its
    /// look-ahead pump has spent its pre-arm budget nothing else will deliver a first buffer
    /// either. The cycle closes whenever the selected audio stream's first packet lies past the
    /// renderer's fill point (a track grouped late in the mux, or one the host switched to at
    /// start-from-zero), and the session then publishes `.playing` at a frozen clock until a seek
    /// arms it by hand. Anchoring on the video the renderer is already holding is the only exit
    /// that needs nothing from the host.
    static func shouldArmFromParkedVideo(clockArmed: Bool,
                                         isPlaying: Bool,
                                         rendererReadyForMoreData: Bool,
                                         audioArmingStillPossible: Bool) -> Bool {
        guard !clockArmed, isPlaying, !rendererReadyForMoreData else { return false }
        return !audioArmingStillPossible
    }
}
