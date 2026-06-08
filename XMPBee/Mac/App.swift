import SwiftUI

#if canImport(Sparkle)
import Sparkle
import Combine
#endif

@main
struct XMPBeeApp: App {
    @Environment(\.openWindow) private var openWindow

    #if canImport(Sparkle)
    // Sparkle auto-updater — only present in the Developer ID (GitHub) build, which
    // links Sparkle. The Mac App Store target doesn't link it, so canImport is false.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var body: some Scene {
        Window("XMPBee", id: "main") {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 650)
        .commands {
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif

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

#if canImport(Sparkle)
// MARK: - Check for Updates menu item

/// Tracks the updater's `canCheckForUpdates` so the menu item disables itself while
/// a check is already in flight. (Sparkle's recommended SwiftUI pattern.)
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif

// MARK: - Command Notifications

extension Notification.Name {
    static let xmpbeeNewDM = Notification.Name("xmpbeeNewDM")
    static let xmpbeeJoinRoom = Notification.Name("xmpbeeJoinRoom")
    static let xmpbeeBrowseRooms = Notification.Name("xmpbeeBrowseRooms")
    static let xmpbeeConnectServer = Notification.Name("xmpbeeConnectServer")
    static let xmpbeeViewLogs = Notification.Name("xmpbeeViewLogs")
    static let xmpbeeSettings = Notification.Name("xmpbeeSettings")
}
