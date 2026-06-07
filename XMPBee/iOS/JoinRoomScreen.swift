import SwiftUI

/// iOS sheet — join a MUC room by name.
/// Mirrors JoinRoomPopover from Mac/SidebarView.swift.
struct JoinRoomScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var roomName = ""

    private var targetServer: Server? {
        viewModel.selectedServer ?? viewModel.servers.first
    }

    private var canJoin: Bool {
        !roomName.trimmingCharacters(in: .whitespaces).isEmpty && targetServer != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Room name", text: $roomName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            if canJoin { performJoin() }
                        }
                } header: {
                    Text("Enter the name of the room you want to join")
                }
            }
            .navigationTitle("Join Room")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Join") { performJoin() }
                        .disabled(!canJoin)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performJoin() {
        guard let server = targetServer else { return }
        viewModel.joinNewRoom(name: roomName.trimmingCharacters(in: .whitespaces), on: server)
        dismiss()
    }
}
