import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform URL open. Routes to `NSWorkspace` on macOS and `UIApplication`
/// on iOS so call sites stay platform-agnostic.
enum URLOpener {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
