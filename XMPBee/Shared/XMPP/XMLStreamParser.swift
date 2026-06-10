import Foundation

/// Delegate for receiving parsed XMPP stanzas
protocol XMLStreamParserDelegate: AnyObject {
    func parser(_ parser: XMLStreamParser, didReceiveStanza stanza: XMLStanza)
    func parser(_ parser: XMLStreamParser, didReceiveStreamFeatures features: XMLStanza)
    func parserDidOpenStream(_ parser: XMLStreamParser, attributes: [String: String])
    func parserDidCloseStream(_ parser: XMLStreamParser)
    func parser(_ parser: XMLStreamParser, didFailWithError error: Error)
}

/// Represents a parsed XML element
class XMLStanza {
    let name: String
    var attributes: [String: String]
    var children: [XMLStanza] = []
    var text: String = ""
    weak var parent: XMLStanza?

    var xmlns: String? { attributes["xmlns"] }

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func child(named name: String) -> XMLStanza? {
        children.first { $0.name == name }
    }

    func child(named name: String, xmlns ns: String) -> XMLStanza? {
        children.first { $0.name == name && $0.xmlns == ns }
    }

    func children(named name: String) -> [XMLStanza] {
        children.filter { $0.name == name }
    }

    /// Build XML string
    func xmlString() -> String {
        var s = "<\(name)"
        for (k, v) in attributes {
            s += " \(k)=\"\(v.xmlEscaped)\""
        }
        if children.isEmpty && text.isEmpty {
            s += "/>"
        } else {
            s += ">"
            s += text.xmlEscaped
            for child in children { s += child.xmlString() }
            s += "</\(name)>"
        }
        return s
    }

    subscript(attr: String) -> String? {
        get { attributes[attr] }
        set { attributes[attr] = newValue }
    }
}

extension String {
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Streaming XML parser for XMPP using a persistent push-parser approach.
///
/// Instead of the fragile "wrap in a root element and re-parse" approach,
/// this uses a pipe-based InputStream feeding a long-lived XMLParser.
/// Data is pushed into the pipe as it arrives from the network, and the
/// parser runs on a background thread, firing SAX callbacks incrementally.
///
/// This matches the approach used by established XMPP libraries (XMPPFramework,
/// libstrophe, Smack): depth tracking identifies stanza boundaries, and
/// complete stanzas are dispatched as soon as they close at depth 1.
class XMLStreamParser: NSObject, XMLParserDelegate {
    weak var delegate: XMLStreamParserDelegate?

    /// Pipe for feeding data to the persistent XMLParser
    private var pipeInput: OutputStream?
    private var pipeOutput: InputStream?
    private var xmlParser: XMLParser?
    private var parserThread: Thread?

    /// Parser state — maintained across all data chunks
    private var depth = 0                     // Current element depth (stream:stream = 1)
    private var elementStack: [XMLStanza] = [] // Stack of open elements
    private var currentStanza: XMLStanza?      // Root stanza being built (depth 1 element)

    /// Whether we're inside an open XMPP stream
    private(set) var isStreamOpen = false

    /// Incremented each time a new parser is started.  The thread-exit closure
    /// captures its own generation so that a superseded parser thread cannot
    /// accidentally fire parserDidCloseStream after in-place recovery.
    private var parserGeneration = 0

    /// Set during in-place recovery so that the synthetic <stream:stream> we
    /// inject does not bubble up as a parserDidOpenStream event.
    private var isRecoveringStream = false

    /// Counts consecutive recovery attempts.  After maxRecoveryAttempts failures
    /// we give up and propagate a fatal error so XMPPClient can reconnect.
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 3

    /// Set the moment `<proceed/>` is recognized on the parser thread.  While set,
    /// `feed(_:)` drops incoming bytes and the dispatch site drops any further
    /// complete stanzas — closing the STARTTLS injection window where a MITM
    /// who packs `<proceed/>` plus attacker-controlled XMPP bytes into the same
    /// TCP segment could otherwise have those bytes parsed and delivered as
    /// legitimate pre-TLS stanzas while the TLS handshake is in flight.
    /// Cleared in `reset()` (called by XMPPClient.openStream() after `onTLSReady`).
    private var isTLSTransitioning = false

