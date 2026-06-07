import SwiftUI

/// iOS sheet — open a direct-message conversation by nickname.
/// Mirrors NewDMPopover from Mac/SidebarView.swift.
struct NewDMScreen: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""

    private var targetServer: Server? {
        viewModel.selectedServer ?? viewModel.servers.first
    }

    private var canOpen: Bool {
        !nickname.trimmingCharacters(in: .whitespaces).isEmpty && targetServer != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: $nickname)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            if canOpen { performOpen() }
                        }
                } header: {
                    Text("Enter the nickname of the person you want to message")
                }
            }
            .navigationTitle("New DM")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open") { performOpen() }
                        .disabled(!canOpen)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performOpen() {
        guard let server = targetServer else { return }
        viewModel.openDM(nick: nickname.trimmingCharacters(in: .whitespaces), on: server)
        dismiss()
    }
}
