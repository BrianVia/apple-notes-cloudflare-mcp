import SwiftUI

@main
struct NotekeeperMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Notekeeper") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await model.loadStoredCredentialsAndConnect()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Replace the default "New Window" (⌘N) with "New Note".
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    Task { await model.createDraft() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.client == nil)
            }
        }
    }
}
