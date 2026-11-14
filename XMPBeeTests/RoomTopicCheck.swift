// Run independently of Xcode's test runner:
// xcrun swiftc XMPBee/Shared/Models/{Room,ChatMessage,Occupant,Nickname}.swift XMPBeeTests/RoomTopicCheck.swift -o /tmp/xmpbee-topic-check
// /tmp/xmpbee-topic-check
import Foundation

@main
struct RoomTopicCheck {
    static func main() {
        let room = Room(jid: "beehive@conference.example.com", name: "beehive")
        assert(!room.hasTopicUpdate(since: "Previous visit"))
        room.updateTopic("")
        assert(room.messages.isEmpty && !room.hasDisplayedTopic)

        room.updateTopic("Beehive is OFFLINE.")
        assert(room.hasDisplayedTopic && room.messages.count == 1)
        assert(room.messages.last?.body == room.topic)

        assert(!room.hasTopicUpdate(since: nil))
        assert(!room.hasTopicUpdate(since: room.topic))
        assert(room.hasTopicUpdate(since: "Previous visit"))

        // Rejoining with the same topic must not add another entry.
        room.updateTopic("Beehive is OFFLINE.")
        assert(room.messages.count == 1)

        // Live changes and changed topics on reconnect use the same receive path.
        room.updateTopic("Beehive is ONLINE.")
        assert(room.topic == "Beehive is ONLINE.")
        assert(room.messages.count == 2 && room.messages.last?.body == room.topic)
        assert(room.messages.last?.type == .topic)
        room.updateTopic("Beehive is ONLINE.")
        assert(room.messages.count == 2)

        room.updateTopic("")
        assert(room.topic.isEmpty && room.messages.count == 3)
        assert(room.hasTopicUpdate(since: "Beehive is ONLINE."))
        assert(!room.hasTopicUpdate(since: ""))
        assert(room.messages.last?.type == .system && room.messages.last?.body == "Topic cleared.")
        room.updateTopic("")
        assert(room.messages.count == 3)
        room.updateTopic("Beehive is OFFLINE.")
        assert(room.messages.count == 4 && room.messages.last?.body == room.topic)

        let cleared = Room(jid: "cleared@conference.example.com", name: "cleared")
        assert(!cleared.hasTopicUpdate(since: "Old topic"))
        cleared.updateTopic("")
        assert(cleared.hasTopicUpdate(since: "Old topic"))

        // A prefilled topic still needs its first transcript entry.
        let prefilled = Room(jid: "other@conference.example.com", name: "other", topic: "Welcome")
        prefilled.updateTopic("Welcome")
        assert(prefilled.messages.count == 1 && prefilled.hasDisplayedTopic)

        // Scrollback cap: the transcript is a sliding window — appending past
        // Room.messageCap drops the oldest block down to Room.messageFloor, so
        // long-lived rooms can't grow unbounded (the ~550 MB / 2-day leak).
        let busy = Room(jid: "busy@conference.example.com", name: "busy")
        func flood(_ room: Room, from: Int, to: Int) {
            for i in from...to {
                room.addMessage(ChatMessage(
                    timestamp: Date(), sender: "n\(i)", body: "msg \(i)",
                    type: .chat, senderColor: .gray
                ))
            }
        }
        flood(busy, from: 0, to: Room.messageCap - 2)
        assert(busy.messages.count == Room.messageCap - 1)          // below cap: no trim
        flood(busy, from: Room.messageCap - 1, to: Room.messageCap + 1)
        // The 2001st append trips the cap and trims to floor; the 2002nd sits on top.
        assert(busy.messages.count == Room.messageFloor + 1)
        assert(busy.messages.first?.body == "msg \(Room.messageCap + 1 - Room.messageFloor)")
        assert(busy.messages.last?.body == "msg \(Room.messageCap + 1)")
        // Steady state: count stays pinned between floor and cap forever.
        flood(busy, from: 0, to: Room.messageCap * 2)
        assert(busy.messages.count >= Room.messageFloor && busy.messages.count <= Room.messageCap)
        assert(busy.messages.last?.body == "msg \(Room.messageCap * 2)")
        // Topic lines go through the same window.
        busy.updateTopic("still bounded")
        assert(busy.messages.count <= Room.messageCap)

        print("Topic changes, unchanged repeats, clearing, initial display, and scrollback cap passed.")
    }
}
