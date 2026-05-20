import SwiftUI
import AppKit

/// Main chat message area — Liquid Glass design with floating topic and input bars.
///
/// The transcript itself is rendered into a single NSTextView (via `ChatTranscriptView`)
/// rather than a LazyVStack of per-message NSTextViews. That gives us:
///   • Native auto-scroll-follows-bottom: only follows when the user is already near the bottom.
///   • No blanking-on-scroll: one text container, all messages laid out coherently.
///   • Performance into the tens of thousands of messages — appends are O(new content),
///     not O(total messages), and NSLayoutManager's non-contiguous layout keeps memory bounded.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("hideJoinPart") private var hideJoinPart = true
    @FocusState private var isInputFocused: Bool
    @State private var topicHovered = false

    // MARK: - Tab completion state
    @State private var completionCandidates: [String] = []
    @State private var completionIndex: Int = 0
    @State private var completionBase: String = ""     // text before the partial word
    @State private var lastCompletedText: String = ""  // guards against cycling after manual edit

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transcript / empty state — content shows through glass bars
            Group {
                if viewModel.selectedRoom != nil {
                    ChatTranscriptView(
                        room: viewModel.selectedRoom,
                        // Touch messages.count so SwiftUI re-invokes updateNSView when new
                        // messages arrive even though Room is a separate ObservableObject.
                        messageCount: viewModel.selectedRoom?.messages.count ?? 0,
                        hideJoinPart: hideJoinPart,
                        scrollTrigger: viewModel.scrollToBottomTrigger
                    )
                } else {
                    emptyState
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 44)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 64)
            }
            .onChange(of: viewModel.selectedRoom?.id) {
                // Reset tab completion on room switch
                completionCandidates = []
                completionIndex = 0
                completionBase = ""
                lastCompletedText = ""
                // Focus input when switching rooms
                DispatchQueue.main.async {
                    isInputFocused = true
                }
            }

            // Floating topic bar at top
            VStack(spacing: 0) {
                topicBar
                Spacer()
            }

            // Floating input bar at bottom
            inputBar
        }
    }

    // MARK: - Tab Completion

    private func handleTabCompletion() {
        guard let room = viewModel.selectedRoom else { return }
        let text = viewModel.inputText

        // If the user edited the text since the last completion, discard the old cycle
        if !completionCandidates.isEmpty && text != lastCompletedText {
            completionCandidates = []
            completionIndex = 0
            completionBase = ""
        }

        if !completionCandidates.isEmpty {
            // Cycle to the next candidate
            completionIndex = (completionIndex + 1) % completionCandidates.count
            let nick = completionCandidates[completionIndex]
            let completed = completionBase.isEmpty ? "\(nick): " : "\(completionBase)\(nick) "
            viewModel.inputText = completed
            lastCompletedText = completed
            return
        }

        // Start a new completion — find the word currently being typed
        let partial = text.components(separatedBy: " ").last ?? ""
        guard !partial.isEmpty else { return }

        let base = String(text.dropLast(partial.count))
        let matches = room.occupants
            .map { $0.nick }
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
        guard !matches.isEmpty else { return }

        completionCandidates = matches
        completionIndex = 0
        completionBase = base

        let nick = matches[0]
        // IRC convention: "nick: " at the start of a line, "nick " mid-sentence
        let completed = base.isEmpty ? "\(nick): " : "\(base)\(nick) "
        viewModel.inputText = completed
        lastCompletedText = completed
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 80)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No channel selected")
                .font(Theme.monoFont)
                .foregroundStyle(.secondary)
            Text("Connect to a server or select a channel from the sidebar")
                .font(Theme.monoFontSmall)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Topic Bar (glass)

    private var topicBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let room = viewModel.selectedRoom {
                    Text(room.displayName)
                        .font(Theme.monoFontBold)
                        .foregroundStyle(Theme.channelText)

                    if !room.topic.isEmpty && !topicHovered {
                        Text("—")
                            .foregroundStyle(.tertiary)
                        Text(room.topic)
                            .font(Theme.monoFontSmall)
                            .foregroundStyle(Theme.topicText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    Text("XMPP Client")
                        .font(Theme.monoFontBold)
                        .foregroundStyle(Theme.channelText)
                }
                Spacer()
            }

            // Expanded topic with clickable links on hover
            if topicHovered, let room = viewModel.selectedRoom, !room.topic.isEmpty {
                TopicTextView(topic: room.topic)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                topicHovered = hovering
            }
        }
    }

    // MARK: - Input Bar (glass)

    /// True when sending a message would actually do something — i.e. there's a
    /// selected room AND its server is currently connected.  Used to gate the
    /// input bar so we don't queue sends into a torn-down connection, which is
    /// what made the reconnect-race crash reachable in the first place.
    private var canSendMessage: Bool {
        viewModel.selectedRoom != nil && viewModel.selectedServer?.isConnected == true
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            if let room = viewModel.selectedRoom {
                Text(room.nickname)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassEffect(.clear, in: .capsule)
            }

            TextField(
                canSendMessage ? "Type a message..." : "Disconnected — waiting to reconnect",
                text: $viewModel.inputText
            )
                .font(Theme.monoFont)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .disabled(!canSendMessage)
                .onSubmit {
                    guard canSendMessage else { return }
                    viewModel.sendMessage()
                }
                .onKeyPress(.tab) {
                    guard canSendMessage else { return .handled }
                    handleTabCompletion()
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

// MARK: - Link detection helpers

/// Shared URL detector for link detection
private let urlDetector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}()

/// URL schemes we'll render as clickable affordances and dispatch via
/// NSWorkspace.shared.open(_:).  Everything else stays as plain text — the user
/// can still copy-paste it if they really want to follow it, but they don't get
/// the implicit "this is safe to click" signal of an underlined link.
///
/// `http` / `https` are the common case.  `mailto` is universal and lands in the
/// user's mail client (which has its own compose preview before sending).  `xmpp`
/// (XEP-0147) is included because it's the natural complement to a chat client —
/// click-to-DM is reasonable and the destination is just another XMPP client UI.
///
/// Notable exclusions and why:
///   • `file://` — would dispatch to whatever app handles the file's type, which
///     ranges from "open a PDF in Preview" (mostly benign) to "open .app/.scpt
///     and prompt to run it" (not).
///   • `x-apple-systempreferences:` — social-engineering primitive for "click
///     here to fix your settings" panes.
///   • Any third-party scheme registered on the user's machine (vlc://,
///     spotify://, custom dev-tool schemes) — opaque attack surface; we can't
///     reason about what each handler does with the URL.
private let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "xmpp"]

