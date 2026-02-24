import Foundation
import SwiftUI

/// Represents an XMPP MUC (Multi-User Chat) room — analogous to an IRC channel
class Room: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    @Published var jid: String          // room@conference.domain
    @Published var name: String         // display name (e.g. "#general")
    @Published var topic: String
    @Published var messages: [ChatMessage] = []
    @Published var occupants: [Occupant] = []
    @Published var unreadCount: Int = 0
    @Published var nickname: String     // our nick in this room

    /// Whether this is a DM (direct message) conversation rather than a MUC room
    var isDM = false

    /// Whether initial presence flood (user list sync) is complete.
    /// Until true, join messages are suppressed and occupant updates are batched.
    var initialPresenceComplete = false
    /// Buffer for occupants during initial presence flood
    var pendingOccupants: [Occupant] = []
    /// Whether the topic has been displayed in chat this session (suppress on reconnect)
    var hasDisplayedTopic = false

    var displayName: String {
        if isDM { return name }
        if name.hasPrefix("#") { return name }
        return "#\(name)"
    }

    init(jid: String, name: String, topic: String = "", nickname: String = "") {
        self.jid = jid
        self.name = name
        self.topic = topic
        self.nickname = nickname
    }

    static func == (lhs: Room, rhs: Room) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
