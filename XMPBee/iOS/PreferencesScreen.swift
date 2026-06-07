import SwiftUI

/// iOS Preferences screen — notification toggles only.
/// Mirrors macOS `PreferencesView` but omits all sound-source/system-sound/
/// custom-sound UI (macOS-only, dropped on iOS per spec).
struct PreferencesScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    /// Expose the shared NotificationManager through the view model.
    private var notifications: NotificationManager { viewModel.notifications }

    var body: some View {
        NavigationStack {
            PreferencesFormBody(notifications: notifications)
                .navigationTitle("Preferences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            notifications.savePreferences()
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Form body (factored out to keep the type-checker happy)

private struct PreferencesFormBody: View {
    @ObservedObject var notifications: NotificationManager
    @AppStorage("hideJoinPart") private var hideJoinPart = true

    var body: some View {
        Form {
            displaySection
            notifySection
            soundSection
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section("Display") {
            Toggle("Hide join / part / quit events", isOn: $hideJoinPart)
        }
    }

    // MARK: Notify on

    private var notifySection: some View {
        Section("Notify on") {
            Toggle("Channel messages", isOn: $notifications.notifyOnMessage)
                .onChange(of: notifications.notifyOnMessage) { _, _ in notifications.savePreferences() }
            Toggle("Mentions of my nick", isOn: $notifications.notifyOnMention)
                .onChange(of: notifications.notifyOnMention) { _, _ in notifications.savePreferences() }
            Toggle("Direct messages", isOn: $notifications.notifyOnDirectMessage)
                .onChange(of: notifications.notifyOnDirectMessage) { _, _ in notifications.savePreferences() }
            Toggle("Join / part events", isOn: $notifications.notifyOnJoinPart)
                .onChange(of: notifications.notifyOnJoinPart) { _, _ in notifications.savePreferences() }
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        Section("Sound") {
            // On iOS this controls only the notification sound (the in-app alert
            // sound is macOS-only).  "Play twice" is omitted — it only ever drove
            // the in-app double-play, which is a no-op on iOS.
            Toggle("Play notification sound", isOn: $notifications.playSound)
                .onChange(of: notifications.playSound) { _, _ in notifications.savePreferences() }
        }
    }
}
