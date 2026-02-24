import SwiftUI

/// Connection dialog matching Adium's XMPP account options
struct ConnectSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverName = ""
    @State private var hostname = ""
    @State private var port = "5222"
    @State private var jid = ""
    @State private var password = ""
    @State private var resource = "XMPBee"
    @State private var conferenceServer = ""
    @State private var roomsToJoin = ""
    @State private var nickname = ""

    // Security options matching Adium
    @State private var securityMode: SecurityMode = .requireTLS

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to XMPP Server")
                .font(.system(size: 15, weight: .semibold))

            GroupBox("Account") {
                VStack(alignment: .leading, spacing: 8) {
                    field("JID:", text: $jid, placeholder: "user@example.com")
                    HStack {
                        Text("Password:")
                            .font(.system(size: 12))
                            .frame(width: 140, alignment: .trailing)
                        SecureField("", text: $password)
                            .font(.system(size: 13))
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Nickname:", text: $nickname, placeholder: "mynick")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Connect Server:", text: $hostname, placeholder: "conference.goonfleet.com")
                    HStack {
                        field("Port:", text: $port, placeholder: "5222")
                            .frame(maxWidth: 240)
                        Spacer()
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Security") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("Encryption:")
                            .font(.system(size: 12))
                            .frame(width: 140, alignment: .trailing)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $securityMode) {
                                Text("Require SSL/TLS").tag(SecurityMode.requireTLS)
                                Text("Opportunistic TLS").tag(SecurityMode.opportunisticTLS)
                                Text("Direct TLS (port 5223)").tag(SecurityMode.directTLS)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            .font(.system(size: 12))

                            Text("\"Require SSL/TLS\" uses STARTTLS on port 5222 (recommended)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)

                            if securityMode == .opportunisticTLS {
                                Text("⚠️ Opportunistic TLS may fall back to an unencrypted connection if the server does not offer STARTTLS.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Rooms (MUC)") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Conference Server:", text: $conferenceServer, placeholder: "conference.example.com")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Rooms to join:")
                                .font(.system(size: 12))
                                .frame(width: 140, alignment: .trailing)
                            TextField("elysium", text: $roomsToJoin)
                                .font(.system(size: 13))
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("Comma-separated room names (without @domain)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 144)
                    }
                    field("Display Name:", text: $serverName, placeholder: "My Server")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connectAndDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(jid.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        // hostname is auto-derived from JID at connect time if left empty
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 140, alignment: .trailing)
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func connectAndDismiss() {
        // Trim and validate JID format (security: prevent injection)
        let trimmedJID = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidJID(trimmedJID) else {
            return
        }

        let connectHost = hostname.isEmpty ? (trimmedJID.components(separatedBy: "@").last ?? "") : hostname
        let name = serverName.isEmpty ? connectHost : serverName
        let portNum = Int(port) ?? 5222
        let nick = nickname.isEmpty ? (trimmedJID.components(separatedBy: "@").first ?? "user") : nickname
        let res = resource.isEmpty ? "XMPBee" : resource
        let confServer = conferenceServer.isEmpty ? "conference.\(trimmedJID.components(separatedBy: "@").last ?? connectHost)" : conferenceServer

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
            securityMode: securityMode,
            nickname: nick,
            conferenceServer: confServer,
            rooms: rooms
        )

        // Clear @State password now that it has been handed off — don't let it linger in view state
        password = ""
        dismiss()
    }

    private func isValidJID(_ jid: String) -> Bool {
        // RFC 6122 / XMPP JID validation
        // Format: localpart@domainpart[/resource]

        // Must not be empty; enforce generous total cap (each part ≤ 1023 bytes per spec)
        guard !jid.isEmpty, jid.count <= 3071 else { return false }

        // No control characters (U+0000–U+001F) or DEL (U+007F) anywhere in the JID
        guard jid.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }) else { return false }

        // Must have exactly one @ sign separating localpart from the rest
        let atComponents = jid.components(separatedBy: "@")
        guard atComponents.count == 2 else { return false }

        let localpart = atComponents[0]
        let afterAt   = atComponents[1]   // domainpart or domainpart/resource

        // Localpart: 1–1023 chars, no @ or /
        guard !localpart.isEmpty, localpart.count <= 1023, !localpart.contains("/") else { return false }

        // Split domain from optional resource on the first /
        let domainParts = afterAt.components(separatedBy: "/")
        let domain = domainParts[0]

        // Domain: 1–253 chars, valid hostname characters only
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let hostnamePattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-\\.]*[a-zA-Z0-9])?$"
        guard let hostnameRegex = try? NSRegularExpression(pattern: hostnamePattern) else { return false }
        let hostnameRange = NSRange(domain.startIndex..., in: domain)
        guard hostnameRegex.firstMatch(in: domain, range: hostnameRange) != nil else { return false }

        // Resource (optional): 1–1023 chars if present
        if domainParts.count > 1 {
            let resource = domainParts[1...].joined(separator: "/")
            guard !resource.isEmpty, resource.count <= 1023 else { return false }
        }

        return true
    }
}

// Make SecurityMode conform to Hashable for Picker
extension SecurityMode: Hashable {}
