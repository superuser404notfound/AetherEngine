import Foundation

/// Sodalite#104 round 4: what a software session does with a pause that arrives before its first frame.
///
/// The demux and feeder loops park on a paused transport, which is right once a picture is up and
/// wrong before it: nothing is decoded, the layer never becomes ready for display, and the viewer
/// looks at black for as long as the session stays paused. Measured on the harness
/// (`play --live --sw --host-calls pausestart`): eight paused ticks of `enq=+0 status=unknown r4d=n`,
/// and the reporter's Apple TV showed the same line after a foreground retune paused a fresh tune. A
/// native session paused at the same moment shows its first frame.
///
/// So until that frame is in, a pause stops the CLOCK and not the loops.
enum PausedFirstFrame {
    /// Whether a pause arriving now keeps the loops running for the first frame. A session whose loops
    /// have not started has nothing to keep running, and `play()` starts them.
    static func holdsForFirstFrame(loopsStarted: Bool, framesEnqueued: Int) -> Bool {
        loopsStarted && framesEnqueued == 0
    }

    /// AE#973: whether a pause starts loops that never ran. Only `play()` started them, so a host that
    /// was loaded and then only paused (a session rebuilt at the playhead while paused, a paused
    /// mount) never decoded a frame and stayed black until the viewer pressed play. A host still
    /// loading leaves them to whichever transport call follows the load.
    static func startsLoopsForFirstFrame(loaded: Bool, loopsStarted: Bool) -> Bool {
        loaded && !loopsStarted
    }

    /// Whether the loops may read and decode.
    static func loopsMayRun(isPlaying: Bool, pausedBeforeFirstFrame: Bool) -> Bool {
        isPlaying || pausedBeforeFirstFrame
    }

    /// The rate a clock arming now starts at. Arming at the last speed under a paused transport would
    /// play the audio the loops are only reading for the picture's sake.
    static func armingRate(lastRate: Float, pausedBeforeFirstFrame: Bool) -> Float {
        pausedBeforeFirstFrame ? 0 : lastRate
    }

    /// The rate a clock that has just armed has to be corrected to, or nil when it already runs at it.
    ///
    /// Arming reads its rate on the loop thread and marks the clock armed a statement later, while
    /// `pause()` and `play()` run on the main actor and only touch a clock they find armed. A transport
    /// call landing between the two is lost in either direction: measured on the harness, a pause right
    /// after load left a VOD clock running under `state=paused` for eight seconds (`cur=8.25`), which
    /// then snapped back to zero on play.
    static func rateCorrectionAtArm(transportPlaying: Bool, pausedBeforeFirstFrame: Bool,
                                    synchronizerRate: Float, lastRate: Float) -> Float? {
        let target: Float = transportPlaying && !pausedBeforeFirstFrame ? lastRate : 0
        return synchronizerRate == target ? nil : target
    }

    /// Where the stopped clock moves once the first frame is in, or nil to leave it.
    ///
    /// A stopped synchronizer presents only what is due at its own time, and a live tune arms on the
    /// first AUDIO packet, which a mid-GOP join puts ahead of the first keyframe: the frame is decoded
    /// and would still never show. An unarmed clock is left alone, because the loop arms it at a sample
    /// it reads after this frame.
    static func presentationAnchor(framePTS: Double, clockArmed: Bool, clockSeconds: Double) -> Double? {
        guard clockArmed, framePTS.isFinite, clockSeconds.isFinite, clockSeconds < framePTS else { return nil }
        return framePTS
    }
}