    /// Serial queue for pipe writes.  Writing to a full bound-stream pipe BLOCKS the
    /// writer until the parser thread drains it — doing that on the main queue (where
    /// feed() is called from) froze the whole UI whenever the parser stalled or died.
    private let feedQueue = DispatchQueue(label: "XMPBee.XMLStreamParser.feed")

    func feed(_ data: Data) {
        // STARTTLS gate: once `<proceed/>` has been seen, no more bytes go to the
        // parser until the post-TLS reset.  TLS handshake bytes are consumed by
        // the SSL stack directly from the socket, not by us.
        if isTLSTransitioning { return }

        // If parser isn't running yet, start it
        if pipeInput == nil {
            startParser()
        }
        guard let pipe = pipeInput else { return }

        // Feed RAW bytes.  No Data→String→Data round-trip: a TCP segment boundary can
        // split a multi-byte UTF-8 sequence, and String(data:) returning nil used to
        // silently drop the whole chunk (stream desync → parse error → lost stanzas).
        // The old regex that stripped <?xml?> declarations is gone for the same
        // reason — declarations only legitimately appear at the start of a stream,
        // and every stream (re)start gets a fresh parser via reset(), where a
        // declaration is valid document-start XML that NSXMLParser handles natively.
        //
        // Writes loop over partial writes; a write error (pipe closed by stopParser/
        // recovery) drops the remainder, which is correct — that parser is gone.
        feedQueue.async {
            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var offset = 0
                while offset < data.count {
                    let written = pipe.write(base + offset, maxLength: data.count - offset)
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    func reset() {
        stopParser()
        depth = 0
        elementStack = []
        currentStanza = nil
        isStreamOpen = false
        isRecoveringStream = false
        recoveryAttempts = 0
        // Reset the STARTTLS gate — the new (post-TLS) parser instance starts clean.
        isTLSTransitioning = false
    }

    // MARK: - Parser Lifecycle

    private func startParser() {
        // Stamp this parser instance with a generation number so its exit handler
        // can be suppressed if in-place recovery replaces it with a newer parser.
        parserGeneration += 1
        let myGeneration = parserGeneration

        // Create a bound pair of streams (pipe)
        var readStream: InputStream?
        var writeStream: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4 * 1024 * 1024, inputStream: &readStream, outputStream: &writeStream)

        guard let input = readStream, let output = writeStream else {
            #if DEBUG
            print("[XMLParser] Failed to create bound streams")
            #endif
            return
        }

        pipeOutput = input
        pipeInput = output

        // Open both ends before starting the parser thread to avoid
        // race conditions where data is written before the reader is ready
        input.open()
        output.open()

        let parser = XMLParser(stream: input)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        self.xmlParser = parser

        let thread = Thread { [weak self, myGeneration] in
            // This blocks until the stream is closed or an error occurs
            parser.parse()
            // Parser finished (stream closed or error)
            #if DEBUG
            print("[XMLParser] Parser thread exited (gen \(myGeneration))")
            #endif
            DispatchQueue.main.async { [weak self, myGeneration] in
                guard let self = self else { return }
                // Only fire the close event if this parser is still the active one.
                // If in-place recovery has already started a new parser (higher
                // generation), this handler belongs to a superseded parser and must
                // be silently discarded.
                guard self.parserGeneration == myGeneration else { return }
                if self.isStreamOpen {
                    self.isStreamOpen = false
                    self.delegate?.parserDidCloseStream(self)
                }
            }
        }
        thread.name = "XMPPXMLParserThread"
        thread.qualityOfService = .userInitiated
        parserThread = thread
        thread.start()
    }

    private func stopParser() {
        // NSXMLParser holds its delegate via an UNSAFE (assign) reference that it
        // never zeroes. The background parse() thread retains the XMLParser (but only
        // weakly references this XMLStreamParser), so if `self` is freed while parse()
        // is still unwinding — e.g. the account is deleted, releasing this object and
        // its pipe streams, which unblocks parse() with EOF — NSXMLParser reports the
        // resulting error to a dangling delegate and crashes (objc_opt_respondsToSelector
        // PAC trap on XMPPXMLParserThread). Clear the delegate FIRST, while `self` is
        // still alive, so the orphaned parser can't call back into a freed object.
        xmlParser?.delegate = nil
        pipeInput?.close()
        pipeOutput?.close()
        pipeInput = nil
        pipeOutput = nil
        parserThread?.cancel()
        parserThread = nil
        xmlParser = nil
    }

    deinit {
        // Backstop: a disconnected-but-not-reset parser leaves its thread blocked in
        // parse(). Deleting the account frees this object; releasing the pipe streams
        // unblocks parse() into its error path. stopParser() nils the parser delegate
        // before the streams are torn down, so that error path sees a nil delegate
        // instead of this freed object.
        stopParser()
    }

    /// Attempt to recover from a mid-stream parse error without dropping the
    /// TCP connection.  The dead NSXMLParser is replaced with a fresh one on a
    /// new pipe.  A synthetic <stream:stream> element is injected so the new
    /// parser has the document root NSXMLParser requires, but the delegate is
    /// NOT notified (isRecoveringStream suppresses parserDidOpenStream).
    /// Subsequent data from the server flows into the new parser as normal.
    ///
    /// If recovery fails maxRecoveryAttempts times in a row, a fatal error is
    /// propagated so XMPPClient can fall back to a clean reconnect.
    func recoverParser() {
        recoveryAttempts += 1
        guard recoveryAttempts <= maxRecoveryAttempts else {
            // Recovery exhausted — close the stream silently and let the reconnect
            // mechanism handle it.  We don't propagate an error because this is a
            // server-side XML problem the user doesn't need a dialog about.
            #if DEBUG
            print("[XMLParser] Recovery limit reached — closing stream for reconnect")
            #endif
            recoveryAttempts = 0
            isStreamOpen = false
            delegate?.parserDidCloseStream(self)
            return
        }

        #if DEBUG
        print("[XMLParser] Recovering parser in-place (attempt \(recoveryAttempts)/\(maxRecoveryAttempts))")
        #endif

        // Tear down the dead parser.  stopParser() closes the pipe, which
        // causes the blocked parse() call to return EOF and the parser thread
        // to exit — but the generation check in the exit handler will suppress
        // any parserDidCloseStream call from that stale thread.
        stopParser()

        // Reset in-stanza state — we're discarding whatever partial stanza was
        // being built when the error occurred.  Set depth to 0 so that the
        // synthetic <stream:stream> advances it to 1, and real stanzas then
        // arrive at depth 2 — matching the normal post-handshake parser state.
        depth = 0
        elementStack = []
        currentStanza = nil
        isRecoveringStream = true   // suppress the synthetic stream:stream callback

        // Start a fresh parser (bumps parserGeneration)
        startParser()

        // Prime the new parser with a synthetic stream root so NSXMLParser
        // believes it is correctly positioned inside an XML document.
        // The didStartElement callback suppresses the delegate notification.
        // Routed through feedQueue like all pipe writes: keeps ordering with any
        // in-flight chunks and keeps blocking writes off the main thread.
        let fakeStream = "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
        if let data = fakeStream.data(using: .utf8), let pipe = pipeInput {
            feedQueue.async {
                data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    var offset = 0
                    while offset < data.count {
                        let written = pipe.write(base + offset, maxLength: data.count - offset)
                        guard written > 0 else { return }
                        offset += written
                    }
                }
            }
        }
    }

    // MARK: - XMLParserDelegate (SAX callbacks)
    //
    // These fire on the parser thread as data arrives incrementally.
    // The persistent XMLParser reads from the pipe InputStream, blocking
    // when no data is available and resuming when more is written.
    //
    // Depth tracking:
    //   depth 0: document root (implicit)
    //   depth 1: <stream:stream> (the XMPP stream element, never closed until disconnect)
    //   depth 2: top-level stanzas (<iq>, <message>, <presence>, <stream:features>, etc.)
    //   depth 3+: child elements within stanzas
    //
    // When an element closes at depth 2, we have a complete stanza.

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        depth += 1

        // stream:stream is the XMPP stream root at depth 1
        if elementName == "stream:stream" || elementName.hasSuffix(":stream") {
            if isRecoveringStream {
                // This is our synthetic stream:stream injected during in-place recovery.
                // The delegate has already been notified of the real stream open — don't
                // fire parserDidOpenStream again.
                isRecoveringStream = false
                return
            }
            isStreamOpen = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.parserDidOpenStream(self, attributes: attributeDict)
            }
            return
        }

