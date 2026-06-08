import SwiftUI

/// iOS add/edit-server form — mirrors macOS ConnectSheet behavior.
///
/// Modes:
///   • Create — `viewModel.editingServer` is nil; fields start with defaults; Save submits via
///     `addServerAndConnect`.
///   • Edit   — `viewModel.editingServer` is non-nil; fields are pre-populated from UserDefaults +
///     Keychain on appear; Save submits via `updateAccount`; a destructive Delete button appears.
struct ConnectScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state (mirrors macOS ConnectSheet defaults)
    @State private var serverName      = ""
    @State private var hostname        = ""
    @State private var port            = "5222"
    @State private var jid             = ""
    @State private var password        = ""
    @State private var resource        = Platform.defaultResource
    @State private var priority        = 0
    @State private var conferenceServer = ""
    @State private var roomsToJoin     = ""
    @State private var nickname        = ""
    @State private var securityMode: SecurityMode = .requireTLS

    @State private var showDeleteConfirm = false

    private var isEditing: Bool { viewModel.editingServer != nil }

    // MARK: - Validation (matches macOS ConnectSheet)
    /// Save/Connect is enabled when JID is non-empty.
    /// In create mode password must also be non-empty (edit mode may reuse the Keychain value).
    private var canSave: Bool {
        !jid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (isEditing || !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Account section
                Section("Account") {
                    TextField("user@example.com", text: $jid)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("JID")

                    SecureField("Password", text: $password)
                        .accessibilityLabel("Password")

                    TextField("Display nickname (must be unique per-device!)", text: $nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Nickname")
                }

                // MARK: Server options
                Section("Connection") {
                    TextField("conference.goonfleet.com", text: $hostname)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server hostname")

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Port")

                    TextField("XMPBee", text: $resource)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Resource")

                    Stepper(value: $priority, in: -128...127) {
                        Text("Priority: \(priority)")
                    }
                    .accessibilityLabel("Priority")
                }

                // MARK: Security
                Section("Security") {
                    Picker("Encryption", selection: $securityMode) {
                        Text("Require SSL/TLS (STARTTLS, port 5222)")
                            .tag(SecurityMode.requireTLS)
                        Text("Direct TLS (port 5223)")
                            .tag(SecurityMode.directTLS)
                    }
                    .pickerStyle(.menu)
                }

                // MARK: Rooms (MUC)
                Section("Rooms (MUC)") {
                    TextField("conference.example.com", text: $conferenceServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Conference server")

                    TextField("Rooms to join (comma-separated)", text: $roomsToJoin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Rooms to join")

                    TextField("My Server", text: $serverName)
                        .accessibilityLabel("Display name")
                }

                // MARK: Delete (edit mode only)
                if isEditing {
                    Section {
                        Button("Delete Account…", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.editingServer = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Save" : "Connect") {
                        if isEditing {
                            saveEditAndDismiss()
                        } else {
                            connectAndDismiss()
                        }
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if isEditing { loadEditingValues() }
            }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let server = viewModel.editingServer {
                        viewModel.deleteAccount(server)
                    }
                    viewModel.editingServer = nil
                    dismiss()
                }
            } message: {
                Text("This disconnects the account, clears its saved settings, and removes its password from the Keychain. You'll need to re-enter everything to reconnect.")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Edit-mode prefill

    /// Populate @State fields from persisted settings + Keychain (mirrors macOS ConnectSheet).
    private func loadEditingValues() {
        guard let server = viewModel.editingServer,
              let dict = viewModel.savedSettings(forJID: server.jid) else { return }
        serverName       = dict["name"]             as? String ?? ""
        hostname         = dict["hostname"]         as? String ?? ""
        port             = String(dict["port"]      as? Int    ?? 5222)
        jid              = dict["jid"]              as? String ?? ""
        resource         = dict["resource"]         as? String ?? Platform.defaultResource
        priority         = dict["priority"]         as? Int    ?? 0
        nickname         = dict["nickname"]         as? String ?? ""
        conferenceServer = dict["conferenceServer"] as? String ?? ""
        roomsToJoin      = (dict["rooms"] as? [String] ?? []).joined(separator: ", ")
        if let modeRaw = dict["securityMode"] as? String,
           let mode = SecurityMode(rawValue: modeRaw) {
            securityMode = mode
        }
        // Pre-populate password from Keychain so it's visible/editable in the form.
        if let saved = viewModel.savedPassword(for: jid) {
            password = saved
        }
    }

    // MARK: - Save / Connect actions

    private func saveEditAndDismiss() {
        guard let server = viewModel.editingServer else { return }
        let trimmedJID = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidJID(trimmedJID) else { return }

        let connectHost = hostname.isEmpty
            ? (trimmedJID.components(separatedBy: "@").last ?? "")
            : hostname
        let name       = serverName.isEmpty ? connectHost : serverName
        let portNum    = Int(port) ?? 5222
        let nick       = nickname.isEmpty
            ? (trimmedJID.components(separatedBy: "@").first ?? "user")
            : nickname
        let res        = resource.isEmpty ? Platform.defaultResource : resource
        let confServer = conferenceServer.isEmpty
            ? "conference.\(trimmedJID.components(separatedBy: "@").last ?? connectHost)"
            : conferenceServer

        let rooms = roomsToJoin
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        viewModel.updateAccount(
            server: server,
            name: name, hostname: connectHost, port: portNum,
            jid: trimmedJID, password: password, resource: res, priority: priority,
            securityMode: securityMode, nickname: nick,
            conferenceServer: confServer, rooms: rooms
        )

        // Drop password from @State immediately — don't let it linger in view memory.
        password = ""
        viewModel.editingServer = nil
        dismiss()
    }

    private func connectAndDismiss() {
        let trimmedJID = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidJID(trimmedJID) else { return }

        let connectHost = hostname.isEmpty
            ? (trimmedJID.components(separatedBy: "@").last ?? "")
            : hostname
        let name       = serverName.isEmpty ? connectHost : serverName
        let portNum    = Int(port) ?? 5222
        let nick       = nickname.isEmpty
            ? (trimmedJID.components(separatedBy: "@").first ?? "user")
            : nickname
        let res        = resource.isEmpty ? Platform.defaultResource : resource
        let confServer = conferenceServer.isEmpty
            ? "conference.\(trimmedJID.components(separatedBy: "@").last ?? connectHost)"
            : conferenceServer

        let rooms = roomsToJoin
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        viewModel.addServerAndConnect(
            name: name,
            hostname: connectHost,
            port: portNum,
            jid: trimmedJID,
            password: password,
            resource: res,
            priority: priority,
            securityMode: securityMode,
            nickname: nick,
            conferenceServer: confServer,
            rooms: rooms
        )

        // Clear @State password now that it has been handed off — don't let it linger.
        password = ""
        dismiss()
    }

    // MARK: - JID validation (mirrors macOS ConnectSheet)

    private func isValidJID(_ jid: String) -> Bool {
        guard !jid.isEmpty, jid.count <= 3071 else { return false }
        guard jid.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }) else { return false }

        let atComponents = jid.components(separatedBy: "@")
        guard atComponents.count == 2 else { return false }

        let localpart = atComponents[0]
        let afterAt   = atComponents[1]

        guard !localpart.isEmpty, localpart.count <= 1023, !localpart.contains("/") else { return false }

        let domainParts = afterAt.components(separatedBy: "/")
        let domain = domainParts[0]

        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let hostnamePattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-\\.]*[a-zA-Z0-9])?$"
        guard let hostnameRegex = try? NSRegularExpression(pattern: hostnamePattern) else { return false }
        let hostnameRange = NSRange(domain.startIndex..., in: domain)
        guard hostnameRegex.firstMatch(in: domain, range: hostnameRange) != nil else { return false }

        if domainParts.count > 1 {
            let resource = domainParts[1...].joined(separator: "/")
            guard !resource.isEmpty, resource.count <= 1023 else { return false }
        }

        return true
    }
}
