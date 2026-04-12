# macOS AI Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS chat app that talks to a local Apple Intelligence server (OpenAI-compatible API) with multiple persisted conversation sessions.

**Architecture:** SwiftUI `NavigationSplitView` with a sidebar listing conversations (SwiftData) and a chat detail view. `AssistantService` makes streaming HTTP requests to `http://127.0.0.1:11535/v1/chat/completions`. All conversation history is sent with every request (stateless client).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest, URLSession (SSE streaming), macOS 14+

---

## File Map

| File | Responsibility |
|---|---|
| `macos_ai_assistantApp.swift` | Entry point, SwiftData `modelContainer` setup |
| `Models/Conversation.swift` | `@Model` — id, title, createdAt, messages |
| `Models/Message.swift` | `@Model` — id, role, content, createdAt |
| `Services/AssistantService.swift` | HTTP POST to `/v1/chat/completions`, SSE parser |
| `Views/ContentView.swift` | `NavigationSplitView` root |
| `Views/ConversationListView.swift` | Sidebar: conversation list + "+" + swipe-delete |
| `Views/ChatView.swift` | Message scroll + `AssistantService` integration |
| `Views/MessageBubble.swift` | Single message bubble (user/assistant styles) |
| `Views/MessageInputView.swift` | `TextEditor` + send button |
| `macos_ai_assistantTests/ModelTests.swift` | Unit tests for Conversation and Message |
| `macos_ai_assistantTests/AssistantServiceTests.swift` | Unit tests for SSE parsing and request building |

---

## Task 1: Xcode Project Setup

**Files:**
- Create: Xcode project at `macos-ai-assistant/macos-ai-assistant.xcodeproj`
- Create: `macos-ai-assistant.entitlements`

- [ ] **Step 1: Create project in Xcode**

  Open Xcode → File → New → Project → macOS → App.
  - Product Name: `macos-ai-assistant`
  - Bundle Identifier: `com.yourname.macos-ai-assistant`
  - Interface: SwiftUI
  - Language: Swift
  - Storage: SwiftData *(check this box so Xcode generates the container boilerplate)*
  - Include Tests: ✓
  - Save to: `/Users/martin.fernandez/Documents/repos_personal/macos-ai-assistant/`

- [ ] **Step 2: Set minimum deployment**

  In the project target → General → Minimum Deployments → set **macOS 14.0**.

- [ ] **Step 3: Enable outgoing network connections**

  In the target → Signing & Capabilities → App Sandbox → check **Outgoing Connections (Client)**.

- [ ] **Step 4: Organize folder structure**

  In Xcode, create groups: `Models`, `Views`, `Services`. Move any Xcode-generated files to the appropriate group.

- [ ] **Step 5: Verify clean build**

  `⌘B` — build must succeed with zero errors.

- [ ] **Step 6: Init git**

  ```bash
  cd /Users/martin.fernandez/Documents/repos_personal/macos-ai-assistant
  git init
  echo "*.xcuserstate\nxcuserdata/\n.DS_Store\nDerivedData/" >> .gitignore
  git add .
  git commit -m "chore: initial Xcode project"
  ```

---

## Task 2: Data Models

**Files:**
- Create: `macos-ai-assistant/Models/Conversation.swift`
- Create: `macos-ai-assistant/Models/Message.swift`
- Create: `macos-ai-assistantTests/ModelTests.swift`

- [ ] **Step 1: Write the failing tests**

  Replace the contents of `macos-ai-assistantTests/ModelTests.swift`:

  ```swift
  import XCTest
  import SwiftData
  @testable import macos_ai_assistant

  @MainActor
  final class ModelTests: XCTestCase {
      var container: ModelContainer!

      override func setUp() async throws {
          container = try ModelContainer(
              for: Conversation.self, Message.self,
              configurations: ModelConfiguration(isStoredInMemoryOnly: true)
          )
      }

      func testConversationCreation() throws {
          let ctx = container.mainContext
          let conv = Conversation(title: "Test")
          ctx.insert(conv)
          try ctx.save()

          let fetched = try ctx.fetch(FetchDescriptor<Conversation>())
          XCTAssertEqual(fetched.count, 1)
          XCTAssertEqual(fetched[0].title, "Test")
      }

      func testMessageBelongsToConversation() throws {
          let ctx = container.mainContext
          let conv = Conversation(title: "Chat")
          let msg = Message(role: "user", content: "Hello", conversation: conv)
          ctx.insert(conv)
          ctx.insert(msg)
          try ctx.save()

          let fetched = try ctx.fetch(FetchDescriptor<Conversation>())
          XCTAssertEqual(fetched[0].messages.count, 1)
          XCTAssertEqual(fetched[0].messages[0].content, "Hello")
      }
  }
  ```

