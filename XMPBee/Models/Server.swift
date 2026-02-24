import Foundation

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
