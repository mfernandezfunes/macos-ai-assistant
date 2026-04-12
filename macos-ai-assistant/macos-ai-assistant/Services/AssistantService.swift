import Foundation

// MARK: - Errors

enum AssistantError: Error, LocalizedError {
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)"
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

// MARK: - Service

final class AssistantService {
    private static let endpointURL = URL(string: "http://127.0.0.1:11535/v1/chat/completions")!
    private static let modelName = "apple-on-device"

    /// Builds the URLRequest for a chat completion (testable static helper).
    static func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
        try AssistantService().makeRequest(messages: messages)
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
            if let token = Self.parseSSELine(line), !token.isEmpty {
                await onToken(token)
            }
        }
    }

    // MARK: - Private

    private func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The local Apple Intelligence server does not require authentication.
        request.setValue("Bearer not-needed", forHTTPHeaderField: "Authorization")
        let body = ChatRequest(model: Self.modelName, messages: messages, stream: true)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
