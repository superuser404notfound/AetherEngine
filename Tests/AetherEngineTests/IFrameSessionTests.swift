// Tests/AetherEngineTests/IFrameSessionTests.swift
import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// A file-backed custom reader that counts its closes: the stand-in for a host's clone.
private final class CountingFileReader: IOReader, @unchecked Sendable {
    let discImageProbeEnabled = false
    private let lock = NSLock()
    private let handle: FileHandle
    private let size: Int64
    private var offset: Int64 = 0
    private var _closes = 0
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
    var closes: Int { lock.withLock { _closes } }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size count: Int32) -> Int32 {
        lock.withLock {
            guard let buffer, count > 0, offset < size else { return 0 }
            try? handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(min(Int64(count), size - offset)))
            data.copyBytes(to: buffer, count: data.count)
            offset += Int64(data.count)
            return Int32(data.count)
        }
    }
    func seek(offset requested: Int64, whence: Int32) -> Int64 {
        lock.withLock {
            if whence & 0x10000 != 0 { return size }
            switch whence & ~0x20000 {
            case SEEK_SET: offset = requested
            case SEEK_CUR: offset += requested
            case SEEK_END: offset = size + requested
            default: return -1
            }
            return offset
        }
    }
    func close() { lock.withLock { _closes += 1 } }
}

@Suite("I-frame rendition on a real session", .serialized)
struct IFrameSessionTests {
    private static let fixture = "restart-witness-av.mp4"

