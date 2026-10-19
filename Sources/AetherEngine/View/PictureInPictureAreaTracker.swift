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
/// `AetherPlayerView.setPictureFit` layout, which is safe.
@MainActor
final class PictureInPictureAreaTracker {
    private let onChange: (CGSize?) -> Void
    private let windows: () -> [NSWindow]
    private let isVisible: (NSWindow) -> Bool
    private var known = NSHashTable<NSWindow>.weakObjects()
    private weak var hostWindow: NSWindow?
    private var aspect: CGFloat?
    private var isTracking = false
    private let registrations = Registrations()

    /// Aspect difference up to which a panel counts as showing the picture.
    static let aspectTolerance: CGFloat = 0.02

    /// `windows` and `isVisible` are injectable for tests; the defaults are the app's windows.
    init(windows: @escaping () -> [NSWindow] = { NSApp?.windows ?? [] },
         isVisible: @escaping (NSWindow) -> Bool = { $0.isVisible },
         onChange: @escaping (CGSize?) -> Void) {
        self.windows = windows
        self.isVisible = isVisible
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
        refresh()
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
        onChange(nil)
    }

    /// Find the window if it is not found yet, then report its content size.
    func refresh() {
        guard isTracking else { return }
        if registrations.view == nil {
            registrations.dropFrameObserver()
            adoptWindow()
        }
        if let view = registrations.view { report(view.bounds.size) }
    }

    private func adoptWindow() {
        let matches = windows().filter { window in
            !known.contains(window) && window !== hostWindow && window is NSPanel && isVisible(window)
                && window.contentView.map { aspectMatches($0.bounds.size) } == true
        }
        guard matches.count == 1, let view = matches[0].contentView else {
            watchWindowUpdates()
            return
        }
        registrations.dropUpdateObserver()
        registrations.adopt(view, frameObserver: NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
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

        func dropFrameObserver() {
            let token = lock.withLock { () -> NSObjectProtocol? in
                defer { frameObserver = nil }
                return frameObserver
            }
            token.map(NotificationCenter.default.removeObserver)
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
