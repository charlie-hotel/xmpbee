import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Per-platform default XMPP resource, so multiple simultaneously-connected clients
/// don't share a resource and fight over the connection.
enum Platform {
    static var defaultResource: String {
        #if os(macOS)
        "XMPBee-macOS"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "XMPBee-iPad" : "XMPBee-iPhone"
        #endif
    }
}

/// Represents an XMPP server connection
class Server: Identifiable, ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published var hostname: String
    @Published var port: Int
    @Published var jid: String // user@domain
    // Note: Password is NOT stored here for security reasons.
    // It's stored in Keychain and passed directly to XMPPClient.connect()
    @Published var isConnected: Bool = false
    @Published var rooms: [Room] = []
    @Published var isExpanded: Bool = true

    // Client-side blocklist, scoped to this account.
    // blockedJIDs: bare JIDs (DMs/roster contacts). blockedNicks: MUC nicknames, server-wide.
    @Published var blockedJIDs: Set<String> = []
    @Published var blockedNicks: Set<String> = []

    func isBlocked(jid: String) -> Bool {
        blockedJIDs.contains(jid.lowercased())
    }

    func isBlocked(nick: String) -> Bool {
        blockedNicks.contains(nick)
    }

    /// Sanitized display forms of blocked MUC nicks. Transcript messages store the
    /// sanitized sender (not the raw nick), so hiding them keys on this.
    var blockedDisplayNicks: Set<String> {
        Set(blockedNicks.map { $0.sanitizedForNicknameDisplay() })
    }

    var domain: String {
        jid.components(separatedBy: "@").last ?? hostname
    }

    var username: String {
        jid.components(separatedBy: "@").first ?? jid
    }

    init(name: String, hostname: String, port: Int = 5222, jid: String) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.jid = jid
    }
}
