import SwiftUI

@main
struct XMPBeeApp: App {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { _, phase in
                    viewModel.handleScenePhase(phase)
                }
        }
    }
}
