import Foundation

// MARK: - Errors

enum AssistantError: Error, LocalizedError {
    case httpError(statusCode: Int)
    case invalidEndpoint
    case serverError(message: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)"
        case .invalidEndpoint: return "Invalid server endpoint URL"
        case .serverError(let message): return message
        }
    }
}

// MARK: - API types

// ChatMessage is defined in OpenAIModels.swift (from Vapor Content types)

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

/// Error frame the local server may stream inside a 200 SSE response.
private struct SSEErrorPayload: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
}

/// Result of parsing a single SSE line.
enum SSEEvent: Equatable {
    case token(String)
    case error(String)
}

// MARK: - Service

final class AssistantService {
    private static let modelName = "apple-on-device"

    private let configuration: ServerConfiguration

    init(configuration: ServerConfiguration = .default) {
        self.configuration = configuration
    }

    /// Builds the URLRequest for a chat completion (testable static helper).
    static func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
        try AssistantService().makeRequest(messages: messages)
    }

    /// Instance-level request builder exposed for tests to verify the endpoint
    /// is derived from the injected `ServerConfiguration`.
    func makeTestableRequest(messages: [ChatMessage]) throws -> URLRequest {
        try makeRequest(messages: messages)
    }

    /// Parses one SSE line into a token, a streamed server error, or nil.
    static func parseSSELine(_ line: String) -> SSEEvent? {
        guard line.hasPrefix("data:") else { return nil }
        // Tolerate both "data: " and "data:" prefixes.
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }

        // Surface server-streamed error frames instead of silently dropping them.
        if let errorPayload = try? JSONDecoder().decode(SSEErrorPayload.self, from: data) {
            return .error(errorPayload.error.message)
        }
        guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
              let content = chunk.choices.first?.delta.content
        else { return nil }
        return .token(content)
    }

    /// Streams a response from the local AI server, calling `onToken` on the main actor for each partial token.
    func send(
        messages: [ChatMessage],
        onToken: @escaping @MainActor (String) -> Void
    ) async throws {
        let request = try makeRequest(messages: messages)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard httpResponse.statusCode == 200 else {
            throw AssistantError.httpError(statusCode: httpResponse.statusCode)
        }

        for try await line in asyncBytes.lines {
            switch Self.parseSSELine(line) {
            case .token(let token):
                if !token.isEmpty { await onToken(token) }
            case .error(let message):
                throw AssistantError.serverError(message: message)
            case nil:
                continue
            }
        }
    }

    /// Preloads the on-device model to reduce time-to-first-token. Runs
    /// in-process against the shared manager (no HTTP round-trip needed).
    func prewarm(instructions: String? = nil) async {
        await aiManager.prewarm(instructions: instructions)
    }

    /// Generates a short conversation title via guided generation. Returns nil
    /// if the model is unavailable or generation fails.
    func generateTitle(for firstMessage: String) async -> String? {
        await aiManager.generateTitle(for: firstMessage)
    }

    // MARK: - Private

    private func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        guard let url = URL(string: configuration.chatCompletionsEndpoint) else {
            throw AssistantError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The local Apple Intelligence server does not require authentication.
        request.setValue("Bearer not-needed", forHTTPHeaderField: "Authorization")
        let body = ChatRequest(model: Self.modelName, messages: messages, stream: true)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