        let element = XMLStanza(name: elementName, attributes: attributeDict)

        if depth == 2 {
            // Top-level stanza (direct child of stream:stream)
            currentStanza = element
            elementStack = [element]
            // #if DEBUG
            // print("[XMLParser] Stanza start: <\(elementName)> at depth \(depth)")
            // #endif
        } else if depth > 2, let parent = elementStack.last {
            // Child element within a stanza
            element.parent = parent
            parent.children.append(element)
            elementStack.append(element)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elementStack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        // stream:stream closing means the XMPP session is ending
        if elementName == "stream:stream" || elementName.hasSuffix(":stream") {
            isStreamOpen = false
            depth -= 1
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.parserDidCloseStream(self)
            }
            return
        }

        if depth == 2, let stanza = currentStanza {
            // Complete top-level stanza — dispatch to delegate on main queue.
            // Capture the current generation so that stanzas queued by a superseded
            // parser (replaced during in-place recovery) are silently discarded.
            currentStanza = nil
            elementStack = []

            // STARTTLS gate: any stanza appearing AFTER we've seen <proceed/> but
            // before the post-TLS reset is treated as MITM-injected garbage and
            // silently dropped.  Combined with feed() dropping new input, this
            // closes the pre-TLS-handshake injection window.
            if isTLSTransitioning {
                depth -= 1
                return
            }

            // If THIS stanza is the STARTTLS <proceed/>, set the gate before the
            // dispatch so any stanzas already in the parser pipe behind it are
            // suppressed (they cannot have come over the TLS-protected channel —
            // TLS hasn't been negotiated yet).
            if stanza.name == "proceed" && stanza.xmlns == "urn:ietf:params:xml:ns:xmpp-tls" {
                isTLSTransitioning = true
            }

            let gen = parserGeneration

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.parserGeneration == gen else { return }
                if stanza.name == "stream:features" {
                    self.delegate?.parser(self, didReceiveStreamFeatures: stanza)
                } else {
                    self.delegate?.parser(self, didReceiveStanza: stanza)
                }
            }
        } else if !elementStack.isEmpty {
            elementStack.removeLast()
        }

        depth -= 1
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let nsError = parseError as NSError
        // prematureDocumentEndError is expected — the stream:stream is never closed
        // during normal operation
        if nsError.code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue {
            return
        }
        #if DEBUG
        print("[XMLParser] Error: \(parseError) (code: \(nsError.code))")
        #endif

        if isStreamOpen {
            // The TCP connection is still alive — attempt in-place recovery.
            // We restart just the XML parser layer, inject a synthetic stream root,
            // and continue receiving stanzas without any visible disruption.
            // recoverParser() must run on the main thread (it modifies shared state).
            DispatchQueue.main.async { [weak self] in
                self?.recoverParser()
            }
            return
        }

        // Stream not yet open — this is a genuine fatal error (e.g. initial
        // connection refused or server sent malformed headers).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.parser(self, didFailWithError: parseError)
        }
    }
}
