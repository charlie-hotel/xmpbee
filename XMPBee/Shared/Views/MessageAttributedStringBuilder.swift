import Foundation

/// Cross-platform chat-message rendering.
///
/// This builder is deliberately **platform-neutral**: it imports only Foundation
/// (no AppKit, no UIKit, no SwiftUI). It turns a `ChatMessage` into a
/// `AttributedString` whose runs carry *semantic style intent* via the
/// `MessageStyle` attribute, plus the standard `.link` attribute for clickable
/// URLs.
///
/// Each platform's chat view walks the produced runs and resolves the intent to
/// concrete fonts/colors:
///   • macOS (`ChatView`) converts to `NSAttributedString` with the exact same
///     `NSFont`/`NSColor` choices it used before this extraction, so the macOS
///     appearance is byte-for-byte unchanged.
///   • iOS (future) will resolve the same intents to UIKit/SwiftUI equivalents.
///
/// The nick-hue algorithm and the URL/scheme allowlist live here so both
/// platforms render identically.
enum MessageAttributedStringBuilder {

    // MARK: - Style intent (platform-neutral)

    /// Font role for a run. Concrete point sizes/weights are resolved per platform,
    /// but the role pins the *intent* (which the macOS side maps back to the exact
    /// monospaced `NSFont` it used before).
    enum FontRole: Hashable {
        case mono          // monospaced, regular, 12pt on macOS
        case monoBold      // monospaced, bold, 12pt on macOS
        case monoSmall     // monospaced, regular, 11pt on macOS
    }

    /// Color role for a run, resolved to a concrete color per platform.
    ///   • `primary`   → label / primary text (message body)
    ///   • `secondary` → secondary label (timestamps, join/part/system lines)
    ///   • `tertiary`  → tertiary label (the `<` `>` brackets around a nick)
    ///   • `nick`      → appearance-aware nick color, picked by `index` into the
    ///                   light/dark nick palettes (resolved on each platform so the
    ///                   color tracks light/dark mode dynamically)
    ///   • `link`      → the platform link color (applied alongside the `.link`
    ///                   attribute on detected URLs)
    enum ColorRole: Hashable {
        case primary
        case secondary
        case tertiary
        case nick(index: Int)
        case link
    }

    /// The combined style intent carried on each run.
    /// `Equatable`/`Hashable` are synthesized (both members are `Hashable` enums),
    /// so adding a `FontRole`/`ColorRole` case can't desync a hand-written hash.
    struct Style: Hashable {
        var font: FontRole
        var color: ColorRole
    }

    // MARK: - Link detection (shared)

