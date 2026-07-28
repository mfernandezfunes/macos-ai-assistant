import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conversation)
                .contextMenu {
                    Button(role: .destructive) {
                        delete(conversation)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .toolbar {
            ToolbarItem {
                Button(action: newConversation) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func newConversation() {
        // Reuse an existing empty conversation instead of stacking up untitled
        // duplicates when "+" is clicked repeatedly.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selection = empty
            return
        }
        let conv = Conversation()
        modelContext.insert(conv)
        try? modelContext.save()
        selection = conv
    }

    private func delete(_ conversation: Conversation) {
        if selection == conversation { selection = nil }
        modelContext.delete(conversation)
        try? modelContext.save()
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            delete(conversations[index])
        }
    }
}
