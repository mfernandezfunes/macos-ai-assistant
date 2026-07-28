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
                        ForEach(sortedMessages) { message in
                            MessageBubble(role: message.role, content: message.content, isStreaming: false)
                                .padding(.horizontal, 12)
                                .id(message.id)
                        }
                        if isStreaming {
                            MessageBubble(role: MessageRole.assistant.rawValue, content: streamingText, isStreaming: true)
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
                .onChange(of: conversation.messages.count) {
                    if let last = sortedMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            MessageInputView(text: $inputText, isStreaming: isStreaming) {
                Task { await send() }
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "New Conversation" : conversation.title)
    }

    private var sortedMessages: [Message] {
        conversation.messages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: - Send

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        errorMessage = nil

        // Persist user message
        let userMsg = Message(role: .user, content: text, conversation: conversation)
        modelContext.insert(userMsg)
        save()

        // Set conversation title from first message
        if conversation.title.isEmpty {
            conversation.title = String(text.prefix(50))
            save()
        }

        // Build messages array for the API
        let allMessages = sortedMessages
            .map { ChatMessage(role: $0.role, content: $0.content) }

        // Stream response
        isStreaming = true
        streamingText = ""

        var failure: String?
        do {
            try await service.send(messages: allMessages) { token in
                self.streamingText += token
            }
        } catch {
            failure = error.localizedDescription
        }

        let finalText = streamingText
        isStreaming = false
        streamingText = ""

        if !finalText.isEmpty {
            // Persist whatever assistant text was produced.
            let assistantMsg = Message(role: .assistant, content: finalText, conversation: conversation)
            modelContext.insert(assistantMsg)
            save()
        }

        // Surface the error, and persist a placeholder so a failed turn isn't
        // silently lost after relaunch.
        if let failure {
            errorMessage = "Error: \(failure)"
            if finalText.isEmpty {
                let errorMsg = Message(
                    role: .assistant,
                    content: "⚠️ Failed to generate a response: \(failure)",
                    conversation: conversation)
                modelContext.insert(errorMsg)
                save()
            }
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}
