import Foundation
import AetherLibavcodec
import AetherLibavutil

public extension AetherEngine {

    /// Records the currently playing live stream to `url`, fed from the connection this session
    /// already holds, so no second connection to the origin is opened. That is what makes the
    /// feature usable on IPTV, where a provider plan commonly caps an account at 1 to 3 simultaneous
    /// connections and a second connection knocks the viewer off the channel.
    ///
    /// The recording is a stream copy of the SOURCE packets into MPEG-TS, taken before any audio
    /// bridging: a TrueHD or DTS channel records its original audio even while playback is listening
    /// to a bridged FLAC rendition. Nothing is decoded and nothing is re-encoded. Writing starts at
    /// the first video keyframe after this call, so the file opens on a decodable picture.
    ///
    /// It follows the source rather than the playhead, so pausing or scrubbing inside the DVR window
    /// does not interrupt it.
    ///
    /// Throws for a condition the host can act on before anything is written: a session that is not
    /// live, a route with no engine-owned byte path (`.remoteBypass`), a recording already running,
    /// or a path that cannot be created. Anything that can only be discovered while writing arrives
    /// through `$recordingState` as `.failed`, never through both.
    func startRecording(to url: URL) async throws {
        if case .recording(let progress) = recordingState {
            throw RecordingFailure.alreadyRecording(progress.url)
        }
        guard isLive else { throw RecordingFailure.notLive }

        let route = videoRoute
        guard route == .loopback || route == .software else {
            throw RecordingFailure.unsupportedRoute(route)
        }
        guard let host = currentRecordingHost() else {
            throw RecordingFailure.unsupportedRoute(route)
        }

        let descriptors = host.recordingStreamDescriptors()
        let writer = try LiveRecordingWriter(
            url: url,
            streams: descriptors,
            ceilingBytes: Self.recordingQueueCeilingBytes,
            onFailure: { [weak self] failure in
                Task { @MainActor in self?.recordingDidFail(failure) }
            }
        )

        activeRecording = writer
        activeRecordingHost = host
        host.setRecordingSink(writer)
        recordingState = .recording(RecordingProgress(url: url,
                                                      startedAt: Date(),
                                                      bytesWritten: 0,
                                                      durationSeconds: 0))
        startRecordingProgressTimer()

        EngineLog.emit(
            "[Recording] started route=\(route.rawValue) streams=\(descriptors.count) "
            + "url=\(url.lastPathComponent)",
            category: .session
        )
    }

    /// Ends the recording and closes the file. Idempotent, and a no-op when nothing is recording.
    func stopRecording() async {
        endRecordingIfRunning(reason: .stoppedByHost)
    }
}

extension AetherEngine {

    /// Ceiling for the recording handoff queue.
    ///
    /// Sized against the two real failure directions: too small and an ordinary disk hiccup ends a
    /// recording that would have recovered, too large and a genuinely dead disk buffers minutes of
    /// video in RAM before anyone notices. 16 MiB is roughly four seconds at a 32 Mbit/s live
    /// bitrate, the top of what the engine's live paths carry, and is bounded RAM a tvOS session can
    /// afford. Pinned by `LiveRecordingCeilingTests`; a retune is a deliberate two-file edit.
    static let recordingQueueCeilingBytes = 16 * 1024 * 1024

    /// How often a running recording republishes its progress. Not per packet: a host binding a
    /// label to a per-packet publisher would re-render thousands of times a second.
    static let recordingProgressInterval: TimeInterval = 1.0

    /// The route component that owns the demux loop right now, or nil.
    ///
    /// `.remoteBypass` has neither, which is the whole reason `startRecording` refuses it: there is
    /// no engine-owned byte path to tap.
    func currentRecordingHost() -> LiveRecordingHost? {
        if let producer = nativeVideoSession?.producer {
            return producer
        }
        if let software = softwareHost {
            return software
        }
        return nil
    }

