import SwiftUI

// MARK: - iPadSplitView

/// 2-column NavigationSplitView for iPad / regular horizontal size class, matching
/// the macOS layout exactly:
/// - Sidebar : server/room tree (reuses `RoomListContent`)
/// - Detail  : chat pane + (for non-DM rooms) an always-visible occupant panel,
///             side by side in an `HStack` — like macOS `ContentView`.
struct iPadSplitView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showPreferences = false
    @State private var showLogs = false
    /// Portrait-only: the occupant panel is dropped from the layout, so it's reachable
    /// on demand as a right-side glass drawer (reusing the compact `UsersDrawerContent`).
    @State private var usersOpen = false

    private var canShowUsers: Bool {
        if let room = viewModel.selectedRoom { return !room.isDM }
        return false
    }

    var body: some View {
        GeometryReader { geo in
        let isPortrait = geo.size.height > geo.size.width
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RoomListContent(drawerOpen: .constant(false))
                .navigationTitle("Connections")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
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
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                    }
                }
        } detail: {
            HStack(spacing: 0) {
                ChatPaneView()
                    .frame(minWidth: 350)

                // Portrait: drop the users bar so the chat keeps the screen and the
                // sidebar doesn't have to cover it. Landscape: full width beside the chat.
                if let room = viewModel.selectedRoom, !room.isDM, !isPortrait {
                    Divider()
                    OccupantsPanel(room: room)
                        .frame(minWidth: 150, idealWidth: 200, maxWidth: 260)
                }
            }
            // Portrait-only on-demand occupant drawer (reuses the compact element).
            .overlay {
                if isPortrait, usersOpen, let room = viewModel.selectedRoom, !room.isDM {
                    portraitUsersOverlay(room: room)
                }
            }
            // macOS-style action toolbar in the wide detail nav bar (the sidebar's
            // nav bar is too narrow for this many items). Mirrors the Mac toolbar.
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isPortrait, canShowUsers {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { usersOpen.toggle() }
                        } label: {
                            Label("Room Members", systemImage: "person.2")
                        }
                    }

                    Button { viewModel.showBrowseRooms = true } label: {
                        Label("Browse Rooms", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .disabled(viewModel.servers.isEmpty)

                    Button { viewModel.showUserSearch = true } label: {
                        Label("Search Users", systemImage: "person.text.rectangle")
                    }
                    .disabled(viewModel.servers.isEmpty)

                    Button { showLogs = true } label: {
                        Label("Logs", systemImage: "list.bullet.badge.ellipsis")
                    }

                    Button { showPreferences = true } label: {
                        Label("Preferences", systemImage: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showPreferences) {
            PreferencesScreen()
        }
        .sheet(isPresented: $showLogs) {
            LogViewerScreen()
        }
        .onChange(of: isPortrait) { _, nowPortrait in
            if !nowPortrait { usersOpen = false }
        }
        }
    }

    /// Right-side glass occupant drawer for portrait, reusing the compact
    /// `UsersDrawerContent`. Slides over the chat; tap outside or a row to dismiss.
    @ViewBuilder
    private func portraitUsersOverlay(room: Room) -> some View {
        ZStack(alignment: .trailing) {
            // Near-clear tap-catcher (no dim, so the glass samples the content cleanly).
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { usersOpen = false }
                }

            GlassEffectContainer {
                UsersDrawerContent(room: room, onClose: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { usersOpen = false }
                })
                .frame(width: 320)
                // Concentric corners conform to the device where the pane meets the
                // physical right/bottom edges (same recipe as the iPhone drawer); the
                // top stays tucked below the nav bar, so those corners hold the floor.
                .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .ignoresSafeArea(edges: [.bottom, .trailing])
            .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}
