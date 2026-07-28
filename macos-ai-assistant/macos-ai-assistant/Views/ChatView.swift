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
    @State private var showingInstructions = false

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
        .task(id: conversation.id) {
            // Prewarm the on-device model when a conversation opens so the first
            // token arrives faster.
            await service.prewarm(instructions: conversation.systemInstructions)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInstructions.toggle()
                } label: {
                    Label("Instructions", systemImage: conversation.systemInstructions.isEmpty
                          ? "text.badge.plus" : "text.badge.checkmark")
                }
                .help("Set system instructions for this conversation")
                .popover(isPresented: $showingInstructions, arrowEdge: .bottom) {
                    instructionsEditor
                }
            }
        }
    }

    /// Role/persona presets from Apple's on-device prompting guidance.
    private static let personaPresets: [(name: String, instructions: String)] = [
        ("English Teacher",
         "You are an expert English teacher. Provide feedback on the person's sentence to help them improve clarity."),
        ("Cowboy",
         "You are a lively cowboy who loves to chat about horses and make jokes. Provide feedback on the person's sentence to help them improve clarity."),
        ("Professional",
         "Communicate as an experienced interior designer consulting with a client. Occasionally reference design elements like harmony, proportion, or focal points."),
        ("Medieval Scholar",
         "Communicate as a learned scribe from a medieval library. Use slightly archaic language (\"thou shalt,\" \"wherein,\" \"henceforth\") but keep it readable."),
        ("Senior Engineer",
         "You are a senior software engineer who values mentoring junior developers. Explain your reasoning clearly and suggest best practices."),
    ]

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System Instructions")
                    .font(.headline)
                Spacer()
                Menu("Presets") {
                    ForEach(Self.personaPresets, id: \.name) { preset in
                        Button(preset.name) {
                            conversation.systemInstructions = preset.instructions
                            save()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("Guides how the assistant responds in this conversation. Applied on every message.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $conversation.systemInstructions)
                .font(.body)
                .frame(width: 360, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separatorColor)))
            HStack {
                Button("Clear") {
                    conversation.systemInstructions = ""
                    save()
                }
                .disabled(conversation.systemInstructions.isEmpty)
                Spacer()
                Button("Done") {
                    save()
                    showingInstructions = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
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

        // Set conversation title from first message. Use guided generation for
        // a concise title, falling back to a truncated prompt if unavailable.
        if conversation.title.isEmpty {
            conversation.title = String(text.prefix(50))
            save()
            let firstMessage = text
            Task {
                if let title = await service.generateTitle(for: firstMessage),
                   !title.isEmpty {
                    conversation.title = title
                    save()
                }
            }
        }

        // Build messages array for the API, prepending the conversation's
        // system instructions (if any) so the server maps them to
        // Transcript.Instructions.
        var allMessages: [ChatMessage] = []
        let instructions = conversation.systemInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            allMessages.append(ChatMessage(role: "system", content: instructions))
        }
        allMessages += sortedMessages
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
