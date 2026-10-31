#if os(macOS)
import AppKit

/// Follows the size of the system picture in picture window on macOS while a software session is in
/// it, so the display layer can be laid out to that window (AE#810).
///
/// AVKit gives no public size for that window, so it is found with public AppKit only: the one visible
/// panel in `NSApp.windows` that did not exist when the PiP controller was made (it is already there by
/// the time a host reports PiP active) and whose content has the picture's aspect. Its content view
/// posts the public frame change notification, which fires when the window first settles, on every
/// resize and when PiP stops. `refresh()` is a second trigger, for the render-size delegate callback.
///
/// This relies on the system PiP window being an in-process panel. If that ever stops being true, or
/// the match is not unique, nothing is adopted, no area is reported and the layer keeps the
/// `AetherPlayerView.setPictureFit` layout, which is safe. The search for the window is bounded by
/// `searchBudget`, so an app-wide window observer does not outlive a window that never turns up.
@MainActor
final class PictureInPictureAreaTracker {
    private let onChange: (CGSize?) -> Void
    private let windows: () -> [NSWindow]
    private let isVisible: (NSWindow) -> Bool
    private let now: () -> TimeInterval
    private var known = NSHashTable<NSWindow>.weakObjects()
    private weak var hostWindow: NSWindow?
    private var aspect: CGFloat?
    private var isTracking = false
    private var searchDeadline: TimeInterval = 0
    private var searchExpired = false
    /// The adopted window was matched without a known aspect, so it still has to pass the first one.
    private var adoptionUnchecked = false
    private let registrations = Registrations()

    /// Aspect difference up to which a panel counts as showing the picture.
    static let aspectTolerance: CGFloat = 0.02

    /// How long the search for the window may keep observing window updates, in seconds. The system
    /// window is in place within about a second of the host reporting PiP active, so five seconds
    /// leaves room for a slow start; past it, no panel is going to match (an out-of-process window,
    /// an aspect outside the tolerance) and the app-wide observer would only cost every update for
    /// the rest of the session. The fit layout stays. A new search starts when an adopted window goes
    /// away, or when the picture's aspect changes while no window is adopted.
    static let searchBudget: TimeInterval = 5

    /// `windows`, `isVisible` and `now` are injectable for tests; the defaults are the app's windows
    /// and the system uptime.
    init(windows: @escaping () -> [NSWindow] = { NSApp?.windows ?? [] },
         isVisible: @escaping (NSWindow) -> Bool = { $0.isVisible },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onChange: @escaping (CGSize?) -> Void) {
        self.windows = windows
        self.isVisible = isVisible
        self.now = now
        self.onChange = onChange
    }

    /// Begin looking for the PiP window. `known` are the windows that existed before the controller was
    /// made (empty when unknown: any matching visible panel then qualifies); `host` is the window of the
    /// view showing the video and is never taken for it; `aspect` is the picture's width over height, or
    /// nil when unknown. Idempotent.
    func start(known: NSHashTable<NSWindow>, host: NSWindow?, aspect: CGFloat?) {
        guard !isTracking else { return }
        isTracking = true
        self.known = known
        hostWindow = host
        self.aspect = aspect
        beginSearch()
        refresh()
    }

    /// The picture's aspect arrived or changed. AVKit resizes the PiP window to each new picture shape,
    /// and the new aspect can arrive before that resize has happened. So a window matched under a known
    /// aspect stays the PiP window until PiP ends, through any number of aspect changes, and its size is
    /// followed as it changes. A window adopted before the aspect was known has not been matched against
    /// the picture yet: the first aspect checks it, and it is dropped if it does not match. With no window
    /// adopted, the search starts again under the new aspect.
    func updateAspect(_ newAspect: CGFloat) {
        guard isTracking, newAspect > 0 else { return }
        if let aspect, aspect > 0, abs(newAspect / aspect - 1) <= Self.aspectTolerance { return }
        aspect = newAspect
        if adoptionUnchecked {
            adoptionUnchecked = false
            if let view = registrations.view, !aspectMatches(view.bounds.size) {
                registrations.release()
                onChange(nil)
            }
        }
        if registrations.view == nil {
            beginSearch()
            refresh()
        }
    }