/// True if `url` is in the allowlist of schemes we'll render and dispatch.
private func isAllowedClickableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return allowedLinkSchemes.contains(scheme)
}

/// Helper to add clickable links to text.  Filters detected URLs through the
/// scheme allowlist so non-allowlisted URLs render as plain text rather than
/// underlined clickable affordances.
private func addLinks(to attrString: NSMutableAttributedString, in range: NSRange) {
    guard let detector = urlDetector else { return }

    let matches = detector.matches(in: attrString.string, range: range)
    for match in matches {
        guard let url = match.url, isAllowedClickableURL(url) else { continue }
        attrString.addAttribute(.link, value: url, range: match.range)
        attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
        attrString.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
    }
}

/// Paragraph style applied to every message — controls inter-message spacing and
/// keeps multi-line bodies tight. paragraphSpacing ≈ the original `.padding(.vertical, 1)` x 2.
private let messageParagraphStyle: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.paragraphSpacing = 2
    p.paragraphSpacingBefore = 0
    p.lineSpacing = 0
    p.lineBreakMode = .byWordWrapping
    return p
}()

/// Helper to build NSAttributedString for a complete message row
private func buildMessageAttributedString(_ message: ChatMessage) -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Font attributes
    let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    let monoSmallFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // Timestamp
    let timestamp = NSAttributedString(
        string: message.timeString + " ",
        attributes: [
            .font: monoFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    )
    result.append(timestamp)

    // Message content based on type
    switch message.type {
    case .chat:
        let bracket1 = NSAttributedString(string: "<", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor])
        result.append(bracket1)

        let nickColor = NSColor(name: nil) { appearance in
            let idx = ChatMessage.nickIndex(message.sender)
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let swiftColor = isDark ? ChatMessage.darkNickColors[idx] : ChatMessage.lightNickColors[idx]
            return NSColor(swiftColor)
        }
        let sender = NSAttributedString(string: message.sender, attributes: [.font: monoBoldFont, .foregroundColor: nickColor])
        result.append(sender)

        let bracket2 = NSAttributedString(string: "> ", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor])
        result.append(bracket2)

        let bodyStart = result.length
        let body = NSAttributedString(string: message.body, attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor])
        result.append(body)
        // Use result.length delta — NSRange needs UTF-16 code unit count, not Swift.count
        addLinks(to: result, in: NSRange(location: bodyStart, length: result.length - bodyStart))

    case .action:
        let text = "* \(message.sender) \(message.body)"
        let actionStart = result.length
        let actionNickColor = NSColor(name: nil) { appearance in
            let idx = ChatMessage.nickIndex(message.sender)
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let swiftColor = isDark ? ChatMessage.darkNickColors[idx] : ChatMessage.lightNickColors[idx]
            return NSColor(swiftColor)
        }
        let action = NSAttributedString(string: text, attributes: [.font: monoFont, .foregroundColor: actionNickColor])
        result.append(action)
        // Use result.length delta — NSRange needs UTF-16 code unit count, not Swift.count
        addLinks(to: result, in: NSRange(location: actionStart, length: result.length - actionStart))

    case .join:
        let text = "→ \(message.sender) has joined"
        let join = NSAttributedString(string: text, attributes: [.font: monoSmallFont, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(join)

    case .part:
        var text = "← \(message.sender) has left"
        if !message.body.isEmpty {
            text += " (\(message.body))"
        }
        let part = NSAttributedString(string: text, attributes: [.font: monoSmallFont, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(part)

    case .quit:
        var text = "⇐ \(message.sender) has quit"
        if !message.body.isEmpty {
            text += " (\(message.body))"
        }
        let quit = NSAttributedString(string: text, attributes: [.font: monoSmallFont, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(quit)

    case .topic:
        let text = "✦ \(message.sender) changed the topic to: \(message.body)"
        let topicStart = result.length
        let topic = NSAttributedString(string: text, attributes: [.font: monoSmallFont, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(topic)
        // Use result.length delta — NSRange needs UTF-16 code unit count, not Swift.count
        addLinks(to: result, in: NSRange(location: topicStart, length: result.length - topicStart))

    case .system:
        let text = "• \(message.body)"
        let system = NSAttributedString(string: text, attributes: [.font: monoSmallFont, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(system)
    }

    // Apply paragraph style across the whole message so inter-message spacing is consistent
    result.addAttribute(
        .paragraphStyle,
        value: messageParagraphStyle,
        range: NSRange(location: 0, length: result.length)
    )

    return result
}

/// Extension to convert SwiftUI Color to NSColor
extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

// MARK: - Chat Transcript (single NSTextView)

/// Renders the full room scrollback into one NSTextView wrapped in an NSScrollView.
///
/// Update strategy:
///   • Room or filter toggle changed → rebuild the whole text storage, scroll to bottom.
///   • Otherwise → append only messages added since the last update.
///   • Auto-scroll-follows-bottom is gated by whether the user was near the bottom
///     immediately before the append (tracked via NSClipView bounds notifications).
struct ChatTranscriptView: NSViewRepresentable {
    let room: Room?
    /// Pass-through so SwiftUI re-runs updateNSView when room.messages grows
    /// (Room is its own ObservableObject and isn't observed here directly).
    let messageCount: Int
    let hideJoinPart: Bool
    let scrollTrigger: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.allowsUndo = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false  // we add links manually
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        // Horizontal layout: text view's width tracks the scroll view's content width.
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 6
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Non-contiguous layout keeps memory bounded on huge transcripts —
        // NSLayoutManager only lays out the visible region rather than the whole document.
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator

        scrollView.documentView = textView

        // Watch scroll position so we know whether the user is "stuck to the bottom"
        // (and should follow new messages) or scrolled up into the backlog.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView

        // Initial population
        context.coordinator.update(
            room: room,
            hideJoinPart: hideJoinPart,
            scrollTrigger: scrollTrigger
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            room: room,
            hideJoinPart: hideJoinPart,
            scrollTrigger: scrollTrigger
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?

        private var renderedRoomID: UUID?
        private var renderedCount: Int = 0
        private var renderedHideJoinPart: Bool = true
        private var lastScrollTrigger: Int = 0
        /// True when the user is at (or within a few pixels of) the bottom.
        /// Updated by NSClipView bounds notifications as the user scrolls.
        private var stickToBottom: Bool = true
        /// Guards stickToBottom from being clobbered by the bounds-change we trigger
        /// ourselves when programmatically scrolling.
        private var ignoreBoundsChange: Bool = false

        // MARK: Scroll tracking

        @objc func boundsChanged(_ note: Notification) {
            guard !ignoreBoundsChange else { return }
            updateStickToBottom()
        }

        private func updateStickToBottom() {
            guard let scrollView, let textView else { return }
            let visible = scrollView.documentVisibleRect
            let bottom = textView.bounds.maxY
            // Within ~24pt of the bottom counts as "at bottom" — gives wiggle room for
            // the layout settling and for users who flick rather than scroll precisely.
            stickToBottom = visible.maxY >= bottom - 24
        }

        // MARK: Update entry point

        func update(room: Room?, hideJoinPart: Bool, scrollTrigger: Int) {
            guard let textView, let storage = textView.textStorage else { return }

            guard let room else {
                if storage.length > 0 {
                    storage.beginEditing()
                    storage.setAttributedString(NSAttributedString())
                    storage.endEditing()
                }
                renderedRoomID = nil
                renderedCount = 0
                renderedHideJoinPart = hideJoinPart
                lastScrollTrigger = scrollTrigger
                return
            }

            let roomChanged = room.id != renderedRoomID
            let filterChanged = hideJoinPart != renderedHideJoinPart

            // Full rebuild path: room switched or join/part toggle flipped.
            if roomChanged || filterChanged {
                rebuild(room: room, hideJoinPart: hideJoinPart, storage: storage)
                renderedRoomID = room.id
                renderedCount = room.messages.count
                renderedHideJoinPart = hideJoinPart
                stickToBottom = true
                lastScrollTrigger = scrollTrigger
                scrollToBottomDeferred()
                return
            }

            // External "scroll to bottom now" trigger — e.g. topic-received on initial connect.
            let triggerFired = scrollTrigger != lastScrollTrigger
            if triggerFired {
                lastScrollTrigger = scrollTrigger
                stickToBottom = true
            }

            // Incremental append path.
            let current = room.messages.count
            if current > renderedCount {
                let wasAtBottom = stickToBottom

                let appended = NSMutableAttributedString()
                for i in renderedCount..<current {
                    let m = room.messages[i]
                    if hideJoinPart && (m.type == .join || m.type == .part || m.type == .quit) {
                        continue
                    }
                    appended.append(buildMessageAttributedString(m))
                    appended.append(NSAttributedString(string: "\n"))
                }
                renderedCount = current

                if appended.length > 0 {
                    storage.beginEditing()
                    storage.append(appended)
                    storage.endEditing()
                    if wasAtBottom {
                        scrollToBottomDeferred()
                    }
                }
            } else if current < renderedCount {
                // Message list was truncated/reset (e.g. rejoin clears history) —
                // fall back to a full rebuild so we stay consistent.
                rebuild(room: room, hideJoinPart: hideJoinPart, storage: storage)
                renderedCount = room.messages.count
                scrollToBottomDeferred()
            }

            if triggerFired {
                scrollToBottomDeferred()
            }
        }

        // MARK: Rendering

        private func rebuild(room: Room, hideJoinPart: Bool, storage: NSTextStorage) {
            let full = NSMutableAttributedString()
            for m in room.messages {
                if hideJoinPart && (m.type == .join || m.type == .part || m.type == .quit) {
                    continue
                }
                full.append(buildMessageAttributedString(m))
                full.append(NSAttributedString(string: "\n"))
            }
            storage.beginEditing()
            storage.setAttributedString(full)
            storage.endEditing()
        }

        private func scrollToBottomDeferred() {
            // Defer to next runloop so NSLayoutManager has finished laying out the
            // newly-appended text and `scrollToEndOfDocument` actually lands at the end.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                self.ignoreBoundsChange = true
                textView.scrollToEndOfDocument(nil)
                self.stickToBottom = true
                // Re-enable on the next runloop tick, after the bounds-change settles.
                DispatchQueue.main.async { [weak self] in
                    self?.ignoreBoundsChange = false
                }
            }
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // Resolve the click target to a URL.
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            // Defense-in-depth: even if a non-allowlisted URL somehow landed in the
            // attributed string with a .link attribute (the addLinks() helper now
            // filters them, but pasted attributed text from elsewhere could carry
            // one), refuse to dispatch.  Returning true here tells NSTextView we
            // "handled" the click, which suppresses its own NSWorkspace.open call
            // that would otherwise fire as a fallback.
            guard let url, isAllowedClickableURL(url) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

// MARK: - Topic Text View

/// Lightweight NSTextView for the expanded topic bar — supports links and wrapping
struct TopicTextView: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(buildTopicAttributedString(topic))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.textStorage?.string != topic {
            textView.textStorage?.setAttributedString(buildTopicAttributedString(topic))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let rawWidth = proposal.width ?? 800
        let width = rawWidth.isFinite ? rawWidth : 800
        nsView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let height = nsView.layoutManager?.usedRect(for: nsView.textContainer!).height ?? 0
        return CGSize(width: width, height: height)
    }

    private func buildTopicAttributedString(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        // result.length is UTF-16 code unit count; text.count is Swift character count — not the same
        addLinks(to: result, in: NSRange(location: 0, length: result.length))
        return result
    }
}

// MARK: - View Extensions

extension View {
    /// Conditionally apply a modifier
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
