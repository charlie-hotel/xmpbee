// Run independently of Xcode's test runner:
// xcrun swiftc XMPBee/Mac/AppZoom.swift XMPBeeTests/AppZoomCheck.swift -o /tmp/xmpbee-zoom-check
// /tmp/xmpbee-zoom-check
import AppKit
import SwiftUI

@main
struct AppZoomCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        for (index, percent) in AppZoom.levels.enumerated() {
            assert(AppZoom.validated(percent) == percent)
            assert(AppZoom.next(percent) == AppZoom.levels[min(index + 1, AppZoom.levels.count - 1)])
            assert(AppZoom.previous(percent) == AppZoom.levels[max(index - 1, 0)])
        }
        for invalid in [0, -1, 99, 201, Int.max] {
            assert(AppZoom.validated(invalid) == 100)
        }

        let suite = "XMPBee.ZoomCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Test both intrinsic sheet sizing and a real AppKit text view's transform.
        for percent in [75, 100, 150, 200] {
            defaults.set(percent, forKey: AppZoom.key)
            let native = NSTextView()
            native.string = "Zoom preserves native text selection"
            let host = NSHostingView(rootView:
                NativeText(view: native)
                    .frame(width: 240, height: 80)
                    .appZoom()
                    .defaultAppStorage(defaults)
            )
            let scale = CGFloat(percent) / 100
            let expected = CGSize(width: 240 * scale, height: 80 * scale)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: expected),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame.size = expected
            host.layoutSubtreeIfNeeded()
            assert(abs(host.fittingSize.width - expected.width) < 1)
            assert(abs(host.fittingSize.height - expected.height) < 1)
            let displayed = native.convert(native.bounds, to: host)
            assert(abs(displayed.width - expected.width) < 1)
            assert(native.bounds.height > 0)
            assert(abs(displayed.height - native.bounds.height * scale) < 1)
            assert(UserDefaults(suiteName: suite)!.integer(forKey: AppZoom.key) == percent)
        }
        print("Zoom levels, bounds, persistence, sheet sizing, and native text scaling passed.")
    }
}

private struct NativeText: NSViewRepresentable {
    let view: NSTextView
    func makeNSView(context: Context) -> NSTextView { view }
    func updateNSView(_ nsView: NSTextView, context: Context) {}
}
