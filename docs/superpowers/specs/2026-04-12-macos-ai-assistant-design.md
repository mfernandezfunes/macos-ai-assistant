# macOS AI Assistant — Design Spec

**Date:** 2026-04-12  
**Status:** Approved

---

## Overview

A small native macOS chat app to explore Apple's on-device Foundation Models framework. The app supports multiple saved conversations with full context restoration when reopening a session.

**Target platform:** macOS 26+ (required by the FoundationModels on-device LLM)  
**Language:** Swift 6  
**Framework:** SwiftUI, SwiftData, URLSession  
**Backend:** Apple Intelligence local server — OpenAI-compatible API at `http://127.0.0.1:11535/v1`, model `apple-on-device`

---

## Goals

- Provide a simple chat interface to test Apple's on-device language model
- Persist multiple conversation sessions to disk via SwiftData
- Restore the full conversation context (`LanguageModelSession`) when reopening a session
- Stream model responses token by token

## Non-goals

- Tool use / function calling
- Cloud AI providers
- iOS / iPadOS support
- Export or sharing of conversations

---

## Architecture

### Layout

`NavigationSplitView` with two columns:
- **Sidebar** (`ConversationListView`): list of past sessions, "+" button to create a new one
- **Detail** (`ChatView`): message history + streaming input for the selected conversation

### File structure

```
macos-ai-assistant/
├── macos_ai_assistantApp.swift
├── Models/
│   ├── Conversation.swift
│   └── Message.swift
├── Views/
│   ├── ContentView.swift
│   ├── ConversationListView.swift
│   ├── ChatView.swift
│   ├── MessageBubble.swift
│   └── MessageInputView.swift
└── Services/
    └── AssistantService.swift
```

---

## Data Model

### `Conversation` (SwiftData `@Model`)

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | Primary key |
| `title` | `String` | Derived from the first user message (truncated to ~50 chars) |
| `createdAt` | `Date` | Set on creation |
| `messages` | `[Message]` | One-to-many relationship, ordered by `createdAt` |

### `Message` (SwiftData `@Model`)

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | Primary key |
| `role` | `String` | `"user"` or `"assistant"` |
| `content` | `String` | Full text of the message |
| `createdAt` | `Date` | Set on creation |
| `conversation` | `Conversation` | Back-reference |

> `"instructions"` role is not persisted — system instructions are injected fresh on each session reconstruction.

---

## Components

### `AssistantService`

Wraps `URLSession` HTTP calls to the local OpenAI-compatible server. Responsible for:

1. **Sending messages** — `send(messages:onToken:)` async function that POSTs to `/v1/chat/completions` with `stream: true`, parses SSE lines, and calls `onToken` for each partial content chunk. Server-streamed error frames are surfaced as thrown `AssistantError.serverError`.
2. **Message history** — the full `[Message]` array from SwiftData is passed as the `messages` array in every request (context is stateless — no session object on the client).
3. **Error handling** — network errors and non-200 HTTP responses surface as thrown errors to the caller.

### `ChatView`

- Receives a `Conversation` from the split view selection
- Creates an `AssistantService` on appear
- Displays messages via `ScrollView` + `ForEach` over `conversation.messages`
- Passes send action down to `MessageInputView`

### `ConversationListView`

- Fetches all `Conversation` objects with `@Query(sort: \.createdAt, order: .reverse)`
- "+" button selects the existing empty `Conversation` if one exists, otherwise creates and selects a new one
- Swipe-to-delete removes the conversation and its messages from SwiftData

### `MessageBubble`

- User messages: right-aligned, blue background
- Assistant messages: left-aligned, dark background, avatar icon
- Streaming state: shows a blinking cursor while the assistant response is being generated

### `MessageInputView`

- Multi-line `TextEditor` that grows up to 4 lines
- Send button (↑) disabled while a response is streaming
- Sends on Return key (Shift+Return for newline)

---

## Data Flow

```
User types → MessageInputView.send()
  → ChatView appends user Message to SwiftData
  → AssistantService.send(text:messages:onToken:) [streaming SSE]
      → POST /v1/chat/completions with full messages array
      → parse SSE lines → call onToken per chunk
  → ChatView updates in-memory streaming text per token
  → persist final assistant Message to SwiftData on completion
  → set Conversation.title from first user message (if not set)
```

### API Types

```swift
struct ChatRequest: Encodable {
    let model: String        // "apple-on-device"
    let messages: [ChatMessage]
    let stream: Bool
}
struct ChatMessage: Codable {
    let role: String         // "user" | "assistant"
    let content: String
}
struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}
```

---

## Error Handling

| Scenario | Handling |
|---|---|
| Server unreachable | Show inline error in chat bubble |
| Non-200 HTTP response | Show inline error with status code |
| Malformed SSE line | Skip line, continue stream |
| SwiftData save failure | Log to console; surface generic error in UI |

---

## Xcode Project Setup

- **Bundle ID:** `com.yourname.macos-ai-assistant`
- **Minimum deployment:** macOS 14.0
- **Entitlements:** `com.apple.security.network.client = true` (outgoing connections to localhost)
- **SwiftData container:** configured in `macos_ai_assistantApp.swift` with `modelContainer(for: [Conversation.self, Message.self])`
