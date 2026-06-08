import SwiftUI

// MARK: - OccupantList (shared)

/// Transparent occupant list shared by the iPhone users drawer and the iPad
/// users panel. Background-clear so it shows through the drawer glass / panel.
struct OccupantList: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject var room: Room
    /// Called after opening a DM from the context menu (lets the iPhone drawer close).
    var onOpenDM: () -> Void = {}

    /// Occupants minus any blocked nicks on the selected server.
    private var visibleOccupants: [Occupant] {
        guard let server = viewModel.selectedServer else { return room.occupants }
        return room.occupants.filter { !server.isBlocked(nick: $0.nick) }
    }

    var body: some View {
        List(visibleOccupants) { occupant in
            // Single tap opens the menu (no long-press needed); swipe still copies.
            Menu {
                Button {
                    if let server = viewModel.selectedServer {
                        viewModel.openDM(nick: occupant.nick, on: server)
                    }
                    onOpenDM()
                } label: {
                    Label("Send Message", systemImage: "message")
                }
                Divider()
                Button {
                    Clipboard.copy(occupant.nick)
                } label: {
                    Label("Copy Nickname", systemImage: "doc.on.doc")
                }
                if occupant.nick != room.nickname {
                    Divider()
                    Button(role: .destructive) {
                        if let server = viewModel.selectedServer {
                            viewModel.blockNick(occupant.nick, on: server)
                        }
                    } label: {
                        Label("Block \(occupant.displayNick)", systemImage: "person.slash")
                    }
                }
            } label: {
                OccupantListRow(occupant: occupant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .tint(.primary)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing) {
                Button {
                    Clipboard.copy(occupant.nick)
                } label: {
                    Label("Copy Nick", systemImage: "doc.on.doc")
                }
                .tint(.accentColor)
            }
        }
        .listStyle(.plain)
        // Transparent so the drawer's Liquid Glass / the iPad panel shows through.
        .scrollContentBackground(.hidden)
    }
}

// MARK: - UsersDrawerContent (iPhone right drawer)

/// iPhone users-drawer body: a plain header (NOT glass — the drawer itself is the
/// glass layer; glass-on-glass is wrong) plus the shared occupant list. Mirrors
/// `DrawerView`'s structure for the channels drawer.
struct UsersDrawerContent: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject var room: Room
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").font(.system(size: 17))
                Text(room.displayName)
                    .font(.title3).fontWeight(.bold)
                    .lineLimit(1)
                Spacer()
                Text("\(viewModel.visibleOccupantCount(in: room))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            OccupantList(room: room, onOpenDM: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - OccupantsPanel (iPad)

/// iPad users panel: a floating glass header over the occupant list, mirroring the
/// macOS `UserListView` (always visible beside the chat for non-DM rooms).
struct OccupantsPanel: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject var room: Room

    var body: some View {
        ZStack(alignment: .top) {
            OccupantList(room: room)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: 44)
                }

            HStack {
                Text("Users")
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(Theme.channelText)
                Spacer()
                Text("\(viewModel.visibleOccupantCount(in: room))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
    }
}

// MARK: - OccupantListRow

/// Single occupant row: presence/role icon + display nick. System font on both
/// iPhone (drawer) and iPad (panel) — slightly smaller on the narrower iPad panel.
private struct OccupantListRow: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let occupant: Occupant

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: prefixSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .center)
                .opacity(occupant.prefix.isEmpty ? 0.3 : 1.0)

            Text(occupant.displayNick)
                .font(.system(size: sizeClass == .compact ? 16 : 15))
                .lineLimit(1)
        }
    }

    private var prefixSymbol: String {
        switch occupant.prefix {
        case "~": return "crown.fill"
        case "&": return "star.fill"
        case "@": return "person.circle.fill"
        case "+": return "person.fill"
        default:  return "person.fill"
        }
    }

    private var prefixColor: Color {
        switch occupant.prefix {
        case "~": return Color(red: 1.0, green: 0.75, blue: 0.0)
        case "&": return .orange
        case "@": return .teal
        case "+": return .gray
        default:  return .gray
        }
    }
}
