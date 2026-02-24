import SwiftUI

/// Color theme — adapted for Liquid Glass on macOS 26 Tahoe.
/// With glass, backgrounds become transparent/translucent so the desktop
/// shows through. Text colors use .primary/.secondary for automatic
/// adaptation to light/dark mode and glass blending.
enum Theme {
    // Main backgrounds — mostly clear to let glass shine through
    static let chatBackground = Color.clear
    static let sidebarBackground = Color.clear
    static let inputBackground = Color.clear
    static let topBarBackground = Color.clear
    static let divider = Color(nsColor: .separatorColor)

    // Text colors — use semantic colors for glass readability
    static let chatText = Color.primary
    static let systemText = Color.secondary
    static let timestampText = Color.secondary.opacity(0.7)
    static let bracketText = Color.secondary
    static let topicText = Color.primary.opacity(0.7)
    static let channelText = Color.primary
    static let userText = Color.primary.opacity(0.85)

    // Selection / active
    static let selectedChannel = Color.accentColor.opacity(0.18)
    static let selectedChannelText = Color.accentColor
    static let hoverBackground = Color.primary.opacity(0.05)

    // Status indicators
    static let connectedDot = Color.green
    static let disconnectedDot = Color.red

    // The monospace font used throughout (IRC aesthetic)
    static let monoFont = Font.system(size: 12.5, design: .monospaced)
    static let monoFontSmall = Font.system(size: 11.5, design: .monospaced)
    static let monoFontBold = Font.system(size: 12.5, weight: .bold, design: .monospaced)
    static let sidebarFont = Font.system(size: 12, design: .monospaced)
    static let headerFont = Font.system(size: 12, weight: .medium, design: .monospaced)
}
