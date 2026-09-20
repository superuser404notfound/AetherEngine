import Foundation
import AetherLibavcodec
import AetherLibavutil

/// One source stream a recording will copy, as the route's demuxer describes it.
///
/// `codecParameters` is borrowed from the source `AVStream` and is only valid while that demuxer is
/// open, which is why the writer copies it (`avcodec_parameters_copy`) at construction and never
/// retains the pointer.
struct RecordingStreamDescriptor {
    let sourceStreamIndex: Int32
    let timeBaseNum: Int32
    let timeBaseDen: Int32
    let codecParameters: UnsafeMutablePointer<AVCodecParameters>?
    /// Whether this is the VIDEO stream. The writer arms on a video keyframe, and it has to know
    /// which stream that means: every AAC packet carries AV_PKT_FLAG_KEY, so a gate that accepts a
    /// keyframe from any stream is armed by the first audio packet and the recording then opens
    /// mid-GOP (measured: `non-existing PPS 0 referenced` for the whole head of the file).
    let isVideo: Bool
}

/// What a demux-thread tap calls.
///
/// **Every implementation must be non-blocking.** This runs on the thread that feeds the renderer;
/// a call that waits on disk parks playback. Implementations copy and return.
protocol LiveRecordingSink: AnyObject, Sendable {
    func accept(packetBytes: UnsafeRawBufferPointer,
                sourceStreamIndex: Int32,
                pts: Int64, dts: Int64, duration: Int64,
                isKeyframe: Bool)
}

/// What a route that owns a demux loop implements, so the engine can start a recording on it
/// without knowing which route is running.
///
/// Main-actor isolated because both callers are: `startRecording(to:)` and `endRecordingIfRunning`
/// live on the engine. The demux-thread side of the feature is `LiveRecordingSink`, which is not.
@MainActor
protocol LiveRecordingHost: AnyObject {
    /// The source streams this route's demuxer(s) expose, in source stream index order. Called off
    /// the demux thread, before any sink is installed.
    func recordingStreamDescriptors() -> [RecordingStreamDescriptor]

    /// Installs (or, with nil, removes) the sink the demux tap feeds. Called off the demux thread;
    /// the implementation publishes the sink under whatever lock its tap reads it under.
    func setRecordingSink(_ sink: LiveRecordingSink?)
}