    /// Ends a running recording, if any, for a reason that is not a failure. Idempotent.
    func endRecordingIfRunning(reason: RecordingEndReason) {
        guard let writer = activeRecording else { return }
        (activeRecordingHost as? LiveRecordingHost)?.setRecordingSink(nil)
        activeRecordingHost = nil
        activeRecording = nil
        stopRecordingProgressTimer()
        writer.finish(reason: reason)
        recordingState = .ended(reason)
    }

    /// Called from the writer's failure callback, already hopped to the main actor.
    func recordingDidFail(_ failure: RecordingFailure) {
        guard activeRecording != nil else { return }
        (activeRecordingHost as? LiveRecordingHost)?.setRecordingSink(nil)
        activeRecordingHost = nil
        activeRecording = nil
        stopRecordingProgressTimer()
        recordingState = .failed(failure)
        EngineLog.emit("[Recording] failed: \(failure)", category: .session)
    }

    func startRecordingProgressTimer() {
        stopRecordingProgressTimer()
        let timer = Timer(timeInterval: Self.recordingProgressInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishRecordingProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingProgressTimer = timer
    }

    func stopRecordingProgressTimer() {
        recordingProgressTimer?.invalidate()
        recordingProgressTimer = nil
    }

    private func publishRecordingProgress() {
        guard let writer = activeRecording,
              case .recording(let previous) = recordingState else { return }
        let next = RecordingProgress(url: previous.url,
                                     startedAt: previous.startedAt,
                                     bytesWritten: writer.bytesWritten,
                                     durationSeconds: Date().timeIntervalSince(previous.startedAt))
        // Assign only on a real change, so an idle recording does not churn Combine.
        guard next != previous else { return }
        recordingState = .recording(next)
    }
}

#if DEBUG
extension AetherEngine {

    /// Test-only: set the live route without loading a source, so the recording guards can be
    /// exercised without a live origin.
    func _testSetLiveRoute(isLive: Bool, route: VideoRoute) {
        self.isLive = isLive
        self.videoRoute = route
    }

    /// Test-only stand-in for a route that owns a demux loop. Returns one synthetic video stream,
    /// which is the same shape `LiveRecordingWriterTests` builds.
    final class TestRecordingHost: LiveRecordingHost {
        // nonisolated: the class is main-actor isolated through LiveRecordingHost, but deinit is
        // not, and it is where the parameters are freed.
        nonisolated(unsafe) private let parameters: UnsafeMutablePointer<AVCodecParameters>
        private(set) var installedSink: LiveRecordingSink?

        init() {
            let p = avcodec_parameters_alloc()!
            p.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            p.pointee.codec_id = AV_CODEC_ID_H264
            p.pointee.width = 640
            p.pointee.height = 360
            parameters = p
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = parameters
            avcodec_parameters_free(&p)
        }

        func recordingStreamDescriptors() -> [RecordingStreamDescriptor] {
            [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                       timeBaseNum: 1, timeBaseDen: 90000,
                                       codecParameters: parameters, isVideo: true)]
        }

        func setRecordingSink(_ sink: LiveRecordingSink?) { installedSink = sink }
    }

    /// Test-only: runs the real `startRecording` path against a stub route, so a lifecycle test
    /// exercises production code rather than a parallel implementation.
    func _testStartRecordingWithStubHost(to url: URL, host: TestRecordingHost) throws {
        _testSetLiveRoute(isLive: true, route: .loopback)
        let writer = try LiveRecordingWriter(
            url: url,
            streams: host.recordingStreamDescriptors(),
            ceilingBytes: Self.recordingQueueCeilingBytes,
            onFailure: { [weak self] failure in
                Task { @MainActor in self?.recordingDidFail(failure) }
            }
        )
        activeRecording = writer
        activeRecordingHost = host
        host.setRecordingSink(writer)
        recordingState = .recording(RecordingProgress(url: url,
                                                      startedAt: Date(),
                                                      bytesWritten: 0,
                                                      durationSeconds: 0))
    }
}
#endif
