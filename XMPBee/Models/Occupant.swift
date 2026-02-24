import Foundation

/// Represents a user in a MUC room
struct Occupant: Identifiable, Hashable, Comparable {
    /// Derived from nick — consistent across copies so SwiftUI can diff correctly.
    /// Every occupant in a MUC room has a unique nick, so this is a safe identity key.
    var id: String { nick }
    let nick: String
    let affiliation: Affiliation
    let role: Role

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
