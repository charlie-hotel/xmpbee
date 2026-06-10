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
    @Published var showUserSearch = false
    @Published var discoveredUsers: [(jid: String, nick: String, name: String)] = []
    @Published var isSearchingUsers = false
    @Published var userSearchError: String? = nil
    /// Per-server cache of the disco-detected XEP-0055 search service JID, so we don't
    /// re-discover on every keystroke.  Cleared on disconnect / reconnect of a server.
    private var userSearchServices: [UUID: String] = [:]
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

    /// MUC membership watchdog (XEP-0410 self-ping). One app-wide repeating sweep;
    /// per-room rejoin cooldown is the primary defense against rejoin loops.
    private var mucSelfPingTimer: Timer?
    private var mucRejoinCooldown: [UUID: Date] = [:]
    private static let mucSelfPingInterval: TimeInterval = 300
    private static let mucRejoinCooldownInterval: TimeInterval = 600

    /// iOS app-lifecycle reconnect intent.  When the app is backgrounded we close
    /// sockets cleanly but record (per-server) that we WANT to be connected again
    /// once foregrounded.  This is deliberately distinct from `manuallyDisconnected`
    /// — backgrounding must NOT permanently mark a server as user-disconnected, or
    /// it would never auto-reconnect.  Only iOS App.swift drives this (via
    /// `handleScenePhase`); macOS leaves it empty.
    private var wantsConnected: Set<UUID> = []
    /// Servers whose sockets we closed because the app is backgrounded.  Used in the
    /// `xmppDidDisconnect` delegate to suppress `scheduleReconnection` (a timer can't
    /// fire while the process is suspended), without marking them user-disconnected.
    private var backgroundedDisconnects: Set<UUID> = []
    /// Whether the app is currently foreground (iOS).  Gates the background-disconnect
    /// delegate so it auto-reconnects only once we're actually `.active`, never during
    /// the brief window between `.background` and process suspension.  macOS never sets
    /// this (and never enters the backgrounded-disconnect branch), so it's a no-op there.
    private var isForeground = true

    /// UI-only projection of reconnect state for the iOS banner.  This is NOT a
    /// second backoff counter — `reconnectionAttempts` remains the single source of
    /// truth for backoff.  This dict is updated in lockstep with the existing
    /// reconnect transition points so the two can't drift.
    enum ReconnectUIState {
        case attempting
        case failed
    }
    @Published var reconnectStatus: [UUID: ReconnectUIState] = [:]

    init() {
        startMUCSelfPingWatchdog()
    }

    // MARK: - MUC Membership Watchdog (XEP-0410)

    /// Periodically self-ping every joined MUC to detect the server having silently
    /// dropped us as an occupant (the connection itself can stay healthy — DMs and
    /// keepalive pings keep flowing — so the c2s keepalive never notices).
    ///
    /// Rejoin-loop defenses, layered:
    ///   • only a definitive <not-acceptable/> triggers a rejoin (timeouts fire no
    ///     callback at all; other errors are inconclusive no-ops)
    ///   • per-room cooldown: at most one auto-rejoin per `mucRejoinCooldownInterval`
    ///   • rooms mid-join (`initialPresenceComplete == false`) are never pinged, so a
    ///     rejoin in flight can't be re-triggered
    private func startMUCSelfPingWatchdog() {
        mucSelfPingTimer = Timer.scheduledTimer(withTimeInterval: Self.mucSelfPingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepMUCMemberships() }
        }
    }

    private func sweepMUCMemberships() {
        for server in servers where server.isConnected {
            guard let client = clients[server.id] else { continue }
            let rooms = server.rooms.filter { !$0.isDM && !$0.jid.isEmpty && $0.initialPresenceComplete }
            for (index, room) in rooms.enumerated() {
                let roomID = room.id
                let roomJID = room.jid
                let nick = room.nickname
                // Stagger so N rooms don't burst N IQs at once.
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.0) { [weak self, weak server, weak client] in
                    guard let self, let server, let client, server.isConnected else { return }
                    client.pingOccupant(roomJID: roomJID, nick: nick) { [weak self, weak server, weak client] result in
                        guard result == .notJoined, let self, let server, let client else { return }
                        Task { @MainActor in
                            self.rejoinDroppedMUC(roomID: roomID, server: server, client: client)
                        }
                    }
                }
            }
        }
    }

    private func rejoinDroppedMUC(roomID: UUID, server: Server, client: XMPPClient) {
        guard server.isConnected,
              let room = server.rooms.first(where: { $0.id == roomID }),
              !room.isDM, room.initialPresenceComplete else { return }
        if let last = mucRejoinCooldown[roomID],
           Date().timeIntervalSince(last) < Self.mucRejoinCooldownInterval { return }
        mucRejoinCooldown[roomID] = Date()

        room.messages.append(ChatMessage(
            timestamp: Date(), sender: "",
            body: "Server dropped us from \(room.displayName), rejoining...",
            type: .system, senderColor: .gray
        ))
        room.initialPresenceComplete = false
        room.pendingOccupants = []
        room.occupants = []
        client.joinRoom(jid: room.jid, nickname: room.nickname)
        objectWillChange.send()
    }

    // MARK: - Server Management

    func addServerAndConnect(
        name: String, hostname: String, port: Int,
        jid: String, password: String,
        resource: String = Platform.defaultResource,
        priority: Int = 0,
        securityMode: SecurityMode = .requireTLS,
        nickname: String, conferenceServer: String, rooms: [String]
    ) {
        // Create server WITHOUT password (security: passwords not stored in Server objects)
        let server = Server(name: name, hostname: hostname, port: port, jid: jid)
        servers.append(server)

        // Load this account's persisted blocklist immediately (not just on auth) so it's
        // enforced from the first stanza AND visible in Settings while disconnected. A
        // brand-new account has no saved dict yet, so the sets come back empty.
        if let dict = savedSettings(forJID: jid) {
            server.blockedJIDs = Set((dict["blockedJIDs"] as? [String] ?? []).map { $0.lowercased() })
            server.blockedNicks = Set(dict["blockedNicks"] as? [String] ?? [])
        }

        pendingConfig[server.id] = (nickname: nickname, confServer: conferenceServer, rooms: rooms)

        let client = XMPPClient()
        client.delegate = self
        clients[server.id] = client

        addSystemMessage(to: server, text: "Connecting to \(hostname):\(port) (\(securityMode))...")

        // Password is passed directly to client and will be cleared after auth
        client.connect(host: hostname, port: port, jid: jid, password: password,
                       resource: resource, priority: priority, securityMode: securityMode)

        // Save settings for next launch (password goes to Keychain, not Server object)
        saveSettings(name: name, hostname: hostname, port: port, jid: jid, password: password,
                     resource: resource, priority: priority, securityMode: securityMode, nickname: nickname,
                     conferenceServer: conferenceServer, rooms: rooms)

        // Reset reconnection attempts for new connections
        reconnectionAttempts[server.id] = 0
    }

    // MARK: - Reconnection

    private func scheduleReconnection(for server: Server) {
        let attempts = reconnectionAttempts[server.id] ?? 0

        guard attempts < maxReconnectionAttempts else {
            logConnectionEvent(to: server, "Max reconnection attempts reached. Click ⚡ to reconnect.")
            // UI projection: backoff exhausted — show the failed/Retry banner.
            reconnectStatus[server.id] = .failed
            return
        }

        // Exponential backoff: 2^attempts seconds (2, 4, 8, 16, 32 seconds)
        let delay = min(pow(2.0, Double(attempts)), 32.0)
        reconnectionAttempts[server.id] = attempts + 1
        // UI projection: a reconnect is now in flight.
        reconnectStatus[server.id] = .attempting

        logConnectionEvent(to: server, "Reconnecting in \(Int(delay))s... (attempt \(attempts + 1)/\(maxReconnectionAttempts))")

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
            logConnectionEvent(to: server, "Reconnection failed: missing credentials")
            // UI projection: no in-flight attempt — surface the failed/Retry banner
            // instead of leaving a stale spinner.
            reconnectStatus[server.id] = .failed
            return
        }

        var password = pw
        defer { password = "" }

        // UI projection: a reconnect attempt is in flight (cleared on success in
        // xmppDidAuthenticateMain, or flipped to .failed by scheduleReconnection).
        reconnectStatus[server.id] = .attempting

        logConnectionEvent(to: server, "Reconnecting to \(server.hostname):\(server.port)...")

        let hostname = dict["hostname"] as? String ?? server.hostname
        let port = dict["port"] as? Int ?? server.port
        let resource = dict["resource"] as? String ?? Platform.defaultResource
        let priority = dict["priority"] as? Int ?? 0
        let modeRaw = dict["securityMode"] as? String ?? "requireTLS"
        let securityMode = SecurityMode(rawValue: modeRaw) ?? .requireTLS

        // Get existing client or create new one
        let client = clients[server.id] ?? XMPPClient()
        if clients[server.id] == nil {
            client.delegate = self
            clients[server.id] = client
        }

        client.connect(host: hostname, port: port, jid: jid, password: password,
                       resource: resource, priority: priority, securityMode: securityMode)
    }

    func manualReconnect(server: Server) {
        // Remove from manually disconnected set
        manuallyDisconnected.remove(server.id)

        // Reset reconnection attempts on manual reconnect
        reconnectionAttempts[server.id] = 0
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        // UI projection: clear any .failed state; reconnect(server:) sets .attempting.
        reconnectStatus[server.id] = .attempting
        reconnect(server: server)
    }

    func disconnect(server: Server) {
        // Mark as manually disconnected
        manuallyDisconnected.insert(server.id)
        // User-initiated disconnect overrides any background reconnect intent.
        wantsConnected.remove(server.id)
        backgroundedDisconnects.remove(server.id)

        // Cancel any pending reconnection attempts
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        // UI projection: user disconnected — no banner for this server.
        reconnectStatus.removeValue(forKey: server.id)

        // Update UI immediately
        server.isConnected = false
        objectWillChange.send()
        addSystemMessage(to: server, text: "Disconnecting...")

        // Disconnect the client (will trigger xmppDidDisconnect delegate)
        if let client = clients[server.id] {
            client.disconnect()
        }
    }

    // MARK: - App Lifecycle (iOS)

    /// React to iOS scene-phase changes.  Called ONLY from the iOS App.swift via
    /// `.onChange(of: scenePhase)`; macOS never invokes this (the method still
    /// compiles there because the file is shared and SwiftUI's `ScenePhase` is
    /// cross-platform).
    ///
    /// - `.background`: the process is about to be suspended.  Remember which
    ///   servers we want to keep connected, cancel pending reconnect timers (they
    ///   can't fire while suspended), and close sockets cleanly — WITHOUT marking
    ///   the server user-disconnected, so we auto-reconnect on return.
    /// - `.active`: reconnect once for each server we wanted connected that isn't.
    /// - `.inactive`: transient state (e.g. app switcher) — no-op.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isForeground = false
            for server in servers where server.isConnected {
                // Record intent to reconnect on return.
                wantsConnected.insert(server.id)
                // A pending backoff timer can't fire while suspended; cancel it so
                // there's a single reconnect path (the .active handler below).  Keep
                // `reconnectionAttempts` as-is (single backoff source of truth).
                reconnectionTimers[server.id]?.invalidate()
                reconnectionTimers[server.id] = nil
                // Close the socket cleanly via the existing client path.  Mark it as
                // a backgrounded disconnect so the xmppDidDisconnect delegate skips
                // scheduleReconnection — distinct from `manuallyDisconnected`.
                backgroundedDisconnects.insert(server.id)
                clients[server.id]?.disconnect()
            }

        case .active:
            isForeground = true
            for server in servers where wantsConnected.contains(server.id) && !server.isConnected {
                wantsConnected.remove(server.id)
                // Belt-and-suspenders: cancel any stray pending timer so we don't
                // double-connect (one explicit reconnect below is the single path).
                reconnectionTimers[server.id]?.invalidate()
                reconnectionTimers[server.id] = nil
                // Fresh foreground attempt — reset the backoff counter (single source
                // of truth) and reconnect once.  reconnect(server:) sets the UI
                // projection to .attempting.
                reconnectionAttempts[server.id] = 0
                reconnect(server: server)
            }
            // Keep reconnect intent ONLY for servers whose background-disconnect
            // delegate hasn't fired yet (they still read as connected here); the
            // gated branch in xmppDidDisconnect reconnects those once the socket
            // finishes closing.  Genuinely still-connected servers drop their intent.
            wantsConnected = wantsConnected.filter { backgroundedDisconnects.contains($0) }

        case .inactive:
            break

        @unknown default:
            break
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
                              jid: String, password: String, resource: String, priority: Int,
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
        entry["priority"] = priority
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
            let resource = dict["resource"] as? String ?? Platform.defaultResource
            let priority = dict["priority"] as? Int ?? 0
            let modeRaw = dict["securityMode"] as? String ?? "requireTLS"
            let securityMode = SecurityMode(rawValue: modeRaw) ?? .requireTLS
            let nickname = dict["nickname"] as? String ?? ""
            let conferenceServer = dict["conferenceServer"] as? String ?? ""
            let rooms = dict["rooms"] as? [String] ?? []

            addServerAndConnect(
                name: name, hostname: hostname, port: port,
                jid: jid, password: password, resource: resource, priority: priority,
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

    /// Base attributes that identify a Keychain entry for an account.  Used as the
    /// matching query for both lookup and update.
    ///
    /// We deliberately do NOT set `kSecUseDataProtectionKeychain: true`.  On macOS
    /// the data-protection keychain requires `keychain-access-groups` entitlement
    /// for unsandboxed apps; without it, writes can silently fail with
    /// errSecMissingEntitlement and leave the user with no saved password (which
    /// looks like "settings aren't being persisted" from their side).  The legacy
    /// macOS keychain is the unsandboxed default and works for any signed app.
    /// If XMPBee adds proper entitlements later, opting back into the
    /// data-protection keychain is a one-line change here.
    private static func keychainBaseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func savePasswordToKeychain(_ password: String, for account: String) {
        guard let data = password.data(using: .utf8) else { return }

        // Try to update an existing entry first; only fall back to add if no entry
        // exists yet.  Compared to the older delete-then-add pattern, this is atomic
        // — there's no window where the entry is briefly absent (e.g. if the process
        // is killed between the delete and the add), and it avoids touching access
        // control attributes on an existing entry.
        let matchQuery = keychainBaseQuery(for: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            // `WhenUnlocked` (not `WhenUnlockedThisDeviceOnly`) keeps the door open
            // for opting future entries into iCloud Keychain sync by flipping
            // `kSecAttrSynchronizable` on writes.  `ThisDeviceOnly` would foreclose
            // that option — entries written under it can't later be made syncable
            // without rewriting each one.  The entry is still local-only today
            // since we don't set kSecAttrSynchronizable.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // No entry yet — add one.
            var addQuery = matchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func loadPasswordFromKeychain(for account: String) -> String? {
        var query = keychainBaseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deletePasswordFromKeychain(for account: String) {
        SecItemDelete(keychainBaseQuery(for: account) as CFDictionary)
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
        resource: String = Platform.defaultResource,
        priority: Int = 0,
        securityMode: SecurityMode = .requireTLS,
        nickname: String, conferenceServer: String, rooms: [String]
    ) {
        // Cancel any pending reconnect cycle from a prior dropped connection.
        reconnectionTimers[server.id]?.invalidate()
        reconnectionTimers[server.id] = nil
        reconnectionAttempts[server.id] = 0
        reconnectStatus.removeValue(forKey: server.id)
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
            resource: resource, priority: priority, securityMode: securityMode, nickname: nickname,
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
            resource: resource, priority: priority, securityMode: securityMode
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
        reconnectStatus.removeValue(forKey: server.id)
        if let client = clients[server.id] {
            client.disconnect()
        }

        // Drop in-memory client + config maps for this server.
        clients.removeValue(forKey: server.id)
        pendingConfig.removeValue(forKey: server.id)
        userSearchServices.removeValue(forKey: server.id)

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
            // In a DM (or MUC PM) tab.  For both, the reply target is room.jid:
            //   • Regular DM: jid is "nick@server" (the recipient's bare JID).
            //   • MUC PM (isMUCPM=true): jid is "room@service/nick" (the full
            //     occupant JID, per XEP-0045 §7.5).
            // sendDirectMessage sends type="chat" to that address, which is
            // correct in both cases.
            client.sendDirectMessage(to: room.jid, body: text)
            let msg = ChatMessage(
                timestamp: Date(), sender: room.nickname, body: text,
                type: .chat, senderColor: ChatMessage.colorForNick(room.nickname)
            )
            room.messages.append(msg)
            objectWillChange.send()

            // Log outgoing message under a path that distinguishes MUC PMs from
            // regular DMs (different identity model — see findOrCreateMUCPMRoom).
            let logRoom = room.isMUCPM ? "MUCPM-\(room.name)" : "DM-\(room.name)"
            LogManager.shared.logMessage(
                server: server.name,
                room: logRoom,
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
            // Regular DMs persist as dmContacts and need an explicit removal.
            // MUC PMs are intentionally not persisted (room-scoped identity), so
            // there's nothing to remove for them.
            if !room.isMUCPM {
                removeSavedDM(room.name, forJID: server.jid)
            }
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

    /// XEP-0055 user search against the server's directory service.  Discovers the
    /// search service on first use (cached per-server thereafter), then sends the term
    /// and publishes the results into `discoveredUsers` for the popover to render.
    ///
    /// IQ callbacks come back on the main thread (XMLStreamParser dispatches via
    /// DispatchQueue.main.async before invoking handleIQ), so this routine doesn't
    /// need to hop the actor explicitly — same pattern as browseRooms.
    func searchUsers(query: String, on server: Server) {
        guard let client = clients[server.id] else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        userSearchError = nil
        discoveredUsers = []
        guard !trimmed.isEmpty else { return }

        isSearchingUsers = true

        let runSearch: (String) -> Void = { [weak self] serviceJID in
            guard let self = self else { return }
            client.searchUsers(at: serviceJID, query: trimmed) { [weak self] results, error in
                guard let self = self else { return }
                self.isSearchingUsers = false
                self.userSearchError = error
                self.discoveredUsers = results.sorted {
                    // Sort by display name, falling back to nick, then JID.
                    let lhs = $0.name.isEmpty ? ($0.nick.isEmpty ? $0.jid : $0.nick) : $0.name
                    let rhs = $1.name.isEmpty ? ($1.nick.isEmpty ? $1.jid : $1.nick) : $1.name
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
            }
        }

        if let cached = userSearchServices[server.id] {
            runSearch(cached)
            return
        }

        client.discoverUserSearchService(on: server.domain) { [weak self] serviceJID in
            guard let self = self else { return }
            guard let serviceJID = serviceJID else {
                self.isSearchingUsers = false
                self.userSearchError = "This server doesn't advertise a user search service."
                return
            }
            self.userSearchServices[server.id] = serviceJID
            runSearch(serviceJID)
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

    /// Find or create a Room representing a MUC private-message thread (XEP-0045 §7.5).
    ///
    /// The Room's `jid` is the FULL occupant JID (`room@service/nick`) — that's what
    /// `sendMessage`'s DM branch will send back to, which is the correct reply target
    /// per XEP-0045 §7.5.  Crucially we do NOT call `appendSavedDM` here: MUC
    /// participant JIDs are room-scoped and shouldn't be persisted as long-term
    /// contacts (the participant disappears when they leave the room or change nicks).
    private func findOrCreateMUCPMRoom(
        replyJID: String,
        peerNick: String,
        roomLabel: String,
        server: Server
    ) -> Room {
        // Look up by full reply JID, restricted to MUC PM rooms so we don't
        // collide with a real DM that happens to share part of the name.
        if let existing = server.rooms.first(where: { $0.isMUCPM && $0.jid == replyJID }) {
            return existing
        }

        let nickname = pendingConfig[server.id]?.nickname ?? "me"
        let pm = Room(jid: replyJID, name: "\(peerNick) @ \(roomLabel)", nickname: nickname)
        pm.isDM = true
        pm.isMUCPM = true
        pm.initialPresenceComplete = true
        server.rooms.append(pm)
        objectWillChange.send()
        return pm
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

    // MARK: - Blocking
    //
    // Client-side blocking, scoped per account. JIDs block DM/roster contacts;
    // nicks block MUC participants server-wide (Occupant carries no real JID, so
    // MUC blocking can only key on the nick). Enforcement lives in the message and
    // presence handlers; these methods own the model, persistence, and purge.

    func blockJID(_ jid: String, on server: Server) {
        let key = jid.lowercased()
        guard key != server.jid.lowercased() else { return }   // can't block yourself
        guard server.blockedJIDs.insert(key).inserted else { return }
        appendSavedBlock(key, field: "blockedJIDs", forJID: server.jid)
        objectWillChange.send()
        // The DM thread is deliberately kept (just marked blocked); new inbound
        // messages from this JID are dropped by xmppDidReceiveMessageMain.
    }

    func unblockJID(_ jid: String, on server: Server) {
        let key = jid.lowercased()
        guard server.blockedJIDs.remove(key) != nil else { return }
        removeSavedBlock(key, field: "blockedJIDs", forJID: server.jid)
        objectWillChange.send()
    }

    func blockNick(_ nick: String, on server: Server) {
        guard !isOwnNick(nick, on: server) else { return }     // can't block yourself
        guard server.blockedNicks.insert(nick).inserted else { return }
        appendSavedBlock(nick, field: "blockedNicks", forJID: server.jid)
        // Non-destructive: their occupant entries and messages stay in the model and
        // are hidden by the views, so unblock reveals them again instantly.
        objectWillChange.send()
    }

    func unblockNick(_ nick: String, on server: Server) {
        guard server.blockedNicks.remove(nick) != nil else { return }
        removeSavedBlock(nick, field: "blockedNicks", forJID: server.jid)
        objectWillChange.send()
    }

    /// Count of a room's occupants excluding nicks blocked on its owning server.
    func visibleOccupantCount(in room: Room) -> Int {
        guard let server = servers.first(where: { $0.rooms.contains { $0.id == room.id } }) else {
            return room.occupants.count
        }
        return room.occupants.filter { !server.isBlocked(nick: $0.nick) }.count
    }

    /// True if `nick` is our own nick on this server (the configured nick or any
    /// joined room's nick). Guards against blocking yourself.
    private func isOwnNick(_ nick: String, on server: Server) -> Bool {
        if let mine = nickname(on: server), nick == mine { return true }
        return server.rooms.contains { !$0.isDM && $0.nickname == nick }
    }

    private func appendSavedBlock(_ value: String, field: String, forJID jid: String) {
        Self.mutateSavedAccount(jid: jid) { entry in
            var list = entry[field] as? [String] ?? []
            if !list.contains(value) {
                list.append(value)
                entry[field] = list
            }
        }
    }

    private func removeSavedBlock(_ value: String, field: String, forJID jid: String) {
        Self.mutateSavedAccount(jid: jid) { entry in
            var list = entry[field] as? [String] ?? []
            list.removeAll { $0 == value }
            entry[field] = list
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

    /// Automatic reconnect/backoff events are intentionally NOT written into the chat
    /// transcript on any platform — connection state is surfaced out-of-band via
    /// `reconnectStatus` (the sidebar connection dot / ⚡ reconnect button on macOS, the
    /// reconnect banner on iOS). Kept as the single policy hook for these events.
    private func logConnectionEvent(to server: Server, _ text: String) {
        // no-op — see doc comment
    }

    private func joinSingleRoom(server: Server, client: XMPPClient, roomJID: String, roomName: String, nickname: String) {
        // Check if MUC already exists (e.g., from a previous connection).  Filter
        // !isDM so a DM tab whose constructed JID coincidentally matches the MUC
        // address can't get promoted/reused as a MUC.
        if let existingRoom = server.rooms.first(where: { !$0.isDM && $0.jid == roomJID }) {
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
        // UI projection: connected — clear any reconnect banner state.
        reconnectStatus.removeValue(forKey: server.id)

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
            logConnectionEvent(to: server, "Disconnected: \(reason)")

            // If this disconnect was caused by backgrounding the app, don't schedule
            // a reconnection timer — it can't fire while the process is suspended,
            // and we'll reconnect once on .active.  Consume the marker; the server
            // stays in `wantsConnected` so the foreground path knows to reconnect.
            if backgroundedDisconnects.remove(server.id) != nil {
                // The socket finished closing.  If we're already foreground and still
                // want this server connected, reconnect now — the `.active` handler
                // may have run before this delegate (the server still read as connected
                // then) and skipped it.  If still backgrounded, leave the intent for
                // `.active` to act on, so we never connect during suspension.
                if isForeground, wantsConnected.remove(server.id) != nil {
                    reconnectionAttempts[server.id] = 0
                    reconnect(server: server)
                }
                return
            }

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

        // Delivery failure (type="error"): the server bounced one of OUR messages,
        // echoing it back with an <error/>. Surface it in the thread it belongs to
        // (full-JID match catches MUC-PM tabs, bare-JID match catches DMs and MUCs)
        // instead of rendering the echoed body as if the peer had sent it.
        if message.type == "error" {
            if let target = server.rooms.first(where: { $0.jid == fullFrom })
                         ?? server.rooms.first(where: { $0.jid == roomJID }) {
                target.messages.append(ChatMessage(
                    timestamp: Date(), sender: "",
                    body: "Message could not be delivered.",
                    type: .system, senderColor: .gray
                ))
                objectWillChange.send()
            }
            return
        }

        // Handle incoming type="chat" messages.  Two cases:
        //   1. MUC private message (XEP-0045 §7.5) — from = "room@service/nick".
        //      The bare-JID portion is a ROOM, not a user.  Reply target is the
        //      full occupant JID, NOT a constructed user JID.
        //   2. Regular DM — from = "user@server[/resource]".  Bare JID identifies
        //      the user account; reply target is that bare JID.
        if message.type == "chat" {
            let bareFrom = roomJID  // parts[0]

            // MUC PM detection:
            //   • Primary: server tagged the stanza with <x xmlns="…muc#user"/>.
            //   • Fallback: the bare JID matches a MUC the client has joined.
            // Both checks are needed — some servers omit the marker, and some
            // markers (without bare-JID match) could be from a room we haven't
            // joined yet (rare but possible).
            let joinedMUC = server.rooms.first(where: { !$0.isDM && $0.jid == bareFrom })
            let looksLikeMUCPM = message.isMUCPrivateMessage || joinedMUC != nil

            if looksLikeMUCPM, parts.count > 1 {
                // It's a MUC PM.  Sender is the resource part (participant's MUC
                // nick), reply target is the full occupant JID.  Don't pollute
                // the DM contacts list and don't construct a bare DM JID from
                // the room's local-part (the original MA-002 bug).
                let participantNick = nick
                // Blocked nick: drop the MUC PM entirely — no tab, no badge, no notification.
                if server.isBlocked(nick: participantNick) { return }
                let safeParticipantNick = participantNick.sanitizedForNicknameDisplay()
                let roomLabel = joinedMUC?.displayName ?? bareFrom

                let pmRoom = findOrCreateMUCPMRoom(
                    replyJID: fullFrom,
                    peerNick: safeParticipantNick,
                    roomLabel: roomLabel,
                    server: server
                )

                let timestamp = message.timestamp ?? Date()
                let chatMsg = ChatMessage(
                    timestamp: timestamp, sender: safeParticipantNick, body: message.body,
                    type: .chat, senderColor: ChatMessage.colorForNick(safeParticipantNick)
                )

                if message.isDelayed {
                    let isDuplicate = pmRoom.messages.contains { existing in
                        existing.sender == chatMsg.sender &&
                        existing.body == chatMsg.body &&
                        abs(existing.timestamp.timeIntervalSince(chatMsg.timestamp)) < 2.0
                    }
                    if isDuplicate { return }
                }

                pmRoom.messages.append(chatMsg)
                objectWillChange.send()

                LogManager.shared.logMessage(
                    server: server.name,
                    room: "MUCPM-\(roomLabel)-\(participantNick)",
                    timestamp: timestamp,
                    sender: participantNick,
                    body: message.body,
                    type: "chat"
                )

                if pmRoom.id != selectedRoom?.id && !message.isDelayed {
                    pmRoom.unreadCount += 1
                }
                notifications.notifyDirectMessage(
                    sender: "\(safeParticipantNick) (\(roomLabel))",
                    body: message.body
                )
                if notifications.playSound {
                    notifications.playAlertSound()
                }
                return
            }

            // Regular DM path — bare JID is the sender's user account.
            // Blocked JID: drop the message. The DM thread (if open) is kept but
            // receives nothing new; no tab is created for a blocked first-contact.
            if server.isBlocked(jid: bareFrom) { return }
            let senderNick = bareFrom.components(separatedBy: "@").first ?? bareFrom
            let safeSenderNick = senderNick.sanitizedForNicknameDisplay()

            let dmRoom = findOrCreateDMRoom(nick: senderNick, server: server)
            let timestamp = message.timestamp ?? Date()
            let chatMsg = ChatMessage(
                timestamp: timestamp, sender: safeSenderNick, body: message.body,
                type: .chat, senderColor: ChatMessage.colorForNick(safeSenderNick)
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
            // If it was a duplicate, we already returned early, so if we're here it's new.
            // The raw senderNick is used in the room-path identifier so logs stay
            // grouped by the same identity across runs; the body's `sender` field
            // gets the sanitized form so spoofing markers persist in the archive.
            LogManager.shared.logMessage(
                server: server.name,
                room: "DM-\(senderNick)",
                timestamp: timestamp,
                sender: safeSenderNick,
                body: message.body,
                type: "chat"
            )

            // Only badge real-time messages as unread, not history
            if dmRoom.id != selectedRoom?.id && !message.isDelayed {
                dmRoom.unreadCount += 1
            }
            notifications.notifyDirectMessage(sender: safeSenderNick, body: message.body)
            if notifications.playSound {
                notifications.playAlertSound()
            }
            return
        }

        // MUC routing: only match actual MUC rooms (not DM/MUC-PM tabs).  Without
        // this !isDM filter, a DM tab whose constructed JID coincidentally matches
        // a server-side MUC service address would receive groupchat-typed stanzas
        // from that address and render them as if they were chat messages —
        // exactly the "mirrored DM" bug pattern.
        guard let room = server.rooms.first(where: { !$0.isDM && $0.jid == roomJID }) else { return }

        // A "groupchat" with no "/nick" resource is from the room itself (server
        // announcement), not an occupant — don't render it attributed to the bare
        // room JID. (Error bounces were already handled upfront.)
        guard parts.count > 1 else { return }

        // Blocked nick (server-wide for this account): store the message but hide it
        // (views filter it out) and suppress all side effects, so unblock reveals it.
        let blocked = server.isBlocked(nick: nick)

        let timestamp = message.timestamp ?? Date()

        // Detect /me actions
        let isAction = message.body.hasPrefix("/me ")
        let body = isAction ? String(message.body.dropFirst(4)) : message.body
        let type: ChatMessage.MessageType = isAction ? .action : .chat

        // Sanitize the MUC nick before storing it — closes Unicode-spoofing
        // attacks (homoglyphs, bidi overrides, zero-width chars) on the sender
        // label rendered in the transcript.
        let safeNick = nick.sanitizedForNicknameDisplay()

        let chatMsg = ChatMessage(
            timestamp: timestamp,
            sender: safeNick,
            body: body,
            type: type,
            senderColor: ChatMessage.colorForNick(safeNick)
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

        // While blocked the message is hidden, so skip logging, unread, and notifications.
        if blocked { return }

        // Log to disk.  Sender is sanitized so spoofing markers persist into the
        // archive; the raw nick is otherwise discarded at this layer.
        LogManager.shared.logMessage(
            server: server.name,
            room: room.name,
            timestamp: timestamp,
            sender: safeNick,
            body: body,
            type: type == .chat ? "chat" : "action"
        )

        // Only badge real-time messages as unread, not history.  "Is this from me?"
        // compares against the user's own nick (room.nickname), which is user-set
        // and not wire-derived — no sanitization needed on the LHS.
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
                    sender: safeNick,
                    body: body,
                    mentionsMe: mentionsMe
                )

                // Play in-app sound for mentions even when focused
                if mentionsMe && notifications.playSound {
                    notifications.playAlertSound()
                }
            } else if message.type == "chat" {
                notifications.notifyDirectMessage(sender: safeNick, body: body)

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
        // MUC presence only belongs to actual MUC rooms — never to DM or MUC-PM tabs.
        guard let room = server.rooms.first(where: { !$0.isDM && $0.jid == roomJID }) else { return }

        // Join failure: the server rejected our presence (most commonly a 409 conflict
        // when this nick is already in the room — e.g. the same account is joined from
        // another device). Surface why and drop the half-created room rather than
        // leaving a phantom "joined" room whose messages silently bounce.
        if presence.type == "error" {
            let reason: String
            switch presence.errorCondition {
            case "conflict": reason = "the nickname “\(nick)” is already in use there"
            case "forbidden": reason = "you are banned from that room"
            case "registration-required": reason = "membership is required to join"
            case "not-allowed": reason = "the server does not allow joining it"
            default: reason = "the server rejected the join"
            }
            errorMessage = "Couldn’t join \(room.displayName): \(reason)."
            showError = true
            server.rooms.removeAll { $0.id == room.id }
            if selectedRoom?.id == room.id { selectedRoom = server.rooms.first }
            objectWillChange.send()
            return
        }

        // Blocked nick: still track their presence (so unblock can restore them if
        // they're still present) but suppress join/part notifications. The occupant
        // list and join/part transcript lines are hidden by the views while blocked.
        let blocked = server.isBlocked(nick: nick)

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

        // Sanitize the nick for display use (system messages, notifications).
        // The raw `nick` is still used to match against occupants because that's
        // the wire identifier — the server uses it for routing and uniqueness.
        let safeNick = nick.sanitizedForNicknameDisplay()

        if presence.type == "unavailable" {
            room.occupants.removeAll { $0.nick == nick }
            if room.initialPresenceComplete {
                let msg = ChatMessage(
                    timestamp: Date(), sender: safeNick, body: "",
                    type: .part, senderColor: ChatMessage.colorForNick(safeNick)
                )
                room.messages.append(msg)
                if !blocked {
                    notifications.notifyJoinPart(room: room.displayName, user: safeNick, joined: false)
                }
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
                        timestamp: Date(), sender: safeNick, body: "",
                        type: .join, senderColor: ChatMessage.colorForNick(safeNick)
                    )
                    room.messages.append(msg)
                    if !blocked {
                        notifications.notifyJoinPart(room: room.displayName, user: safeNick, joined: true)
                    }
                }
            }
        }
        objectWillChange.send()
    }

    nonisolated func xmpp(_ client: XMPPClient, didReceiveRoomSubject subject: String, room roomJID: String) {
        Task { @MainActor in
            guard let server = server(for: client) else { return }
            // Room subjects only belong to actual MUC rooms.
            guard let room = server.rooms.first(where: { !$0.isDM && $0.jid == roomJID }) else { return }

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
