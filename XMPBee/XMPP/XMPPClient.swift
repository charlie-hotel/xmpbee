import Foundation
import CommonCrypto

/// XMPP protocol events
protocol XMPPClientDelegate: AnyObject {
    func xmppDidConnect(_ client: XMPPClient)
    func xmppDidAuthenticate(_ client: XMPPClient)
    func xmppDidDisconnect(_ client: XMPPClient, error: Error?)
    func xmpp(_ client: XMPPClient, didReceiveMessage message: XMPPIncomingMessage)
    func xmpp(_ client: XMPPClient, didReceivePresence presence: XMPPPresence)
    func xmpp(_ client: XMPPClient, didReceiveRoomSubject subject: String, room: String)
    func xmpp(_ client: XMPPClient, didFailWithError error: XMPPError)
}

struct XMPPIncomingMessage {
    let from: String       // full JID (room@conference/nick or user@domain/resource)
    let body: String
    let type: String       // "groupchat", "chat", "normal"
    let timestamp: Date?   // delayed delivery timestamp
    let isDelayed: Bool    // history replay
    /// True if the stanza carried an `<x xmlns="http://jabber.org/protocol/muc#user"/>`
    /// child element.  Per XEP-0045 §7.5, MUC servers SHOULD include this marker on
    /// private messages between participants so clients can tell them apart from
    /// regular DMs (where `from` is a user JID with a resource).  Without this
    /// disambiguation the room JID's local-part would be mis-parsed as the sender's
    /// username — see MA-002 in the security audit for the impact.
    let isMUCPrivateMessage: Bool
}

struct XMPPPresence {
    let from: String
    let type: String?      // nil = available, "unavailable", etc.
    let show: String?      // "away", "xa", "dnd", "chat"
    let status: String?
    let roomJID: String?   // if this is a MUC presence
    let nick: String?
    let affiliation: String?
    let role: String?
    let isSelfPresence: Bool  // status code 110 = our own presence reflected back
}

enum XMPPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case streamError(String)
    case tlsRequired

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed(let msg): return "Auth failed: \(msg)"
        case .streamError(let msg): return "Stream error: \(msg)"
        case .tlsRequired: return "Server does not support STARTTLS but TLS is required"
        }
    }
}

/// XMPP client handling protocol negotiation, STARTTLS, auth, messaging, and MUC
class XMPPClient: XMLStreamParserDelegate {
    weak var delegate: XMPPClientDelegate?

    private var connection: XMPPConnection?
    private let xmlParser = XMLStreamParser()

    private(set) var jid: String = ""
    private var password: String = ""
    private(set) var domain: String = ""
    private(set) var resource: String = "XMPBee"
    private(set) var isAuthenticated = false
    private(set) var boundJID: String = ""

    /// Tracks whether we've already done STARTTLS on this connection
    private var tlsNegotiated = false
    /// Whether STARTTLS is pending (waiting for <proceed/>)
    private var startTLSPending = false

    /// SCRAM state (works for both SCRAM-SHA-1 and SCRAM-SHA-256)
    private var scramClientNonce: String = ""
    private var scramClientFirstMessageBare: String = ""
    private var scramServerSignature: Data?
    /// Which SCRAM hash variant the current handshake is using.  Set when we send
    /// `<auth mechanism="SCRAM-SHA-{1,256}">`, consulted in handleSCRAMChallenge to
    /// pick the right PBKDF2 / HMAC / digest functions.
    private var scramVariant: SCRAMHashVariant?

    /// A pending IQ request awaiting a response.  The expectedFrom field locks the
    /// response down to the JID we addressed the request to — without it, any
    /// authenticated peer who guesses the request ID can forge a result.
    ///
    /// `expectedFrom`:
    ///   • Non-empty: the bare `to` attribute we put on the request.  The
    ///     response's `from` must match this exactly (the server stamps it).
    ///   • Empty: the request had no `to` attribute (server-directed — bind,
    ///     session, ping).  The response must come from the user's own server
    ///     domain, or carry no `from` at all (some servers omit it for
    ///     server-directed responses).
    private struct PendingIQ {
        let expectedFrom: String
        let expiresAt: Date
        let callback: (XMLStanza) -> Void
    }
    private var pendingIQCallbacks: [String: PendingIQ] = [:]

    /// Maximum lifetime of a pending IQ callback.  Late-arriving forged responses
    /// after this window can't trigger callbacks the user has moved on from.
    private let pendingIQTimeout: TimeInterval = 30

    /// Random IDs assigned to the bind and session-establishment IQs at connect
    /// time.  Previously these were hardcoded `bind_1` / `session_1`, which was
    /// only exploitable during the pre-bind window (server-only) but became a
    /// trivial fix once we moved to random IDs for everything else.
    private var pendingBindID: String?
    private var pendingSessionID: String?

