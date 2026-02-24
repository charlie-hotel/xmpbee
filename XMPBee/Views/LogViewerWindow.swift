import SwiftUI

struct LogViewerWindow: View {
    @State private var selectedServer: String?
    @State private var selectedRoom: String?
    @State private var selectedDate: String?
    @State private var logContent: String = ""
    @State private var searchText: String = ""
    @State private var showClearConfirmation = false
    /// Cached — recomputed only when logContent or searchText changes, not on every render.
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

    var body: some View {
        NavigationSplitView {
            // Sidebar: servers + rooms
            List(selection: $selectedRoom) {
                ForEach(servers, id: \.self) { server in
                    Section {
                        ForEach(LogManager.shared.getLoggedRooms(for: server), id: \.self) { room in
                            Label(room, systemImage: room.hasPrefix("DM-") ? "person" : "number")
                                .font(Theme.monoFont)
                                .tag(room)
                        }
                    } header: {
                        Text(server)
                            .font(Theme.sidebarFont)
                            .fontWeight(.semibold)
                            .padding(.bottom, 4)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            .listStyle(.sidebar)
        } detail: {
            logDetailView
        }
        .navigationTitle("Log Viewer")
        .onChange(of: selectedRoom) {
            selectedServer = servers.first { LogManager.shared.getLoggedRooms(for: $0).contains(selectedRoom ?? "") }
            // Auto-select the most recent date
            selectedDate = dates.first
            loadLog()
        }
        .onChange(of: selectedDate) { loadLog() }
        .onChange(of: logContent) { updateGroups() }
        .onChange(of: searchText) { updateFilteredGroups() }
        .alert("Clear All Logs?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All Logs", role: .destructive) { clearAllLogs() }
        } message: {
            Text("This will permanently delete all chat logs. This action cannot be undone.")
        }
    }

    private var logDetailView: some View {
        ScrollView {
            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    selectedDate == nil ? "No Date Selected" : "No Results",
                    systemImage: selectedDate == nil ? "calendar" : "magnifyingglass",
                    description: Text(selectedDate == nil ? "Select a date from the list" : "No lines match \"\(searchText)\"")
                )
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredGroups.indices, id: \.self) { i in
                        let group = filteredGroups[i]
                        Text(group.joined(separator: "\n"))
                            .font(Theme.monoFont)
                            .foregroundStyle(lineColor(group.first ?? ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.chatBackground)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !dates.isEmpty {
                    Picker("Date", selection: $selectedDate) {
                        ForEach(dates, id: \.self) { date in
                            Text(date).tag(Optional(date))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive, action: { showClearConfirmation = true }) {
                    Label("Clear All Logs", systemImage: "trash")
                }
                .help("Delete all log files")
            }
        }
    }

    /// Colour-code lines by type to match the chat view style
    private func lineColor(_ line: String) -> Color {
        if line.contains("] <") { return Theme.chatText }
        if line.contains("] * ") { return Theme.systemText }
        if line.contains("] →") || line.contains("] ←") || line.contains("] ⇐") { return Theme.systemText }
        if line.contains("] ✦") { return Theme.topicText }
        if line.contains("] •") { return Theme.systemText }
        return Theme.chatText
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
}

#Preview {
    LogViewerWindow()
}
