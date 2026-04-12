import SwiftUI
import SwiftData

@MainActor
struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var modelContext

    @State private var inputText = ""
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var errorMessage: String?

    private let service = AssistantService()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(conversation.messages.sorted(by: { $0.createdAt < $1.createdAt })) { message in
                            MessageBubble(role: message.role, content: message.content, isStreaming: false)
                                .padding(.horizontal, 12)
                        }
                        if isStreaming {
                            MessageBubble(role: "assistant", content: streamingText, isStreaming: true)
                                .padding(.horizontal, 12)
                                .id("streaming")
                        }
                        if let error = errorMessage {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            MessageInputView(text: $inputText, isStreaming: isStreaming) {
                Task { await send() }
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "New Conversation" : conversation.title)
    }

    // MARK: - Send

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        errorMessage = nil

        // Persist user message
        let userMsg = Message(role: "user", content: text, conversation: conversation)
        modelContext.insert(userMsg)
        try? modelContext.save()

        // Set conversation title from first message
        if conversation.title.isEmpty {
            conversation.title = String(text.prefix(50))
            try? modelContext.save()
        }

        // Build messages array for the API
        let allMessages = conversation.messages
            .sorted(by: { $0.createdAt < $1.createdAt })
            .map { ChatMessage(role: $0.role, content: $0.content) }

        // Stream response
        isStreaming = true
        streamingText = ""

        do {
            try await service.send(messages: allMessages) { token in
                self.streamingText += token
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }

        // Persist assistant message
        if !streamingText.isEmpty {
            let assistantMsg = Message(role: "assistant", content: streamingText, conversation: conversation)
            modelContext.insert(assistantMsg)
            try? modelContext.save()
        }

        isStreaming = false
        streamingText = ""
    }
}
