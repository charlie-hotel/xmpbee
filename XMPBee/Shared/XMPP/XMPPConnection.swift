import Foundation

/// Security mode for the XMPP connection.
///
/// Both modes guarantee an encrypted channel before SASL credentials are sent.
/// The previously-supported `opportunisticTLS` (try STARTTLS, silently fall back
/// to cleartext if the server doesn't advertise it) was removed because it allowed
/// a network attacker to strip the `<starttls/>` feature and harvest SCRAM proofs
/// over plaintext — see RFC 7590 §3.4.  Saved settings holding the old raw value
/// fall back to `.requireTLS` via the `SecurityMode(rawValue:)` initializer.
enum SecurityMode: String {
    case requireTLS  // STARTTLS required on port 5222 (default)
    case directTLS   // Legacy SSL on port 5223
}

/// Low-level TCP connection with STARTTLS support using Foundation streams.
/// Foundation's Stream API supports `startSecureConnection()` for mid-stream
/// TLS upgrade, which Network.framework does not.
class XMPPConnection: NSObject, StreamDelegate {
    private let host: String
    private let port: Int
    let securityMode: SecurityMode

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var streamThread: Thread?
    private var readBuffer = Data()
    private var writeBuffer = Data()
    // Guards against flushWriteBuffer() re-entering itself: output.write() can
    // synchronously deliver .hasSpaceAvailable on the same runloop, which would
    // shrink writeBuffer mid-flush and make the outer removeFirst overrun.
    private var isFlushing = false

    var onData: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onTLSReady: (() -> Void)?

    private(set) var isConnected = false
    private(set) var isTLSActive = false

    /// The JID we expect server-initiated XEP-0199 pings to come `from`.  Typically
    /// the bare server domain (the part after `@` in the user's JID).  The fast
    /// ping responder refuses to fire unless the inbound IQ's `from` attribute
    /// matches this exactly — closes the silent-online-status oracle where any
    /// peer could trigger a pong by including the ping namespace as a substring.
    /// Set by XMPPClient at connect time; nil disables the fast path entirely.
    var expectedPingSourceJID: String?

    // Security: Track activity for idle timeout
    private var lastActivityTime = Date()
    private var idleTimeoutTimer: Timer?
    private let idleTimeoutSeconds: TimeInterval = 300 // 5 minutes

    init(host: String, port: Int, securityMode: SecurityMode) {
        self.host = host
        self.port = port
        self.securityMode = securityMode
        super.init()
    }

    func connect() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let input = readStream?.takeRetainedValue() as? InputStream,
              let output = writeStream?.takeRetainedValue() as? OutputStream else {
            DispatchQueue.main.async {
                self.onDisconnected?(XMPPError.connectionFailed("Failed to create streams"))
            }
            return
        }

        inputStream = input
        outputStream = output

        // For direct TLS (port 5223), enable TLS immediately
        if securityMode == .directTLS {
            enableTLSOnStreams()
        }

        input.delegate = self
        output.delegate = self

        // Streams need a dedicated thread with a persistent RunLoop.
        // GCD queues don't guarantee a stable RunLoop for delegate callbacks.
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            input.schedule(in: .current, forMode: .default)
            output.schedule(in: .current, forMode: .default)
            input.open()
            output.open()

