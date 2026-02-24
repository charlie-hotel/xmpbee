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

    /// SCRAM-SHA-1 state
    private var scramClientNonce: String = ""
    private var scramClientFirstMessageBare: String = ""
    private var scramServerSignature: Data?

    private var pendingIQCallbacks: [String: (XMLStanza) -> Void] = [:]
    private var iqCounter = 0

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

    // MARK: - SCRAM-SHA-1

    private func authenticateSCRAM() {
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

        let sasl = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='SCRAM-SHA-1'>\(base64)</auth>"
        connection?.send(sasl)
    }

    private func handleSCRAMChallenge(_ challenge: String) {
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

        // Compute SaltedPassword using PBKDF2-HMAC-SHA1
        guard let saltedPassword = pbkdf2SHA1(password: password, salt: saltData, iterations: iterations) else {
            delegate?.xmpp(self, didFailWithError: .authenticationFailed("SCRAM crypto failed"))
            return
        }

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        let clientKey = hmacSHA1(key: saltedPassword, data: Data("Client Key".utf8))

        // StoredKey = SHA1(ClientKey)
        let storedKey = sha1(clientKey)

        // Client-final-message-without-proof: c=biws (base64("n,,")),r=<nonce>
        let channelBinding = Data("n,,".utf8).base64EncodedString()
        let clientFinalWithoutProof = "c=\(channelBinding),r=\(serverNonce)"

        // AuthMessage = client-first-bare + "," + server-first + "," + client-final-without-proof
        let authMessage = "\(scramClientFirstMessageBare),\(challengeStr),\(clientFinalWithoutProof)"

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        let clientSignature = hmacSHA1(key: storedKey, data: Data(authMessage.utf8))

        // ClientProof = ClientKey XOR ClientSignature
        let clientProof = xor(clientKey, clientSignature)

        // ServerKey = HMAC(SaltedPassword, "Server Key")
        let serverKey = hmacSHA1(key: saltedPassword, data: Data("Server Key".utf8))

        // ServerSignature = HMAC(ServerKey, AuthMessage) - save for verification
        scramServerSignature = hmacSHA1(key: serverKey, data: Data(authMessage.utf8))

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

    // MARK: - SCRAM Crypto Helpers

    private func pbkdf2SHA1(password: String, salt: Data, iterations: Int) -> Data? {
        let passwordData = password.data(using: .utf8)!
        var derivedKey = Data(repeating: 0, count: 20) // SHA1 = 20 bytes

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(iterations),
                    derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 20
                )
            }
        }

        return result == kCCSuccess ? derivedKey : nil
    }

    private func hmacSHA1(key: Data, data: Data) -> Data {
        var hmac = Data(repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        hmac.withUnsafeMutableBytes { hmacBytes in
            key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyBytes.baseAddress, key.count,
                        dataBytes.baseAddress, data.count,
                        hmacBytes.baseAddress
                    )
                }
            }
        }
        return hmac
    }

    private func sha1(_ data: Data) -> Data {
        var hash = Data(repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { dataBytes in
            hash.withUnsafeMutableBytes { hashBytes in
                CC_SHA1(dataBytes.baseAddress, CC_LONG(data.count), hashBytes.baseAddress?.assumingMemoryBound(to: UInt8.self))
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
        let iq = """
        <iq type='set' id='bind_1'>\
        <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
        <resource>\(resource.xmlEscaped)</resource>\
        </bind></iq>
        """
        connection?.send(iq)
    }

    private func startSession() {
        let iq = "<iq type='set' id='session_1'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>"
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
        pendingIQCallbacks[id] = { stanza in
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
        let iq = "<iq type='get' id='\(id)'><ping xmlns='urn:xmpp:ping'/></iq>"
        pendingIQCallbacks[id] = { [weak self] _ in
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

    private func nextIQId() -> String {
        iqCounter += 1
        return "iq_\(iqCounter)"
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

        // Step 1: If we haven't done TLS yet and the server offers STARTTLS, do it
        if !tlsNegotiated && secMode != .directTLS {
            if features.child(named: "starttls") != nil {
                initiateSTARTTLS()
                return
            } else if secMode == .requireTLS {
                // TLS required but server doesn't offer STARTTLS
                delegate?.xmpp(self, didFailWithError: .tlsRequired)
                disconnect()
                return
            }
            // opportunisticTLS: server doesn't offer it, continue without
        }

        // Step 2: Check for SASL mechanisms (post-TLS or no-TLS)
        if let mechanisms = features.child(named: "mechanisms") {
            let mechs = mechanisms.children(named: "mechanism").map { $0.text }
            // Prefer SCRAM-SHA-1 over PLAIN for better security
            if mechs.contains("SCRAM-SHA-1") {
                authenticateSCRAM()
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
            // SASL auth succeeded
            // For SCRAM, verify server signature
            if let sig = scramServerSignature, !sig.isEmpty {
                let successText = stanza.text
                if !successText.isEmpty && !verifySCRAMSuccess(successText) {
                    delegate?.xmpp(self, didFailWithError: .authenticationFailed("SCRAM server verification failed"))
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

        // Pings are handled at the connection layer (fast path on stream thread)
        // so we just ignore them here
        if type == "get", iq.child(named: "ping") != nil { return }

        if type == "result" {
            if id == "bind_1", let bind = iq.child(named: "bind"),
               let boundJid = bind.child(named: "jid") {
                self.boundJID = boundJid.text
                startSession()
            } else if id == "session_1" {
                // Session established — we're fully connected
                sendPresence()
                startPingTimer()
                delegate?.xmppDidAuthenticate(self)
            }

            // Disco results (room list)
            if let query = iq.child(named: "query") {
                let items = query.children(named: "item")
                if !items.isEmpty {
                    // This is a disco#items result — handled by callback or delegate
                }
            }
        }

        // Check pending callbacks
        if let callback = pendingIQCallbacks.removeValue(forKey: id) {
            callback(iq)
        }
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

        let incoming = XMPPIncomingMessage(
            from: from,
            body: body.text,
            type: type,
            timestamp: timestamp,
            isDelayed: isDelayed
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