    // MARK: - Keepalive (XEP-0199)
    private var pingTimer: Timer?
    private var pingTimeoutTimer: Timer?

    init() {
        xmlParser.delegate = self
    }

    // MARK: - Connection

    func connect(host: String, port: Int, jid: String, password: String,
                 resource: String = "XMPBee", securityMode: SecurityMode = .requireTLS) {
        self.jid = jid
        self.password = password
        self.resource = resource
        self.domain = jid.components(separatedBy: "@").last ?? host
        self.tlsNegotiated = false
        self.startTLSPending = false

        connection = XMPPConnection(host: host, port: port, securityMode: securityMode)
        // The fast-path ping responder uses this to reject pings that don't come
        // from the user's own server (closes a presence-leak oracle — see
        // XMPPConnection.handlePingFast for the full rationale).
        connection?.expectedPingSourceJID = self.domain

        connection?.onConnected = { [weak self] in
            self?.openStream()
        }
        connection?.onData = { [weak self] data in
            self?.xmlParser.feed(data)
        }
        connection?.onDisconnected = { [weak self] error in
            guard let self = self else { return }
            self.isAuthenticated = false
            self.delegate?.xmppDidDisconnect(self, error: error)
        }
        connection?.onTLSReady = { [weak self] in
            // TLS upgrade complete — reopen stream over encrypted connection
            self?.tlsNegotiated = true
            self?.startTLSPending = false
            self?.openStream()
        }

        connection?.connect()
    }

    func disconnect() {
        stopPingTimer()
        pendingIQCallbacks.removeAll()
        pendingBindID = nil
        pendingSessionID = nil
        connection?.disconnect()
    }

    // MARK: - Stream

    private func openStream() {
        stopPingTimer()
        xmlParser.reset()
        let stream = """
        <?xml version='1.0'?>\
        <stream:stream to='\(domain.xmlEscaped)' \
        xmlns='jabber:client' \
        xmlns:stream='http://etherx.jabber.org/streams' \
        version='1.0'>
        """
        connection?.send(stream)
    }

    // MARK: - STARTTLS

    private func initiateSTARTTLS() {
        startTLSPending = true
        connection?.send("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    }

    // MARK: - Authentication (SASL PLAIN)

    private func authenticate() {
        // CRITICAL SECURITY: Never send PLAIN auth without TLS
        let secMode = connection?.securityMode ?? .requireTLS
        if !tlsNegotiated && secMode != .directTLS {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                "SASL PLAIN requires TLS. Connection is not encrypted."
            ))
            disconnect()
            return
        }

        let username = jid.components(separatedBy: "@").first ?? jid
        // SASL PLAIN: \0username\0password
        let authString = "\0\(username)\0\(password)"
        let base64 = Data(authString.utf8).base64EncodedString()
        let sasl = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>\(base64)</auth>"
        connection?.send(sasl)
    }

    // MARK: - SCRAM (SHA-1 / SHA-256)

