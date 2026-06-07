import Foundation
import SwiftUI

/// A single chat message or system event
struct ChatMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sender: String
    let body: String
    let type: MessageType
    let senderColor: Color

    enum MessageType {
        case chat           // normal message
        case join           // user joined
        case part           // user left
        case quit           // user quit
        case topic          // topic change
        case action         // /me action
        case system         // system/server message
    }

    /// Shared formatter — DateFormatter allocation is expensive; reuse one instance.
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    var timeString: String { ChatMessage.timeFormatter.string(from: timestamp) }

    /// Consistent palette index for a nick — same index maps to paired colours in each palette
    static func nickIndex(_ nick: String) -> Int {
        let hash = nick.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return abs(hash) % 10
    }

    /// Light-mode palette — saturated, readable on white/light backgrounds
    static let lightNickColors: [Color] = [
        Color(red: 0.75, green: 0.22, blue: 0.17),  // dark red
        Color(red: 0.15, green: 0.55, blue: 0.15),  // dark green
        Color(red: 0.17, green: 0.35, blue: 0.70),  // dark blue
        Color(red: 0.65, green: 0.33, blue: 0.68),  // purple
        Color(red: 0.80, green: 0.45, blue: 0.10),  // orange
        Color(red: 0.00, green: 0.55, blue: 0.55),  // teal
        Color(red: 0.60, green: 0.15, blue: 0.45),  // magenta
        Color(red: 0.40, green: 0.50, blue: 0.10),  // olive
        Color(red: 0.20, green: 0.45, blue: 0.60),  // steel blue
        Color(red: 0.70, green: 0.25, blue: 0.40),  // rose
    ]

    /// Dark-mode palette — pastel, readable on dark backgrounds, same hue order as light palette
    static let darkNickColors: [Color] = [
        Color(red: 1.00, green: 0.60, blue: 0.58),  // pastel coral
        Color(red: 0.58, green: 0.93, blue: 0.63),  // pastel mint
        Color(red: 0.60, green: 0.76, blue: 1.00),  // pastel periwinkle
        Color(red: 0.83, green: 0.68, blue: 0.97),  // pastel lavender
        Color(red: 1.00, green: 0.78, blue: 0.55),  // pastel peach
        Color(red: 0.45, green: 0.93, blue: 0.93),  // pastel aqua
        Color(red: 0.97, green: 0.62, blue: 0.83),  // pastel orchid
        Color(red: 0.82, green: 0.93, blue: 0.60),  // pastel sage
        Color(red: 0.63, green: 0.83, blue: 0.97),  // pastel sky blue
        Color(red: 1.00, green: 0.72, blue: 0.76),  // pastel flamingo
    ]

    /// Generate a consistent color from a username (light mode, used when storing senderColor)
    static func colorForNick(_ nick: String) -> Color {
        lightNickColors[nickIndex(nick)]
    }
}
