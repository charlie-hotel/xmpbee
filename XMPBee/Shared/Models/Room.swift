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

    /// Whether this is a MUC private message (XEP-0045 §7.5) — a 1:1 thread
    /// scoped to a participant inside a MUC room, addressed by `room@service/nick`.
    /// `isMUCPM` Rooms also have `isDM == true` (they share the DM UI shape),
    /// but they route replies to the full occupant JID rather than constructing
    /// a bare JID from the participant nick, and they are NOT persisted into
    /// the saved dmContacts list (room-scoped identity expires when the room
    /// is left).
    var isMUCPM = false

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