- [ ] **Step 2: Run tests to verify they fail**

  `⌘U` — expected: compile error (`Conversation` and `Message` not defined).

- [ ] **Step 3: Create `Conversation.swift`**

  ```swift
  import Foundation
  import SwiftData

  @Model
  final class Conversation {
      var id: UUID
      var title: String
      var createdAt: Date
      @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
      var messages: [Message]

      init(title: String = "") {
          self.id = UUID()
          self.title = title
          self.createdAt = Date()
          self.messages = []
      }
  }
  ```

- [ ] **Step 4: Create `Message.swift`**

  ```swift
  import Foundation
  import SwiftData

  @Model
  final class Message {
      var id: UUID
      var role: String   // "user" | "assistant"
      var content: String
      var createdAt: Date
      var conversation: Conversation?

      init(role: String, content: String, conversation: Conversation? = nil) {
          self.id = UUID()
          self.role = role
          self.content = content
          self.createdAt = Date()
          self.conversation = conversation
      }
  }
  ```

- [ ] **Step 5: Run tests to verify they pass**

  `⌘U` — both tests must pass.

- [ ] **Step 6: Commit**

  ```bash
  git add macos-ai-assistant/Models/ macos-ai-assistantTests/ModelTests.swift
  git commit -m "feat: add Conversation and Message SwiftData models"
  ```

---

## Task 3: AssistantService

**Files:**
- Create: `macos-ai-assistant/Services/AssistantService.swift`
- Create: `macos-ai-assistantTests/AssistantServiceTests.swift`

- [ ] **Step 1: Write failing tests**

  Create `macos-ai-assistantTests/AssistantServiceTests.swift`:

  ```swift
  import XCTest
  @testable import macos_ai_assistant

  final class AssistantServiceTests: XCTestCase {

      func testBuildRequestIncludesAllMessages() throws {
          let messages = [
              ChatMessage(role: "user", content: "Hello"),
              ChatMessage(role: "assistant", content: "Hi there"),
              ChatMessage(role: "user", content: "How are you?")
          ]
          let request = try AssistantService.buildRequest(messages: messages)

          XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11535/v1/chat/completions")
          XCTAssertEqual(request.httpMethod, "POST")

          let body = try JSONDecoder().decode(ChatRequest.self, from: request.httpBody!)
          XCTAssertEqual(body.model, "apple-on-device")
          XCTAssertTrue(body.stream)
          XCTAssertEqual(body.messages.count, 3)
          XCTAssertEqual(body.messages[2].content, "How are you?")
      }

      func testParseSSELineExtractsContent() {
          let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
          let token = AssistantService.parseSSELine(line)
          XCTAssertEqual(token, "Hello")
      }

      func testParseSSELineDoneReturnsNil() {
          XCTAssertNil(AssistantService.parseSSELine("data: [DONE]"))
      }

      func testParseSSELineNonDataReturnsNil() {
          XCTAssertNil(AssistantService.parseSSELine("event: ping"))
      }

      func testParseSSELineMissingContentReturnsNil() {
          let line = #"data: {"choices":[{"delta":{}}]}"#
          XCTAssertNil(AssistantService.parseSSELine(line))
      }
  }
  ```

- [ ] **Step 2: Run tests to verify they fail**

  `⌘U` — expected: compile errors.

