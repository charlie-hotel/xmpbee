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
                        scrollTrigger: viewModel.scrollToBottomTrigger,
                        blockedSenders: viewModel.selectedServer?.blockedDisplayNicks ?? []
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
                    let isBlockedDM = room.isDM && (viewModel.selectedServer?.isBlocked(jid: room.jid) ?? false)
                    Text(room.displayName)
                        .font(Theme.monoFontBold)
                        .foregroundStyle(Theme.channelText)
                        .strikethrough(isBlockedDM, color: .secondary)

                    if isBlockedDM {
                        Image(systemName: "person.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Unblock") {
                            if let server = viewModel.selectedServer {
                                viewModel.unblockJID(room.jid, on: server)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue)
                    }

                    if !isBlockedDM && !room.topic.isEmpty && !topicHovered {
                        Text("-")
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
                canSendMessage ? "Type a message..." : "Disconnected, waiting to reconnect",
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

// MARK: - Link / scheme allowlist (macOS bridge to shared builder)

/// True if `url` is in the shared allowlist of schemes we'll render and dispatch.
/// Defined as a thin wrapper so the click-handler below keeps reading the same.
private func isAllowedClickableURL(_ url: URL) -> Bool {
    MessageAttributedStringBuilder.isAllowedClickableURL(url)
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

// MARK: - macOS resolution of shared style intent

/// Resolve a shared `FontRole` to the exact `NSFont` the original code used.
private func nsFont(for role: MessageAttributedStringBuilder.FontRole) -> NSFont {
    switch role {
    case .mono:      return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    case .monoBold:  return NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    case .monoSmall: return NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

/// Resolve a shared `ColorRole` to the exact `NSColor` the original code used.
/// `.nick` reproduces the original appearance-aware dynamic color so it still
/// tracks light/dark mode at draw time.
private func nsColor(for role: MessageAttributedStringBuilder.ColorRole) -> NSColor {
    switch role {
    case .primary:   return NSColor.labelColor
    case .secondary: return NSColor.secondaryLabelColor
    case .tertiary:  return NSColor.tertiaryLabelColor
    case .link:      return NSColor.linkColor
    case .nick(let idx):
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark
                ? MessageAttributedStringBuilder.darkNickColors[idx]
                : MessageAttributedStringBuilder.lightNickColors[idx]
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1.0)
        }
    }
}

/// Convert a platform-neutral `AttributedString` from the shared builder into the
/// macOS `NSAttributedString`, reapplying the exact AppKit-only bits (font, color,
/// link underline + link color) so the rendering is identical to before.
private func makeNSAttributedString(
    from attr: AttributedString
) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()
    for run in attr.runs {
        let substring = String(attr[run.range].characters)
        var attrs: [NSAttributedString.Key: Any] = [:]

        if let style = run.messageStyle {
            attrs[.font] = nsFont(for: style.font)
            attrs[.foregroundColor] = nsColor(for: style.color)
        } else {
            // Defensive fallback — should not happen for builder output.
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attrs[.foregroundColor] = NSColor.labelColor
        }

        // Links: reproduce the original `.link` + underline + link color stamp.
        if let url = run.link {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = NSColor.linkColor
        }

        result.append(NSAttributedString(string: substring, attributes: attrs))
    }
    return result
}

/// Helper to build NSAttributedString for a complete message row, from the shared
/// platform-neutral builder.
private func buildMessageAttributedString(_ message: ChatMessage) -> NSAttributedString {
    let result = makeNSAttributedString(
        from: MessageAttributedStringBuilder.attributedString(for: message)
    )

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
    /// Sanitized display nicks blocked on this room's server — their lines are hidden.
    /// A change forces a full rebuild so block/unblock re-renders immediately.
    let blockedSenders: Set<String>

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
            blockedSenders: blockedSenders,
            scrollTrigger: scrollTrigger
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            room: room,
            hideJoinPart: hideJoinPart,
            blockedSenders: blockedSenders,
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
        private var renderedBlockedSenders: Set<String> = []
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

        func update(room: Room?, hideJoinPart: Bool, blockedSenders: Set<String>, scrollTrigger: Int) {
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
                renderedBlockedSenders = blockedSenders
                lastScrollTrigger = scrollTrigger
                return
            }

            let roomChanged = room.id != renderedRoomID
            let filterChanged = hideJoinPart != renderedHideJoinPart
            let blocklistChanged = blockedSenders != renderedBlockedSenders

            // Full rebuild path: room switched, join/part toggle flipped, or blocklist changed.
            if roomChanged || filterChanged || blocklistChanged {
                rebuild(room: room, hideJoinPart: hideJoinPart, blockedSenders: blockedSenders, storage: storage)
                renderedRoomID = room.id
                renderedCount = room.messages.count
                renderedHideJoinPart = hideJoinPart
                renderedBlockedSenders = blockedSenders
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
                    if blockedSenders.contains(m.sender) { continue }
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
                rebuild(room: room, hideJoinPart: hideJoinPart, blockedSenders: blockedSenders, storage: storage)
                renderedCount = room.messages.count
                scrollToBottomDeferred()
            }

            if triggerFired {
                scrollToBottomDeferred()
            }
        }

        // MARK: Rendering

        private func rebuild(room: Room, hideJoinPart: Bool, blockedSenders: Set<String>, storage: NSTextStorage) {
            let full = NSMutableAttributedString()
            for m in room.messages {
                if blockedSenders.contains(m.sender) { continue }
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
            URLOpener.open(url)
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
        // The shared builder tags topic text as `.monoSmall` (11pt), which
        // resolves to the original topic-bar font — no override needed.
        let shared = MessageAttributedStringBuilder.topicAttributedString(text)
        return makeNSAttributedString(from: shared)
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
