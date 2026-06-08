import SwiftUI
import UIKit

// MARK: - ChatPaneView (iOS)
//
// The real iOS chat pane: a scrolling transcript + a message composer.
// Renders through the SHARED `MessageAttributedStringBuilder` and drives the
// existing `ChatViewModel`.
//
// IMPORTANT: This view does NOT own a `NavigationStack`. Its parent supplies the
// navigation context (iPhone shell's `NavigationStack`, or the iPad
// `NavigationSplitView`). It attaches `.navigationTitle`/`.toolbar` directly so
// they hang on the parent nav context.
struct ChatPaneView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("hideJoinPart") private var hideJoinPart = true
    /// Horizontal displacement + fade for the floating composer, driven by the iPhone
    /// drawers so an expanding sidebar pushes the input bar out of its way in the
    /// sidebar's direction of travel. iPad uses the defaults (no drawers).
    var composerOffsetX: CGFloat = 0
    var composerOpacity: Double = 1

    var body: some View {
        Group {
            if let room = viewModel.selectedRoom {
                roomView(room)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
        .navigationTitle(viewModel.selectedRoom?.displayName ?? "XMPBee")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let room = viewModel.selectedRoom, room.isDM,
               viewModel.selectedServer?.isBlocked(jid: room.jid) == true {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(room.displayName)
                            .font(.headline)
                            .strikethrough(true, color: .secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unblock") {
                        if let server = viewModel.selectedServer {
                            viewModel.unblockJID(room.jid, on: server)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            ReconnectBanner()
        }
        // Allowlist-checked link dispatch — taps on `.link` runs route here.
        .environment(\.openURL, OpenURLAction { url in
            if MessageAttributedStringBuilder.isAllowedClickableURL(url) {
                URLOpener.open(url)
            }
            return .handled
        })
    }

    // MARK: - Room view (transcript + composer)

    @ViewBuilder
    private func roomView(_ room: Room) -> some View {
        // Floating glass composer docked at the bottom; the transcript scrolls
        // underneath it and shows through the glass (mirrors the macOS input bar).
        RoomTranscriptView(room: room, hideJoinPart: hideJoinPart, scrollTrigger: viewModel.scrollToBottomTrigger, blockedSenders: viewModel.selectedServer?.blockedDisplayNicks ?? [])
            // Tap the transcript to dismiss the keyboard. Simultaneous so it doesn't
            // swallow link taps, text selection, or scrolling.
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView()
                    .offset(x: composerOffsetX)
                    .opacity(composerOpacity)
            }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No channel selected")
                .font(Theme.monoFont)
                .foregroundStyle(.secondary)
            Text(sizeClass == .compact
                 ? "Open the sidebar to choose a channel"
                 : "Select a channel from the sidebar")
                .font(Theme.monoFontSmall)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reconnect banner
//
// Surfaces the view model's `reconnectStatus` UI projection at the top of the chat
// pane. Failure takes precedence over an in-flight attempt. Renders nothing when no
// server has reconnect status. Kept small so the type-checker stays fast.
private struct ReconnectBanner: View {
    @EnvironmentObject var viewModel: ChatViewModel

    var body: some View {
        let failed = serverNames(matching: .failed)
        let attempting = serverNames(matching: .attempting)

        if !failed.isEmpty {
            banner {
                Text(failed.count == 1 ? "\(failed[0]) disconnected" : "\(failed.count) servers disconnected")
                    .font(Theme.monoFontSmall)
                Spacer(minLength: 8)
                Button("Retry", action: retryFailed)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if !attempting.isEmpty {
            banner {
                ProgressView()
                    .controlSize(.small)
                Text(attempting.count == 1 ? "Reconnecting to \(attempting[0])…" : "Reconnecting (\(attempting.count))…")
                    .font(Theme.monoFontSmall)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular)
    }

    /// Server names whose reconnect projection equals `state`, in stable sidebar order.
    private func serverNames(matching state: ChatViewModel.ReconnectUIState) -> [String] {
        viewModel.servers
            .filter { viewModel.reconnectStatus[$0.id] == state }
            .map(\.name)
    }

    /// Retry every server currently showing the failed state.
    private func retryFailed() {
        for server in viewModel.servers where viewModel.reconnectStatus[server.id] == .failed {
            viewModel.manualReconnect(server: server)
        }
    }
}

// MARK: - Transcript

/// Scrolling transcript for a single room. Observes the `Room` directly so it
/// re-renders as `messages`/`topic` change. Auto-scrolls to the bottom when new
/// messages arrive or when `scrollTrigger` (the view model's
/// `scrollToBottomTrigger`) changes.
private struct RoomTranscriptView: View {
    @ObservedObject var room: Room
    let hideJoinPart: Bool
    let scrollTrigger: Int
    /// Sanitized display nicks blocked on this room's server — their lines are hidden.
    var blockedSenders: Set<String> = []

    /// True when the user is at (or within ~24pt of) the bottom — mirrors the macOS
    /// `stickToBottom` gate so new messages only auto-scroll when already at the end.
    @State private var isAtBottom = true

    /// Messages to display — mirrors the macOS transcript's join/part/quit hiding.
    private var displayedMessages: [ChatMessage] {
        room.messages.filter { msg in
            if blockedSenders.contains(msg.sender) { return false }
            if hideJoinPart && (msg.type == .join || msg.type == .part || msg.type == .quit) { return false }
            return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !room.topic.isEmpty {
                        TopicRow(topic: room.topic)
                            .padding(.bottom, 4)
                    }
                    ForEach(displayedMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    // Sentinel anchor at the very bottom for reliable scroll-to-end.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // Track proximity to the bottom (24pt slack, like macOS) as the user scrolls.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 24
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: room.messages.count) {
                // Only follow new messages when the user is already at the bottom; if
                // they've scrolled up to read history, don't yank them down (macOS parity).
                if isAtBottom { scrollToBottom(proxy) }
            }
            .onChange(of: room.id) {
                // Switching rooms jumps to the latest, like the macOS rebuild-and-scroll.
                isAtBottom = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: scrollTrigger) {
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private static let bottomAnchor = "xmpbee.transcript.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Defer so the new row is laid out before we scroll to the anchor.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }
}

// MARK: - Rows

/// One transcript row. Kept tiny so the SwiftUI type-checker stays fast.
private struct MessageRow: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(displayString)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayString: AttributedString {
        MessageStyleResolver.resolve(
            MessageAttributedStringBuilder.attributedString(for: message),
            dark: colorScheme == .dark
        )
    }
}

/// Expanded topic bar row (mono-small, primary, links). Mirrors the macOS topic.
private struct TopicRow: View {
    let topic: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(displayString)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    private var displayString: AttributedString {
        MessageStyleResolver.resolve(
            MessageAttributedStringBuilder.topicAttributedString(topic),
            dark: colorScheme == .dark
        )
    }
}

// MARK: - Composer

/// Bottom message composer. Drives `viewModel.inputText` and `sendMessage()`.
/// Sending is gated on a selected room whose server is connected (mirrors macOS).
private struct ComposerView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    private var canSendMessage: Bool {
        viewModel.selectedRoom != nil && viewModel.selectedServer?.isConnected == true
    }

    /// Input-bar text that reflects connection state.  On iOS connection status is
    /// surfaced here (and in the top banner) rather than logged into the transcript.
    private var inputPlaceholder: String {
        if canSendMessage { return "Type a message…" }
        guard let server = viewModel.selectedServer else { return "Not connected" }
        switch viewModel.reconnectStatus[server.id] {
        case .attempting: return "Reconnecting…"
        case .failed:     return "Disconnected — tap Retry to reconnect"
        case nil:         return "Disconnected — waiting to reconnect"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let room = viewModel.selectedRoom {
                Text(room.nickname)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassEffect(.clear, in: .capsule)
            }

            TextField(
                inputPlaceholder,
                text: $viewModel.inputText,
                axis: .vertical
            )
            .font(Theme.monoFont)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isInputFocused)
            .disabled(!canSendMessage)
            .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .disabled(!canSendMessage || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func send() {
        guard canSendMessage else { return }
        viewModel.sendMessage()
    }
}

// MARK: - iOS resolution of shared style intent
//
// Converts the platform-neutral `AttributedString` produced by
// `MessageAttributedStringBuilder` (whose runs carry `MessageStyleKey` intent +
// `.link`) into a SwiftUI `AttributedString` with concrete `.font`,
// `.foregroundColor`, `.underlineStyle`, and `.link` attributes.
//
// Nick colors are appearance-aware: each call resolves against the current
// `colorScheme` (passed in as `dark`), so colors track light/dark mode.
enum MessageStyleResolver {

    /// Resolve a shared `FontRole` to the iOS monospaced `Font` matching the
    /// macOS sizes/weights (12 regular, 12 bold, 11 regular).
    static func font(for role: MessageAttributedStringBuilder.FontRole) -> Font {
        switch role {
        case .mono:      return Font(UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        case .monoBold:  return Font(UIFont.monospacedSystemFont(ofSize: 12, weight: .bold))
        case .monoSmall: return Font(UIFont.monospacedSystemFont(ofSize: 11, weight: .regular))
        }
    }

    /// Resolve a shared `ColorRole` to a concrete `Color`. `.nick` selects from
    /// the light/dark palettes by index based on `dark`.
    static func color(for role: MessageAttributedStringBuilder.ColorRole, dark: Bool) -> Color {
        switch role {
        case .primary:   return .primary
        case .secondary: return .secondary
        case .tertiary:  return Color(uiColor: .tertiaryLabel)
        case .link:      return Color(uiColor: .link)
        case .nick(let idx):
            let palette = dark
                ? MessageAttributedStringBuilder.darkNickColors
                : MessageAttributedStringBuilder.lightNickColors
            let rgb = palette[idx % palette.count]
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
    }

    /// Convert the builder's `AttributedString` into a SwiftUI-ready one.
    static func resolve(_ source: AttributedString, dark: Bool) -> AttributedString {
        var result = source
        for run in source.runs {
            let range = run.range
            if let style = run.messageStyle {
                result[range].font = font(for: style.font)
                result[range].foregroundColor = color(for: style.color, dark: dark)
            } else {
                result[range].font = font(for: .mono)
                result[range].foregroundColor = .primary
            }
            // Links: keep the `.link` URL (allowlisted at build time) and add the
            // standard link color + underline so they read as tappable.
            if let url = run.link {
                result[range].link = url
                result[range].underlineStyle = .single
                result[range].foregroundColor = Color(uiColor: .link)
            }
        }
        return result
    }
}
