import SwiftUI

/// Root view — three-column NavigationSplitView with Liquid Glass
struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var showPreferences = false
    @State private var browseFilter = ""
    @State private var joinRoomName = ""
    @State private var dmNickname = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            // Left column: server/channel tree
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 280)
        } detail: {
            // Main content: chat + user list side by side
            HStack(spacing: 0) {
                ChatView(viewModel: viewModel)
                    .frame(minWidth: 400)

                if viewModel.selectedRoom?.isDM != true {
                    Divider()

                    // Right panel: user list
                    UserListView(viewModel: viewModel)
                        .frame(minWidth: 130, idealWidth: 170, maxWidth: 230)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button("New Connection...") {
                        viewModel.showConnectSheet = true
                    }

                    Divider()

                    Button("Join Room...") {
                        viewModel.showJoinRoom = true
                    }
                    .disabled(viewModel.servers.isEmpty)

                    Button("New DM...") {
                        viewModel.showNewDM = true
                    }
                    .disabled(viewModel.servers.isEmpty)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New Connection, Room, or DM")

                Button(action: {
                    browseFilter = ""
                    viewModel.showBrowseRooms = true
                }) {
                    Label("Browse Rooms", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Browse Rooms")
                .disabled(viewModel.servers.isEmpty)
                .popover(isPresented: $viewModel.showBrowseRooms) {
                    if let server = viewModel.selectedServer ?? viewModel.servers.first {
                        RoomBrowserPopover(
                            viewModel: viewModel,
                            server: server,
                            filter: $browseFilter,
                            isPresented: $viewModel.showBrowseRooms
                        )
                    }
                }

                Button(action: { openWindow(id: "logs") }) {
                    Label("Chat Logs", systemImage: "list.bullet.badge.ellipsis")
                }
                .help("View Chat Logs")

                Button(action: { showPreferences = true }) {
                    Label("Preferences", systemImage: "gearshape")
                }
                .help("Notification Preferences")
            }
        }
        .sheet(isPresented: $viewModel.showConnectSheet) {
            ConnectSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showPreferences) {
            PreferencesView(notifications: viewModel.notifications)
        }
        .sheet(isPresented: $viewModel.showJoinRoom) {
            if let server = viewModel.selectedServer ?? viewModel.servers.first {
                JoinRoomPopover(roomName: $joinRoomName, onJoin: {
                    guard !joinRoomName.isEmpty else { return }
                    viewModel.joinNewRoom(name: joinRoomName, on: server)
                    joinRoomName = ""
                    viewModel.showJoinRoom = false
                }, onCancel: {
                    viewModel.showJoinRoom = false
                })
            }
        }
        .sheet(isPresented: $viewModel.showNewDM) {
            // Only need a server — openDM derives everything from server domain, no room required
            if let server = viewModel.selectedServer ?? viewModel.servers.first {
                NewDMPopover(nickname: $dmNickname, onOpen: {
                    guard !dmNickname.isEmpty else { return }
                    viewModel.openDM(nick: dmNickname, on: server)
                    dmNickname = ""
                    viewModel.showNewDM = false
                }, onCancel: {
                    viewModel.showNewDM = false
                })
            }
        }
        .alert("Connection Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeNewDM)) { _ in
            guard !viewModel.servers.isEmpty else { return }
            viewModel.showNewDM = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeJoinRoom)) { _ in
            guard !viewModel.servers.isEmpty else { return }
            viewModel.showJoinRoom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeBrowseRooms)) { _ in
            guard !viewModel.servers.isEmpty else { return }
            browseFilter = ""
            viewModel.showBrowseRooms = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeConnectServer)) { _ in
            viewModel.showConnectSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeViewLogs)) { _ in
            openWindow(id: "logs")
        }
        .onReceive(NotificationCenter.default.publisher(for: .xmpbeeSettings)) { _ in
            showPreferences = true
        }
        .onAppear {
            if viewModel.servers.isEmpty {
                viewModel.loadAndReconnect()
                if viewModel.servers.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.showConnectSheet = true
                    }
                }
            }
        }
    }
}
