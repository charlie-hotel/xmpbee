import Foundation

/// Security mode matching Adium's options
enum SecurityMode: String {
    case requireTLS       // STARTTLS required (default, like Adium's "Require SSL/TLS")
    case opportunisticTLS // Try STARTTLS, fall back to plain if server doesn't offer it
    case directTLS        // Legacy SSL on port 5223
    // .none has been removed — unencrypted connections are not supported
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

    var onData: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onTLSReady: (() -> Void)?

    private(set) var isConnected = false
    private(set) var isTLSActive = false

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
        // Security: Track activity time for idle timeout
        lastActivityTime = Date()
        performOnStreamThread { [weak self] in
            guard let self = self else { return }
            self.writeBuffer.append(data)
            self.flushWriteBuffer()
        }
    }

    /// Drain the write buffer into the output stream.  Called on the stream thread.
    /// Handles partial writes by keeping unwritten bytes for the next hasSpaceAvailable event.
    private func flushWriteBuffer() {
        guard let output = outputStream, !writeBuffer.isEmpty else { return }
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
            writeBuffer.removeFirst(written)
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
        DispatchQueue.main.async {
            self.onDisconnected?(nil)
        }
        performOnStreamThread { [weak self] in
            self?.closeStreams()
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

    /// Run a block on the stream thread's RunLoop
    private func performOnStreamThread(_ block: @escaping () -> Void) {
        guard let thread = streamThread, !thread.isCancelled else {
            // Fallback: run directly if thread isn't available yet
            block()
            return
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

    /// Fast ping response — called directly on the stream thread to avoid main queue latency.
    /// Uses simple string parsing instead of full XML parsing (security: no regex DoS).
    private func handlePingFast(_ str: String) {
        // Security: Limit string length to prevent DoS
        guard str.count < 4096 else { return }

        // Extract id attribute using safe string parsing
        guard let id = extractAttribute("id", from: str, maxLength: 256) else {
            #if DEBUG
            print("[XMPP] Fast ping: could not extract id")
            #endif
            return
        }

        // Extract from attribute
        let from = extractAttribute("from", from: str, maxLength: 512) ?? ""

        // Build pong response
        let pong: String
        if from.isEmpty {
            pong = "<iq type='result' id='\(id.xmlEscaped)'/>"
        } else {
            pong = "<iq type='result' id='\(id.xmlEscaped)' to='\(from.xmlEscaped)'/>"
        }

        guard let output = outputStream, let data = pong.data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                output.write(baseAddr, maxLength: data.count)
            }
        }
        // #if DEBUG
        // print("[XMPP] >>> \(pong) (fast pong)")
        // #endif
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
        let idle = Date().timeIntervalSince(lastActivityTime)
        if idle > idleTimeoutSeconds {
            #if DEBUG
            print("[XMPP] Idle timeout: \(Int(idle))s")
            #endif
            disconnect()
        }
    }

    private func closeStreams() {
        idleTimeoutTimer?.invalidate()
        idleTimeoutTimer = nil
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
                    DispatchQueue.main.async {
                        self.onDisconnected?(error)
                    }
                    closeStreams()
                    break
                }
            }

        case .errorOccurred:
            let error = aStream.streamError
            DispatchQueue.main.async {
                self.onDisconnected?(error)
            }
            closeStreams()

        case .endEncountered:
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