    /// URL schemes we render as clickable affordances. Everything else stays plain
    /// text. Identical to the original macOS allowlist so behaviour is unchanged.
    ///
    ///   • `http` / `https` — the common case.
    ///   • `mailto` — universal, lands in the user's mail client.
    ///   • `xmpp` (XEP-0147) — click-to-DM, natural for a chat client.
    ///
    /// Excluded (and why): `file://` (could launch apps), `x-apple-systempreferences:`
    /// (settings-pane social-engineering), and any third-party scheme (opaque attack
    /// surface).
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "xmpp"]

    /// True if `url` is in the allowlist of schemes we'll render and dispatch.
    static func isAllowedClickableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }

    /// Shared URL detector.
    private static let urlDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    // MARK: - Nick color algorithm (shared)

    /// Platform-neutral RGB triple in the 0...1 range. Resolved to a concrete color
    /// on each platform.
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Light-mode nick palette — saturated, readable on light backgrounds.
    /// Mirrors `ChatMessage.lightNickColors` (kept in sync; this layer must not
    /// import SwiftUI's `Color`).
    static let lightNickColors: [RGB] = [
        RGB(red: 0.75, green: 0.22, blue: 0.17),  // dark red
        RGB(red: 0.15, green: 0.55, blue: 0.15),  // dark green
        RGB(red: 0.17, green: 0.35, blue: 0.70),  // dark blue
        RGB(red: 0.65, green: 0.33, blue: 0.68),  // purple
        RGB(red: 0.80, green: 0.45, blue: 0.10),  // orange
        RGB(red: 0.00, green: 0.55, blue: 0.55),  // teal
        RGB(red: 0.60, green: 0.15, blue: 0.45),  // magenta
        RGB(red: 0.40, green: 0.50, blue: 0.10),  // olive
        RGB(red: 0.20, green: 0.45, blue: 0.60),  // steel blue
        RGB(red: 0.70, green: 0.25, blue: 0.40),  // rose
    ]

    /// Dark-mode nick palette — pastel, same hue order as the light palette.
    /// Mirrors `ChatMessage.darkNickColors`.
    static let darkNickColors: [RGB] = [
        RGB(red: 1.00, green: 0.60, blue: 0.58),  // pastel coral
        RGB(red: 0.58, green: 0.93, blue: 0.63),  // pastel mint
        RGB(red: 0.60, green: 0.76, blue: 1.00),  // pastel periwinkle
        RGB(red: 0.83, green: 0.68, blue: 0.97),  // pastel lavender
        RGB(red: 1.00, green: 0.78, blue: 0.55),  // pastel peach
        RGB(red: 0.45, green: 0.93, blue: 0.93),  // pastel aqua
        RGB(red: 0.97, green: 0.62, blue: 0.83),  // pastel orchid
        RGB(red: 0.82, green: 0.93, blue: 0.60),  // pastel sage
        RGB(red: 0.63, green: 0.83, blue: 0.97),  // pastel sky blue
        RGB(red: 1.00, green: 0.72, blue: 0.76),  // pastel flamingo
    ]

    /// Consistent palette index for a nick. Same algorithm as
    /// `ChatMessage.nickIndex`.
    static func nickIndex(_ nick: String) -> Int {
        let hash = nick.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return abs(hash) % 10
    }

    // MARK: - Builder

    /// Build the platform-neutral `AttributedString` for one message row.
    ///
    /// The returned string mirrors, run for run, the structure the macOS view
    /// produced before this extraction (timestamp + body forms per message type),
    /// with style intent on `MessageStyle` and `.link`/`.url` set on detected URLs.
    /// Paragraph styling and the trailing newline are applied by the platform side.
    static func attributedString(for message: ChatMessage) -> AttributedString {
        var result = AttributedString()

        // Timestamp: "HH:mm " in mono / secondary.
        result.append(run(message.timeString + " ", .init(font: .mono, color: .secondary)))

        switch message.type {
        case .chat:
            // "<" tertiary
            result.append(run("<", .init(font: .mono, color: .tertiary)))
            // sender bold, nick color by index
            result.append(run(message.sender, .init(font: .monoBold,
                                                     color: .nick(index: nickIndex(message.sender)))))
            // "> " tertiary
            result.append(run("> ", .init(font: .mono, color: .tertiary)))
            // body primary, with links
            var body = run(message.body, .init(font: .mono, color: .primary))
            addLinks(to: &body)
            result.append(body)

        case .action:
            // "* sender body" entirely in nick color, mono, with links
            let text = "* \(message.sender) \(message.body)"
            var action = run(text, .init(font: .mono,
                                         color: .nick(index: nickIndex(message.sender))))
            addLinks(to: &action)
            result.append(action)

        case .join:
            let text = "→ \(message.sender) has joined"
            result.append(run(text, .init(font: .monoSmall, color: .secondary)))

        case .part:
            var text = "← \(message.sender) has left"
            if !message.body.isEmpty { text += " (\(message.body))" }
            result.append(run(text, .init(font: .monoSmall, color: .secondary)))

        case .quit:
            var text = "⇐ \(message.sender) has quit"
            if !message.body.isEmpty { text += " (\(message.body))" }
            result.append(run(text, .init(font: .monoSmall, color: .secondary)))

        case .topic:
            let text = "✦ \(message.sender) changed the topic to: \(message.body)"
            var topic = run(text, .init(font: .monoSmall, color: .secondary))
            addLinks(to: &topic)
            result.append(topic)

        case .system:
            let text = "• \(message.body)"
            result.append(run(text, .init(font: .monoSmall, color: .secondary)))
        }

        return result
    }

    /// Build the platform-neutral `AttributedString` for the expanded topic bar:
    /// the raw topic text in mono / primary with links detected. Mirrors the old
    /// `buildTopicAttributedString`.
    static func topicAttributedString(_ text: String) -> AttributedString {
        // The expanded topic bar renders at the small (11pt) monospaced size on
        // both platforms — encode that intent here so neither side needs a
        // post-hoc font override.
        var result = run(text, .init(font: .monoSmall, color: .primary))
        addLinks(to: &result)
        return result
    }

    // MARK: - Internals

    /// Make a single styled run.
    private static func run(_ string: String, _ style: Style) -> AttributedString {
        var s = AttributedString(string)
        s[MessageStyleKey.self] = style
        return s
    }

    /// Detect allowlisted URLs in `s` and mark them with `.link` (carrying the URL)
    /// plus a `.link` color intent. The `.underlineStyle` and concrete link color
    /// are applied per platform — on macOS the text view's `linkTextAttributes`
    /// already underline + color links, and the original code also stamped the
    /// underline/color directly; we preserve both there.
    private static func addLinks(to s: inout AttributedString) {
        guard let detector = urlDetector else { return }
        let plain = String(s.characters)
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        let matches = detector.matches(in: plain, range: nsRange)
        for match in matches {
            guard let url = match.url, isAllowedClickableURL(url) else { continue }
            guard let swiftRange = Range(match.range, in: plain),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: s),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: s)
            else { continue }
            let attrRange = lower..<upper
            s[attrRange].link = url
            // Tag the link run so the platform side can apply its link color.
            var existing = s[attrRange].messageStyle ?? Style(font: .mono, color: .link)
            existing.color = .link
            s[attrRange][MessageStyleKey.self] = existing
        }
    }
}

// MARK: - Custom AttributedString attribute (platform-neutral)

/// Custom attribute key carrying the platform-neutral `Style` intent on each run.
enum MessageStyleKey: AttributedStringKey {
    typealias Value = MessageAttributedStringBuilder.Style
    static let name = "xmpbee.messageStyle"
}

extension AttributeScopes {
    /// Scope exposing the XMPBee message-style attribute alongside Foundation's.
    struct XMPBeeAttributes: AttributeScope {
        let messageStyle: MessageStyleKey
        let foundation: FoundationAttributes
    }
    var xmpbee: XMPBeeAttributes.Type { XMPBeeAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.XMPBeeAttributes, T>
    ) -> T {
        self[T.self]
    }
}
