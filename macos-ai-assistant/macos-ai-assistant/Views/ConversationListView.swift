import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var importError: String?

    private var filtered: [Conversation] {
        conversations.filter {
            ConversationSearch.matches(
                title: $0.title, messages: $0.messages.map(\.content), query: searchText)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { conversation in
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
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search conversations")
        .overlay {
            if !searchText.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            importConversation(result)
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) { Button("OK") {} } message: { Text(importError ?? "") }
        .toolbar {
            ToolbarItem {
                Button { showingImporter = true } label: {
                    Label("Import Conversation", systemImage: "square.and.arrow.down")
                }
                .help("Import a conversation exported as JSON")
            }
            ToolbarItem {
                Button(action: newConversation) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func importConversation(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let snapshot = try ConversationExport.decode(Data(contentsOf: url))
            let (conversation, messages) = Conversation.make(from: snapshot)
            modelContext.insert(conversation)
            messages.forEach { modelContext.insert($0) }
            try modelContext.save()
            selection = conversation
        } catch {
            importError = error.localizedDescription
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
            delete(filtered[index])
        }
    }
}
