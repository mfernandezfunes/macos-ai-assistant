//
//  VaporServerManager.swift
//  AppleOnDeviceOpenAI
//
//  Created by Channing Dai on 6/15/25.
//

import Combine
import Foundation
import FoundationModels
import Vapor

@MainActor
class VaporServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private var app: Application?
    private var serverTask: Task<Void, Never>?

    private static let modelName = "apple-on-device"
    private static var loggingBootstrapped = false
    private static let logger = Logger(label: "VaporServerManager")

    func startServer(configuration: ServerConfiguration) async {
        guard !isRunning else { return }

        do {
            // Create Vapor application
            var env = try Environment.detect()

            // Only bootstrap logging system once per process
            // This prevents the "logging system can only be initialized once per process" error
            // when stopping and restarting the server
            if !Self.loggingBootstrapped {
                try LoggingSystem.bootstrap(from: &env)
                Self.loggingBootstrapped = true
            }

            let app = Application(env)
            self.app = app

            // Fix for running Vapor in iOS/macOS app - clear command line arguments
            if let executable = app.environment.arguments.first {
                app.environment.arguments = [executable]
            }

            // Configure routes
            configureRoutes(app)

            // Configure server
            app.http.server.configuration.hostname = configuration.host
            app.http.server.configuration.port = configuration.port

            // Start server in background task. If binding fails (e.g. the port is
            // already in use) reset the running state so the UI reflects reality.
            serverTask = Task { [weak self] in
                do {
                    try await app.execute()
                } catch {
                    await MainActor.run {
                        self?.lastError = error.localizedDescription
                        self?.isRunning = false
                    }
                }
            }

            isRunning = true
            lastError = nil

        } catch {
            self.app = nil
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    func stopServer() async {
        guard isRunning else { return }

        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil

        // Shutdown the application
        if let app = app {
            try? await app.asyncShutdown()
            self.app = nil
        }

        isRunning = false
    }

    private func configureRoutes(_ app: Application) {
        // Health check endpoint
        app.get("health") { req async -> HTTPStatus in
            return .ok
        }

        // Model status endpoint
        app.get("status") { req async throws -> ServerStatus in
            let (available, reason) = await aiManager.isModelAvailable()
            let supportedLanguages = await aiManager.getSupportedLanguages()

            return ServerStatus(
                modelAvailable: available,
                reason: reason ?? "Model is available",
                supportedLanguages: supportedLanguages,
                serverVersion: "1.0.0",
                appleIntelligenceCompatible: true
            )
        }

        // OpenAI compatible endpoints
        let v1 = app.grouped("v1")

        // List models endpoint
        v1.get("models") { req async throws -> ModelsResponse in
            let (available, _) = await aiManager.isModelAvailable()

            var models: [ModelInfo] = []

            if available {
                models.append(
                    ModelInfo(
                        id: Self.modelName,
                        object: "model",
                        created: Int(Date().timeIntervalSince1970),
                        ownedBy: "apple-on-device-openai"
                    ))
            }

            return ModelsResponse(
                object: "list",
                data: models
            )
        }

        // Chat completions endpoint (main endpoint)
        v1.post("chat", "completions") { req async throws -> Response in
            let chatRequest = try req.content.decode(ChatCompletionRequest.self)

            // Validate request
            guard !chatRequest.messages.isEmpty else {
                throw Abort(.badRequest, reason: "No messages provided")
            }

            do {
                // Handle streaming vs non-streaming
                if chatRequest.stream == true {
                    return try await self.handleStreamingResponse(chatRequest)
                }

                // Generate response using the manager
                let response = try await aiManager.generateResponse(
                    for: chatRequest.messages,
                    temperature: chatRequest.temperature,
                    maxTokens: chatRequest.maxTokens
                )

                let chatResponse = ChatCompletionResponse(
                    id: "chatcmpl-\(UUID().uuidString)",
                    object: "chat.completion",
                    created: Int(Date().timeIntervalSince1970),
                    model: chatRequest.model ?? Self.modelName,
                    choices: [
                        ChatCompletionChoice(
                            index: 0,
                            message: ChatMessage(
                                role: "assistant",
                                content: response
                            ),
                            finishReason: "stop"
                        )
                    ]
                )

                // Encode response as JSON
                let jsonData = try JSONEncoder().encode(chatResponse)
                var res = Response()
                res.headers.contentType = .json
                res.body = .init(data: jsonData)
                return res
            } catch let error as AbortError {
                throw error
            } catch {
                throw Abort(
                    .internalServerError,
                    reason: "Error generating response: \(error.localizedDescription)")
            }
        }
    }

    // Helper function to handle streaming responses
    private func handleStreamingResponse(_ chatRequest: ChatCompletionRequest) async throws
        -> Response
    {
        let response = Response()
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: "*")
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Headers", value: "Cache-Control")

        // Create the streaming body using Vapor's Response.Body(stream:)
        response.body = Response.Body(stream: { writer in
            Task {
                do {
                    // Check availability first
                    let (available, reason) = await aiManager.isModelAvailable()
                    guard available else {
                        let errorData = Self.sseErrorPayload(
                            message: reason ?? "Model not available",
                            type: "unavailable_error")
                        try await writer.write(.buffer(ByteBuffer(string: errorData)))
                        try await writer.write(.end)
                        return
                    }

                    // Trim old turns so instructions + prompts fit the context
                    // window before building the transcript.
                    let fitted = await aiManager.fitToContextWindow(chatRequest.messages)

                    // Get the last message as the current prompt. The route guards
                    // against an empty messages array before this runs.
                    guard let lastMessage = fitted.last else {
                        let errorData = Self.sseErrorPayload(
                            message: "No messages provided", type: "invalid_request_error")
                        try await writer.write(.buffer(ByteBuffer(string: errorData)))
                        try await writer.write(.end)
                        return
                    }
                    let currentPrompt = lastMessage.content

                    // Resolve the user-enabled tools once so the same set is
                    // advertised in the transcript and wired into the session.
                    let tools = AssistantToolFactory.makeTools(
                        for: ToolSettings.currentEnabledIDs())

                    // Convert previous messages (excluding the last one) to
                    // transcript, advertising the tool definitions so the model
                    // can discover them.
                    let previousMessages =
                        fitted.count > 1 ? Array(fitted.dropLast()) : []
                    let transcriptEntries = await aiManager.convertMessagesToTranscript(
                        previousMessages, tools: tools)

                    // Create transcript with conversation history
                    let transcript = Transcript(entries: transcriptEntries)

                    // Create new session with the conversation transcript and any
                    // user-enabled tools.
                    let session = LanguageModelSession(
                        model: SystemLanguageModel.default,
                        tools: tools,
                        transcript: transcript
                    )

                    // Create generation options
                    var options = GenerationOptions()
                    if let temp = chatRequest.temperature {
                        options = GenerationOptions(
                            temperature: temp, maximumResponseTokens: chatRequest.maxTokens)
                    } else if let maxTokens = chatRequest.maxTokens {
                        options = GenerationOptions(maximumResponseTokens: maxTokens)
                    }

                    // Get the streaming response from the session
                    let responseStream = session.streamResponse(to: currentPrompt, options: options)

                    // Response metadata
                    let responseId = "chatcmpl-\(UUID().uuidString)"
                    let created = Int(Date().timeIntervalSince1970)

                    // Track previous content to calculate deltas
                    var previousContent = ""
                    var isFirstChunk = true

                    // Iterate through the stream and yield partial responses
                    for try await cumulativeResponse in responseStream {
                        // Calculate the delta (new content since last iteration)
                        let deltaContent = String(cumulativeResponse.content.dropFirst(previousContent.count))

                        // Skip empty deltas (except for the first chunk which might include role)
                        if deltaContent.isEmpty && !isFirstChunk {
                            continue
                        }

                        let streamResponse = ChatCompletionStreamResponse(
                            id: responseId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: Self.modelName,
                            choices: [
                                ChatCompletionStreamChoice(
                                    index: 0,
                                    delta: ChatCompletionDelta(
                                        role: isFirstChunk ? "assistant" : nil,
                                        content: deltaContent.isEmpty ? nil : deltaContent
                                    ),
                                    finishReason: nil
                                )
                            ]
                        )

                        let encoder = JSONEncoder()
                        let jsonData = try encoder.encode(streamResponse)
                        let sseData = "data: \(String(decoding: jsonData, as: UTF8.self))\n\n"

                        try await writer.write(.buffer(ByteBuffer(string: sseData)))

                        // Update tracking variables
                        previousContent = cumulativeResponse.content
                        isFirstChunk = false
                    }

                    // Send final completion message
                    let finalResponse = ChatCompletionStreamResponse(
                        id: responseId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: Self.modelName,
                        choices: [
                            ChatCompletionStreamChoice(
                                index: 0,
                                delta: ChatCompletionDelta(
                                    role: nil,
                                    content: nil
                                ),
                                finishReason: "stop"
                            )
                        ]
                    )

                    let encoder = JSONEncoder()
                    let finalJsonData = try encoder.encode(finalResponse)
                    let finalSseData = "data: \(String(decoding: finalJsonData, as: UTF8.self))\n\n"

                    try await writer.write(.buffer(ByteBuffer(string: finalSseData)))

                    // Send [DONE] to indicate stream completion
                    try await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))

                    // Complete the stream
                    try await writer.write(.end)

                } catch {
                    Self.logger.error("Error in chat completion stream: \(error)")

                    // Handle errors by sending error message in SSE format
                    let errorData = Self.sseErrorPayload(
                        message: error.localizedDescription, type: "internal_error")
                    try? await writer.write(.buffer(ByteBuffer(string: errorData)))
                    try? await writer.write(.end)
                }
            }
        })

        return response
    }

    /// Builds a properly-escaped OpenAI-compatible SSE error frame followed by
    /// the terminating `[DONE]` sentinel. Encoding through `JSONEncoder` prevents
    /// quotes/backslashes/newlines in `message` from producing malformed JSON.
    private static func sseErrorPayload(message: String, type: String) -> String {
        let payload = APIErrorResponse(message: message, type: type)
        let json: String
        if let data = try? JSONEncoder().encode(payload) {
            json = String(decoding: data, as: UTF8.self)
        } else {
            json = #"{"error": {"message": "Unknown error", "type": "internal_error"}}"#
        }
        return "data: \(json)\n\ndata: [DONE]\n\n"
    }
}
