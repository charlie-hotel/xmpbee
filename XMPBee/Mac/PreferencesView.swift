import SwiftUI
import UniformTypeIdentifiers

/// Notification & sound preferences panel
struct PreferencesView: View {
    @ObservedObject var notifications: NotificationManager
    @AppStorage("hideJoinPart") private var hideJoinPart = true
    @Environment(\.dismiss) private var dismiss
    @State private var showSoundFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences")
                .font(.system(size: 15, weight: .semibold))

            // Display options
            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Hide join / part / quit events in chat", isOn: $hideJoinPart)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Event toggles
            GroupBox("Notify on") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Channel messages", isOn: $notifications.notifyOnMessage)
                    Toggle("Mentions of my nick", isOn: $notifications.notifyOnMention)
                    Toggle("Direct messages", isOn: $notifications.notifyOnDirectMessage)
                    Toggle("Join / part events", isOn: $notifications.notifyOnJoinPart)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Sound settings
            GroupBox("Sound") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Play sound", isOn: $notifications.playSound)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))

                    if notifications.playSound {
                        Toggle("Play twice (for power-saving speakers)", isOn: $notifications.playSoundTwice)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))

                        Divider()

                        // Sound source picker
                        Picker("Source:", selection: $notifications.soundSource) {
                            ForEach(NotificationManager.SoundSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .font(.system(size: 11))

                        // System sound picker
                        if notifications.soundSource == .system {
                            systemSoundPicker
                        }

                        // Custom sound file picker
                        if notifications.soundSource == .custom {
                            customSoundPicker
                        }

                        Divider()

                        // Preview button
                        HStack {
                            Spacer()
                            Button(action: { notifications.previewSound() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.wave.2")
                                    Text("Preview")
                                }
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") {
                    notifications.savePreferences()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .fileImporter(
            isPresented: $showSoundFilePicker,
            allowedContentTypes: [.aiff, .wav, .mp3, .audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                notifications.importCustomSound(from: url)
            }
        }
    }

    // MARK: - System Sound Picker

    private var systemSoundPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("System sound:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("", selection: $notifications.systemSoundName) {
                    ForEach(NotificationManager.availableSystemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)

                Button(action: { notifications.previewSound() }) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)
                .help("Preview this sound")
            }
        }
    }

    // MARK: - Custom Sound Picker

    private var customSoundPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Custom file:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if notifications.customSoundURL != nil {
                    Text(notifications.customSoundDisplayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.channelText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No file selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .italic()
                }

                Spacer()

                Button("Browse...") {
                    showSoundFilePicker = true
                }
                .font(.system(size: 11))
            }

            Text("Supported: .aiff, .wav, .caf, .mp3 (max 30 seconds)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
