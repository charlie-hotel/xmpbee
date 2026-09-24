import Foundation
import SwiftUI

/// Represents an XMPP MUC (Multi-User Chat) room — analogous to an IRC channel
class Room: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    @Published var jid: String          // room@conference.domain
    @Published var name: String         // display name (e.g. "#general")
    @Published private(set) var hasReceivedTopic = false
    @Published var topic: String
    @Published var messages: [ChatMessage] = []
    @Published var occupants: [Occupant] = []
    @Published var unreadCount: Int = 0
    /// A live MOTD/topic change arrived while this channel wasn't the selected one.
    /// Surfaced as a "MOTD" badge in the sidebar; cleared when the channel is opened.
    @Published var motdUpdated = false
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
    /// Whether a topic has been displayed in chat this session (for initial scrolling).
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

    /// Keep the current topic and transcript in sync, suppressing unchanged repeats on rejoin.
    func updateTopic(_ subject: String) {
        let changed = topic != subject
        topic = subject
        hasReceivedTopic = true
        guard changed || (!hasDisplayedTopic && !subject.isEmpty) else { return }

        messages.append(ChatMessage(
            timestamp: Date(), sender: "", body: subject.isEmpty ? "Topic cleared." : subject,
            type: subject.isEmpty ? .system : .topic, senderColor: .gray
        ))
        hasDisplayedTopic = true
    }

    /// Initial room sync must finish before comparing with the last message read.
    func hasTopicUpdate(since lastReadTopic: String?) -> Bool {
        hasReceivedTopic && lastReadTopic != nil && topic != lastReadTopic
    }

    static func == (lhs: Room, rhs: Room) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
