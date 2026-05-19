import Foundation
import SwiftUI
import Security

/// Main view model — bridges XMPP connections to the UI
@MainActor
class ChatViewModel: ObservableObject, XMPPClientDelegate {
    @Published var servers: [Server] = []
    @Published var selectedRoom: Room?
    @Published var selectedServer: Server?
    @Published var inputText = ""
    @Published var showConnectSheet = false
    @Published var showJoinRoom = false
    @Published var showNewDM = false
    @Published var showBrowseRooms = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var discoveredRooms: [(jid: String, name: String)] = []
    @Published var isLoadingRooms = false
    /// Incremented when the chat view should scroll to bottom (e.g. on initial connect)
    @Published var scrollToBottomTrigger = 0
    /// When non-nil, the ConnectSheet opens in Edit mode against this server.
    /// Set just before flipping showConnectSheet = true, cleared on dismiss.
    @Published var editingServer: Server? = nil

    /// Notification manager
    let notifications = NotificationManager.shared

    /// Maps server ID → XMPP client
    private var clients: [UUID: XMPPClient] = [:]
    /// Maps server ID → pending rooms/config
    private var pendingConfig: [UUID: (nickname: String, confServer: String, rooms: [String])] = [:]

    /// Reconnection state
    private var reconnectionTimers: [UUID: Timer] = [:]
    private var reconnectionAttempts: [UUID: Int] = [:]
    private let maxReconnectionAttempts = 5
    private var manuallyDisconnected: Set<UUID> = []

    // MARK: - Server Management

    func addServerAndConnect(
        name: String, hostname: String, port: Int,
        jid: String, password: String,
        resource: String = "XMPBee",
        securityMode: SecurityMode = .requireTLS,
        nickname: String, conferenceServer: String, rooms: [String]
    ) {
        // Create server WITHOUT password (security: passwords not stored in Server objects)
        let server = Server(name: name, hostname: hostname, port: port, jid: jid)
        servers.append(server)

        pendingConfig[server.id] = (nickname: nickname, confServer: conferenceServer, rooms: rooms)

        let client = XMPPClient()
        client.delegate = self
        clients[server.id] = client

        addSystemMessage(to: server, text: "Connecting to \(hostname):\(port) (\(securityMode))...")

        // Password is passed directly to client and will be cleared after auth
        client.connect(host: hostname, port: port, jid: jid, password: password,
                       resource: resource, securityMode: securityMode)

        // Save settings for next launch (password goes to Keychain, not Server object)
        saveSettings(name: name, hostname: hostname, port: port, jid: jid, password: password,
                     resource: resource, securityMode: securityMode, nickname: nickname,
                     conferenceServer: conferenceServer, rooms: rooms)

        // Reset reconnection attempts for new connections
        reconnectionAttempts[server.id] = 0
    }

    // MARK: - Reconnection

