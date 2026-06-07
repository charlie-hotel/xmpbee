import SwiftUI

/// iOS sheet — XEP-0055 user-directory search.
/// Mirrors UserSearchPopover from Mac/SidebarView.swift.
struct UserSearchScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var targetServer: Server? {
        viewModel.selectedServer ?? viewModel.servers.first
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targetServer != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultArea
            }
            .navigationTitle("Search Users")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search by nick…", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { runSearch() }
                .submitLabel(.search)

            Button("Search") { runSearch() }
                .disabled(!canSearch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Result area

    @ViewBuilder
    private var resultArea: some View {
        if viewModel.isSearchingUsers {
            searchingView
        } else if let error = viewModel.userSearchError {
            errorView(error)
        } else if viewModel.discoveredUsers.isEmpty {
            placeholderView
        } else {
            userListView
        }
    }

    private var searchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Searching…")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.red)
            .font(.subheadline)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderView: some View {
        Text(query.isEmpty
             ? "Type a nickname or name and press Search."
             : "No matches.")
            .foregroundStyle(.secondary)
            .font(.subheadline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var userListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.discoveredUsers, id: \.jid) { user in
                    UserSearchRow(user: user, onDM: {
                        guard let server = targetServer else { return }
                        // Pick nick if provided; otherwise fall back to JID local-part.
                        // Mirrors UserSearchPopover in Mac/SidebarView.swift.
                        let target = !user.nick.isEmpty
                            ? user.nick
                            : (user.jid.components(separatedBy: "@").first ?? user.jid)
                        viewModel.openDM(nick: target, on: server)
                        dismiss()
                    })
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Helpers

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let server = targetServer else { return }
        viewModel.searchUsers(query: trimmed, on: server)
    }
}

// MARK: - Row sub-view (extracted to avoid type-checker blowup)

private struct UserSearchRow: View {
    let user: (jid: String, nick: String, name: String)
    let onDM: () -> Void

    /// Primary display name: full name if set, else nick, else JID.
    private var displayName: String {
        if !user.name.isEmpty { return user.name }
        if !user.nick.isEmpty { return user.nick }
        return user.jid
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(user.jid)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("DM", action: onDM)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
