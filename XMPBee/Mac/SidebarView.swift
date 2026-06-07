import SwiftUI

/// Left sidebar showing server/channel tree — Liquid Glass design
struct SidebarView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        List(selection: Binding<Room.ID?>(
            get: { viewModel.selectedRoom?.id },
            set: { newID in
                guard let id = newID else { return }
                for server in viewModel.servers {
                    if let room = server.rooms.first(where: { $0.id == id }) {
                        viewModel.selectRoom(room, on: server)
                        return
                    }
                }
            }
        )) {
            ForEach(viewModel.servers) { server in
                ServerSection(server: server, viewModel: viewModel)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Channels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Connection...") {
                        viewModel.editingServer = nil
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
            }
        }
    }
}

struct ServerSection: View {
    @ObservedObject var server: Server
    @ObservedObject var viewModel: ChatViewModel
    @State private var joinRoomName = ""
    @State private var dmNickname = ""
    @State private var isHoveringReconnect = false

    var body: some View {
        Section(isExpanded: Binding(
            get: { server.isExpanded },
            set: { server.isExpanded = $0 }
        )) {
            ForEach(server.rooms) { room in
                ChannelRow(room: room)
                .tag(room.id)
                .contextMenu {
                    Button(room.isDM ? "Close DM" : "Leave Room", role: .destructive) {
                        viewModel.leaveRoom(room, on: server)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.leaveRoom(room, on: server)
                    } label: {
                        Label("Leave", systemImage: "xmark.circle")
                    }
                }
            }
        } header: {
            Button(action: {}) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.isConnected ? Theme.connectedDot : Theme.disconnectedDot)
                        .frame(width: 7, height: 7)

                    Text(server.name)
                        .font(.system(size: 13))
                        .fontWeight(.semibold)

                    if !server.isConnected {
                        Button(action: {
                            viewModel.manualReconnect(server: server)
                        }) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .padding(3)
                                .background(
                                    Circle()
                                        .fill(Color.primary.opacity(isHoveringReconnect ? 0.1 : 0))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Reconnect")
                        .onHover { hovering in
                            isHoveringReconnect = hovering
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            .contextMenu {
                if server.isConnected {
                    Button("Disconnect") {
                        viewModel.disconnect(server: server)
                    }
                }
                Button("Edit Account…") {
                    viewModel.editingServer = server
                    viewModel.showConnectSheet = true
                }
            }
        }
    }
}

// MARK: - Popovers

struct JoinRoomPopover: View {
    @Binding var roomName: String
    var onJoin: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join Room")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the name of the room you want to join:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Room name", text: $roomName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(onJoin)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    roomName = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Join") {
                    onJoin()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct NewDMPopover: View {
    @Binding var nickname: String
    var onOpen: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Direct Message")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the nickname of the person you want to message:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(onOpen)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    nickname = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open") {
                    onOpen()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Plain row content. Selection (highlight + selected-text color) is owned entirely
/// by the enclosing `List(selection:)` — do NOT wrap this in a Button or apply a custom
/// selected color: a Button steals key-focus from the list (flipping the native accent
/// highlight to gray / nothing), and a hand-rolled color fights the system's automatic
/// selected-text vibrancy. The list handles the click via its `selection` binding.
struct ChannelRow: View {
    // @ObservedObject (not `let`): the row must re-render on its own when the room's
    // @Published `unreadCount` / `name` change. Without it, since the row's only input is
    // the unchanged `room` reference, SwiftUI's view-equality optimization skips
    // re-rendering it on a parent update, so the unread badge never appears.
    @ObservedObject var room: Room

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: room.isDM ? "person" : "number")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(room.isDM ? .orange : .secondary)

            Text(room.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular.tint(.accentColor), in: .capsule)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Room Browser

struct RoomBrowserPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    let server: Server
    @Binding var filter: String
    @Binding var isPresented: Bool

    private var filteredRooms: [(jid: String, name: String)] {
        if filter.isEmpty { return viewModel.discoveredRooms }
        return viewModel.discoveredRooms.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.jid.localizedCaseInsensitiveContains(filter)
        }
    }

    private var joinedJIDs: Set<String> {
        Set(server.rooms.map(\.jid))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browse Rooms")
                .font(.headline)

            TextField("Filter...", text: $filter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if viewModel.isLoadingRooms {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if filteredRooms.isEmpty {
                Text("No rooms found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredRooms, id: \.jid) { room in
                            let alreadyJoined = joinedJIDs.contains(room.jid)
                            HStack(spacing: 6) {
                                Image(systemName: "number")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(room.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                if alreadyJoined {
                                    Text("joined")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("Join") {
                                        let name = room.jid.components(separatedBy: "@").first ?? room.name
                                        viewModel.joinNewRoom(name: name, on: server)
                                    }
                                    .font(.system(size: 11))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                Text("\(filteredRooms.count) room\(filteredRooms.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh") {
                    viewModel.browseRooms(on: server)
                }
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340, height: 500)
        .onAppear {
            viewModel.browseRooms(on: server)
        }
    }
}

// MARK: - User Search

/// XEP-0055 user-directory search popover.  Mirrors the room browser in shape but
/// goes through the server's directory/user component rather than the MUC conference.
struct UserSearchPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    let server: Server
    @Binding var query: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Users")
                .font(.headline)

            HStack {
                TextField("Search by nick…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(runSearch)
                Button("Search", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if viewModel.isSearchingUsers {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error = viewModel.userSearchError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.vertical, 6)
            } else if viewModel.discoveredUsers.isEmpty {
                Text(query.isEmpty ? "Type a nickname or name and press Search."
                                   : "No matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.discoveredUsers, id: \.jid) { user in
                            HStack(spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.name.isEmpty
                                         ? (user.nick.isEmpty ? user.jid : user.nick)
                                         : user.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Text(user.jid)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("DM") {
                                    // Pick the nick if provided; otherwise fall back to the
                                    // JID local-part.  openDM constructs the DM target from
                                    // this — see findOrCreateDMRoom.
                                    let target = !user.nick.isEmpty
                                        ? user.nick
                                        : (user.jid.components(separatedBy: "@").first ?? user.jid)
                                    viewModel.openDM(nick: target, on: server)
                                    isPresented = false
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                Text("\(viewModel.discoveredUsers.count) result\(viewModel.discoveredUsers.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 340, height: 500)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.searchUsers(query: trimmed, on: server)
    }
}

