import SwiftUI

/// iOS full-screen log viewer. Mirrors macOS `LogViewerWindow`.
/// Presented as `.fullScreenCover`.
struct LogViewerScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedServer: String? = nil
    @State private var selectedRoom: String? = nil
    @State private var selectedDate: String? = nil
    @State private var logContent: String = ""
    @State private var searchText: String = ""
    @State private var showClearConfirmation = false

    /// Cached groups — recomputed only when `logContent` / `searchText` changes.
    @State private var groupedMessages: [[String]] = []
    @State private var filteredGroups: [[String]] = []

    private var servers: [String] { LogManager.shared.getLoggedServers() }
    private var rooms: [String] {
        guard let server = selectedServer else { return [] }
        return LogManager.shared.getLoggedRooms(for: server)
    }
    private var dates: [String] {
        guard let server = selectedServer, let room = selectedRoom else { return [] }
        return LogManager.shared.getLogDates(server: server, room: room)
    }

    var body: some View {
        NavigationStack {
            LogViewerContent(
                servers: servers,
                selectedServer: $selectedServer,
                selectedRoom: $selectedRoom,
                selectedDate: $selectedDate,
                dates: dates,
                filteredGroups: filteredGroups,
                searchText: $searchText,
                showClearConfirmation: $showClearConfirmation,
                lineColor: lineColor(_:)
            )
            .navigationTitle("Log Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(servers.isEmpty)
                }
            }
        }
        .onChange(of: selectedRoom) { _, _ in
            selectedServer = servers.first { LogManager.shared.getLoggedRooms(for: $0).contains(selectedRoom ?? "") }
            selectedDate = dates.first
            loadLog()
        }
        .onChange(of: selectedDate) { _, _ in loadLog() }
        .onChange(of: logContent) { _, _ in updateGroups() }
        .onChange(of: searchText) { _, _ in updateFilteredGroups() }
        .alert("Clear All Logs?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All Logs", role: .destructive) { clearAllLogs() }
        } message: {
            Text("This will permanently delete all chat logs. This action cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func updateGroups() {
        let lines = logContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        var groups: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("[") && line.count > 10 {
                if !current.isEmpty { groups.append(current) }
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { groups.append(current) }
        groupedMessages = groups
        updateFilteredGroups()
    }

    private func updateFilteredGroups() {
        guard !searchText.isEmpty else { filteredGroups = groupedMessages; return }
        filteredGroups = groupedMessages.filter { $0.joined().localizedCaseInsensitiveContains(searchText) }
    }

    private func loadLog() {
        guard let server = selectedServer, let room = selectedRoom, let date = selectedDate else { return }
        logContent = LogManager.shared.readLog(server: server, room: room, date: date)
    }

    private func clearAllLogs() {
        LogManager.shared.clearAllLogs()
        selectedServer = nil
        selectedRoom = nil
        selectedDate = nil
        logContent = ""
        groupedMessages = []
        filteredGroups = []
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("] <") { return Theme.chatText }
        if line.contains("] * ") { return Theme.systemText }
        if line.contains("] →") || line.contains("] ←") || line.contains("] ⇐") { return Theme.systemText }
        if line.contains("] ✦") { return Theme.topicText }
        if line.contains("] •") { return Theme.systemText }
        return Theme.chatText
    }
}

// MARK: - Content (factored out to keep type-checker fast)

private struct LogViewerContent: View {
    let servers: [String]
    @Binding var selectedServer: String?
    @Binding var selectedRoom: String?
    @Binding var selectedDate: String?
    let dates: [String]
    let filteredGroups: [[String]]
    @Binding var searchText: String
    @Binding var showClearConfirmation: Bool
    let lineColor: (String) -> Color

    var body: some View {
        List {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "list.bullet.badge.ellipsis",
                    description: Text("No chat logs have been recorded yet.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(servers, id: \.self) { server in
                    Section(server) {
                        ForEach(LogManager.shared.getLoggedRooms(for: server), id: \.self) { room in
                            Button {
                                selectedRoom = room
                            } label: {
                                Label(room, systemImage: room.hasPrefix("DM-") ? "person" : "number")
                                    .font(Theme.monoFont)
                                    .foregroundStyle(selectedRoom == room ? Color.accentColor : Color.primary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedRoom != nil {
                logDetailPanel
            }
        }
    }

    // MARK: Detail panel

    private var logDetailPanel: some View {
        VStack(spacing: 0) {
            Divider()
            if !dates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dates, id: \.self) { date in
                            Button(date) { selectedDate = date }
                                .buttonStyle(.bordered)
                                .tint(selectedDate == date ? .accentColor : .secondary)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                Divider()
            }
            logTranscriptPanel
        }
        .background(.bar)
        .frame(maxHeight: 340)
    }

    private var logTranscriptPanel: some View {
        ScrollView {
            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    selectedDate == nil ? "No Date Selected" : "No Results",
                    systemImage: selectedDate == nil ? "calendar" : "magnifyingglass",
                    description: Text(
                        selectedDate == nil
                            ? "Select a date above"
                            : "No lines match \"\(searchText)\""
                    )
                )
                .padding(.top, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredGroups.indices, id: \.self) { i in
                        let group = filteredGroups[i]
                        Text(group.joined(separator: "\n"))
                            .font(Theme.monoFont)
                            .foregroundStyle(lineColor(group.first ?? ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
        }
        .searchable(text: $searchText, prompt: "Search logs")
        .background(Theme.chatBackground)
    }
}