    @Test("a flagged VOD session lists the rendition and serves keyframes on the plan's timeline",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func servesRendition() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        let playbackURL = try engine.start()
        defer { engine.stop() }
        try #require(engine.planBoundariesClaimRandomAccess, "fixture must plan on its keyframe index")
        #expect(engine.iFrameRenditionVerdict == .served)
        #expect(playbackURL.lastPathComponent == "master.m3u8")
        let prov = try #require(engine.provider)
        #expect(prov.iFrameRenditionServed)
        #expect(prov.iFrameRenditionFormat == .keyframes)
        try #require(prov.segmentCount >= 2)

        let initSegment = try #require(prov.iFrameInitSegment())
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: initSegment)))
        // Deliberately out of order: the last entry first.
        for index in [prov.segmentCount - 1, 0, 1] {
            let fragment = try #require(prov.iFrameSegment(at: index))
            #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
            let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: fragment)))
            #expect(abs(tfdt / timescale - engine.segmentPlan[index].startSeconds) < 0.002,
                    "iframe\(index) sits at \(tfdt / timescale), plan says \(engine.segmentPlan[index].startSeconds)")
        }
        #expect(prov.iFrameSegment(at: prov.segmentCount) == nil)
    }

    private static let dolbyVisionFixture = "user/Patterns_Of_Nature_DoVi_24_P5_UHD_HEVC-10mbps_DD+JOC-768kbps_iOS.mp4"

    // Profile 5 stills need the DolbyVisionStillReshaping trait (README, "Optional components").
    #if DolbyVisionStillReshaping
    @Test("a Dolby Vision session serves SDR JPEG stills on the plan's timeline",
          .enabled(if: fixtureExists(dolbyVisionFixture)), .timeLimit(.minutes(2)))
    func dolbyVisionServesJPEG() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.dolbyVisionFixture), dvModeAvailable: true)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        defer { engine.stop() }
        try #require(engine.iFrameRenditionVerdict == .served)
        let prov = try #require(engine.provider)
        guard case .jpeg(let width, let height, _) = prov.iFrameRenditionFormat else {
            Issue.record("expected a JPEG rendition, got \(String(describing: prov.iFrameRenditionFormat))")
            return
        }
        #expect(width == 640 && height == 360)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: prov)
        #expect(master.contains("CODECS=\"mjpg\",RESOLUTION=640x360,VIDEO-RANGE=SDR"))
        let initSegment = try #require(prov.iFrameInitSegment())
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: initSegment)))
        for index in [prov.segmentCount - 1, 2] {
            let fragment = try #require(prov.iFrameSegment(at: index))
            let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: fragment)))
            #expect(abs(tfdt / timescale - engine.segmentPlan[index].startSeconds) < 0.002)
            let mdat = try #require(IFrameTestBoxes.find(["mdat"], in: fragment))
            #expect(fragment.subdata(in: mdat).prefix(2) == Data([0xFF, 0xD8]))
        }
    }

    @Test("a JPEG I-frame playlist waits for the main variant and is withheld from a player that refused it",
          .enabled(if: fixtureExists(dolbyVisionFixture)), .timeLimit(.minutes(2)))
    func jpegPlaylistFollowsMainVariant() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.dolbyVisionFixture), dvModeAvailable: true)
        engine.requestIFramePlaylist()
        let playbackURL = try engine.start()
        defer { engine.stop() }
        let base = playbackURL.deletingLastPathComponent()
        let playlistURL = base.appendingPathComponent("iframe.m3u8")

        let started = Date()
        #expect(!engine.iFrameRenditionWithheld)
        #expect((try? String(contentsOf: playlistURL, encoding: .utf8)) == nil)
        #expect(Date().timeIntervalSince(started) >= HLSLocalServer.iFrameMainVariantWaitSeconds - 0.1)
        #expect(engine.iFrameRenditionWithheld)

        _ = try Data(contentsOf: base.appendingPathComponent("init.mp4"))
        let playlist = try String(contentsOf: playlistURL, encoding: .utf8)
        #expect(playlist.contains("iframe1.mp4"))
    }
    #else
    @Test("without the reshaping trait a Profile 5 session lists no I-frame rendition",
          .enabled(if: fixtureExists(dolbyVisionFixture)), .timeLimit(.minutes(2)))
    func dolbyVisionWithoutReshapingHasNoRendition() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.dolbyVisionFixture), dvModeAvailable: true)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.iFrameRenditionVerdict == .absent(.dolbyVisionStillsNotBuiltIn))
        #expect(!engine.yieldsStills)
        let prov = try #require(engine.provider)
        #expect(!prov.iFrameRenditionServed)
    }
    #endif

    @Test("the loopback server answers the three new paths",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func routes() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        let playbackURL = try engine.start()
        defer { engine.stop() }
        let base = playbackURL.deletingLastPathComponent()
        let master = try String(contentsOf: playbackURL, encoding: .utf8)
        #expect(master.contains("#EXT-X-I-FRAME-STREAM-INF:"))
        #expect(master.contains("URI=\"iframe.m3u8\""))
        let playlist = try String(contentsOf: base.appendingPathComponent("iframe.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#EXT-X-I-FRAMES-ONLY"))
        #expect(playlist.contains("iframe1.mp4"))
        let initSegment = try Data(contentsOf: base.appendingPathComponent("iframe_init.mp4"))
        #expect(IFrameTestBoxes.topLevelTypes(initSegment) == ["ftyp", "moov"])
        let fragment = try Data(contentsOf: base.appendingPathComponent("iframe1.mp4"))
        #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
        #expect((try? Data(contentsOf: base.appendingPathComponent("iframe99999.mp4"))) == nil)
    }

    @Test("without the request the session is what it was: no tag, no route, no reader",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func flagOffLeavesMasterUntouched() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.iFrameRenditionVerdict == .absent(.notRequested))
        let prov = try #require(engine.provider)
        #expect(!prov.iFrameRenditionServed)
        #expect(prov.iFrameInitSegment() == nil)
        #expect(prov.iFrameSegment(at: 0) == nil)
        #expect(!HLSLocalServer.buildMasterPlaylistText(provider: prov).contains("I-FRAME"))
    }

    @Test("the fallback to the media playlist takes the rendition down with it",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func fallbackDropsRendition() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)
        #expect(prov.iFrameSegment(at: 0) != nil)
        engine.markServingMediaAfterFallback()
        #expect(!prov.iFrameRenditionServed)
        #expect(prov.iFrameSegment(at: 0) == nil)
    }

    @Test("stopping while a keyframe request is in flight neither crashes nor hangs",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func stopWithRenditionInFlightDoesNotCrash() async throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        let prov = try #require(engine.provider)
        let count = prov.segmentCount
        await withTaskGroup(of: Void.self) { group in
            for round in 0..<20 {
                group.addTask { _ = prov.iFrameSegment(at: round % count) }
            }
            group.addTask { engine.stop() }
        }
        #expect(prov.iFrameSegment(at: 0) == nil)
    }

    @Test("a live session is never a candidate, whatever else is true")
    func liveSessionServesNoRendition() {
        let verdict = IFrameRenditionEligibility.candidate(.init(
            requested: true, isLive: true, planBoundariesClaimRandomAccess: true,
            sequentialOrigin: false, heldSourceConnection: false, originIsSerial: false,
            isDiscSource: false, secondReaderAvailable: true))
        #expect(verdict == .absent(.live))
    }

    @Test("the load option defaults to off and is a tuning field, not a session identity")
    func loadOptionDefault() {
        #expect(LoadOptions().serveIFramePlaylist == false)
        var on = LoadOptions()
        on.serveIFramePlaylist = true
        #expect(LoadOptions(serveIFramePlaylist: true) == on)
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: on).isEmpty)
        #expect(SessionOptionCorrection.knownFields.contains("serveIFramePlaylist"))
    }

    @Test("a custom source's clone feeds the side reader and is closed exactly once at stop",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func customCloneIsClosedAtStop() async throws {
        let clone = try CountingFileReader(url: fixtureURL(Self.fixture))
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        engine.customIFrameReader = (reader: clone, formatHint: "mp4")
        _ = try engine.start()
        let prov = try #require(engine.provider)
        let fragment = try #require(prov.iFrameSegment(at: 1))
        #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
        #expect(clone.closes == 0)
        engine.stop()
        try await waitFor { clone.closes == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(clone.closes == 1)
    }

    @Test("a clone nobody ever read from is still closed at stop",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func untouchedCloneIsClosedAtStop() async throws {
        let clone = try CountingFileReader(url: fixtureURL(Self.fixture))
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        engine.customIFrameReader = (reader: clone, formatHint: "mp4")
        _ = try engine.start()
        engine.stop()
        try await waitFor { clone.closes == 1 }
    }

    @Test("a clone handed to a session that cannot serve the rendition is closed at once",
          .enabled(if: fixtureExists("sdr-h264.mp4")), .timeLimit(.minutes(2)))
    func cloneOfAnAbsentRenditionIsClosed() throws {
        // One IRAP in the whole file: no keyframe-aligned plan, so the rendition stays absent.
        let clone = try CountingFileReader(url: fixtureURL("sdr-h264.mp4"))
        let engine = HLSVideoEngine(url: fixtureURL("sdr-h264.mp4"), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        engine.customIFrameReader = (reader: clone, formatHint: "mp4")
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.iFrameRenditionVerdict == .absent(.planNotKeyframeAligned))
        #expect(clone.closes == 1)
    }
}