    /// Stop following, give the content view back its notification setting and report no area.
    func stop() {
        guard isTracking else { return }
        isTracking = false
        registrations.teardown()
        // Drop the reference only: the table belongs to the source that made it and is reused.
        known = .weakObjects()
        hostWindow = nil
        aspect = nil
        searchExpired = false
        adoptionUnchecked = false
        onChange(nil)
    }

    /// Find the window if it is not found yet, then report its content size.
    func refresh() {
        guard isTracking else { return }
        if registrations.view == nil {
            // The window we followed is gone: look for the next one with a fresh budget.
            if registrations.dropFrameObserver() { beginSearch() }
            if !searchExpired { adoptWindow() }
        }
        if let view = registrations.view { report(view.bounds.size) }
    }

    private func adoptWindow() {
        let matches = windows().filter { window in
            !known.contains(window) && window !== hostWindow && window is NSPanel && isVisible(window)
                && window.contentView.map { aspectMatches($0.bounds.size) } == true
        }
        guard matches.count == 1, let view = matches[0].contentView else {
            if now() >= searchDeadline {
                searchExpired = true
                registrations.dropUpdateObserver()
            } else {
                watchWindowUpdates()
            }
            return
        }
        registrations.dropUpdateObserver()
        adoptionUnchecked = aspect == nil
        registrations.adopt(view, frameObserver: NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private func beginSearch() {
        searchDeadline = now() + Self.searchBudget
        searchExpired = false
    }

    /// Until a window is adopted, every window update is a chance to find it. Cheap and public.
    private func watchWindowUpdates() {
        guard !registrations.isWatchingUpdates else { return }
        registrations.watchUpdates(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private func aspectMatches(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        guard let aspect, aspect > 0 else { return true }
        return abs(size.width / size.height / aspect - 1) <= Self.aspectTolerance
    }

    private func report(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onChange(size)
    }

    /// The notification tokens and the adopted view, kept apart from the main-actor state so a tracker
    /// that is released while tracking still removes its observers and gives the view its setting back
    /// (a MainActor deinit can't touch non-Sendable stored state under Swift 6).
    private final class Registrations: @unchecked Sendable {
        private let lock = NSLock()
        private var updateObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private weak var adopted: NSView?
        private var postedBefore = false

        var view: NSView? { lock.withLock { adopted } }
        var isWatchingUpdates: Bool { lock.withLock { updateObserver != nil } }

        func watchUpdates(_ token: NSObjectProtocol) {
            lock.withLock { updateObserver = token }
        }

        func dropUpdateObserver() {
            let token = lock.withLock { () -> NSObjectProtocol? in
                defer { updateObserver = nil }
                return updateObserver
            }
            token.map(NotificationCenter.default.removeObserver)
        }

        /// Returns whether there was a frame observer to drop.
        @discardableResult
        func dropFrameObserver() -> Bool {
            let token = lock.withLock { () -> NSObjectProtocol? in
                defer { frameObserver = nil }
                return frameObserver
            }
            token.map(NotificationCenter.default.removeObserver)
            return token != nil
        }

        @MainActor
        func adopt(_ view: NSView, frameObserver token: NSObjectProtocol) {
            lock.withLock {
                adopted = view
                postedBefore = view.postsFrameChangedNotifications
                frameObserver = token
            }
            view.postsFrameChangedNotifications = true
        }

        /// Remove every observer and restore the adopted view's setting.
        func teardown() {
            dropUpdateObserver()
            release()
        }

        /// Drop the frame observer and give the adopted view its setting back.
        func release() {
            dropFrameObserver()
            let (view, before) = lock.withLock { () -> (NSView?, Bool) in
                defer { adopted = nil }
                return (adopted, postedBefore)
            }
            guard let view else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { view.postsFrameChangedNotifications = before }
            } else {
                nonisolated(unsafe) let unsafeView = view
                DispatchQueue.main.async { unsafeView.postsFrameChangedNotifications = before }
            }
        }

        deinit { teardown() }
    }
}
#endif
