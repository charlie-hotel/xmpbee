import SwiftUI

@main
struct XMPBeeApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("XMPBee", id: "main") {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 650)
        .commands {
            // Replace File → New Window (⌘N) with New DM
            CommandGroup(replacing: .newItem) {
                Button("New Direct Message") {
                    NotificationCenter.default.post(name: .xmpbeeNewDM, object: nil)
                }
                .keyboardShortcut("n")

                Button("Join Room") {
                    NotificationCenter.default.post(name: .xmpbeeJoinRoom, object: nil)
                }
                .keyboardShortcut("j")

                Button("Browse Rooms") {
                    NotificationCenter.default.post(name: .xmpbeeBrowseRooms, object: nil)
                }
                .keyboardShortcut("b")

                Divider()

                Button("Connect to Server") {
                    NotificationCenter.default.post(name: .xmpbeeConnectServer, object: nil)
                }
                .keyboardShortcut("k")
            }

            CommandGroup(after: .sidebar) {
                Button("View Logs") {
                    NotificationCenter.default.post(name: .xmpbeeViewLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.shift, .command])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .xmpbeeSettings, object: nil)
                }
                .keyboardShortcut(",")
            }
        }

        // Log viewer window
        Window("Chat Logs", id: "logs") {
            LogViewerWindow()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 800, height: 600)
        .keyboardShortcut("l", modifiers: [.shift, .command])
    }
}

// MARK: - Command Notifications

extension Notification.Name {
    static let xmpbeeNewDM = Notification.Name("xmpbeeNewDM")
    static let xmpbeeJoinRoom = Notification.Name("xmpbeeJoinRoom")
    static let xmpbeeBrowseRooms = Notification.Name("xmpbeeBrowseRooms")
    static let xmpbeeConnectServer = Notification.Name("xmpbeeConnectServer")
    static let xmpbeeViewLogs = Notification.Name("xmpbeeViewLogs")
    static let xmpbeeSettings = Notification.Name("xmpbeeSettings")
}
