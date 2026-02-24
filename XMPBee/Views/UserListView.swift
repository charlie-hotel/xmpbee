import SwiftUI

/// Right sidebar showing room occupants — Liquid Glass design
struct UserListView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ZStack(alignment: .top) {
            // User list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let room = viewModel.selectedRoom, !room.isDM {
                        ForEach(room.occupants) { occupant in
                            OccupantRow(occupant: occupant)
                                .contextMenu {
                                    Button("Send Message") {
                                        if let server = viewModel.selectedServer {
                                            viewModel.openDM(nick: occupant.nick, on: server)
                                        }
                                    }
                                    Divider()
                                    Button("Copy Nickname") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(occupant.nick, forType: .string)
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 44)
            }

            // Floating glass header
            HStack {
                Text("Users")
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.channelText)
                Spacer()
                if let room = viewModel.selectedRoom {
                    Text("\(room.occupants.count)")
                        .font(Theme.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.clear, in: .capsule)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
    }
}

struct OccupantRow: View {
    let occupant: Occupant
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: prefixSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(prefixColor)
                .frame(width: 12, alignment: .center)
                .opacity(occupant.prefix.isEmpty ? 0.25 : 1.0)

            Text(occupant.nick)
                .font(Theme.sidebarFont)
                .foregroundStyle(Theme.userText)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            isHovered
                ? AnyView(RoundedRectangle(cornerRadius: 6).fill(Theme.hoverBackground))
                : AnyView(Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
        case "~": return Color(red: 1.0, green: 0.75, blue: 0.0)  // gold
        case "&": return .orange
        case "@": return .teal
        case "+": return .gray
        default:  return .gray
        }
    }
}
