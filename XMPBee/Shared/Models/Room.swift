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

    /// In-memory transcript ceiling. Without it, every chat line AND every
    /// join/part presence row (hidden by default but still stored, so the
    /// hide-join/part toggle can reveal them) accumulates for the life of the
    /// process — a 2-day uptime on busy MUCs reached ~550 MB this way.
    /// Older lines are never lost to the user: LogManager writes every message
    /// to disk and the log viewer reads history back on demand.
    ///
    /// Trimming uses hysteresis (cap → floor) on purpose. A one-for-one trim
    /// would keep `messages.count` pinned at the cap, which breaks the macOS
    /// transcript's incremental-append diff (`current > renderedCount` never
    /// fires) and would force a full text-storage rebuild on *every* message.
    /// With a 500-line slack, only the rare trim step pays the rebuild.
    static let messageCap = 2_000
    static let messageFloor = 1_500

    /// Append a transcript line, dropping the oldest block once the room is
    /// over `messageCap`. All runtime transcript writes MUST go through here.
    func addMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.messageCap {
            messages.removeFirst(messages.count - Self.messageFloor)
        }
    }

    /// Keep the current topic and transcript in sync, suppressing unchanged repeats on rejoin.
    func updateTopic(_ subject: String) {
        let changed = topic != subject
        topic = subject
        hasReceivedTopic = true
        guard changed || (!hasDisplayedTopic && !subject.isEmpty) else { return }

        addMessage(ChatMessage(
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
