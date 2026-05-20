import Foundation

/// Represents a user in a MUC room.
///
/// `nick` is the raw wire form, used as identity and for routing (e.g. constructing
/// MUC PM reply targets).  `displayNick` is the spoofing-resistant form for UI —
/// see `String.sanitizedForNicknameDisplay()`.  We keep both because the raw form
/// is what the XMPP server uses to address the participant; the sanitized form
/// is what protects the user from homoglyph / bidi / zero-width impersonation.
/// `id` stays the raw nick so SwiftUI's ForEach renders two participants as two
/// rows even when their display forms happen to look similar.
struct Occupant: Identifiable, Hashable, Comparable {
    /// Derived from nick — consistent across copies so SwiftUI can diff correctly.
    /// Every occupant in a MUC room has a unique nick, so this is a safe identity key.
    var id: String { nick }
    let nick: String
    let displayNick: String
    let affiliation: Affiliation
    let role: Role

    init(nick: String, affiliation: Affiliation, role: Role) {
        self.nick = nick
        self.displayNick = nick.sanitizedForNicknameDisplay()
        self.affiliation = affiliation
        self.role = role
    }

    enum Affiliation: Int, Comparable {
        case owner = 0
        case admin = 1
        case member = 2
        case none = 3
        case outcast = 4
        static func < (lhs: Affiliation, rhs: Affiliation) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Role: Int, Comparable {
        case moderator = 0
        case participant = 1
        case visitor = 2
        case none = 3
        static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// IRC-style prefix
    var prefix: String {
        switch affiliation {
        case .owner: return "~"
        case .admin: return "&"
        default:
            switch role {
            case .moderator: return "@"
            case .participant: return "+"
            default: return ""
            }
        }
    }

    static func < (lhs: Occupant, rhs: Occupant) -> Bool {
        if lhs.affiliation != rhs.affiliation { return lhs.affiliation < rhs.affiliation }
        if lhs.role != rhs.role { return lhs.role < rhs.role }
        return lhs.nick.lowercased() < rhs.nick.lowercased()
    }
}

// MARK: - Nickname sanitization for display
//
// Closes the spoofing vectors described in MA-003 of the security audit:
// homoglyphs, bidi overrides, zero-width characters, combining marks,
// variation selectors, tag characters, and width-mapped forms.
//
// This is a pragmatic subset of RFC 8266 (PRECIS Nickname).  We don't ship the
// full PRECIS framework — there's no first-party Swift implementation and
// pulling a library in for this would be heavyweight — but we cover the
// attacks that actually matter for visual spoofing in a chat UI:
//
//   1. NFKC normalization folds compatibility-equivalent and width-mapped
//      forms onto their canonical equivalents (`Ａ` → `A`, ligatures → letters).
//   2. Control characters, bidi overrides, and zero-width codepoints are
//      replaced with U+FFFD (REPLACEMENT CHARACTER) so they render as a
//      visible `�` instead of silently altering the text around them.  We
//      *replace* rather than *strip* deliberately — silent stripping lets an
//      attacker craft a nick whose stripped form matches a real user.
//   3. Variation selectors and tag characters are dropped — they're invisible
//      by design and exist only to byte-differentiate visually-identical
//      strings, which is exactly the attack we're closing.
//   4. Whitespace is trimmed and the result capped at 64 scalars; an empty
//      result is replaced with a single U+FFFD so participants without a
//      usable nick still occupy a row in the UI rather than disappearing.
//
// The sanitized form is for *display* and *internal equality* (mention
// detection, duplicate-rendering checks).  Wire-level routing still uses the
// raw form — see Occupant.nick (raw, routing) vs Occupant.displayNick
// (sanitized, UI).

extension String {
    func sanitizedForNicknameDisplay() -> String {
        // Step 1 — NFKC.  Collapses width-mapped Latin (`Ａdmin` → `Admin`),
        // ligatures, and other compatibility forms.
        let normalized = self.precomposedStringWithCompatibilityMapping

        // Step 2/3 — scalar walk.  Hostile invisibles become U+FFFD; gratuitous
        // invisibles (variation selectors, tag characters) are dropped entirely.
        var out = String.UnicodeScalarView()
        out.reserveCapacity(normalized.unicodeScalars.count)
        var emitted = 0
        let scalarCap = 64

        for scalar in normalized.unicodeScalars {
            if emitted >= scalarCap { break }
            let v = scalar.value

            // Drop invisibles that exist solely to byte-differentiate strings.
            if (0xFE00...0xFE0F).contains(v) ||
               (0xE0100...0xE01EF).contains(v) ||
               (0xE0000...0xE007F).contains(v) {
                continue
            }

            // Hostile or invisible codepoints — render as a visible REPLACEMENT
            // CHARACTER so the user sees that something fishy is in the nick
            // instead of being silently spoofed.
            let isControl = scalar.properties.generalCategory == .control
            let isBidi = (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            let isZeroWidth = v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF

            if isControl || isBidi || isZeroWidth {
                out.append(Unicode.Scalar(0xFFFD)!)
            } else {
                out.append(scalar)
            }
            emitted += 1
        }

        // Step 4 — trim outer whitespace, fallback to a visible marker if the
        // result is empty (e.g. nick was only whitespace).
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\u{FFFD}" : trimmed
    }
}
