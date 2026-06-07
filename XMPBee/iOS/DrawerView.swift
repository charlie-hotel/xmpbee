import SwiftUI

// MARK: - DrawerView

/// Left-side navigation drawer for iPhone; also reused as the sidebar column in
/// `iPadSplitView`. Shows the server/room tree, mirroring the macOS `SidebarView`
/// / `ServerSection` / `ChannelRow` structure.
/// iPhone glass drawer. Rendered as a transparent `ScrollView`/`VStack` (NOT a
/// `List` or `NavigationStack` — those paint an opaque system background that hides
/// the Liquid Glass applied by the parent shell). The parent (`iPhoneDrawerShell`)
/// wraps this in a `GlassEffectContainer` + `.glassEffect`, so everything here must
/// stay background-transparent for the glass to show through.
struct DrawerView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var drawerOpen: Bool

    @State private var showLogs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            RoomListContent(drawerOpen: $drawerOpen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showLogs) { LogViewerScreen() }
    }

    // Custom header row (replaces the opaque nav bar): "Connections" · + menu.
    // (Preferences lives in the main nav bar, not here.)
    private var header: some View {
        HStack(spacing: 12) {
            Text("Connections").font(.title3).fontWeight(.bold)
            Spacer()

            Menu {
                Button {
                    viewModel.editingServer = nil
                    viewModel.showConnectSheet = true
                } label: { Label("New Connection…", systemImage: "plus.circle") }

                Divider()

                Button { viewModel.showJoinRoom = true } label: { Label("Join Room…", systemImage: "number") }
                    .disabled(viewModel.servers.isEmpty)
                Button { viewModel.showNewDM = true } label: { Label("New DM…", systemImage: "person") }
                    .disabled(viewModel.servers.isEmpty)
                Button { viewModel.showBrowseRooms = true } label: { Label("Browse Rooms…", systemImage: "bubble.left.and.text.bubble.right") }
                    .disabled(viewModel.servers.isEmpty)
                Button { viewModel.showUserSearch = true } label: { Label("Search Users…", systemImage: "person.text.rectangle") }
                    .disabled(viewModel.servers.isEmpty)

                Divider()

                Button { showLogs = true } label: { Label("View Logs", systemImage: "list.bullet.badge.ellipsis") }
            } label: {
                Image(systemName: "plus").font(.system(size: 17))
            }
            .accessibilityLabel("Add")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

}

// MARK: - ServerRows (native List rows for the iPhone glass drawer)

/// One server's rows for the connections `List`: a tappable header (expand/collapse)
/// plus its channel rows when expanded. Emitted as a `Section` so the `List` treats
/// them as individual rows — required for native per-row `.swipeActions`. Everything
/// is transparent with hidden separators so the drawer's Liquid Glass shows through.
private struct ServerRows: View {
    @ObservedObject var server: Server
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var drawerOpen: Bool

    var body: some View {
        Section {
            // Header row — tap expands/collapses; swipe reveals Disconnect / Edit.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { server.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.isConnected ? Theme.connectedDot : Theme.disconnectedDot)
                        .frame(width: 7, height: 7)
                    Text(server.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !server.isConnected {
                        Button { viewModel.manualReconnect(server: server) } label: {
                            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reconnect \(server.name)")
                    }
                    Spacer()
                    Image(systemName: server.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if server.isConnected {
                    Button {
                        viewModel.disconnect(server: server)
                    } label: { Label("Disconnect", systemImage: "bolt.slash") }
                    .tint(.orange)
                }
                Button {
                    viewModel.editingServer = server
                    viewModel.showConnectSheet = true
                } label: { Label("Edit", systemImage: "pencil") }
                .tint(.blue)
            }

            if server.isExpanded {
                ForEach(server.rooms) { room in
                    GlassChannelRow(room: room,
                                    isSelected: viewModel.selectedRoom?.id == room.id,
                                    isBlocked: room.isDM && server.isBlocked(jid: room.jid)) {
                        viewModel.selectRoom(room, on: server)
                        withAnimation(.easeInOut(duration: 0.25)) { drawerOpen = false }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.leaveRoom(room, on: server)
                        } label: {
                            Label(room.isDM ? "Close" : "Leave", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if room.isDM {
                            if server.isBlocked(jid: room.jid) {
                                Button {
                                    viewModel.unblockJID(room.jid, on: server)
                                } label: {
                                    Label("Unblock", systemImage: "person.fill.checkmark")
                                }
                                .tint(.blue)
                            } else {
                                Button(role: .destructive) {
                                    viewModel.blockJID(room.jid, on: server)
                                } label: {
                                    Label("Block", systemImage: "person.slash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Single room/DM row for the glass drawer. Transparent background with a
/// translucent selection highlight (so it reads over glass).
private struct GlassChannelRow: View {
    let room: Room
    let isSelected: Bool
    var isBlocked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: room.isDM ? (isBlocked ? "person.slash" : "person") : "number")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(room.isDM ? .orange : .secondary)
                    .frame(width: 20)
                Text(room.name)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Theme.selectedChannelText : Theme.channelText)
                    .strikethrough(isBlocked, color: .secondary)
                    .lineLimit(1)
                Spacer()
                if room.unreadCount > 0 {
                    Text("\(room.unreadCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

// MARK: - RoomListContent

/// The server/room list body, factored out so both `DrawerView` (iPhone) and
/// `iPadSplitView` (iPad sidebar column) can embed it without duplication.
struct RoomListContent: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var drawerOpen: Bool

    var body: some View {
        List {
            if viewModel.servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "network.slash",
                    description: Text("Tap + to add a connection.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.servers) { server in
                    ServerRows(server: server, drawerOpen: $drawerOpen)
                }
            }
        }
        // Shared by the iPhone glass drawer and the iPad sidebar column. `.plain`
        // (not `.sidebar`) + transparent rows so it reads cleanly in both, and the
        // server header is a real row so native swipe-actions work on it.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 0)
    }
}