    private func scheduleReconnection(for server: Server) {
        let attempts = reconnectionAttempts[server.id] ?? 0

        guard attempts < maxReconnectionAttempts else {
            addSystemMessage(to: server, text: "Max reconnection attempts reached. Click ⚡ to reconnect.")
            return
        }

        // Exponential backoff: 2^attempts seconds (2, 4, 8, 16, 32 seconds)
        let delay = min(pow(2.0, Double(attempts)), 32.0)
        reconnectionAttempts[server.id] = attempts + 1

        addSystemMessage(to: server, text: "Reconnecting in \(Int(delay))s... (attempt \(attempts + 1)/\(maxReconnectionAttempts))")

        let serverID = server.id
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let server = self.servers.first(where: { $0.id == serverID }) else { return }
                self.reconnect(server: server)
            }
        }
    }

    func reconnect(server: Server) {
        // Look up this specific account's saved settings by JID rather than reading
        // a singular "current" dict — multiple accounts may be saved.
        let accounts = Self.savedAccountsArray()
        guard let dict = accounts.first(where: { ($0["jid"] as? String) == server.jid }),
              let jid = dict["jid"] as? String,
              let pw = Self.loadPasswordFromKeychain(for: jid),
              let _ = pendingConfig[server.id] else {
            addSystemMessage(to: server, text: "Reconnection failed: missing credentials")
            return
        }

        var password = pw
        defer { password = "" }

        addSystemMessage(to: server, text: "Reconnecting to \(server.hostname):\(server.port)...")

        let hostname = dict["hostname"] as? String ?? server.hostname
        let port = dict["port"] as? Int ?? server.port
        let resource = dict["resource"] as? String ?? "XMPBee"
        let modeRaw = dict["securityMode"] as? String ?? "requireTLS"
        let securityMode = SecurityMode(rawValue: modeRaw) ?? .requireTLS

        // Get existing client or create new one
        let client = clients[server.id] ?? XMPPClient()
        if clients[server.id] == nil {
            client.delegate = self
            clients[server.id] = client
        }

        client.connect(host: hostname, port: port, jid: jid, password: password,
                       resource: resource, securityMode: securityMode)
    }

    func manualReconnect(server: Server) {
        // Remove from manually disconnected set
        manuallyDisconnected.remove(server.id)

        // Reset reconnection attempts on manual reconnect
        reconnectionAttempts[server.id] = 0
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        reconnect(server: server)
    }

    func disconnect(server: Server) {
        // Mark as manually disconnected
        manuallyDisconnected.insert(server.id)

        // Cancel any pending reconnection attempts
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil

        // Update UI immediately
        server.isConnected = false
        objectWillChange.send()
        addSystemMessage(to: server, text: "Disconnecting...")

        // Disconnect the client (will trigger xmppDidDisconnect delegate)
        if let client = clients[server.id] {
            client.disconnect()
        }
    }

    // MARK: - Settings Persistence

    private static let settingsKey = "SavedServerSettings"

    // MARK: - Saved accounts storage (multi-account, with legacy single-dict migration)
    //
    // The UserDefaults value under `settingsKey` is now an array of per-account dicts.
    // Older builds stored a single dict here (one account); we read both shapes and
    // always write the new array shape, so existing installs migrate on first save.

    /// Read the saved-accounts array, transparently migrating the legacy single-dict
    /// format into a single-element array.  Returns [] when nothing has been saved.
    private static func savedAccountsArray() -> [[String: Any]] {
        let raw = UserDefaults.standard.object(forKey: settingsKey)
        if let array = raw as? [[String: Any]] {
            return array
        }
        if let singleDict = raw as? [String: Any], !singleDict.isEmpty {
            return [singleDict]
        }
        return []
    }

    /// Write the saved-accounts array.  Always uses the new array format.
    private static func setSavedAccountsArray(_ accounts: [[String: Any]]) {
        if accounts.isEmpty {
            UserDefaults.standard.removeObject(forKey: settingsKey)
        } else {
            UserDefaults.standard.set(accounts, forKey: settingsKey)
        }
    }

    /// Find the index of the account dict whose JID matches `jid`, or nil if none.
    private static func savedAccountIndex(for jid: String, in accounts: [[String: Any]]) -> Int? {
        accounts.firstIndex { ($0["jid"] as? String) == jid }
    }

    /// Mutate a single account dict (matched by JID) inside the saved array via the
    /// provided closure, then write the array back.  No-op if no account with that JID.
    private static func mutateSavedAccount(jid: String, _ mutate: (inout [String: Any]) -> Void) {
        var accounts = savedAccountsArray()
        guard let idx = savedAccountIndex(for: jid, in: accounts) else { return }
        mutate(&accounts[idx])
        setSavedAccountsArray(accounts)
    }

    private func saveSettings(name: String, hostname: String, port: Int,
                              jid: String, password: String, resource: String,
                              securityMode: SecurityMode, nickname: String,
                              conferenceServer: String, rooms: [String]) {
        var accounts = Self.savedAccountsArray()

        // Find existing entry by JID, or build a new one. Preserves per-account fields
        // (dmContacts most importantly) on update.
        var entry: [String: Any] = Self.savedAccountIndex(for: jid, in: accounts)
            .map { accounts[$0] } ?? [:]

        // Update server settings
        entry["name"] = name
        entry["hostname"] = hostname
        entry["port"] = port
        entry["jid"] = jid
        entry["resource"] = resource
        entry["securityMode"] = securityMode.rawValue
        entry["nickname"] = nickname
        entry["conferenceServer"] = conferenceServer
        entry["rooms"] = rooms
        // Scrub any leftover plaintext password from legacy dicts the moment we touch them.
        entry.removeValue(forKey: "password")

        if let idx = Self.savedAccountIndex(for: jid, in: accounts) {
            accounts[idx] = entry
        } else {
            accounts.append(entry)
        }
        Self.setSavedAccountsArray(accounts)

        // Store password in Keychain
        Self.savePasswordToKeychain(password, for: jid)
    }

    func loadAndReconnect() {
        // Read all saved accounts.  This transparently handles the legacy single-dict
        // format (older builds saved one dict directly under the settings key).
        var accounts = Self.savedAccountsArray()
        guard !accounts.isEmpty else { return }

        var didMigrateLegacyPassword = false

        for (idx, dict) in accounts.enumerated() {
            guard let jid = dict["jid"] as? String, !jid.isEmpty else { continue }

            // Resolve the password: Keychain is the source of truth; fall back to any
            // leftover plaintext "password" key from very old single-dict installs and
            // migrate it across.
            var password: String
            if let keychainPw = Self.loadPasswordFromKeychain(for: jid) {
                password = keychainPw
            } else if let legacyPw = dict["password"] as? String, !legacyPw.isEmpty {
                Self.savePasswordToKeychain(legacyPw, for: jid)
                accounts[idx].removeValue(forKey: "password")
                didMigrateLegacyPassword = true
                password = legacyPw
            } else {
                continue
            }
            defer { password = "" }
            guard !password.isEmpty else { continue }

            let name = dict["name"] as? String ?? ""
            let hostname = dict["hostname"] as? String ?? ""
            let port = dict["port"] as? Int ?? 5222
            let resource = dict["resource"] as? String ?? "XMPBee"
            let modeRaw = dict["securityMode"] as? String ?? "requireTLS"
            let securityMode = SecurityMode(rawValue: modeRaw) ?? .requireTLS
            let nickname = dict["nickname"] as? String ?? ""
            let conferenceServer = dict["conferenceServer"] as? String ?? ""
            let rooms = dict["rooms"] as? [String] ?? []

            addServerAndConnect(
                name: name, hostname: hostname, port: port,
                jid: jid, password: password, resource: resource,
                securityMode: securityMode, nickname: nickname,
                conferenceServer: conferenceServer, rooms: rooms
            )
        }

        // If we migrated any plaintext passwords, rewrite the array sans those keys
        // so the next launch doesn't see them again.  Also collapses any legacy
        // single-dict on-disk format into the new array format.
        if didMigrateLegacyPassword {
            Self.setSavedAccountsArray(accounts)
        }

        // DM contacts will be restored per account in xmppDidAuthenticate() after connection
    }

    private func appendSavedRoom(_ name: String, forJID jid: String) {
        Self.mutateSavedAccount(jid: jid) { entry in
            var rooms = entry["rooms"] as? [String] ?? []
            if !rooms.contains(name) {
                rooms.append(name)
                entry["rooms"] = rooms
            }
        }
    }

    private func removeSavedRoom(_ name: String, forJID jid: String) {
        Self.mutateSavedAccount(jid: jid) { entry in
            var rooms = entry["rooms"] as? [String] ?? []
            rooms.removeAll { $0 == name }
            entry["rooms"] = rooms
        }
    }

    // MARK: - Keychain

    private static let keychainService = "com.xmpbee.app"

    private static func savePasswordToKeychain(_ password: String, for account: String) {
        guard let data = password.data(using: .utf8) else { return }

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadPasswordFromKeychain(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deletePasswordFromKeychain(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Account inspection / edit / delete

    /// The saved settings dict for a specific account (by JID).  Used by ConnectSheet's
    /// edit mode to pre-populate fields.  Returns nil if no account with that JID has
    /// been saved.
    func savedSettings(forJID jid: String) -> [String: Any]? {
        let accounts = Self.savedAccountsArray()
        return accounts.first { ($0["jid"] as? String) == jid }
    }

    /// Read the Keychain-stored password for a JID. Used by ConnectSheet's edit mode to
    /// pre-populate the password field so the user can see/edit it without having to re-enter.
    func savedPassword(for jid: String) -> String? {
        Self.loadPasswordFromKeychain(for: jid)
    }

    /// Save edits to an existing account. Disconnects whatever's currently connected for this
    /// server and reconnects using the new field values. Settings are persisted to UserDefaults
    /// and the password is written to Keychain.
    func updateAccount(
        server: Server,
        name: String, hostname: String, port: Int,
        jid: String, password: String,
        resource: String = "XMPBee",
        securityMode: SecurityMode = .requireTLS,
        nickname: String, conferenceServer: String, rooms: [String]
    ) {
        // Cancel any pending reconnect cycle from a prior dropped connection.
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        reconnectionAttempts[server.id] = 0
        manuallyDisconnected.remove(server.id)

        // Tear down the existing connection if any.
        if let client = clients[server.id] {
            client.disconnect()
        }

        // If the JID itself was changed, the saved entry under the old JID is now
        // orphaned — remove it (and its Keychain password) before saveSettings upserts
        // the new entry, so we don't end up with two array entries for the same Server.
        let oldJID = server.jid
        if oldJID != jid {
            var accounts = Self.savedAccountsArray()
            accounts.removeAll { ($0["jid"] as? String) == oldJID }
            Self.setSavedAccountsArray(accounts)
            Self.deletePasswordFromKeychain(for: oldJID)
        }

        // Update the in-memory Server model so the sidebar reflects the rename/host change.
        server.name = name
        server.hostname = hostname
        server.port = port
        server.jid = jid
        server.isConnected = false

        // Update the per-server pending config (nickname / conference server / room list).
        pendingConfig[server.id] = (nickname: nickname, confServer: conferenceServer, rooms: rooms)

        // Persist to UserDefaults + Keychain.
        saveSettings(
            name: name, hostname: hostname, port: port, jid: jid, password: password,
            resource: resource, securityMode: securityMode, nickname: nickname,
            conferenceServer: conferenceServer, rooms: rooms
        )

        // Surface the change in the UI before kicking the reconnect off.
        objectWillChange.send()

        // Reconnect using the new settings.  Reuse the existing XMPPClient where possible so
        // pendingIQCallbacks / message routing line up after the round-trip.
        let client = clients[server.id] ?? XMPPClient()
        if clients[server.id] == nil {
            client.delegate = self
            clients[server.id] = client
        }
        addSystemMessage(to: server, text: "Reconnecting with updated settings...")
        client.connect(
            host: hostname, port: port, jid: jid, password: password,
            resource: resource, securityMode: securityMode
        )
    }

    /// Permanently remove an account: disconnect, drop in-memory state, delete the saved
    /// settings dict (if it points at this account), and erase the Keychain password.
    func deleteAccount(_ server: Server) {
        // Disconnect and stop any pending reconnect timers.
        manuallyDisconnected.insert(server.id)
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        reconnectionAttempts[server.id] = 0
        if let client = clients[server.id] {
            client.disconnect()
        }

        // Drop in-memory client + config maps for this server.
        clients.removeValue(forKey: server.id)
        pendingConfig.removeValue(forKey: server.id)

        // Erase the Keychain entry for this account's JID.
        Self.deletePasswordFromKeychain(for: server.jid)

        // Remove only this account's entry from the saved-accounts array; other
        // accounts in the array stay put.
        var accounts = Self.savedAccountsArray()
        accounts.removeAll { ($0["jid"] as? String) == server.jid }
        Self.setSavedAccountsArray(accounts)

        // Remove from the sidebar and refresh the selection.
        servers.removeAll { $0.id == server.id }
        if selectedServer?.id == server.id {
            selectedServer = servers.first
            selectedRoom = selectedServer?.rooms.first
        }

        objectWillChange.send()
    }

    func selectRoom(_ room: Room, on server: Server) {
        // Defer all state changes to avoid publishing during view update
        DispatchQueue.main.async {
            self.selectedRoom = room
            self.selectedServer = server
            room.unreadCount = 0
        }
    }

    // MARK: - Messaging

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let room = selectedRoom, let server = selectedServer else { return }
        guard let client = clients[server.id] else { return }

        inputText = ""

        // Sending implies "I'm engaging now" — snap the transcript to the bottom
        // regardless of where the user had scrolled to. This also re-arms stickToBottom
        // so the inevitable echo back from the server keeps following.
        scrollToBottomTrigger &+= 1

        // Handle /me actions
        if text.hasPrefix("/me ") {
            let action = String(text.dropFirst(4))
            client.sendGroupMessage(to: room.jid, body: "/me \(action)")
        } else if text.hasPrefix("/topic ") {
            // Set topic (requires permission)
            let _ = String(text.dropFirst(7))
            // Send as subject change — simplified
            client.sendGroupMessage(to: room.jid, body: text)
        } else if text.hasPrefix("/join ") {
            let roomName = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let config = pendingConfig[server.id] {
                let roomJID = "\(roomName)@\(config.confServer)"
                joinSingleRoom(server: server, client: client, roomJID: roomJID, roomName: roomName, nickname: config.nickname)
                appendSavedRoom(roomName, forJID: server.jid)
            }
        } else if text.hasPrefix("/part") || text.hasPrefix("/leave") {
            client.leaveRoom(jid: room.jid, nickname: room.nickname)
            server.rooms.removeAll { $0.id == room.id }
            selectedRoom = server.rooms.first
        } else if text.hasPrefix("/msg ") {
            // /msg nick message — send a MUC private message
            let rest = String(text.dropFirst(5))
            if let spaceIdx = rest.firstIndex(of: " ") {
                let nick = String(rest[rest.startIndex..<spaceIdx])
                let body = String(rest[rest.index(after: spaceIdx)...])
                sendDM(to: nick, body: body, in: room, on: server)
            }
        } else if room.isDM {
            // In a DM tab, send as a direct chat message to nick@server
            client.sendDirectMessage(to: room.jid, body: text)
            let msg = ChatMessage(
                timestamp: Date(), sender: room.nickname, body: text,
                type: .chat, senderColor: ChatMessage.colorForNick(room.nickname)
            )
            room.messages.append(msg)
            objectWillChange.send()

            // Log outgoing DM
            LogManager.shared.logMessage(
                server: server.name,
                room: "DM-\(room.name)",
                timestamp: msg.timestamp,
                sender: room.nickname,
                body: text,
                type: "chat"
            )
        } else {
            client.sendGroupMessage(to: room.jid, body: text)
        }
    }

    // MARK: - Leave Room

    func leaveRoom(_ room: Room, on server: Server) {
        if room.isDM {
            // Remove from saved DM contacts
            removeSavedDM(room.name, forJID: server.jid)
        } else {
            // Send XMPP leave presence
            clients[server.id]?.leaveRoom(jid: room.jid, nickname: room.nickname)
            // Remove from saved rooms
            removeSavedRoom(room.name, forJID: server.jid)
        }
        // Remove from UI
        server.rooms.removeAll { $0.id == room.id }
        if selectedRoom?.id == room.id {
            selectedRoom = server.rooms.first
        }
        objectWillChange.send()
    }

    // MARK: - Join Room

    /// Join a new MUC room on the given server
    func joinNewRoom(name: String, on server: Server) {
        guard let client = clients[server.id],
              let config = pendingConfig[server.id] else { return }
        let roomJID = "\(name)@\(config.confServer)"
        guard !server.rooms.contains(where: { $0.jid == roomJID }) else { return }
        joinSingleRoom(server: server, client: client, roomJID: roomJID, roomName: name, nickname: config.nickname)
        objectWillChange.send()
        appendSavedRoom(name, forJID: server.jid)
    }

    /// Get the nickname we're using on a server
    func nickname(on server: Server) -> String? {
        pendingConfig[server.id]?.nickname
    }

    /// Fetch available rooms from the conference server
    func browseRooms(on server: Server) {
        guard let client = clients[server.id],
              let config = pendingConfig[server.id] else { return }
        isLoadingRooms = true
        discoveredRooms = []
        client.requestRoomList(from: config.confServer) { [weak self] rooms in
            self?.discoveredRooms = rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self?.isLoadingRooms = false
        }
    }

    // MARK: - DM Support

    /// Send a direct message to a user on the server
    func sendDM(to nick: String, body: String, in room: Room, on server: Server) {
        guard let client = clients[server.id] else { return }

        // DMs go to nick@server-domain (the user's bare JID)
        let dmJID = "\(nick)@\(server.domain)"
        client.sendDirectMessage(to: dmJID, body: body)

        let dmRoom = findOrCreateDMRoom(nick: nick, server: server)
        let msg = ChatMessage(
            timestamp: Date(), sender: room.nickname, body: body,
            type: .chat, senderColor: ChatMessage.colorForNick(room.nickname)
        )
        dmRoom.messages.append(msg)
        objectWillChange.send()
        selectedRoom = dmRoom
        selectedServer = server
    }

    /// Open a DM tab for a user (called from context menu or New DM button).
    /// No room parameter needed — DMs are created from server domain alone.
    func openDM(nick: String, on server: Server) {
        let dmRoom = findOrCreateDMRoom(nick: nick, server: server)
        selectedRoom = dmRoom
        selectedServer = server
    }

    private func findOrCreateDMRoom(nick: String, server: Server, save: Bool = true) -> Room {
        let dmJID = "\(nick)@\(server.domain)"
        // Check if we already have a DM tab for this user
        if let existing = server.rooms.first(where: { $0.isDM && $0.jid == dmJID }) {
            return existing
        }

        let nickname = pendingConfig[server.id]?.nickname ?? "me"
        let dmRoom = Room(jid: dmJID, name: nick, nickname: nickname)
        dmRoom.isDM = true
        dmRoom.initialPresenceComplete = true

        server.rooms.append(dmRoom)
        objectWillChange.send()
        if save { appendSavedDM(nick, forJID: server.jid) }

        // Load history on a background thread — file I/O + parsing must not block the main thread.
        // We don't capture `dmRoom` directly because Room is a non-Sendable class and the
        // background closure is @Sendable; instead we capture its UUID and re-resolve on the
        // main thread when we go to mutate.
        let serverName = server.name
        let serverID = server.id
        let dmRoomID = dmRoom.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let history = LogManager.shared.loadRecentHistory(
                server: serverName,
                room: "DM-\(nick)",
                days: 7,
                limit: 100
            )
            guard !history.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let server = self.servers.first(where: { $0.id == serverID }),
                      let room = server.rooms.first(where: { $0.id == dmRoomID }) else { return }
                // Insert before any real-time messages that may have arrived while loading
                room.messages.insert(contentsOf: history, at: 0)
                self.objectWillChange.send()
            }
        }

        return dmRoom
    }

    // MARK: - DM Contact Persistence

    private func appendSavedDM(_ nick: String, forJID jid: String) {
        #if DEBUG
        print("[DM] appendSavedDM called for: \(nick) on account \(jid)")
        #endif
        Self.mutateSavedAccount(jid: jid) { entry in
            var dms = entry["dmContacts"] as? [String] ?? []
            #if DEBUG
            print("[DM] Current DM contacts: \(dms)")
            #endif
            if !dms.contains(nick) {
                dms.append(nick)
                entry["dmContacts"] = dms
                #if DEBUG
                print("[DM] Saved DM contact. New list: \(dms)")
                #endif
            } else {
                #if DEBUG
                print("[DM] DM contact already exists, not saving")
                #endif
            }
        }
    }

    private func removeSavedDM(_ nick: String, forJID jid: String) {
        Self.mutateSavedAccount(jid: jid) { entry in
            var dms = entry["dmContacts"] as? [String] ?? []
            dms.removeAll { $0 == nick }
            entry["dmContacts"] = dms
        }
    }

    // MARK: - Internal Helpers

    private func server(for client: XMPPClient) -> Server? {
        for (id, c) in clients where c === client {
            return servers.first { $0.id == id }
        }
        return nil
    }

    private func myNickname(in room: Room) -> String {
        room.nickname
    }

    private func addSystemMessage(to server: Server, text: String) {
        guard let room = server.rooms.first else { return }
        // Suppress duplicate consecutive system messages (e.g. TLS firing multiple times)
        if room.messages.last?.body == text && room.messages.last?.type == .system { return }
        let msg = ChatMessage(
            timestamp: Date(), sender: "", body: text,
            type: .system, senderColor: .gray
        )
        room.messages.append(msg)
    }

    private func joinSingleRoom(server: Server, client: XMPPClient, roomJID: String, roomName: String, nickname: String) {
        // Check if room already exists (e.g., from a previous connection)
        if let existingRoom = server.rooms.first(where: { $0.jid == roomJID }) {
            // Reuse existing room to preserve message history
            existingRoom.messages.append(ChatMessage(
                timestamp: Date(), sender: "", body: "Rejoining \(existingRoom.displayName)...",
                type: .system, senderColor: .gray
            ))
            // Reset presence state to batch incoming presence updates during rejoin
            existingRoom.initialPresenceComplete = false
            existingRoom.pendingOccupants = []
            existingRoom.occupants = []
            client.joinRoom(jid: roomJID, nickname: nickname)
            return
        }

        // Create new room if it doesn't exist
        let room = Room(jid: roomJID, name: roomName, nickname: nickname)

        room.messages.append(ChatMessage(
            timestamp: Date(), sender: "", body: "Joining \(room.displayName)...",
            type: .system, senderColor: .gray
        ))
        server.rooms.append(room)

        if selectedRoom == nil {
            selectedRoom = room
            selectedServer = server
        }

        client.joinRoom(jid: roomJID, nickname: nickname)
    }

    // MARK: - XMPPClientDelegate

    nonisolated func xmppDidConnect(_ client: XMPPClient) {
        Task { @MainActor in
            guard let server = server(for: client) else { return }
            addSystemMessage(to: server, text: "Connected, negotiating TLS...")
        }
    }

    nonisolated func xmppDidAuthenticate(_ client: XMPPClient) {
        Task { @MainActor in
            await xmppDidAuthenticateMain(client)
        }
    }

    private func xmppDidAuthenticateMain(_ client: XMPPClient) async {
        guard let server = server(for: client) else { return }
        server.isConnected = true
        // Server is its own ObservableObject; the views observe viewModel, so
        // republish here to flip the input bar back on.
        objectWillChange.send()

        // Reset reconnection state on successful connection
        reconnectionAttempts[server.id] = 0
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil

        // Join configured rooms
        if let config = pendingConfig[server.id] {
            if config.rooms.isEmpty {
                let statusRoom = Room(jid: "", name: server.name, nickname: config.nickname)
                statusRoom.messages.append(ChatMessage(
                    timestamp: Date(), sender: "", body: "Connected to \(server.hostname) as \(client.boundJID)",
                    type: .system, senderColor: .gray
                ))
                server.rooms.append(statusRoom)
                if selectedRoom == nil {
                    selectedRoom = statusRoom
                    selectedServer = server
                }
            } else {
                // Join rooms with delays to avoid overwhelming SwiftUI during reconnect
                Task {
                    for (index, roomName) in config.rooms.enumerated() {
                        let roomJID = "\(roomName)@\(config.confServer)"
                        await MainActor.run {
                            joinSingleRoom(server: server, client: client, roomJID: roomJID, roomName: roomName, nickname: config.nickname)
                        }
                        // Small delay between joins to let SwiftUI process updates
                        if index < config.rooms.count - 1 {
                            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        }
                    }
                }
            }

            // Restore saved DMs with delays — scoped to *this* account, not the
            // legacy singular settings dict.
            if let accountDict = savedSettings(forJID: server.jid),
               let dmContacts = accountDict["dmContacts"] as? [String], !dmContacts.isEmpty {
                #if DEBUG
                print("[DM] Restoring \(dmContacts.count) DM contact(s): \(dmContacts)")
                #endif
                addSystemMessage(to: server, text: "Restoring \(dmContacts.count) DM contact(s)...")
                Task {
                    for (index, nick) in dmContacts.enumerated() {
                        await MainActor.run {
                            _ = findOrCreateDMRoom(nick: nick, server: server, save: false)
                        }
                        // Small delay between DM restorations
                        if index < dmContacts.count - 1 {
                            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        }
                    }
                }
            } else {
                #if DEBUG
                print("[DM] No DMs to restore (dmContacts empty or missing)")
                #endif
            }
        }
    }

    nonisolated func xmppDidDisconnect(_ client: XMPPClient, error: Error?) {
        Task { @MainActor in
            guard let server = server(for: client) else { return }
            server.isConnected = false
            // Same reason as in xmppDidAuthenticateMain — publish so the input bar
            // observes the state flip and disables.
            objectWillChange.send()
            let reason = error?.localizedDescription ?? "Connection closed"
            addSystemMessage(to: server, text: "Disconnected: \(reason)")

            // Only attempt automatic reconnection if not manually disconnected
            if !manuallyDisconnected.contains(server.id) {
                scheduleReconnection(for: server)
            }
        }
    }

    nonisolated func xmpp(_ client: XMPPClient, didReceiveMessage message: XMPPIncomingMessage) {
        Task { @MainActor in
            await xmppDidReceiveMessageMain(client, message: message)
        }
    }

    private func xmppDidReceiveMessageMain(_ client: XMPPClient, message: XMPPIncomingMessage) async {
        guard let server = server(for: client) else { return }

        let fullFrom = message.from
        let parts = fullFrom.components(separatedBy: "/")
        let roomJID = parts.first ?? fullFrom
        let nick = parts.count > 1 ? parts[1] : fullFrom

        // Handle incoming DMs (type="chat" from user@server or user@server/resource)
        if message.type == "chat" {
            // Extract the bare JID (nick@server) — the sender
            let bareFrom = roomJID  // parts[0] = "nick@server"
            let senderNick = bareFrom.components(separatedBy: "@").first ?? bareFrom

            let dmRoom = findOrCreateDMRoom(nick: senderNick, server: server)
            let timestamp = message.timestamp ?? Date()
            let chatMsg = ChatMessage(
                timestamp: timestamp, sender: senderNick, body: message.body,
                type: .chat, senderColor: ChatMessage.colorForNick(senderNick)
            )

            // Deduplicate DM history messages against loaded log history
            if message.isDelayed {
                let isDuplicate = dmRoom.messages.contains { existing in
                    existing.sender == chatMsg.sender &&
                    existing.body == chatMsg.body &&
                    abs(existing.timestamp.timeIntervalSince(chatMsg.timestamp)) < 2.0
                }
                if isDuplicate {
                    return // Skip duplicate history message
                }
            }

            dmRoom.messages.append(chatMsg)
            objectWillChange.send()

            // Log DM to disk
            // If it was a duplicate, we already returned early, so if we're here it's new
            LogManager.shared.logMessage(
                server: server.name,
                room: "DM-\(senderNick)",
                timestamp: timestamp,
                sender: senderNick,
                body: message.body,
                type: "chat"
            )

            // Only badge real-time messages as unread, not history
            if dmRoom.id != selectedRoom?.id && !message.isDelayed {
                dmRoom.unreadCount += 1
            }
            notifications.notifyDirectMessage(sender: senderNick, body: message.body)
            if notifications.playSound {
                notifications.playAlertSound()
            }
            return
        }

        guard let room = server.rooms.first(where: { $0.jid == roomJID }) else { return }

        let timestamp = message.timestamp ?? Date()

        // Detect /me actions
        let isAction = message.body.hasPrefix("/me ")
        let body = isAction ? String(message.body.dropFirst(4)) : message.body
        let type: ChatMessage.MessageType = isAction ? .action : .chat

        let chatMsg = ChatMessage(
            timestamp: timestamp,
            sender: nick,
            body: body,
            type: type,
            senderColor: ChatMessage.colorForNick(nick)
        )

        // Deduplicate: if this is delayed (history) message, check if we already have it
        if message.isDelayed {
            let isDuplicate = room.messages.contains { existing in
                existing.sender == chatMsg.sender &&
                existing.body == chatMsg.body &&
                abs(existing.timestamp.timeIntervalSince(chatMsg.timestamp)) < 2.0
            }
            if isDuplicate {
                return // Skip duplicate history message
            }
        }

        room.messages.append(chatMsg)
        objectWillChange.send()

        // Log to disk
        // If it was a duplicate, we already returned early, so if we're here it's new
        LogManager.shared.logMessage(
            server: server.name,
            room: room.name,
            timestamp: timestamp,
            sender: nick,
            body: body,
            type: type == .chat ? "chat" : "action"
        )

        // Only badge real-time messages as unread, not history
        if room.id != selectedRoom?.id && !message.isDelayed {
            room.unreadCount += 1
        }

        // --- Notifications ---
        let isFromMe = nick == room.nickname
        let isHistory = message.isDelayed

        if !isFromMe && !isHistory {
            let mentionsMe = body.localizedCaseInsensitiveContains(room.nickname)

            if message.type == "groupchat" {
                notifications.notifyGroupMessage(
                    room: room.displayName,
                    sender: nick,
                    body: body,
                    mentionsMe: mentionsMe
                )

                // Play in-app sound for mentions even when focused
                if mentionsMe && notifications.playSound {
                    notifications.playAlertSound()
                }
            } else if message.type == "chat" {
                notifications.notifyDirectMessage(sender: nick, body: body)

                // Always play sound for DMs
                if notifications.playSound {
                    notifications.playAlertSound()
                }
            }
        }
    }

    nonisolated func xmpp(_ client: XMPPClient, didReceivePresence presence: XMPPPresence) {
        Task { @MainActor in
            await xmppDidReceivePresenceMain(client, presence: presence)
        }
    }

    private func xmppDidReceivePresenceMain(_ client: XMPPClient, presence: XMPPPresence) async {
        guard let server = server(for: client) else { return }
        guard let roomJID = presence.roomJID, let nick = presence.nick else { return }
        guard let room = server.rooms.first(where: { $0.jid == roomJID }) else { return }

        let affiliation: Occupant.Affiliation = {
            switch presence.affiliation {
            case "owner": return .owner
            case "admin": return .admin
            case "member": return .member
            case "outcast": return .outcast
            default: return .none
            }
        }()

        let role: Occupant.Role = {
            switch presence.role {
            case "moderator": return .moderator
            case "participant": return .participant
            case "visitor": return .visitor
            default: return .none
            }
        }()

        if presence.type == "unavailable" {
            room.occupants.removeAll { $0.nick == nick }
            if room.initialPresenceComplete {
                let msg = ChatMessage(
                    timestamp: Date(), sender: nick, body: "",
                    type: .part, senderColor: ChatMessage.colorForNick(nick)
                )
                room.messages.append(msg)
                notifications.notifyJoinPart(room: room.displayName, user: nick, joined: false)
            }
        } else {
            let occupant = Occupant(nick: nick, affiliation: affiliation, role: role)

            if !room.initialPresenceComplete {
                // During initial flood, buffer occupants without triggering @Published
                if !room.pendingOccupants.contains(where: { $0.nick == nick }) {
                    room.pendingOccupants.append(occupant)
                }

                // Self-presence (status 110) means flood is over — flush the batch
                if presence.isSelfPresence {
                    room.occupants = room.pendingOccupants.sorted()
                    room.pendingOccupants = []
                    room.initialPresenceComplete = true

                    let msg = ChatMessage(
                        timestamp: Date(), sender: "",
                        body: "Joined \(room.displayName) (\(room.occupants.count) users)",
                        type: .system, senderColor: .gray
                    )
                    room.messages.append(msg)
                    // Don't log our own join events
                }
            } else {
                // Normal post-join presence
                let existing = room.occupants.first { $0.nick == nick }
                if existing == nil {
                    // Insert in sorted position — keeps the list sorted so the view doesn't have to
                    let insertIdx = room.occupants.firstIndex(where: { occupant < $0 }) ?? room.occupants.endIndex
                    room.occupants.insert(occupant, at: insertIdx)
                    let msg = ChatMessage(
                        timestamp: Date(), sender: nick, body: "",
                        type: .join, senderColor: ChatMessage.colorForNick(nick)
                    )
                    room.messages.append(msg)
                    notifications.notifyJoinPart(room: room.displayName, user: nick, joined: true)
                }
            }
        }
        objectWillChange.send()
    }

    nonisolated func xmpp(_ client: XMPPClient, didReceiveRoomSubject subject: String, room roomJID: String) {
        Task { @MainActor in
            guard let server = server(for: client) else { return }
            guard let room = server.rooms.first(where: { $0.jid == roomJID }) else { return }

            room.topic = subject
            // Only show topic in chat once per session, not on every reconnect
            if !subject.isEmpty && !room.hasDisplayedTopic {
                let msg = ChatMessage(
                    timestamp: Date(), sender: "", body: subject,
                    type: .topic, senderColor: .gray
                )
                room.messages.append(msg)
                room.hasDisplayedTopic = true
                // Scroll to bottom after initial connect sequence completes
                scrollToBottomTrigger += 1
                // Don't log topics - they're sent on every join and aren't chat messages
            }
            objectWillChange.send()
        }
    }

    nonisolated func xmpp(_ client: XMPPClient, didFailWithError error: XMPPError) {
        Task { @MainActor in
            errorMessage = "\(error)"
            showError = true
        }
    }
}
