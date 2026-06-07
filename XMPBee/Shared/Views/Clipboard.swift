import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform clipboard write. Routes to `NSPasteboard` on macOS and
/// `UIPasteboard` on iOS so call sites stay platform-agnostic.
enum Clipboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}
