import CoreGraphics
#if os(tvOS) || os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The main display's native size in pixels, the box the upscale stage (#846) fits its target into.
enum DisplayPixelSize {
    @MainActor static func current() -> CGSize? {
        #if os(tvOS) || os(iOS)
        // `nativeBounds` is portrait-up on iOS whatever the orientation; video fills it landscape.
        let native = UIScreen.main.nativeBounds.size
        let size = CGSize(width: max(native.width, native.height), height: min(native.width, native.height))
        return size.width > 0 && size.height > 0 ? size : nil
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return nil }
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        return size.width > 0 && size.height > 0 ? size : nil
        #else
        return nil
        #endif
    }
}
