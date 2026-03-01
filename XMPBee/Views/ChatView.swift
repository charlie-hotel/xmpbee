import SwiftUI
import AppKit

/// Main chat message area — Liquid Glass design with floating topic and input bars
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
            // Messages fill the full area — content shows through glass bars
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let room = viewModel.selectedRoom {
                            ForEach(room.messages) { msg in
                                if !hideJoinPart || (msg.type != .join && msg.type != .part && msg.type != .quit) {
                                    MessageRow(message: msg)
                                        .id(msg.id)
                                }
                            }
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .id(viewModel.selectedRoom?.id) // Force recreation on room change
                .defaultScrollAnchor(.bottom) // Start at bottom
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: 44)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 64)
                }
                .onChange(of: viewModel.selectedRoom?.id) {
                    // Clear height cache on room switch — prevents stale entries accumulating
                    messageHeightCache.removeAll()
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
                .onChange(of: viewModel.scrollToBottomTrigger) {
                    // Scroll to bottom on initial connect (after topic received)
                    if let last = viewModel.selectedRoom?.messages.last {
                        DispatchQueue.main.async {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
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

            TextField("Type a message...", text: $viewModel.inputText)
                .font(Theme.monoFont)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit {
                    viewModel.sendMessage()
                }
                .onKeyPress(.tab) {
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

/// Shared URL detector for link detection
private let urlDetector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}()

/// Helper to add clickable links to text
private func addLinks(to attrString: NSMutableAttributedString, in range: NSRange) {
    guard let detector = urlDetector else { return }

    let matches = detector.matches(in: attrString.string, range: range)
    for match in matches {
        if let url = match.url {
            attrString.addAttribute(.link, value: url, range: match.range)
            attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            attrString.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
        }
    }
}

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

    return result
}

/// Extension to convert SwiftUI Color to NSColor
extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

/// A single message row — IRC-style formatting using native NSTextView
struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        MessageTextView(messageID: message.id.uuidString, attributedString: buildMessageAttributedString(message))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
    }
}

// MARK: - Native Text View for Performance

/// Shared height cache keyed by message ID + width to prevent LazyVStack jitter
private var messageHeightCache: [String: CGFloat] = [:]

/// NSTextView wrapper for message content - handles links and selection natively
struct MessageTextView: NSViewRepresentable {
    let messageID: String
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false

        // Configure text container
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = .zero

        // Disable scrolling - we're in a ScrollView
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        // Max size
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)

        // Set content immediately so first sizeThatFits call has content to measure
        textView.textStorage?.setAttributedString(attributedString)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // Only update if content actually changed
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
            // Invalidate cached height for this message
            messageHeightCache.removeValue(forKey: messageID)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let rawWidth = proposal.width ?? 800
        let width = rawWidth.isFinite ? rawWidth : 800
        let cacheKey = "\(messageID)@\(Int(width))"

        // Return cached height if available - avoids layout thrashing in LazyVStack
        if let cached = messageHeightCache[cacheKey] {
            return CGSize(width: width, height: cached)
        }

        nsView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let height = nsView.layoutManager?.usedRect(for: nsView.textContainer!).height ?? 0

        messageHeightCache[cacheKey] = height
        return CGSize(width: width, height: height)
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
