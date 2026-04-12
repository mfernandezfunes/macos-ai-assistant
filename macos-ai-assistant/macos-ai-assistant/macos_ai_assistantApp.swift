import SwiftUI
import SwiftData

@main
struct macos_ai_assistantApp: App {
    @StateObject private var serverManager = VaporServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .task {
                    await serverManager.startServer(configuration: .default)
                }
        }
        .modelContainer(for: [Conversation.self, Message.self])
        .commands {
            CommandGroup(replacing: .appInfo) {
                OpenAboutWindowButton()
            }
        }

        Window("About macOS AI Assistant", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
