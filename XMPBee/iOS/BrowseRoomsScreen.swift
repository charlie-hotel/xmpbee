import SwiftUI

/// iOS sheet — browse available MUC rooms on the target server.
/// Mirrors RoomBrowserPopover from Mac/SidebarView.swift.
struct BrowseRoomsScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""

    private var targetServer: Server? {
        viewModel.selectedServer ?? viewModel.servers.first
    }

    private var filteredRooms: [(jid: String, name: String)] {
        if filter.isEmpty { return viewModel.discoveredRooms }
        return viewModel.discoveredRooms.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.jid.localizedCaseInsensitiveContains(filter)
        }
    }

    private var joinedJIDs: Set<String> {
        guard let server = targetServer else { return [] }
        return Set(server.rooms.map(\.jid))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingRooms {
                    loadingView
                } else if filteredRooms.isEmpty {
                    emptyView
                } else {
                    roomListView
                }
            }
            .navigationTitle("Browse Rooms")
            .searchable(text: $filter, prompt: "Filter rooms…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let server = targetServer {
                            viewModel.browseRooms(on: server)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if let server = targetServer {
                viewModel.browseRooms(on: server)
            }
        }
    }

    // MARK: - Sub-views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading rooms…")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        Text(viewModel.discoveredRooms.isEmpty ? "No rooms found." : "No rooms match your filter.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var roomListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredRooms, id: \.jid) { room in
                    RoomBrowseRow(
                        room: room,
                        alreadyJoined: joinedJIDs.contains(room.jid),
                        onJoin: {
                            guard let server = targetServer else { return }
                            let name = room.jid.components(separatedBy: "@").first ?? room.name
                            viewModel.joinNewRoom(name: name, on: server)
                        }
                    )
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - Row sub-view (extracted to avoid type-checker blowup)

private struct RoomBrowseRow: View {
    let room: (jid: String, name: String)
    let alreadyJoined: Bool
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.body)
                    .lineLimit(1)
                Text(room.jid)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if alreadyJoined {
                Text("joined")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Join", action: onJoin)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
