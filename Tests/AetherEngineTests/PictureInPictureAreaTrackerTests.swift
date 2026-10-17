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
