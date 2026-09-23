import SwiftUI

enum AppZoom {
    static let key = "interfaceZoomPercent"
    static let levels = [75, 90, 100, 110, 125, 150, 175, 200]

    static func validated(_ percent: Int) -> Int {
        levels.contains(percent) ? percent : 100
    }

    static func next(_ percent: Int) -> Int {
        levels.first { $0 > validated(percent) } ?? levels.last!
    }

    static func previous(_ percent: Int) -> Int {
        levels.last { $0 < validated(percent) } ?? levels.first!
    }
}

struct AppZoomCommands: Commands {
    @AppStorage(AppZoom.key) private var storedPercent = 100
    private var percent: Int { AppZoom.validated(storedPercent) }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Zoom In") { storedPercent = AppZoom.next(percent) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(percent == AppZoom.levels.last)
            // Also accept Command-= without requiring Shift on US keyboards.
            Button("Zoom In") { storedPercent = AppZoom.next(percent) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(percent == AppZoom.levels.last)
                .hidden()
            Button("Zoom Out") { storedPercent = AppZoom.previous(percent) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(percent == AppZoom.levels.first)
            Button("Actual Size") { storedPercent = 100 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(percent == 100)
            Divider()
        }
    }
}

private struct AppZoomModifier: ViewModifier {
    @AppStorage(AppZoom.key) private var percent = 100

    func body(content: Content) -> some View {
        let scale = CGFloat(AppZoom.validated(percent)) / 100
        ZoomLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// Give content its unscaled space, then report its actual displayed size.
/// A scaleEffect alone would overlap or clip adjacent controls and sheet edges.
struct ZoomLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(
            width: proposal.width.map { $0 / scale },
            height: proposal.height.map { $0 / scale }
        ))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(
            width: bounds.width / scale, height: bounds.height / scale
        ))
    }
}

extension View {
    func appZoom() -> some View { modifier(AppZoomModifier()) }
}