- [ ] **Step 3: Create `AssistantService.swift`**

  ```swift
  import Foundation

  // MARK: - API types

  struct ChatMessage: Codable {
      let role: String
      let content: String
  }

  struct ChatRequest: Codable {
      let model: String
      let messages: [ChatMessage]
      let stream: Bool
  }

  private struct ChatCompletionChunk: Decodable {
      struct Choice: Decodable {
          struct Delta: Decodable { let content: String? }
          let delta: Delta
      }
      let choices: [Choice]
  }

  // MARK: - Service

  final class AssistantService {
      private let baseURL = URL(string: "http://127.0.0.1:11535/v1/chat/completions")!
      private let model = "apple-on-device"

      /// Builds the URLRequest for a chat completion (testable static helper).
      static func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
          let service = AssistantService()
          return try service.makeRequest(messages: messages)
      }

      /// Parses one SSE line and returns the content token, or nil.
      static func parseSSELine(_ line: String) -> String? {
          guard line.hasPrefix("data: ") else { return nil }
          let payload = String(line.dropFirst(6))
          guard payload != "[DONE]" else { return nil }
          guard let data = payload.data(using: .utf8),
                let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
          else { return nil }
          return chunk.choices.first?.delta.content
      }

      /// Streams a response from the local AI server, calling `onToken` for each partial token.
      func send(
          messages: [ChatMessage],
          onToken: @escaping @Sendable (String) -> Void
      ) async throws {
          let request = try makeRequest(messages: messages)
          let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

          guard let httpResponse = response as? HTTPURLResponse else {
              throw URLError(.badServerResponse)
          }
          guard httpResponse.statusCode == 200 else {
              throw URLError(.badServerResponse)
          }

          for try await line in asyncBytes.lines {
              if let token = Self.parseSSELine(line) {
                  onToken(token)
              }
          }
      }

      // MARK: - Private

      private func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
          var request = URLRequest(url: baseURL)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer not-needed", forHTTPHeaderField: "Authorization")
          let body = ChatRequest(model: model, messages: messages, stream: true)
          request.httpBody = try JSONEncoder().encode(body)
          return request
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  `⌘U` — all 5 tests must pass.

- [ ] **Step 5: Commit**

  ```bash
  git add macos-ai-assistant/Services/ macos-ai-assistantTests/AssistantServiceTests.swift
  git commit -m "feat: add AssistantService with SSE streaming"
  ```

---

## Task 4: MessageBubble

**Files:**
- Create: `macos-ai-assistant/Views/MessageBubble.swift`

- [ ] **Step 1: Create `MessageBubble.swift`**

  ```swift
  import SwiftUI

  struct MessageBubble: View {
      let role: String
      let content: String
      let isStreaming: Bool

      private var isUser: Bool { role == "user" }

      var body: some View {
          HStack(alignment: .bottom, spacing: 8) {
              if isUser { Spacer(minLength: 60) }

              if !isUser {
                  Circle()
                      .fill(Color(.windowBackgroundColor))
                      .overlay(Text("🤖").font(.caption))
                      .frame(width: 26, height: 26)
              }

              VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                  Text(content + (isStreaming ? "▌" : ""))
                      .textSelection(.enabled)
                      .padding(.horizontal, 12)
                      .padding(.vertical, 8)
                      .background(isUser ? Color.accentColor : Color(.controlBackgroundColor))
                      .foregroundStyle(isUser ? .white : .primary)
                      .clipShape(RoundedRectangle(cornerRadius: 14))
              }

              if !isUser { Spacer(minLength: 60) }
          }
      }
  }

  #Preview {
      VStack(spacing: 12) {
          MessageBubble(role: "user", content: "How does on-device AI work?", isStreaming: false)
          MessageBubble(role: "assistant", content: "It runs on the Neural Engine...", isStreaming: true)
      }
      .padding()
  }
  ```

- [ ] **Step 2: Verify preview renders**

  Open the preview canvas in Xcode (`⌥⌘↩`) — two bubbles should appear, user on the right and assistant on the left with a blinking cursor.

- [ ] **Step 3: Commit**

  ```bash
  git add macos-ai-assistant/Views/MessageBubble.swift
  git commit -m "feat: add MessageBubble view"
  ```

---

## Task 5: MessageInputView

**Files:**
- Create: `macos-ai-assistant/Views/MessageInputView.swift`

- [ ] **Step 1: Create `MessageInputView.swift`**

  ```swift
  import SwiftUI

  struct MessageInputView: View {
      @Binding var text: String
      let isStreaming: Bool
      let onSend: () -> Void

      var body: some View {
          HStack(alignment: .bottom, spacing: 8) {
              TextField("Message...", text: $text, axis: .vertical)
                  .lineLimit(1...4)
                  .textFieldStyle(.plain)
                  .padding(10)
                  .background(Color(.controlBackgroundColor))
                  .clipShape(RoundedRectangle(cornerRadius: 16))
                  .onSubmit {
                      if !isStreaming { submit() }
                  }

              Button(action: submit) {
                  Image(systemName: "arrow.up.circle.fill")
                      .font(.title2)
                      .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
              }
              .buttonStyle(.plain)
              .disabled(!canSend)
          }
          .padding(12)
          .background(.bar)
      }

      private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming }

      private func submit() {
          guard canSend else { return }
          onSend()
      }
  }

  #Preview {
      MessageInputView(text: .constant(""), isStreaming: false, onSend: {})
  }
  ```

- [ ] **Step 2: Verify preview renders**

  Preview canvas — input field with send button visible.

- [ ] **Step 3: Commit**

  ```bash
  git add macos-ai-assistant/Views/MessageInputView.swift
  git commit -m "feat: add MessageInputView"
  ```

---

## Task 6: ChatView

**Files:**
- Create: `macos-ai-assistant/Views/ChatView.swift`

- [ ] **Step 1: Create `ChatView.swift`**

  ```swift
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
                  Task { @MainActor in self.streamingText += token }
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
  ```

- [ ] **Step 2: Build to verify no compile errors**

  `⌘B` — must succeed.

- [ ] **Step 3: Commit**

  ```bash
  git add macos-ai-assistant/Views/ChatView.swift
  git commit -m "feat: add ChatView with streaming"
  ```

---

## Task 7: ConversationListView

**Files:**
- Create: `macos-ai-assistant/Views/ConversationListView.swift`

- [ ] **Step 1: Create `ConversationListView.swift`**

  ```swift
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
          let conv = Conversation()
          modelContext.insert(conv)
          try? modelContext.save()
          selection = conv
      }

      private func deleteConversations(at offsets: IndexSet) {
          let sorted = conversations  // already sorted by @Query
          for index in offsets {
              modelContext.delete(sorted[index])
          }
          try? modelContext.save()
      }
  }
  ```

- [ ] **Step 2: Build to verify no compile errors**

  `⌘B` — must succeed.

- [ ] **Step 3: Commit**

  ```bash
  git add macos-ai-assistant/Views/ConversationListView.swift
  git commit -m "feat: add ConversationListView with sidebar"
  ```

---

## Task 8: ContentView + App Entry Point

**Files:**
- Modify: `macos-ai-assistant/Views/ContentView.swift`
- Modify: `macos-ai-assistant/macos_ai_assistantApp.swift`

- [ ] **Step 1: Replace `ContentView.swift`**

  ```swift
  import SwiftUI
  import SwiftData

  struct ContentView: View {
      @State private var selectedConversation: Conversation?

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
      }
  }

  #Preview {
      ContentView()
          .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
  }
  ```

- [ ] **Step 2: Update `macos_ai_assistantApp.swift`**

  ```swift
  import SwiftUI
  import SwiftData

  @main
  struct macos_ai_assistantApp: App {
      var body: some Scene {
          WindowGroup {
              ContentView()
          }
          .modelContainer(for: [Conversation.self, Message.self])
      }
  }
  ```

- [ ] **Step 3: Build and run**

  `⌘R` — app should launch showing the sidebar + empty detail area. Click "+" to create a conversation. Make sure the local Apple Intelligence server is running at `http://127.0.0.1:11535`, then send a message and verify streaming works.

- [ ] **Step 4: Run all tests**

  `⌘U` — all tests must pass.

- [ ] **Step 5: Commit**

  ```bash
  git add macos-ai-assistant/Views/ContentView.swift macos-ai-assistant/macos_ai_assistantApp.swift
  git commit -m "feat: wire NavigationSplitView and SwiftData container"
  ```

---

## Self-Review Checklist

- [x] **Spec coverage**
  - Chat interface ✓ (ChatView + MessageBubble)
  - Multiple sessions ✓ (ConversationListView + Conversation model)
  - Persist to disk ✓ (SwiftData)
  - Context restoration ✓ (full messages array sent with every request)
  - Streaming ✓ (AssistantService SSE)
  - OpenAI-compatible API ✓ (AssistantService)
- [x] **Type consistency** — `ChatMessage` defined once in `AssistantService.swift`, used in `ChatView.swift` and tests
- [x] **No placeholders** — all steps have complete code
- [x] **Entitlement** — Task 1 Step 3 covers outgoing network permission
