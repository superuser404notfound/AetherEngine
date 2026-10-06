import Foundation

/// [MovieClaw P27] 软件通路读包卡住时的时钟看护（MovieClaw 补丁，见 PATCHES.md）。
///
/// 软件通路的播放循环每读一个包才检查一次「音频提前量耗尽没有、要不要停钟重新缓冲」
/// （`applyAudioClockAction`）。断流时这一次读会一直等（读取端在反复重连），循环走不到检查，
/// 同步器时钟就一直空转：画面定格、没声音，播放进度却照走；宿主的断线看门狗靠「播放头不动」判断，
/// 于是永远察觉不到（故障注入实测：断流 150 秒进度从 75 走到 225，`rebuf=n`、音频落后时钟 118 秒）。
///
/// 读之前起一个看护定时器，读等待期间每 0.25 秒按同一条规则（`AudioLookaheadPolicy.clockAction`）
/// 判一次，提前量耗尽就先把时钟停下。读回来后停掉定时器；下一轮循环的 `applyAudioClockAction`
/// 看到提前量仍不够会照常记成重新缓冲，数据攒够了按原规则恢复——这里只补「读卡住期间」这一段空白。
final class ReadStarvationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var engaged = false
    private let timer: DispatchSourceTimer
    private let audioOutput: AudioOutput
    private let lastFedAudioPTS: Double
    private let isPlaying: () -> Bool

    /// lastFedAudioPTS：读之前最后喂给渲染器的音频时间戳（读卡住期间不会再变）
    init(audioOutput: AudioOutput, lastFedAudioPTS: Double, isPlaying: @escaping () -> Bool) {
        self.audioOutput = audioOutput
        self.lastFedAudioPTS = lastFedAudioPTS
        self.isPlaying = isPlaying
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    private func check() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !engaged, lastFedAudioPTS.isFinite, isPlaying() else { return }
        let action = AudioLookaheadPolicy.clockAction(
            rebuffering: false, lastFedAudioPTS: lastFedAudioPTS,
            clockSeconds: audioOutput.currentTimeSeconds, atRingEnd: true, sourceEnded: false)
        guard action == .pauseForRebuffer else { return }
        engaged = true
        EngineLog.emit(
            "[SWHost] [MovieClaw P27] read blocked and audio lead exhausted "
            + "(fed to \(String(format: "%.2f", lastFedAudioPTS))s); pausing clock for rebuffer",
            category: .swPlayback)
        audioOutput.pause()
    }

    /// 读回来了（拿到包、出错或被打断都算）：停掉定时器
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        timer.cancel()
    }
}