    private func authenticateSCRAM(variant: SCRAMHashVariant) {
        // CRITICAL SECURITY: never send SCRAM proofs over cleartext either — they
        // permit offline dictionary attack against the user's password.  PLAIN has
        // an analogous gate in authenticate(); this one keeps the same invariant
        // for SCRAM, independent of how this method is reached.
        let secMode = connection?.securityMode ?? .requireTLS
        if !tlsNegotiated && secMode != .directTLS {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                "\(variant.mechanismName) requires TLS. Connection is not encrypted."
            ))
            disconnect()
            return
        }

        scramVariant = variant

        // Generate client nonce (random base64 string)
        var nonceBytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        scramClientNonce = Data(nonceBytes).base64EncodedString()

        let username = jid.components(separatedBy: "@").first ?? jid
        // Escape username per RFC 5802: = becomes =3D, , becomes =2C
        let escapedUsername = username.replacingOccurrences(of: "=", with: "=3D")
                                      .replacingOccurrences(of: ",", with: "=2C")

        // Client-first-message-bare (no GS2 header)
        scramClientFirstMessageBare = "n=\(escapedUsername),r=\(scramClientNonce)"

        // Client-first-message (with GS2 header: n,, means no channel binding)
        let clientFirstMessage = "n,,\(scramClientFirstMessageBare)"
        let base64 = Data(clientFirstMessage.utf8).base64EncodedString()

        let sasl = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='\(variant.mechanismName)'>\(base64)</auth>"
        connection?.send(sasl)
    }

    private func handleSCRAMChallenge(_ challenge: String) {
        // Pull the variant we set in authenticateSCRAM.  If somehow missing, abort —
        // we shouldn't be processing a challenge for a handshake we didn't start.
        guard let variant = scramVariant else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed("Unexpected SCRAM challenge (no variant set)"))
            return
        }

        guard let challengeData = Data(base64Encoded: challenge),
              let challengeStr = String(data: challengeData, encoding: .utf8) else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed("Invalid SCRAM challenge"))
            return
        }

        // Parse server-first-message: r=<nonce>,s=<salt>,i=<iterations>
        var serverNonce = ""
        var salt = ""
        var iterations = 4096

        for part in challengeStr.components(separatedBy: ",") {
            if part.hasPrefix("r=") {
                serverNonce = String(part.dropFirst(2))
            } else if part.hasPrefix("s=") {
                salt = String(part.dropFirst(2))
            } else if part.hasPrefix("i=") {
                iterations = Int(part.dropFirst(2)) ?? 4096
            }
        }

        guard serverNonce.hasPrefix(scramClientNonce),
              let saltData = Data(base64Encoded: salt) else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed("Invalid SCRAM server response"))
            return
        }

        // RFC 5802 mandates a minimum of 4096 PBKDF2 iterations.  A hostile or
        // compromised server can advertise i=1 to make offline brute-force of the
        // password effectively free; refuse to proceed under that floor.
        let scramMinIterations = 4096
        guard iterations >= scramMinIterations else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                "SCRAM iteration count below RFC 5802 minimum (\(iterations) < \(scramMinIterations))."
            ))
            return
        }

        // Compute SaltedPassword using PBKDF2-HMAC-<variant>
        guard let saltedPassword = pbkdf2(variant: variant, password: password, salt: saltData, iterations: iterations) else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed("SCRAM crypto failed"))
            return
        }

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        let clientKey = hmac(variant: variant, key: saltedPassword, data: Data("Client Key".utf8))

        // StoredKey = H(ClientKey)
        let storedKey = digest(variant: variant, clientKey)

        // Client-final-message-without-proof: c=biws (base64("n,,")),r=<nonce>
        let channelBinding = Data("n,,".utf8).base64EncodedString()
        let clientFinalWithoutProof = "c=\(channelBinding),r=\(serverNonce)"

        // AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof
        let authMessage = "\(scramClientFirstMessageBare),\(challengeStr),\(clientFinalWithoutProof)"

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        let clientSignature = hmac(variant: variant, key: storedKey, data: Data(authMessage.utf8))

        // ClientProof = ClientKey XOR ClientSignature
        let clientProof = xor(clientKey, clientSignature)

        // ServerKey = HMAC(SaltedPassword, "Server Key")
        let serverKey = hmac(variant: variant, key: saltedPassword, data: Data("Server Key".utf8))

        // ServerSignature = HMAC(ServerKey, AuthMessage) - save for verification on <success>
        scramServerSignature = hmac(variant: variant, key: serverKey, data: Data(authMessage.utf8))

        // Send client-final-message
        let clientFinal = "\(clientFinalWithoutProof),p=\(clientProof.base64EncodedString())"
        let base64Final = Data(clientFinal.utf8).base64EncodedString()

        let response = "<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(base64Final)</response>"
        connection?.send(response)
    }

    private func verifySCRAMSuccess(_ message: String) -> Bool {
        guard let messageData = Data(base64Encoded: message),
              let messageStr = String(data: messageData, encoding: .utf8) else {
            return false
        }

        // Parse v=<signature>
        guard messageStr.hasPrefix("v="),
              let serverSig = Data(base64Encoded: String(messageStr.dropFirst(2))),
              let expectedSig = scramServerSignature else {
            return false
        }

        return serverSig == expectedSig
    }

    // MARK: - SCRAM Crypto Helpers (variant-parameterized)

    private func pbkdf2(variant: SCRAMHashVariant, password: String, salt: Data, iterations: Int) -> Data? {
        let passwordData = password.data(using: .utf8)!
        var derivedKey = Data(repeating: 0, count: variant.digestLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    variant.ccPrfAlgorithm,
                    UInt32(iterations),
                    derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), variant.digestLength
                )
            }
        }

        return result == kCCSuccess ? derivedKey : nil
    }

    private func hmac(variant: SCRAMHashVariant, key: Data, data: Data) -> Data {
        var out = Data(repeating: 0, count: variant.digestLength)
        out.withUnsafeMutableBytes { outBytes in
            key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    CCHmac(
                        variant.ccHmacAlgorithm,
                        keyBytes.baseAddress, key.count,
                        dataBytes.baseAddress, data.count,
                        outBytes.baseAddress
                    )
                }
            }
        }
        return out
    }

    private func digest(variant: SCRAMHashVariant, _ data: Data) -> Data {
        var hash = Data(repeating: 0, count: variant.digestLength)
        data.withUnsafeBytes { dataBytes in
            hash.withUnsafeMutableBytes { hashBytes in
                let outPtr = hashBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let len = CC_LONG(data.count)
                switch variant {
                case .sha1:
                    CC_SHA1(dataBytes.baseAddress, len, outPtr)
                case .sha256:
                    CC_SHA256(dataBytes.baseAddress, len, outPtr)
                }
            }
        }
        return hash
    }

    private func xor(_ a: Data, _ b: Data) -> Data {
        var result = Data(count: min(a.count, b.count))
        for i in 0..<result.count {
            result[i] = a[i] ^ b[i]
        }
        return result
    }

    // MARK: - Resource Binding & Session

    private func bindResource() {
        let id = nextIQId()
        pendingBindID = id
        let iq = """
        <iq type='set' id='\(id.xmlEscaped)'>\
        <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
        <resource>\(resource.xmlEscaped)</resource>\
        </bind></iq>
        """
        connection?.send(iq)
    }

    private func startSession() {
        let id = nextIQId()
        pendingSessionID = id
        let iq = "<iq type='set' id='\(id.xmlEscaped)'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>"
        connection?.send(iq)
    }

    // MARK: - Messaging

    func sendGroupMessage(to roomJID: String, body: String) {
        let msg = """
        <message to='\(roomJID.xmlEscaped)' type='groupchat'>\
        <body>\(body.xmlEscaped)</body>\
        </message>
        """
        connection?.send(msg)
    }

    func sendDirectMessage(to jid: String, body: String) {
        let msg = """
        <message to='\(jid.xmlEscaped)' type='chat'>\
        <body>\(body.xmlEscaped)</body>\
        </message>
        """
        connection?.send(msg)
    }

    // MARK: - MUC (Multi-User Chat)

    func joinRoom(jid roomJID: String, nickname: String, historyMaxStanzas: Int = 50) {
        let presence = """
        <presence to='\(roomJID.xmlEscaped)/\(nickname.xmlEscaped)'>\
        <x xmlns='http://jabber.org/protocol/muc'>\
        <history maxstanzas='\(historyMaxStanzas)'/>\
        </x></presence>
        """
        connection?.send(presence)
    }

    func leaveRoom(jid roomJID: String, nickname: String) {
        let presence = "<presence to='\(roomJID.xmlEscaped)/\(nickname.xmlEscaped)' type='unavailable'/>"
        connection?.send(presence)
    }

    func requestRoomList(from service: String, completion: @escaping ([(jid: String, name: String)]) -> Void) {
        let id = nextIQId()
        let iq = "<iq to='\(service.xmlEscaped)' type='get' id='\(id.xmlEscaped)'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
        registerPendingIQ(id: id, expectedFrom: service) { stanza in
            var rooms: [(jid: String, name: String)] = []
            if let query = stanza.child(named: "query") {
                for item in query.children(named: "item") {
                    let jid = item["jid"] ?? ""
                    let name = item["name"] ?? jid.components(separatedBy: "@").first ?? jid
                    rooms.append((jid: jid, name: name))
                }
            }
            completion(rooms)
        }
        connection?.send(iq)
    }

    // MARK: - User Search (XEP-0055)

    /// Disco the server's components, probe each for `jabber:iq:search` support, return
    /// the JID of the first one that advertises it.  Used to find the directory/user
    /// component (typically `search.<domain>`) without hard-coding its name.
    func discoverUserSearchService(on domain: String, completion: @escaping (String?) -> Void) {
        let id = nextIQId()
        let iq = "<iq to='\(domain.xmlEscaped)' type='get' id='\(id.xmlEscaped)'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
        registerPendingIQ(id: id, expectedFrom: domain) { [weak self] stanza in
            guard let self = self else { completion(nil); return }
            if stanza["type"] == "error" {
                completion(nil)
                return
            }
            guard let query = stanza.child(named: "query") else { completion(nil); return }
            let candidates = query.children(named: "item").compactMap { $0["jid"] }
            self.probeForUserSearch(candidates: candidates, completion: completion)
        }
        connection?.send(iq)
    }

    /// Walk the candidate component JIDs one at a time, disco#info each, return the
    /// first that lists `jabber:iq:search` as a feature.  Sequential rather than parallel
    /// to keep the IQ callback bookkeeping simple — server lists are tiny in practice.
    private func probeForUserSearch(candidates: [String], completion: @escaping (String?) -> Void) {
        guard let first = candidates.first else { completion(nil); return }
        let rest = Array(candidates.dropFirst())

        let id = nextIQId()
        let iq = "<iq to='\(first.xmlEscaped)' type='get' id='\(id.xmlEscaped)'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>"
        registerPendingIQ(id: id, expectedFrom: first) { [weak self] stanza in
            guard let self = self else { completion(nil); return }
            if stanza["type"] != "error",
               let info = stanza.child(named: "query") {
                let features = info.children(named: "feature").compactMap { $0["var"] }
                if features.contains("jabber:iq:search") {
                    completion(first)
                    return
                }
            }
            self.probeForUserSearch(candidates: rest, completion: completion)
        }
        connection?.send(iq)
    }

    /// XEP-0055 search.  Sends the term against the `nick` field — the field that
    /// every common server implementation supports.  Returns parsed (jid, nick, name)
    /// tuples plus an optional error string from the server.
    func searchUsers(
        at service: String,
        query: String,
        completion: @escaping ([(jid: String, nick: String, name: String)], String?) -> Void
    ) {
        let id = nextIQId()
        let iq = """
        <iq to='\(service.xmlEscaped)' type='set' id='\(id.xmlEscaped)'>\
        <query xmlns='jabber:iq:search'>\
        <nick>\(query.xmlEscaped)</nick>\
        </query></iq>
        """
        registerPendingIQ(id: id, expectedFrom: service) { stanza in
            if stanza["type"] == "error" {
                let reason = stanza.child(named: "error")?.children.first?.name ?? "Search failed"
                completion([], reason)
                return
            }
            guard let query = stanza.child(named: "query") else {
                completion([], nil)
                return
            }
            var results: [(jid: String, nick: String, name: String)] = []
            for item in query.children(named: "item") {
                let jid = item["jid"] ?? ""
                let nick = item.child(named: "nick")?.text ?? ""
                let first = item.child(named: "first")?.text ?? ""
                let last  = item.child(named: "last")?.text ?? ""
                let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                results.append((jid: jid, nick: nick, name: name))
            }
            completion(results, nil)
        }
        connection?.send(iq)
    }

    // MARK: - Presence

    func sendPresence(show: String? = nil, status: String? = nil) {
        var xml = "<presence>"
        if let show = show { xml += "<show>\(show.xmlEscaped)</show>" }
        if let status = status { xml += "<status>\(status.xmlEscaped)</status>" }
        xml += "</presence>"
        connection?.send(xml)
    }

    // MARK: - Keepalive Pings (XEP-0199)

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.sendKeepalivePing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        pingTimeoutTimer?.invalidate()
        pingTimeoutTimer = nil
    }

    private func sendKeepalivePing() {
        let id = nextIQId()
        // No `to` on the IQ — ping is server-directed.  Expected from is "" which
        // the registerPendingIQ validator interprets as "accept empty or our own
        // server's bare domain" (matches both stamping conventions in the wild).
        let iq = "<iq type='get' id='\(id.xmlEscaped)'><ping xmlns='urn:xmpp:ping'/></iq>"
        registerPendingIQ(id: id, expectedFrom: "") { [weak self] _ in
            // Any response (result or error) means the connection is alive
            self?.pingTimeoutTimer?.invalidate()
            self?.pingTimeoutTimer = nil
        }
        connection?.send(iq)
        pingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            #if DEBUG
            print("[XMPP] Ping timeout — reconnecting")
            #endif
            self.stopPingTimer()
            self.disconnect()
        }
    }

    // MARK: - Helpers

    /// Generate a fresh cryptographically-random IQ ID.  96 bits (24 hex chars) is
    /// well past the threshold where an attacker could blind-guess the next ID
    /// (~2^-95 odds per attempt).  Falls back to a counter only if SecRandomCopyBytes
    /// fails, which on a healthy macOS doesn't happen.
    private func nextIQId() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Defensive fallback — should never hit this on macOS.
        return "iq_\(Int.random(in: 1...Int.max))"
    }

    /// Register a pending IQ callback with strict from/type validation.  Callers pass
    /// the JID they addressed the request to (or "" for server-directed requests).
    /// The dispatch path in handleIQ() will refuse to invoke the callback unless the
    /// response actually came from that JID and is of type "result" or "error".
    private func registerPendingIQ(
        id: String,
        expectedFrom: String,
        callback: @escaping (XMLStanza) -> Void
    ) {
        // Drop any callbacks that have aged past the timeout — limits the pending
        // dict's growth and prevents late forgeries from invoking abandoned
        // callbacks.  Cheap O(n) sweep on the small dict, runs only at registration.
        sweepExpiredPendingIQs()
        pendingIQCallbacks[id] = PendingIQ(
            expectedFrom: expectedFrom,
            expiresAt: Date().addingTimeInterval(pendingIQTimeout),
            callback: callback
        )
    }

    private func sweepExpiredPendingIQs() {
        let now = Date()
        pendingIQCallbacks = pendingIQCallbacks.filter { $0.value.expiresAt > now }
    }

    /// Validate that an IQ result's `from` attribute matches what the request was
    /// addressed to.  See the PendingIQ doc for the case analysis.
    private func isValidIQResponseFrom(_ responseFrom: String, expectedFrom: String) -> Bool {
        let userServer = self.domain
        if expectedFrom.isEmpty {
            // Server-directed request (bind, session, ping — `to` was unset, so
            // the server is the implicit destination).  The 96-bit random ID is
            // the load-bearing security boundary here; `from` validation is
            // defense-in-depth, and we don't want to reject a legitimate server
            // response just because the server chose to stamp a `from` attribute
            // we couldn't predict.  Accept any of:
            //   • empty (most common — Prosody, ejabberd, etc.)
            //   • our server's bare domain (some servers identify themselves)
            //   • our own bare JID (Openfire stamps this on bind results)
            //   • a full JID whose bare part is our own JID (server-assigned resource)
            if responseFrom.isEmpty { return true }
            if responseFrom == userServer { return true }
            if responseFrom == self.jid { return true }
            if responseFrom.hasPrefix(self.jid + "/") { return true }
            return false
        }
        // Targeted request — strict match, with one allowance: an empty from is
        // acceptable only when the target WAS our own server (some servers omit it).
        if responseFrom == expectedFrom { return true }
        if responseFrom.isEmpty && expectedFrom == userServer { return true }
        return false
    }

    // MARK: - XMLStreamParserDelegate

    func parserDidOpenStream(_ parser: XMLStreamParser, attributes: [String: String]) {
        delegate?.xmppDidConnect(self)
    }

    func parserDidCloseStream(_ parser: XMLStreamParser) {
        delegate?.xmppDidDisconnect(self, error: nil)
    }

    func parser(_ parser: XMLStreamParser, didReceiveStreamFeatures features: XMLStanza) {
        let secMode = connection?.securityMode ?? .requireTLS

        // Step 1: If we haven't done TLS yet and we're not on directTLS, the server
        // MUST offer STARTTLS — otherwise refuse to proceed.  There's no silent
        // fall-back to cleartext (per RFC 7590 §3.4); the only encrypted-by-default
        // mode that doesn't go through STARTTLS is directTLS on port 5223.
        if !tlsNegotiated && secMode != .directTLS {
            if features.child(named: "starttls") != nil {
                initiateSTARTTLS()
                return
            }
            delegate?.xmpp(self, didFailWithError: .tlsRequired)
            disconnect()
            return
        }

        // Step 2: SASL mechanism selection.  By this point the channel is either
        // STARTTLS-upgraded or directTLS-established; the defensive guard below
        // catches anything that would let us authenticate over cleartext, even
        // though removing opportunisticTLS already makes that path unreachable.
        if let mechanisms = features.child(named: "mechanisms") {
            // Belt-and-braces: never send any SASL credentials over a cleartext socket.
            guard tlsNegotiated || secMode == .directTLS else {
                delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                    "Refusing to send SASL credentials over an unencrypted connection."
                ))
                disconnect()
                return
            }

            let mechs = mechanisms.children(named: "mechanism").map { $0.text }
            // Mechanism preference (strongest first):
            //   1. SCRAM-SHA-256 (RFC 7677) — modern default
            //   2. SCRAM-SHA-1  (RFC 5802) — legacy fallback
            //   3. PLAIN        — last resort, gated by TLS above
            // Channel-binding `-PLUS` variants are not yet supported (would need
            // tls-exporter or tls-server-end-point material from the TLS stream).
            if mechs.contains("SCRAM-SHA-256") {
                authenticateSCRAM(variant: .sha256)
            } else if mechs.contains("SCRAM-SHA-1") {
                authenticateSCRAM(variant: .sha1)
            } else if mechs.contains("PLAIN") {
                authenticate()
            } else {
                delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                    "No supported auth mechanism. Server offers: \(mechs.joined(separator: ", "))"
                ))
            }
            return
        }

        // Step 3: Post-auth features — bind resource
        if features.child(named: "bind") != nil {
            bindResource()
        }
    }

    func parser(_ parser: XMLStreamParser, didReceiveStanza stanza: XMLStanza) {
        // STARTTLS phase enforcement (RFC 6120 §5.4.3.3): once we've sent
        // <starttls/>, the only valid responses are <proceed/> or <failure/>.
        // Any other stanza arriving in that window is a protocol violation —
        // most likely a MITM trying to slip injected content past the gate.
        // Refuse to act on it and disconnect.  (The XMLStreamParser-level gate
        // already suppresses post-<proceed/> stanzas; this catches the inverse:
        // stanzas other than proceed/failure arriving BEFORE <proceed/>.)
        if startTLSPending && stanza.name != "proceed" && stanza.name != "failure" {
            delegate?.xmpp(self, didFailWithError: .streamError(
                "Unexpected stanza <\(stanza.name)> while awaiting STARTTLS response."
            ))
            disconnect()
            return
        }

        switch stanza.name {
        case "proceed":
            // STARTTLS: server says proceed — upgrade the connection to TLS
            if startTLSPending {
                connection?.upgradeTLS()
            }

        case "challenge":
            // SCRAM challenge from server
            let challengeText = stanza.text
            handleSCRAMChallenge(challengeText)

        case "success":
            // SASL auth succeeded.
            //
            // For SCRAM, the server MUST include the v=ServerSignature proof per
            // RFC 5802 §3 — it's how the server demonstrates knowledge of the
            // user's password and provides mutual authentication.  An empty
            // <success/> payload is a protocol violation, and treating it as
            // "verification skipped" lets a MITM that terminated TLS in front
            // of the real server bypass server-identity proof entirely.
            if let sig = scramServerSignature, !sig.isEmpty {
                let successText = stanza.text
                guard !successText.isEmpty, verifySCRAMSuccess(successText) else {
                    delegate?.xmpp(self, didFailWithError: .authenticationFailed(
                        "SCRAM server verification failed (missing or invalid server signature)."
                    ))
                    disconnect()
                    return
                }
            }

            isAuthenticated = true
            // Clear password from memory immediately after successful auth
            password = ""
            // Clear SCRAM state
            scramClientNonce = ""
            scramClientFirstMessageBare = ""
            scramServerSignature = nil
            scramVariant = nil
            openStream()

        case "failure":
            if startTLSPending {
                delegate?.xmpp(self, didFailWithError: .connectionFailed("STARTTLS failed"))
                startTLSPending = false
            } else {
                // Clear password on auth failure — no longer needed and shouldn't linger
                password = ""
                let reason = stanza.children.first?.name ?? "unknown"
                delegate?.xmpp(self, didFailWithError: .authenticationFailed(reason))
            }

        case "iq":
            handleIQ(stanza)

        case "message":
            handleMessage(stanza)

        case "presence":
            handlePresence(stanza)

        default:
            break
        }
    }

    func parser(_ parser: XMLStreamParser, didFailWithError error: Error) {
        // XMLStreamParser attempts in-place recovery for errors that occur while the
        // stream is open — those never reach this method.  Errors that do reach here
        // are either pre-stream failures or exhausted recovery (3 consecutive failures).
        // Surface the error and disconnect; the reconnect mechanism handles the rest.
        delegate?.xmpp(self, didFailWithError: .streamError(error.localizedDescription))
        disconnect()
    }

    // MARK: - Stanza Handlers

    private func handleIQ(_ iq: XMLStanza) {
        let type = iq["type"] ?? ""
        let id = iq["id"] ?? ""
        let from = iq["from"] ?? ""

        // Pings are handled at the connection layer (fast path on stream thread)
        // so we just ignore them here
        if type == "get", iq.child(named: "ping") != nil { return }

        // Bind / session handshake — match by the random IDs we generated at
        // request time.  Both are server-directed, so the response's `from`
        // should be empty or our own server's domain.
        if type == "result" {
            if let bindID = pendingBindID, id == bindID {
                pendingBindID = nil
                guard isValidIQResponseFrom(from, expectedFrom: "") else { return }
                if let bind = iq.child(named: "bind"),
                   let boundJid = bind.child(named: "jid") {
                    self.boundJID = boundJid.text
                    startSession()
                }
                return
            }
            if let sessionID = pendingSessionID, id == sessionID {
                pendingSessionID = nil
                guard isValidIQResponseFrom(from, expectedFrom: "") else { return }
                sendPresence()
                startPingTimer()
                delegate?.xmppDidAuthenticate(self)
                return
            }
        }

        // Generic pending-callback dispatch.  Only `result` and `error` are valid
        // responses to a request we issued — anything else (an attacker injecting
        // a `set` or `get` with the same ID) gets dropped silently.
        guard type == "result" || type == "error" else { return }

        guard let pending = pendingIQCallbacks.removeValue(forKey: id) else { return }

        // Expired pending callback — drop the response.  This closes the late-
        // forgery window where a response arrives after the user has moved on.
        if pending.expiresAt < Date() { return }

        // Validate that the response actually came from where we sent the request.
        // The server stamps `from` on inbound stanzas with the authenticated
        // origin, so an attacker can't claim to be a different JID at the
        // protocol level — this is what makes the validation load-bearing.
        guard isValidIQResponseFrom(from, expectedFrom: pending.expectedFrom) else { return }

        pending.callback(iq)
    }

    private func handleMessage(_ msg: XMLStanza) {
        let from = msg["from"] ?? ""
        let type = msg["type"] ?? "normal"

        // Room subject
        if let subject = msg.child(named: "subject") {
            let subjectText = subject.text
            let roomJID = from.components(separatedBy: "/").first ?? from
            delegate?.xmpp(self, didReceiveRoomSubject: subjectText, room: roomJID)
            return
        }

        guard let body = msg.child(named: "body"), !body.text.isEmpty else { return }

        // Check for delayed delivery (message history)
        var timestamp: Date? = nil
        var isDelayed = false
        if let delay = msg.child(named: "delay") ?? msg.child(named: "x") {
            if let stamp = delay["stamp"] {
                timestamp = parseXMPPDate(stamp)
                isDelayed = true
            }
        }

        // XEP-0045 §7.5 — MUC private messages carry an <x xmlns="…muc#user"/>
        // marker.  Surface it on the incoming-message struct so the view model can
        // distinguish PMs (which come from `room@service/nick`) from real DMs
        // (which come from `user@server/resource`) without having to second-guess
        // the JID shape.
        let isMUCPM = msg.child(named: "x", xmlns: "http://jabber.org/protocol/muc#user") != nil

        let incoming = XMPPIncomingMessage(
            from: from,
            body: body.text,
            type: type,
            timestamp: timestamp,
            isDelayed: isDelayed,
            isMUCPrivateMessage: isMUCPM
        )
        delegate?.xmpp(self, didReceiveMessage: incoming)
    }

    private func handlePresence(_ pres: XMLStanza) {
        let from = pres["from"] ?? ""
        let type = pres["type"]
        let show = pres.child(named: "show")?.text
        let status = pres.child(named: "status")?.text

        var affiliation: String? = nil
        var role: String? = nil
        var roomJID: String? = nil
        var nick: String? = nil
        var isSelfPresence = false

        // Check for MUC user info — must match the MUC namespace specifically,
        // since presences often have multiple <x> elements (vcard, muc#user, etc.)
        if let x = pres.child(named: "x", xmlns: "http://jabber.org/protocol/muc#user") {
            if let item = x.child(named: "item") {
                affiliation = item["affiliation"]
                role = item["role"]
            }
            let parts = from.components(separatedBy: "/")
            if parts.count == 2 {
                roomJID = parts[0]
                nick = parts[1]
            }
            // Status code 110 = this is our own presence reflected back
            // This marks the end of the initial presence flood
            let statusCodes = x.children(named: "status")
            isSelfPresence = statusCodes.contains { $0["code"] == "110" }
        }

        let presence = XMPPPresence(
            from: from, type: type, show: show, status: status,
            roomJID: roomJID, nick: nick, affiliation: affiliation, role: role,
            isSelfPresence: isSelfPresence
        )
        delegate?.xmpp(self, didReceivePresence: presence)
    }

    /// DateFormatter allocation is expensive — share one set of formatters for the lifetime of the client.
    private static let xmppDateFormatters: [DateFormatter] = {
        let f1 = DateFormatter()
        f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        f1.locale = Locale(identifier: "en_US_POSIX")
        let f2 = DateFormatter()
        f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f2.locale = Locale(identifier: "en_US_POSIX")
        let f3 = DateFormatter()
        f3.dateFormat = "yyyyMMdd'T'HH:mm:ss"
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.timeZone = TimeZone(identifier: "UTC")
        return [f1, f2, f3]
    }()

    private func parseXMPPDate(_ string: String) -> Date? {
        for fmt in XMPPClient.xmppDateFormatters {
            if let date = fmt.date(from: string) { return date }
        }
        return nil
    }
}

// MARK: - SCRAM Hash Variant

/// Tags a SCRAM exchange with the hash function being used.  SCRAM-SHA-1 (RFC 5802)
/// and SCRAM-SHA-256 (RFC 7677) share the entire wire protocol; only the underlying
/// hash, HMAC, and PBKDF2 PRF differ.  This enum exposes those choices uniformly so
/// `authenticateSCRAM` and `handleSCRAMChallenge` are a single code path.
enum SCRAMHashVariant {
    case sha1
    case sha256

    var mechanismName: String {
        switch self {
        case .sha1:   return "SCRAM-SHA-1"
        case .sha256: return "SCRAM-SHA-256"
        }
    }

    var digestLength: Int {
        switch self {
        case .sha1:   return Int(CC_SHA1_DIGEST_LENGTH)   // 20
        case .sha256: return Int(CC_SHA256_DIGEST_LENGTH) // 32
        }
    }

    var ccHmacAlgorithm: CCHmacAlgorithm {
        switch self {
        case .sha1:   return CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha256: return CCHmacAlgorithm(kCCHmacAlgSHA256)
        }
    }

    var ccPrfAlgorithm: CCPseudoRandomAlgorithm {
        switch self {
        case .sha1:   return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }
    }
}