            // Keep the RunLoop alive as long as streams exist
            while self.inputStream != nil && !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "XMPPStreamThread"
        thread.qualityOfService = .default
        streamThread = thread
        thread.start()
    }

    func send(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        performOnStreamThread { [weak self] in
            guard let self = self else { return }
            // lastActivityTime is confined to the stream thread (also written by the
            // hasBytesAvailable handler) — bump it here, not on the caller's thread.
            self.lastActivityTime = Date()
            self.writeBuffer.append(data)
            self.flushWriteBuffer()
        }
    }

    /// Drain the write buffer into the output stream.  Called on the stream thread.
    /// Handles partial writes by keeping unwritten bytes for the next hasSpaceAvailable event.
    private func flushWriteBuffer() {
        guard let output = outputStream, !writeBuffer.isEmpty else { return }
        guard !isFlushing else { return }  // dropped bytes flush on the next hasSpaceAvailable/send
        isFlushing = true
        defer { isFlushing = false }

        let written: Int = writeBuffer.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return output.write(baseAddr, maxLength: writeBuffer.count)
        }
        if written < 0 {
            // Stream write error — treat as disconnect
            let error = output.streamError
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnected?(error)
            }
            closeStreams()
        } else if written > 0 {
            writeBuffer.removeFirst(min(written, writeBuffer.count))
        }
        // written == 0: stream not ready — keep buffer, flush on next hasSpaceAvailable
    }

    #if DEBUG
    /// Redact sensitive information from debug logs
    private func redactSensitiveData(_ xml: String) -> String {
        var redacted = xml

        // Redact SASL auth (contains password)
        if xml.contains("<auth") && xml.contains("mechanism='PLAIN'") {
            redacted = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>[REDACTED]</auth>"
        } else if xml.contains("<auth") && xml.contains("mechanism='SCRAM-SHA-1'") {
            redacted = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='SCRAM-SHA-1'>[REDACTED]</auth>"
        }

        // Redact SCRAM responses (contain authentication proofs)
        if xml.contains("<response") && xml.contains("xmpp-sasl") {
            redacted = "<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>[REDACTED]</response>"
        }

        return redacted
    }
    #endif

    func disconnect() {
        send("</stream:stream>")
        // Tear the stream down on its own thread, THEN announce the disconnect.
        // Announcing on main first lets the reconnect path start before the old
        // stream thread has finished — and the new connection ends up racing the
        // old one's still-pending writeBuffer mutations.  If the stream thread is
        // already gone, performOnStreamThread drops this block (see below); that's
        // safe because in that case onDisconnected was already fired by whichever
        // error/end-encountered path tore the thread down.
        performOnStreamThread { [weak self] in
            self?.closeStreams()
            DispatchQueue.main.async {
                self?.onDisconnected?(nil)
            }
        }
    }

    /// Upgrade the existing TCP connection to TLS (STARTTLS)
    func upgradeTLS() {
        performOnStreamThread { [weak self] in
            guard let self = self else { return }
            self.enableTLSOnStreams()
            self.isTLSActive = true
            DispatchQueue.main.async {
                self.onTLSReady?()
            }
        }
    }

    /// Run a block on the stream thread's RunLoop.
    ///
    /// Every block passed here mutates state (writeBuffer, the streams themselves)
    /// that MUST only be touched from the stream thread.  If the stream thread is
    /// gone, the block is dropped — running it on the caller's thread (formerly main)
    /// races the stream thread's tail-end work and traps inside Data's COW path.
    /// Callers that need a completion notification should do so via onDisconnected
    /// after closeStreams(), not by relying on this method to always invoke their block.
    private func performOnStreamThread(_ block: @escaping () -> Void) {
        guard let thread = streamThread, !thread.isCancelled else {
            return // Stream is torn down — nothing valid to do.
        }
        // CFRunLoopPerformBlock doesn't exist on Thread, so use perform(_:on:)
        let wrapper = BlockRunner(block: block)
        wrapper.perform(#selector(BlockRunner.run), on: thread, with: nil, waitUntilDone: false)
    }

    private func enableTLSOnStreams() {
        let sslSettings: [String: Any] = [
            kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
            // For self-signed certs during testing, you could set:
            // kCFStreamSSLValidatesCertificateChain as String: false,
        ]
        inputStream?.setProperty(sslSettings, forKey: .init(kCFStreamPropertySSLSettings as String))
        outputStream?.setProperty(sslSettings, forKey: .init(kCFStreamPropertySSLSettings as String))
    }

    /// Fast ping response — called on the stream thread to avoid main-queue latency.
    ///
    /// The original implementation fired on any chunk containing the substring
    /// `"urn:xmpp:ping"` and extracted attributes structure-blindly, which let
    /// any peer trigger a silent online-status oracle by sending a message
    /// stanza with a decorative `<x xmlns="urn:xmpp:ping"/>` child.  This
    /// rewrite locks the fast path down to genuine XEP-0199 server pings:
    ///
    ///   • Chunk must be a single `<iq>…</iq>` envelope with nothing before or
    ///     after it (multi-stanza chunks fall through to the slow path).
    ///   • `from` attribute on the IQ opener must equal `expectedPingSourceJID`
    ///     (set to the user's server domain at connect time).  XMPP servers
    ///     stamp `from` on inbound stanzas with the authenticated origin, so
    ///     this is not spoofable by other connected users.
    ///   • `type` must be `"get"`.
    ///   • The IQ's body must be exactly one `<ping xmlns="urn:xmpp:ping"/>`
    ///     element — no siblings, no nesting, no other children.
    ///
    /// Anything that fails these checks is silently passed through to the slow
    /// path (the dispatch to main below this site still happens) and never
    /// produces a fast pong.  The user's online status is no longer leaked.
    private func handlePingFast(_ str: String) {
        // Bound the work — pings should be small.
        guard str.count < 4096 else { return }

        // Without a configured source JID we can't safely gate; never fast-path.
        guard let expectedJID = expectedPingSourceJID, !expectedJID.isEmpty else { return }

        // Trim outer whitespace (TCP segment boundaries are noisy).
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must be a single, paired <iq …>…</iq> envelope.  A self-closing
        // `<iq …/>` couldn't carry a <ping/> body, so we don't accept it.
        guard trimmed.hasPrefix("<iq"),
              trimmed.hasSuffix("</iq>") else { return }

        // The character right after "<iq" must be whitespace — otherwise
        // we'd match other element names that happen to start with "iq".
        let afterIQ = trimmed.index(trimmed.startIndex, offsetBy: 3)
        guard afterIQ < trimmed.endIndex, trimmed[afterIQ].isWhitespace else { return }

        // Locate the end of the IQ opener tag (the first `>`).  Attributes
        // are parsed only from this opener, not from anywhere else in the
        // chunk — this is what prevents nested-element attributes from
        // leaking into our parse (the original bug).
        guard let openTagEnd = trimmed.firstIndex(of: ">") else { return }
        let openerTag = String(trimmed[..<trimmed.index(after: openTagEnd)])

        // Attribute checks — type, from, id — all read from the opener only.
        guard let typeAttr = extractAttribute("type", from: openerTag, maxLength: 32),
              typeAttr == "get" else { return }
        guard let fromAttr = extractAttribute("from", from: openerTag, maxLength: 512),
              fromAttr == expectedJID else { return }
        guard let id = extractAttribute("id", from: openerTag, maxLength: 256) else { return }

        // Validate the IQ body is exactly a single ping element.  Body is the
        // substring between the opener's `>` and the closing `</iq>`.
        let bodyStart = trimmed.index(after: openTagEnd)
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -5) // strip "</iq>"
        guard bodyStart <= bodyEnd else { return }
        let body = trimmed[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)

        guard body.hasPrefix("<ping"),
              body.contains("urn:xmpp:ping"),
              (body.hasSuffix("/>") || body.hasSuffix("</ping>")) else { return }
        // No siblings or nested elements: one element open-tag (self-closing)
        // or two (open + close).  Anything else means there's another element
        // alongside the ping, which disqualifies the fast path.
        let elementOpens = body.reduce(0) { $1 == "<" ? $0 + 1 : $0 }
        guard elementOpens == 1 || elementOpens == 2 else { return }

        // Build pong response.  We always include `to=fromAttr` because we've
        // already confirmed the source is the legitimate server JID.
        // Goes through writeBuffer (we're already on the stream thread), never the
        // raw stream: a direct write could interleave into the middle of a stanza
        // whose unwritten tail is still sitting in writeBuffer after a partial flush.
        let pong = "<iq type='result' id='\(id.xmlEscaped)' to='\(fromAttr.xmlEscaped)'/>"
        guard let data = pong.data(using: .utf8) else { return }
        writeBuffer.append(data)
        flushWriteBuffer()
    }

    /// Safely extract XML attribute value without regex (security: prevent regex DoS)
    private func extractAttribute(_ name: String, from xml: String, maxLength: Int) -> String? {
        // Look for name=" or name=' patterns
        let patterns = ["\(name)=\"", "\(name)='"]

        for pattern in patterns {
            guard let startRange = xml.range(of: pattern) else { continue }
            let quote = pattern.last! // " or '
            let afterStart = xml.index(startRange.upperBound, offsetBy: 0)
            guard let endRange = xml[afterStart...].firstIndex(of: quote) else { continue }

            let value = String(xml[afterStart..<endRange])
            // Security: Validate length and content
            guard value.count <= maxLength,
                  !value.contains("<"),
                  !value.contains(">") else {
                return nil
            }
            return value
        }
        return nil
    }

    // MARK: - Idle Timeout (Security)

    private func startIdleTimeoutTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.idleTimeoutTimer?.invalidate()
            self.idleTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: 30, // Check every 30 seconds
                repeats: true
            ) { [weak self] _ in
                self?.checkIdleTimeout()
            }
        }
    }

    private func checkIdleTimeout() {
        // lastActivityTime is stream-thread-confined — hop there to read it.
        performOnStreamThread { [weak self] in
            guard let self = self else { return }
            let idle = Date().timeIntervalSince(self.lastActivityTime)
            if idle > self.idleTimeoutSeconds {
                logDisconnectReason("CLIENT", "idle timeout - no inbound data for \(Int(idle))s, closing")
                DispatchQueue.main.async { self.disconnect() }
            }
        }
    }

    private func closeStreams() {
        // The idle timer was scheduled on the main runloop; Timer must be
        // invalidated from the thread it was installed on.
        DispatchQueue.main.async { [weak self] in
            self?.idleTimeoutTimer?.invalidate()
            self?.idleTimeoutTimer = nil
        }
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .current, forMode: .default)
        outputStream?.remove(from: .current, forMode: .default)
        inputStream = nil
        outputStream = nil
        writeBuffer = Data()
        isConnected = false
        streamThread?.cancel()
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream == outputStream {
                isConnected = true
                lastActivityTime = Date()
                startIdleTimeoutTimer()
                DispatchQueue.main.async { self.onConnected?() }
            }

        case .hasSpaceAvailable:
            if aStream == outputStream {
                flushWriteBuffer()
            }

        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            let bufferSize = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while input.hasBytesAvailable {
                let bytesRead = input.read(buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    // Security: Track activity time for idle timeout
                    lastActivityTime = Date()

                    let data = Data(bytes: buffer, count: bytesRead)
                    // Fast-path: respond to server pings immediately on the stream
                    // thread, bypassing the main queue which may be busy with UI updates.
                    // Check for ping in the raw data — handles both <ping xmlns=.../>
                    // and <ping xmlns=...></ping> forms
                    if let str = String(data: data, encoding: .utf8),
                       str.contains("urn:xmpp:ping") {
                        self.handlePingFast(str)
                    }

                    DispatchQueue.main.async {
                        self.onData?(data)
                    }
                } else if bytesRead < 0 {
                    // Read error — treat as disconnect
                    let error = aStream.streamError
                    logDisconnectReason("NETWORK", "read error: \(error?.localizedDescription ?? "unknown")")
                    DispatchQueue.main.async {
                        self.onDisconnected?(error)
                    }
                    closeStreams()
                    break
                }
            }

        case .errorOccurred:
            let error = aStream.streamError
            logDisconnectReason("NETWORK", "stream errorOccurred: \(error?.localizedDescription ?? "unknown")")
            DispatchQueue.main.async {
                self.onDisconnected?(error)
            }
            closeStreams()

        case .endEncountered:
            logDisconnectReason("REMOTE", "server closed the connection (stream EOF)")
            DispatchQueue.main.async {
                self.onDisconnected?(nil)
            }
            closeStreams()

        default:
            break
        }
    }
}

/// Helper to run a closure on a specific Thread via perform(_:on:with:)
private class BlockRunner: NSObject {
    let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}
