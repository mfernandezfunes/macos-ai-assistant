import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

@MainActor
struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var modelContext

    @State private var inputText = ""
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var errorMessage: String?
    @State private var showingInstructions = false
    @State private var sendStartedAt = Date.distantFuture
    @State private var attachments: [AttachmentExtractor.Extracted] = []
    @State private var showingImporter = false
    @StateObject private var toolActivity = ToolActivityCenter.shared

    private let service = AssistantService()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedMessages) { message in
                            MessageBubble(role: message.role, content: message.content, isStreaming: false,
                                          attachmentNames: message.attachmentNames.split(separator: "\n").map(String.init))
                                .padding(.horizontal, 12)
                                .id(message.id)
                        }
                        if isStreaming {
                            MessageBubble(role: MessageRole.assistant.rawValue, content: streamingText, isStreaming: true)
                                .padding(.horizontal, 12)
                                .id("streaming")
                        }
                        ForEach(toolEventsThisTurn) { event in
                            ToolEventRow(event: event)
                                .padding(.horizontal, 12)
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

            MessageInputView(
                text: $inputText, isStreaming: isStreaming,
                attachments: attachments.map(\.name),
                onAttach: { showingImporter = true },
                onRemoveAttachment: { attachments.remove(at: $0) }
            ) {
                Task { await send() }
            }
        }
        .alert(
            "Allow \(toolActivity.pendingApproval?.tool.displayName ?? "tool")?",
            isPresented: Binding(
                get: { toolActivity.pendingApproval != nil },
                set: { if !$0, let id = toolActivity.pendingApproval?.id {
                    toolActivity.resolve(id, approved: false) } }
            ),
            presenting: toolActivity.pendingApproval
        ) { request in
            Button("Allow") { toolActivity.resolve(request.id, approved: true) }
            if !request.tool.alwaysRequiresApproval {
                Button("Always Allow") {
                    ToolSettings.shared.setRequiresConfirmation(request.tool, false)
                    toolActivity.resolve(request.id, approved: true)
                }
            }
            Button("Deny", role: .cancel) { toolActivity.resolve(request.id, approved: false) }
        } message: { request in
            Text("The assistant wants to: \(request.detail)")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf, .image, .text, .json, .xml, .sourceCode, .data],
            allowsMultipleSelection: true
        ) { result in
            Task { await attach(result) }
        }
        .navigationTitle(conversation.title.isEmpty ? "New Conversation" : conversation.title)
        .task(id: conversation.id) {
            // Prewarm the on-device model when a conversation opens so the first
            // token arrives faster.
            await service.prewarm(instructions: conversation.systemInstructions)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export as Markdown…") { export(markdown: true) }
                    Button("Export as JSON…") { export(markdown: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(conversation.messages.isEmpty)
            }
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

    private var toolEventsThisTurn: [ToolEvent] {
        toolActivity.events.filter { $0.startedAt >= sendStartedAt }
    }

    private var sortedMessages: [Message] {
        conversation.messages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: - Send

    private func send() async {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAttachments = attachments
        guard !text.isEmpty || !sentAttachments.isEmpty else { return }
        if text.isEmpty { text = "Please look at the attached file(s)." }

        inputText = ""
        attachments = []
        errorMessage = nil
        sendStartedAt = Date()

        // Persist user message
        let userMsg = Message(role: .user, content: text, conversation: conversation)
        userMsg.attachmentNames = sentAttachments.map(\.name).joined(separator: "\n")
        userMsg.attachmentText = AttachmentExtractor.promptBlock(sentAttachments)
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
            .map { message in
                // Attached file text goes to the model but not into the bubble.
                let body = message.attachmentText.isEmpty
                    ? message.content : message.content + "\n\n" + message.attachmentText
                return ChatMessage(role: message.role, content: body)
            }

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

    private func attach(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                attachments.append(try await AttachmentExtractor.extract(from: url))
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(markdown: Bool) {
        let snapshot = conversation.snapshot
        let panel = NSSavePanel()
        panel.allowedContentTypes = [markdown ? UTType(filenameExtension: "md") ?? .plainText : .json]
        panel.nameFieldStringValue = ConversationExport.fileName(for: snapshot) + (markdown ? ".md" : ".json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown
                ? Data(ConversationExport.markdown(snapshot).utf8)
                : try ConversationExport.json(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
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

/// Compact line showing a tool call the assistant made during this turn.
private struct ToolEventRow: View {
    let event: ToolEvent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text("\(event.tool.displayName): \(event.detail)")
                .lineLimit(2)
            Text(statusText).foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch event.status {
        case .awaitingApproval: return "hand.raised"
        case .running: return "gearshape"
        case .completed: return "checkmark.circle"
        case .denied: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch event.status {
        case .awaitingApproval: return "waiting for approval"
        case .running: return "running"
        case .completed: return "done"
        case .denied: return "denied"
        case .failed(let message): return "failed: \(message)"
        }
    }
}
