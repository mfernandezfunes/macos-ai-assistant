# Apple Intelligence Assistant

A native macOS chat app that uses Apple's on-device AI model (Apple Intelligence) through an embedded OpenAI-compatible local server.

## How it works

The app embeds a [Vapor](https://vapor.codes) HTTP server that exposes an OpenAI-compatible API at `http://127.0.0.1:11535/v1`. This server uses Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels) framework to run inference directly on-device, with no data leaving the machine.

The chat interface communicates with this local server using streaming SSE responses, the same way any OpenAI client would.

```
┌─────────────────────────────────────────┐
│              macOS App                  │
│                                         │
│  ┌──────────────┐   ┌─────────────────┐ │
│  │  SwiftUI UI  │──▶│  Vapor Server   │ │
│  │  (chat view) │   │  :11535/v1      │ │
│  └──────────────┘   └────────┬────────┘ │
│                              │          │
│                    ┌─────────▼────────┐ │
│                    │ FoundationModels │ │
│                    │ (on-device LLM)  │ │
│                    └──────────────────┘ │
└─────────────────────────────────────────┘
```

## Features

- Multi-session sidebar with persistent conversation history (SwiftData)
- Streaming responses with a live cursor indicator
- Markdown rendering for assistant messages (code blocks, lists, etc.)
- Toolbar status indicator: Apple Intelligence availability, model name, server on/off toggle
- Right-click to delete conversations
- Custom About screen
- Fully local — no internet connection required for inference

## Requirements

- macOS 26+
- Apple Intelligence enabled (Settings → Apple Intelligence & Siri)
- A supported device: Mac with Apple Silicon

## Getting started

1. Clone the repo
2. Open `macos-ai-assistant/macos-ai-assistant.xcodeproj` in Xcode
3. Add the following Swift packages if not already resolved:
   - [Vapor](https://github.com/vapor/vapor.git) `4.115.0`
   - [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) `>= 2.4.1`
4. Build and run (`⌘R`)

The Vapor server starts automatically on launch. The toolbar shows the server status and a toggle to stop/restart it.

## Local API

Once running, the server is compatible with any OpenAI client:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11535/v1", api_key="not-needed")

response = client.chat.completions.create(
    model="apple-on-device",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

Available endpoints:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/status` | Model availability and supported languages |
| GET | `/v1/models` | List available models |
| POST | `/v1/chat/completions` | Chat completions (streaming supported) |

## Project structure

```
macos-ai-assistant/
├── Models/
│   ├── Conversation.swift        # SwiftData model
│   ├── Message.swift             # SwiftData model
│   ├── OpenAIModels.swift        # Request/response types (Vapor Content)
│   └── ServerConfiguration.swift # Server host/port config
├── Services/
│   ├── AssistantService.swift    # HTTP client with SSE streaming
│   ├── OnDeviceModelManager.swift # FoundationModels wrapper
│   └── VaporServerManager.swift  # Vapor app lifecycle
├── Views/
│   ├── ContentView.swift         # NavigationSplitView root
│   ├── ConversationListView.swift # Sidebar
│   ├── ChatView.swift            # Chat area with streaming
│   ├── MessageBubble.swift       # User/assistant message bubbles
│   ├── MessageInputView.swift    # Text input bar
│   ├── ServerStatusView.swift    # Toolbar status indicator
│   └── AboutView.swift           # About window
└── macos_ai_assistantApp.swift   # App entry point
```

## Credits

Server implementation based on [apple-on-device-openai](https://github.com/obra/apple-on-device-openai) by [@obra](https://github.com/obra).
