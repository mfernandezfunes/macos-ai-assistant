import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedConversation: Conversation?
    @EnvironmentObject var serverManager: VaporServerManager

    var body: some View {
        NavigationSplitView {
            ConversationListView(selection: $selectedConversation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let conversation = selectedConversation {
                ChatView(conversation: conversation)
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a new conversation or select one from the sidebar.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ServerStatusView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
        .environmentObject(VaporServerManager())
}
