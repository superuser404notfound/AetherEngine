#if os(macOS)
import AppKit
import AVFoundation
import Testing
@testable import AetherEngine

/// AE#810: the tracker that follows the system PiP window's size. Plain panels stand in for that window
/// and are never ordered on screen; visibility is injected.
@Suite("PiP area tracker", .serialized)
@MainActor
struct PictureInPictureAreaTrackerTests {
    private func panel(_ size: CGSize) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        // A plain view posts frame changes by default; start from off so the restore is observable.
        content.postsFrameChangedNotifications = false
        panel.contentView = content
        return panel
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private final class Reports {
        var sizes: [CGSize?] = []
        var last: CGSize? { sizes.last ?? nil }
    }

    private func tracker(_ windows: [NSWindow], _ reports: Reports) -> PictureInPictureAreaTracker {
        PictureInPictureAreaTracker(windows: { windows }, isVisible: { _ in true }, onChange: { reports.sizes.append($0) })
    }

    private func known(_ windows: [NSWindow]) -> NSHashTable<NSWindow> {
        let table = NSHashTable<NSWindow>.weakObjects()
        windows.forEach(table.add)
        return table
    }

    @Test("only the new panel with the picture's aspect is adopted")
    func filters() {
        let old = panel(CGSize(width: 556, height: 312))
        let host = panel(CGSize(width: 556, height: 312))
        let notPanel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 556, height: 312), styleMask: [], backing: .buffered, defer: true)
        notPanel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 556, height: 312))
        let wrongAspect = panel(CGSize(width: 400, height: 400))
        let target = panel(CGSize(width: 556, height: 312))
        let reports = Reports()
        let tracker = tracker([old, host, notPanel, wrongAspect, target], reports)
        tracker.start(known: known([old]), host: host, aspect: 16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312))
        target.contentView?.setFrameSize(CGSize(width: 700, height: 394))
        pump()
        #expect(reports.last == CGSize(width: 700, height: 394))
        tracker.stop()
    }

    @Test("two matching panels adopt nothing")
    func ambiguousAdoptsNothing() {
        let reports = Reports()
        let tracker = tracker([panel(CGSize(width: 556, height: 312)), panel(CGSize(width: 320, height: 180))], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)
        #expect(reports.sizes.isEmpty)
        tracker.stop()
    }

    @Test("a panel that settles to the picture's aspect later is found on a window update")
    func foundOnUpdate() {
        let target = panel(CGSize(width: 100, height: 100))
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)
        #expect(reports.sizes.isEmpty)
        target.contentView?.setFrameSize(CGSize(width: 556, height: 312.75))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: target)
        pump()
        #expect(reports.last == CGSize(width: 556, height: 312.75))
        tracker.stop()
    }

    @Test("without a picture aspect any single new panel qualifies")
    func noAspect() {
        let reports = Reports()
        let tracker = tracker([panel(CGSize(width: 300, height: 200))], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        #expect(reports.last == CGSize(width: 300, height: 200))
        tracker.stop()
    }

    @Test("stop reports no area, restores the view's setting and removes the observers")
    func stopCleansUp() {
        let target = panel(CGSize(width: 556, height: 312))
        let view = try! #require(target.contentView)
        #expect(!view.postsFrameChangedNotifications)
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        #expect(view.postsFrameChangedNotifications)
        tracker.stop()
        #expect(reports.sizes.last as CGSize?? == .some(nil))
        #expect(!view.postsFrameChangedNotifications)
        let count = reports.sizes.count
        // Turn posting back on so a frame observer left behind would hear the change.
        view.postsFrameChangedNotifications = true
        view.setFrameSize(CGSize(width: 800, height: 450))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: target)
        pump()
        #expect(reports.sizes.count == count)
    }

    @Test("a second start adds no second observer, and the window-update observer goes once a panel is adopted")
    func singleRegistration() {
        let target = panel(CGSize(width: 556, height: 312))
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        let afterStart = reports.sizes.count
        #expect(afterStart == 1)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: target)
        pump()
        #expect(reports.sizes.count == afterStart)
        target.contentView?.setFrameSize(CGSize(width: 600, height: 337))
        pump()
        #expect(reports.sizes.count == afterStart + 1)
        tracker.stop()
    }

    @Test("a tracker released while tracking gives the view its setting back")
    func releaseRestores() {
        let target = panel(CGSize(width: 556, height: 312))
        let view = try! #require(target.contentView)
        do {
            let tracker = tracker([target], Reports())
            tracker.start(known: .weakObjects(), host: nil, aspect: nil)
            #expect(view.postsFrameChangedNotifications)
        }
        #expect(!view.postsFrameChangedNotifications)
    }

    @Test("stop leaves the source's snapshot alone, so a second start on it still filters")
    func stopKeepsSnapshot() {
        let old = panel(CGSize(width: 556, height: 312))
        let target = panel(CGSize(width: 556, height: 312))
        let snapshot = known([old])
        let reports = Reports()
        let tracker = tracker([old, target], reports)
        tracker.start(known: snapshot, host: nil, aspect: 16.0 / 9.0)
        tracker.stop()
        #expect(snapshot.count == 1 && snapshot.contains(old))
        tracker.start(known: snapshot, host: nil, aspect: 16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312))
        // `old` was still filtered: with it counted, two panels would have matched and nothing been adopted.
        tracker.stop()
    }

    private final class Clock {
        var value: TimeInterval = 100
    }

    private func tracker(_ windows: [NSWindow], _ reports: Reports, clock: Clock) -> PictureInPictureAreaTracker {
        PictureInPictureAreaTracker(windows: { windows }, isVisible: { _ in true }, now: { clock.value },
                                    onChange: { reports.sizes.append($0) })
    }

    private func postUpdate(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        pump()
    }

    @Test("the search for the window stops observing updates after its budget, and keeps no area")
    func searchExpires() {
        let target = panel(CGSize(width: 100, height: 100))
        let reports = Reports()
        let clock = Clock()
        let tracker = tracker([target], reports, clock: clock)
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)

        // Inside the budget a late match is still found (see foundOnUpdate); here it just keeps looking.
        clock.value += PictureInPictureAreaTracker.searchBudget - 1
        postUpdate(target)
        #expect(reports.sizes.isEmpty)

        // The first update past the budget ends the observation.
        clock.value += 2
        postUpdate(target)
        #expect(reports.sizes.isEmpty)
        target.contentView?.setFrameSize(CGSize(width: 556, height: 312.75))
        postUpdate(target)
        #expect(reports.sizes.isEmpty)

        // Stopping and starting again is a new search.
        tracker.stop()
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312.75))
        tracker.stop()
    }

    @Test("a new aspect after the search expired starts a new search")
    func aspectRestartsExpiredSearch() {
        let target = panel(CGSize(width: 400, height: 300))
        let reports = Reports()
        let clock = Clock()
        let tracker = tracker([target], reports, clock: clock)
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)
        clock.value += PictureInPictureAreaTracker.searchBudget + 1
        postUpdate(target)
        #expect(reports.sizes.isEmpty)
        tracker.updateAspect(4.0 / 3.0)
        #expect(reports.last == CGSize(width: 400, height: 300))
        tracker.stop()
    }

    @Test("an aspect that arrives after start finds a window the unknown aspect could not tell apart")
    func aspectArrivesLate() {
        let a = panel(CGSize(width: 556, height: 312))
        let b = panel(CGSize(width: 400, height: 400))
        let reports = Reports()
        let tracker = tracker([a, b], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        #expect(reports.sizes.isEmpty)
        tracker.updateAspect(16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312))
        tracker.stop()
    }

    @Test("a window adopted under an unknown aspect is dropped when the known aspect does not match it")
    func wrongAdoptionIsDropped() {
        let wrong = panel(CGSize(width: 400, height: 400))
        let right = panel(CGSize(width: 556, height: 312))
        let wrongView = try! #require(wrong.contentView)
        var windows: [NSWindow] = [wrong]
        let reports = Reports()
        let tracker = PictureInPictureAreaTracker(windows: { windows }, isVisible: { _ in true },
                                                  onChange: { reports.sizes.append($0) })
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        #expect(reports.last == CGSize(width: 400, height: 400))
        #expect(wrongView.postsFrameChangedNotifications)

        tracker.updateAspect(16.0 / 9.0)
        #expect(reports.sizes.last as CGSize?? == .some(nil))
        #expect(!wrongView.postsFrameChangedNotifications)

        // The real window turns up afterwards and is adopted; the wrong one is still ignored.
        windows.append(right)
        postUpdate(right)
        #expect(reports.last == CGSize(width: 556, height: 312))
        wrongView.setFrameSize(CGSize(width: 500, height: 500))
        pump()
        #expect(reports.last == CGSize(width: 556, height: 312))
        tracker.stop()
    }

    @Test("an adopted window that fits the arriving aspect is kept, and a repeated aspect changes nothing")
    func matchingAdoptionIsKept() {
        let target = panel(CGSize(width: 556, height: 312))
        let view = try! #require(target.contentView)
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        let count = reports.sizes.count
        tracker.updateAspect(16.0 / 9.0)
        tracker.updateAspect(16.0 / 9.0)
        #expect(reports.sizes.count == count)
        #expect(view.postsFrameChangedNotifications)
        tracker.stop()
    }

    @Test("a window matched under a known aspect is kept through aspect changes, in either direction")
    func adoptionSurvivesAspectChanges() {
        let target = panel(CGSize(width: 556, height: 312))
        let view = try! #require(target.contentView)
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: 16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312))
        let count = reports.sizes.count
        tracker.updateAspect(4.0 / 3.0)
        tracker.updateAspect(16.0 / 9.0)
        tracker.updateAspect(4.0 / 3.0)
        #expect(reports.sizes.count == count)
        #expect(view.postsFrameChangedNotifications)
        // AVKit resizes the window to the new picture shape, a little after the aspect arrives. The kept
        // window reports each of those sizes.
        view.setFrameSize(CGSize(width: 480, height: 360))
        pump()
        #expect(reports.last == CGSize(width: 480, height: 360))
        view.setFrameSize(CGSize(width: 500, height: 281))
        pump()
        #expect(reports.last == CGSize(width: 500, height: 281))
        tracker.stop()
        #expect(reports.last == nil)
    }

    @Test("a window matched under the first known aspect is kept when the aspect changes again")
    func firstAspectCheckedOnce() {
        let target = panel(CGSize(width: 556, height: 312))
        let reports = Reports()
        let tracker = tracker([target], reports)
        tracker.start(known: .weakObjects(), host: nil, aspect: nil)
        tracker.updateAspect(16.0 / 9.0)
        #expect(reports.last == CGSize(width: 556, height: 312))
        let count = reports.sizes.count
        tracker.updateAspect(4.0 / 3.0)
        #expect(reports.sizes.count == count)
        #expect(reports.last == CGSize(width: 556, height: 312))
        tracker.stop()
    }

    @Test("engine wiring: a picture aspect change during PiP keeps the window's area and the layer on it")
    func engineKeepsAreaThroughAspectChange() throws {
        let right = panel(CGSize(width: 556, height: 312))
        let windows: [NSWindow] = [right]
        let full = CGRect(x: 0, y: 0, width: 640, height: 392)
        let view = AetherPlayerView(frame: full)
        let engine = try AetherEngine()
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        engine.softwareHost = host
        engine.bind(view: view)
        let layer = host.displayLayer
        engine.pictureInPictureAreaTracker = PictureInPictureAreaTracker(
            windows: { windows }, isVisible: { _ in true },
            onChange: { [weak engine] in engine?.pictureInPictureArea = $0 })
        engine.softwareDisplaySize = CGSize(width: 1280, height: 720)

        engine.pictureInPictureActive = true
        #expect(engine.pictureInPictureArea == CGSize(width: 556, height: 312))
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 556, height: 312))

        engine.softwareDisplaySize = CGSize(width: 640, height: 480)
        #expect(engine.pictureInPictureArea == CGSize(width: 556, height: 312))
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 556, height: 312))

        engine.softwareDisplaySize = CGSize(width: 1280, height: 720)
        #expect(engine.pictureInPictureArea == CGSize(width: 556, height: 312))
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 556, height: 312))

        engine.pictureInPictureActive = false
        #expect(engine.pictureInPictureArea == nil)
        #expect(layer.frame == full)
    }

    @Test("engine wiring: the picture size arriving during PiP re-arms the window match")
    func engineRearmsOnDisplaySize() throws {
        let wrong = panel(CGSize(width: 400, height: 400))
        let right = panel(CGSize(width: 556, height: 312))
        var windows: [NSWindow] = [wrong]
        let engine = try AetherEngine()
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        engine.softwareHost = host
        engine.pictureInPictureAreaTracker = PictureInPictureAreaTracker(
            windows: { windows }, isVisible: { _ in true },
            onChange: { [weak engine] in engine?.pictureInPictureArea = $0 })

        // PiP starts before the first frame told the engine the picture's size: the lone panel is taken.
        engine.pictureInPictureActive = true
        #expect(engine.pictureInPictureArea == CGSize(width: 400, height: 400))

        engine.softwareDisplaySize = CGSize(width: 1280, height: 720)
        #expect(engine.pictureInPictureArea == nil)
        windows.append(right)
        postUpdate(right)
        #expect(engine.pictureInPictureArea == CGSize(width: 556, height: 312))
        engine.pictureInPictureActive = false
        #expect(engine.pictureInPictureArea == nil)
    }

    @Test("engine wiring: the area lays the layer out only while PiP is active, and clearing it restores")
    func engineDrivesPictureArea() throws {
        let full = CGRect(x: 0, y: 0, width: 640, height: 392)
        let view = AetherPlayerView(frame: full)
        let engine = try AetherEngine()
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        engine.softwareHost = host
        engine.bind(view: view)
        let layer = host.displayLayer
        engine.softwareDisplaySize = CGSize(width: 1280, height: 720)

        // Not in PiP: an area changes nothing.
        engine.pictureInPictureArea = CGSize(width: 556, height: 312)
        #expect(layer.frame == full)

        engine.pictureInPictureActive = true
        engine.pictureInPictureArea = CGSize(width: 417, height: 313)
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 417, height: 313))
        engine.pictureInPictureArea = CGSize(width: 720, height: 405)
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 720, height: 405))

        engine.pictureInPictureActive = false
        #expect(engine.pictureInPictureArea == nil)
        #expect(layer.frame == full)
    }

    @Test("a view detached during PiP comes back with its normal layout")
    func detachResetsPictureLayout() {
        let full = CGRect(x: 0, y: 0, width: 640, height: 392)
        let view = AetherPlayerView(frame: full)
        let layer = AVSampleBufferDisplayLayer()
        view.attach(layer)
        view.setPictureFit(CGSize(width: 1280, height: 720))
        view.setPictureArea(CGSize(width: 417, height: 313))
        view.detach()
        view.attach(layer)
        #expect(layer.frame == full)
    }
}
#endif
