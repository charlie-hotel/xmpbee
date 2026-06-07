import SwiftUI

// MARK: - Root

/// Size-class-adaptive root for iOS.
/// - Regular (iPad): delegates to `iPadSplitView`.
/// - Compact (iPhone): chat pane as base layer with a left-edge drawer overlay.
struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadSplitView()
            } else {
                iPhoneDrawerShell()
            }
        }
        // Action sheets — bound to existing ChatViewModel @Published flags.
        .sheet(isPresented: $viewModel.showConnectSheet) {
            ConnectScreen()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showJoinRoom) {
            JoinRoomScreen()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showNewDM) {
            NewDMScreen()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showBrowseRooms) {
            BrowseRoomsScreen()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showUserSearch) {
            UserSearchScreen()
                .environmentObject(viewModel)
        }
        .onAppear {
            if viewModel.servers.isEmpty {
                viewModel.loadAndReconnect()
                if viewModel.servers.isEmpty {
                    // Mirror macOS first-launch behavior: open connect sheet after
                    // a short delay so the view hierarchy has settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.editingServer = nil
                        viewModel.showConnectSheet = true
                    }
                }
            }
        }
    }
}

// MARK: - iPhone drawer shell

private struct iPhoneDrawerShell: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var drawerOpen: Bool = false
    /// Live finger-tracking translation while dragging the channels drawer open.
    @State private var dragTranslation: CGFloat = 0
    /// Right-side users drawer (mirror of the channels drawer).
    @State private var usersOpen: Bool = false
    @State private var usersDragTranslation: CGFloat = 0
    @State private var showPreferences: Bool = false
    /// Width of the drawer overlay (≈80 % of screen width, capped).
    private let drawerFraction: CGFloat = 0.82
    private var drawerAnimation: Animation { .spring(response: 0.35, dampingFraction: 0.86) }

    /// The users drawer is only meaningful for a selected non-DM (MUC) room.
    private var canShowUsers: Bool {
        if let room = viewModel.selectedRoom { return !room.isDM }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = min(geo.size.width * drawerFraction, 340)
            let leadingInset: CGFloat = 10
            // Off-screen resting position: clears the pane width, leading inset, and shadow.
            let hiddenOffset = -(leadingInset + drawerWidth + 30)
            let baseOffset: CGFloat = drawerOpen ? 0 : hiddenOffset
            let offsetX = min(0, max(hiddenOffset, baseOffset + dragTranslation))
            // Right (users) drawer: mirror — parks off the trailing edge (positive offset).
            let hiddenOffsetR = leadingInset + drawerWidth + 30
            let baseOffsetR: CGFloat = usersOpen ? 0 : hiddenOffsetR
            let offsetXR = max(0, min(hiddenOffsetR, baseOffsetR + usersDragTranslation))

            // How far each drawer is open (0 closed → 1 open), tracking the drag too.
            // Drives the floating composer: each drawer pushes it in its own direction of
            // travel and fades it out; reverses as the drawer closes.
            let opennessL = (offsetX - hiddenOffset) / -hiddenOffset
            let opennessR = (hiddenOffsetR - offsetXR) / hiddenOffsetR
            let composerOffsetX = (opennessL - opennessR) * drawerWidth
            let composerOpacity = 1 - Double(max(opennessL, opennessR))

            ZStack(alignment: .leading) {

                // ── Base layer: chat pane (owns the NavigationStack so the
                //     hamburger toolbar has a navigation context) ────────────
                NavigationStack {
                    ChatPaneView(composerOffsetX: composerOffsetX, composerOpacity: composerOpacity)
                        // Invisible tap-catcher when the drawer is open — no dim, so the
                        // content beside the drawer stays at full brightness (like the
                        // Narwhal reference). Tapping it closes the drawer.
                        .overlay {
                            if drawerOpen || usersOpen {
                                Color.clear
                                    .ignoresSafeArea()
                                    .contentShape(Rectangle())
                                    .onTapGesture { closeAll() }
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { setDrawer(!drawerOpen) } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                                .accessibilityLabel("Toggle sidebar")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { showPreferences = true } label: {
                                    Image(systemName: "gearshape")
                                }
                                .accessibilityLabel("Preferences")
                            }
                            if canShowUsers {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button { setUsers(!usersOpen) } label: {
                                        Image(systemName: "person.2")
                                    }
                                    .accessibilityLabel("Room Members")
                                }
                            }
                        }
                }

                // ── Left screen-edge affordance: pull the drawer open. A thin strip
                //     so the open-drag isn't swallowed by the chat scroll view. ──
                if !drawerOpen && !usersOpen {
                    Color.clear
                        .frame(width: 18)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(openDrag(drawerWidth: drawerWidth, hiddenOffset: hiddenOffset))
                }

                // ── Right screen-edge affordance: pull the users drawer open. Only
                //     live when BOTH drawers are closed, so closing one drawer can't
                //     accidentally spawn the other from the opposite edge. ──
                if !usersOpen && !drawerOpen && canShowUsers {
                    HStack {
                        Spacer()
                        Color.clear
                            .frame(width: 18)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(openDragUsers(drawerWidth: drawerWidth, hiddenOffset: hiddenOffsetR))
                    }
                }

                // ── Drawer pane: always present, slid off-screen via offset when
                //     closed so it can track the finger and always animate. ──────
                GlassEffectContainer {
                    DrawerView(drawerOpen: $drawerOpen)
                        .frame(width: drawerWidth)
                        // Corners resolve INDIVIDUALLY (isUniform: false) so the bottom
                        // corners — now near the display edge — conform to the device's
                        // physical curvature, while the far top corners hold the 20pt floor.
                        .glassEffect(
                            .regular,
                            in: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: false)
                        )
                }
                // Top-pin so the greedy pane grows DOWNWARD (not centered, which spilled
                // it off-screen). Work in physical coordinates (ignoresSafeArea) so insets
                // are measured from the device edges, where the concentric corners conform:
                // matching 10pt off the leading AND bottom physical edges keeps the bottom
                // corners symmetric with the leading ones; top starts below the nav-bar row
                // (status bar + ~44pt nav bar + margin) so it clears the hamburger button.
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, leadingInset)
                .padding(.top, geo.safeAreaInsets.top + 52)
                .padding(.bottom, 10)
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
                .offset(x: offsetX)
                // Don't intercept touches while parked off-screen (lets the chat and the
                // edge strip receive them); only live when open.
                .allowsHitTesting(drawerOpen)

                // ── Right drawer pane: room occupants (mirror of the channels
                //     drawer on the trailing edge). Only present for non-DM rooms. ──
                if canShowUsers, let room = viewModel.selectedRoom {
                    GlassEffectContainer {
                        UsersDrawerContent(room: room, onClose: { setUsers(false) })
                            .frame(width: drawerWidth)
                            .glassEffect(
                                .regular,
                                in: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: false)
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, leadingInset)
                    .padding(.top, geo.safeAreaInsets.top + 52)
                    .padding(.bottom, 10)
                    .ignoresSafeArea()
                    .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
                    .offset(x: offsetXR)
                    .allowsHitTesting(usersOpen)
                }
            }
            // Leftward flick closes the channels drawer; rightward flick closes users.
            .gesture(closeDrag(drawerWidth: drawerWidth))
        }
        // Close the users drawer if the room changes to one without an occupant list.
        .onChange(of: viewModel.selectedRoom?.id) {
            if !canShowUsers, usersOpen { setUsers(false) }
        }
        // When no room is selected, start with the drawer open (slides in).
        .onAppear {
            if viewModel.selectedRoom == nil {
                setDrawer(true)
            }
        }
        .sheet(isPresented: $showPreferences) {
            PreferencesScreen()
        }
    }

    /// Open/close the channels drawer. Opening it closes the users drawer (one at a time).
    private func setDrawer(_ open: Bool) {
        withAnimation(drawerAnimation) {
            drawerOpen = open
            if open { usersOpen = false }
            dragTranslation = 0
        }
    }

    /// Open/close the users drawer. Opening it closes the channels drawer (one at a time).
    private func setUsers(_ open: Bool) {
        withAnimation(drawerAnimation) {
            usersOpen = open
            if open { drawerOpen = false }
            usersDragTranslation = 0
        }
    }

    private func closeAll() {
        withAnimation(drawerAnimation) {
            drawerOpen = false
            usersOpen = false
            dragTranslation = 0
            usersDragTranslation = 0
        }
    }

    /// Finger-tracking pull from the left screen edge to open the channels drawer.
    private func openDrag(drawerWidth: CGFloat, hiddenOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard !drawerOpen else { return }
                dragTranslation = max(0, min(-hiddenOffset, value.translation.width))
            }
            .onEnded { value in
                guard !drawerOpen else { return }
                let projected = value.predictedEndTranslation.width
                setDrawer(value.translation.width > drawerWidth * 0.33 || projected > drawerWidth * 0.6)
            }
    }

    /// Finger-tracking pull from the right screen edge to open the users drawer.
    private func openDragUsers(drawerWidth: CGFloat, hiddenOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard !usersOpen else { return }
                usersDragTranslation = min(0, max(-hiddenOffset, value.translation.width))
            }
            .onEnded { value in
                guard !usersOpen else { return }
                let projected = value.predictedEndTranslation.width
                setUsers(value.translation.width < -drawerWidth * 0.33 || projected < -drawerWidth * 0.6)
            }
    }

    /// Leftward flick closes the channels drawer; rightward flick closes the users drawer.
    private func closeDrag(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projected = value.predictedEndTranslation.width
                if drawerOpen, value.translation.width < 0,
                   value.translation.width < -drawerWidth * 0.33 || projected < -drawerWidth * 0.6 {
                    setDrawer(false)
                } else if usersOpen, value.translation.width > 0,
                          value.translation.width > drawerWidth * 0.33 || projected > drawerWidth * 0.6 {
                    setUsers(false)
                }
            }
    }
}

