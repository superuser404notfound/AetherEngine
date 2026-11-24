import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// A full segment volume used to reach the host as `vodSourceFailed` ("Source audio cannot be
/// muxed"): the session directory or the staging files could not be written, every revive failed
/// the same way, and the give-up arm blamed the audio. Measured on a device with 197 MB free, a 4K60
/// title failed to start that way while the source and its audio were fine.
@Suite("Segment storage exhaustion")
struct SegmentStorageExhaustionTests {

    private final class SurfacedFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (code: Int32, reason: String, kind: PlaybackErrorKind)?
        var snapshot: (code: Int32, reason: String, kind: PlaybackErrorKind)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ code: Int32, _ reason: String, _ kind: PlaybackErrorKind) {
            lock.lock(); value = (code, reason, kind); lock.unlock()
        }
    }

    private func makeEngine() -> HLSVideoEngine {
        HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/storage.mkv"), dvModeAvailable: false)
    }

    private func makeCache() -> SegmentCache {
        SegmentCache(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-exhaustion-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("a full volume is recognised from Foundation, POSIX and a wrapped error")
    func outOfSpaceClassification() {
        #expect(SegmentCache.isOutOfSpace(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(SegmentCache.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(SegmentCache.isOutOfSpace(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
        #expect(!SegmentCache.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(!SegmentCache.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    @Test("the latch starts clear and holds once noted")
    func latch() {
        let cache = makeCache()
        defer { cache.close() }
        #expect(!cache.storageExhausted)
        cache.noteStorageExhausted()
        cache.noteStorageExhausted()
        #expect(cache.storageExhausted)
    }

    @Test("an exhausted revive on a full segment volume names the storage, not the audio")
    func exhaustedGateNamesTheStorage() {
        let engine = makeEngine()
        let cache = makeCache()
        defer { cache.close() }
        cache.noteStorageExhausted()
        engine.cache = cache
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(surfaced.snapshot?.kind == .storageExhausted,
                "vodSourceFailed reads as a dead source and ends a host's fallback ladder")
        #expect(surfaced.snapshot?.code == FFmpegErr.enospc)
    }

    @Test("a full volume before the first stored segment ends the session at once (#1124)")
    func fullVolumeSkipsTheRevives() {
        let engine = makeEngine()
        let cache = makeCache()
        defer { cache.close() }
        cache.noteStorageExhausted()
        engine.cache = cache
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 2)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(surfaced.snapshot?.kind == .storageExhausted,
                "each revive fails the same way and re-aims at the consumer's 0:00")
        #expect(engine.muxerFailureReviveGate.attempts == 0)
    }

    @Test("a full volume mid-session still gets its revives, and the cap names the storage (#1124)")
    func fullVolumeMidSessionRevivesFirst() {
        let engine = makeEngine()
        let cache = makeCache()
        defer { cache.close() }
        #expect(cache.store(index: 0, data: Data(count: 16)))
        cache.noteStorageExhausted()
        engine.cache = cache
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(engine.muxerFailureReviveGate.attempts == 1,
                "a dip below the free reserve mid-film can clear, so the budget is spent first")
        #expect(surfaced.snapshot?.kind == .storageExhausted)
    }

    @Test("a failure surfaced before the session is installed is kept for the load (#1124)")
    func failureBeforeInstallIsRetained() {
        let engine = makeEngine()
        let cache = makeCache()
        defer { cache.close() }
        cache.noteStorageExhausted()
        engine.cache = cache
        #expect(engine.pendingVODSourceFailure == nil)

        // No onVODSourceFailed wired: loadNative has not installed the session yet.
        engine.handleVODMuxerFailure()

        #expect(engine.pendingVODSourceFailure?.kind == .storageExhausted)
        #expect(engine.pendingVODSourceFailure?.code == FFmpegErr.enospc)
    }

    @MainActor
    @Test("a load that fails with a startup source failure publishes its kind, not sourceOpenFailed (#1124)")
    func startupFailurePublishesItsKind() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }

        engine.publishLoadFailure(HLSVideoEngine.VODSourceFailure(
            code: FFmpegErr.enospc, reason: "Device storage is full: video segments cannot be written",
            kind: .storageExhausted))

        let info = try #require(engine.errorInfo)
        #expect(info.kind == .storageExhausted)
        #expect(info.underlyingCode == Int(FFmpegErr.enospc))
        #expect(info.message == "Device storage is full: video segments cannot be written (code -28)")
    }

    @Test("an exhausted revive with room on the volume keeps the muxer verdict")
    func exhaustedGateWithRoomKeepsTheMuxerVerdict() {
        let engine = makeEngine()
        let cache = makeCache()
        defer { cache.close() }
        engine.cache = cache
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(surfaced.snapshot?.kind == .vodSourceFailed)
        #expect(surfaced.snapshot?.reason == "Source audio cannot be muxed")
    }
    @Test("Muxer admission denial reaches the host as storageExhausted, cancellation does not", arguments: [false, true])
    func muxerAdmissionPreservesTheFailureKind(cancelled: Bool) throws {
        let cache = SegmentCache(freeDiskReserveBytes: 1, availableVolumeBytes: { _ in 0 })
        defer { cache.close() }
        let source = try #require(Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                      options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: source), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let muxer = try MP4SegmentMuxer(initialSegmentIndex: 0, sessionDir: cache.sessionDir,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base,
                         codecTagOverride: nil), audio: nil,
            onStorageExhausted: { cache.noteStorageExhausted() },
            admitStagingBytes: { path, count in
                cache.stagingWriteAdmission(path: path, bytes: count, shouldStop: { cancelled })
            }, onInitCaptured: { _ in })
        var packet: UnsafeMutablePointer<AVPacket>? = try #require(try demuxer.readPacket())
        defer { trackedPacketFree(&packet) }
        packet!.pointee.stream_index = muxer.videoOutputStreamIndex
        #expect(muxer.writePacket(packet!).rc >= 0)
        #expect(muxer.cutFragmentForNextSegment(1) == .failed)
        #expect(cache.storageExhausted == !cancelled)
        let engine = makeEngine()
        engine.cache = cache
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { surfaced.set($0, $1, $2) }
        engine.handleVODMuxerFailure()
        #expect(surfaced.snapshot?.kind == (cancelled ? .vodSourceFailed : .storageExhausted))
        if !cancelled { #expect(surfaced.snapshot?.code == FFmpegErr.enospc) }
    }

}
