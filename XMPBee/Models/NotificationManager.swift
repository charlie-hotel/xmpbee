import Foundation
import UserNotifications
import AppKit

/// Manages macOS notifications with sound for incoming XMPP messages
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // MARK: - Notification Preferences

    @Published var notifyOnMessage = true
    @Published var notifyOnMention = true
    @Published var notifyOnDirectMessage = true
    @Published var notifyOnJoinPart = false
    @Published var playSound = true
    @Published var playSoundTwice = false

    /// Sound source: .system for built-in macOS sounds, .custom for a user-chosen file
    @Published var soundSource: SoundSource = .system

    /// Name of the selected system sound (e.g. "Glass", "Ping", "Purr")
    @Published var systemSoundName: String = "Glass"

    /// File URL to a custom sound file (.aiff, .wav, .caf, .mp3)
    /// The file gets copied into the app's sound directory so UNNotification can use it
    @Published var customSoundURL: URL? = nil

    /// Resolved display name of the custom sound (just the filename)
    var customSoundDisplayName: String {
        customSoundURL?.lastPathComponent ?? "None"
    }

    /// All available macOS system sounds
    static let availableSystemSounds: [String] = {
        let systemSoundDir = "/System/Library/Sounds"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: systemSoundDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }()

    enum SoundSource: String, CaseIterable, Identifiable {
        case system = "System Sound"
        case custom = "Custom Sound File"
        var id: String { rawValue }
    }

    /// Whether the app currently has focus
    private var appIsActive = true

    /// Whether UNUserNotificationCenter is available (requires proper bundle)
    private var notificationsAvailable = false

    /// Directory where we copy custom sounds so UNNotification can find them
    private var appSoundsDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("XMPBee/Sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Persistence Keys
    private let kPlaySound = "notification.playSound"
    private let kPlaySoundTwice = "notification.playSoundTwice"
    private let kSoundSource = "notification.soundSource"
    private let kSystemSound = "notification.systemSoundName"
    private let kCustomSoundPath = "notification.customSoundPath"
    private let kNotifyMessage = "notification.onMessage"
    private let kNotifyMention = "notification.onMention"
    private let kNotifyDM = "notification.onDM"
    private let kNotifyJoinPart = "notification.onJoinPart"

    override init() {
        super.init()
        loadPreferences()
        observeAppState()
        // Defer notification center setup until the app run loop is running,
        // which ensures the bundle proxy is available.
        DispatchQueue.main.async { [weak self] in
            self?.setupNotifications()
        }
    }

    // MARK: - Persistence

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(playSound, forKey: kPlaySound)
        d.set(playSoundTwice, forKey: kPlaySoundTwice)
        d.set(soundSource.rawValue, forKey: kSoundSource)
        d.set(systemSoundName, forKey: kSystemSound)
        d.set(customSoundURL?.path, forKey: kCustomSoundPath)
        d.set(notifyOnMessage, forKey: kNotifyMessage)
        d.set(notifyOnMention, forKey: kNotifyMention)
        d.set(notifyOnDirectMessage, forKey: kNotifyDM)
        d.set(notifyOnJoinPart, forKey: kNotifyJoinPart)
    }

    private func loadPreferences() {
        let d = UserDefaults.standard
        if d.object(forKey: kPlaySound) != nil { playSound = d.bool(forKey: kPlaySound) }
        if d.object(forKey: kPlaySoundTwice) != nil { playSoundTwice = d.bool(forKey: kPlaySoundTwice) }
        if let src = d.string(forKey: kSoundSource), let s = SoundSource(rawValue: src) { soundSource = s }
        if let name = d.string(forKey: kSystemSound) { systemSoundName = name }
        if let path = d.string(forKey: kCustomSoundPath) { customSoundURL = URL(fileURLWithPath: path) }
        if d.object(forKey: kNotifyMessage) != nil { notifyOnMessage = d.bool(forKey: kNotifyMessage) }
        if d.object(forKey: kNotifyMention) != nil { notifyOnMention = d.bool(forKey: kNotifyMention) }
        if d.object(forKey: kNotifyDM) != nil { notifyOnDirectMessage = d.bool(forKey: kNotifyDM) }
        if d.object(forKey: kNotifyJoinPart) != nil { notifyOnJoinPart = d.bool(forKey: kNotifyJoinPart) }
    }

    // MARK: - Custom Sound Import

    /// Import a custom sound file — copies it to the app support directory
    /// so it's available for UNNotificationSound. Returns true on success.
    @discardableResult
    func importCustomSound(from sourceURL: URL) -> Bool {
        guard let soundsDir = appSoundsDirectory else { return false }

        // Security-scoped resource access (required for sandboxed file picker)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        // Security: Sanitize filename to prevent path traversal
        let originalFilename = sourceURL.lastPathComponent
        let sanitizedFilename = sanitizeFilename(originalFilename)
        let destURL = soundsDir.appendingPathComponent(sanitizedFilename)

        // Remove old copy if exists
        try? FileManager.default.removeItem(at: destURL)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            customSoundURL = destURL
            soundSource = .custom
            savePreferences()
            return true
        } catch {
            print("[Notifications] Failed to import sound: \(error)")
            return false
        }
    }

    // MARK: - Sound Resolution

    /// The resolved sound name for UNNotificationSound
    private var resolvedNotificationSound: UNNotificationSound {
        switch soundSource {
        case .system:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: systemSoundName + ".aiff"))
        case .custom:
            if let url = customSoundURL {
                return UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
            }
            return .default
        }
    }

    // MARK: - Setup

    private func setupNotifications() {
        // UNUserNotificationCenter requires a proper app bundle.
        guard Bundle.main.bundleIdentifier != nil else {
            print("[Notifications] No bundle identifier — notifications disabled")
            return
        }

        notificationsAvailable = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error = error {
                print("[Notifications] Authorization error: \(error)")
            }
            if granted {
                print("[Notifications] Permission granted")
            }
        }

        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )

        let category = UNNotificationCategory(
            identifier: "XMPP_MESSAGE",
            actions: [replyAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        center.setNotificationCategories([category])
    }

    private func observeAppState() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appIsActive = true
                NSApplication.shared.dockTile.badgeLabel = nil
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appIsActive = false
            }
        }
    }

    // MARK: - Send Notifications

    func notifyGroupMessage(room: String, sender: String, body: String, mentionsMe: Bool) {
        guard !appIsActive else { return }

        if mentionsMe && notifyOnMention {
            sendNotification(
                title: "\(room) — \(sender) mentioned you",
                body: body, category: "XMPP_MESSAGE",
                sound: playSound, threadId: room
            )
        } else if notifyOnMessage {
            sendNotification(
                title: "\(room) — \(sender)",
                body: body, category: "XMPP_MESSAGE",
                sound: playSound, threadId: room
            )
        }
    }

    func notifyDirectMessage(sender: String, body: String) {
        guard !appIsActive && notifyOnDirectMessage else { return }
        sendNotification(
            title: "DM from \(sender)", body: body,
            category: "XMPP_MESSAGE", sound: playSound,
            threadId: "dm-\(sender)", badge: true
        )
    }

    func notifyJoinPart(room: String, user: String, joined: Bool) {
        guard !appIsActive && notifyOnJoinPart else { return }
        let action = joined ? "joined" : "left"
        sendNotification(
            title: room, body: "\(user) has \(action)",
            category: nil, sound: false, threadId: room
        )
    }

    private func sendNotification(title: String, body: String, category: String?, sound: Bool, threadId: String, badge: Bool = false) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadId

        if sound {
            content.sound = resolvedNotificationSound
        }

        if let category = category {
            content.categoryIdentifier = category
        }

        if badge {
            DispatchQueue.main.async {
                let current = Int(NSApplication.shared.dockTile.badgeLabel ?? "0") ?? 0
                NSApplication.shared.dockTile.badgeLabel = "\(current + 1)"
            }
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notifications] Failed to deliver: \(error)")
            }
        }
    }

    // MARK: - Play Sound Manually (in-app alerts)

    func playAlertSound() {
        playSingleSound()

        // Play twice for power-saving speakers if enabled
        if playSoundTwice {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.playSingleSound()
            }
        }
    }

    private func playSingleSound() {
        switch soundSource {
        case .system:
            if let sound = NSSound(named: systemSoundName) {
                sound.play()
            } else {
                NSSound.beep()
            }
        case .custom:
            if let url = customSoundURL {
                if let sound = NSSound(contentsOf: url, byReference: true) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            } else {
                NSSound.beep()
            }
        }
    }

    /// Preview whatever sound is currently selected (for the preferences UI)
    func previewSound() {
        playAlertSound()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "REPLY_ACTION",
           let textResponse = response as? UNTextInputNotificationResponse {
            let replyText = textResponse.userText
            let threadId = response.notification.request.content.threadIdentifier
            NotificationCenter.default.post(
                name: .xmppNotificationReply, object: nil,
                userInfo: ["threadId": threadId, "text": replyText]
            )
        }
        completionHandler()
    }

    // MARK: - Security

    /// Sanitize filename to prevent path traversal attacks
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove path separators and parent directory references
        var sanitized = filename.replacingOccurrences(of: "/", with: "_")
                                .replacingOccurrences(of: "\\", with: "_")
                                .replacingOccurrences(of: "..", with: "_")

        // Remove leading dots (hidden files)
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        // If empty after sanitization, use a default
        if sanitized.isEmpty {
            sanitized = "sound.aiff"
        }

        // Limit length
        if sanitized.count > 255 {
            let ext = (sanitized as NSString).pathExtension
            let base = (sanitized as NSString).deletingPathExtension
            sanitized = String(base.prefix(250)) + "." + ext
        }

        return sanitized
    }
}

extension Notification.Name {
    static let xmppNotificationReply = Notification.Name("xmppNotificationReply")
}

