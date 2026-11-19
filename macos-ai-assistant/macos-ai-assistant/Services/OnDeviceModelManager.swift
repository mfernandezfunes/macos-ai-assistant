import Foundation
import FoundationModels
import Vapor

// MARK: - Guided-generation types

/// Structured output for auto-generating a short conversation title.
@Generable
struct ConversationTitle {
    @Guide(description: "A concise chat title, 2 to 5 words, no quotes and no trailing punctuation.")
    var title: String
}

// MARK: - Apple Intelligence Manager

/// Manager for Apple Intelligence on-device language model
actor OnDeviceModelManager {
    private let model: SystemLanguageModel

    /// Fallback context window (~4,096 tokens shared across instructions +
    /// prompts + outputs) used when the model can't report its own size. At
    /// request time we prefer `SystemLanguageModel.contextSize`. We trim older
    /// turns to stay under it and reserve headroom for the response.
    static let contextTokenLimit = 4_096
    static let reservedResponseTokens = 1_024

    init() {
        self.model = SystemLanguageModel.default
    }

    /// Rough token estimate (~4 characters per token for Latin scripts, ~1 for
    /// CJK). Deliberately conservative so we trim before the framework throws
    /// a context-size error.
    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 3)
    }

    /// Trims the message history so instructions + prompts fit the context
    /// window, always keeping any leading system messages and the most recent
    /// turns (including the current prompt). Preserves ordering.
    func fitToContextWindow(
        _ messages: [ChatMessage],
        reservingTokens: Int = OnDeviceModelManager.reservedResponseTokens,
        contextLimit: Int = OnDeviceModelManager.contextTokenLimit
    ) -> [ChatMessage] {
        let budget = contextLimit - reservingTokens
        guard budget > 0, !messages.isEmpty else { return messages }

        // System messages steer every turn and are small — always keep them.
        let systemMessages = messages.filter { $0.role.lowercased() == "system" }
        let conversational = messages.filter { $0.role.lowercased() != "system" }

        var used = systemMessages.reduce(0) { $0 + Self.estimatedTokens($1.content) }
        var kept: [ChatMessage] = []
        // Walk newest-to-oldest so we drop the oldest turns first.
        for message in conversational.reversed() {
            let cost = Self.estimatedTokens(message.content)
            // Always keep the most recent message (the current prompt).
            if !kept.isEmpty && used + cost > budget { break }
            kept.append(message)
            used += cost
        }
        kept.reverse()

        return systemMessages + kept
    }

    /// Generates a short, descriptive title for a conversation using guided
    /// generation. Returns nil if the model is unavailable or generation fails.
    func generateTitle(for firstMessage: String) async -> String? {
        guard isModelAvailable().available else { return nil }

        let session = LanguageModelSession(
            model: model,
            instructions: """
                Generate a short, descriptive title for a conversation that begins \
                with the person's message. Use 2 to 5 words. Do not use quotes or \
                end punctuation.
                """
        )
        do {
            let response = try await session.respond(
                to: firstMessage,
                generating: ConversationTitle.self
            )
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }

    /// Check if the model is available
    func isModelAvailable() -> (available: Bool, reason: String?) {
        let availability = model.availability

        switch availability {
        case .available:
            return (true, nil)

        case .unavailable(let reason):
            let reasonString: String
            switch reason {
            case .deviceNotEligible:
                reasonString =
                    "Device not eligible for Apple Intelligence. Supported devices: iPhone 15 Pro/Pro Max or newer, iPad with M1 chip or newer, Mac with Apple Silicon"

            case .appleIntelligenceNotEnabled:
                reasonString =
                    "Apple Intelligence not enabled. Enable it in Settings > Apple Intelligence & Siri"

            case .modelNotReady:
                reasonString =
                    "AI model not ready. Models are downloaded automatically based on network status, battery level, and system load. Please wait and try again later."

            @unknown default:
                reasonString = "Unknown availability issue"
            }
            return (false, reasonString)

        @unknown default:
            return (false, "Unknown availability status")
        }
    }

    /// Get supported languages
    func getSupportedLanguages() -> [String] {
        let languages = model.supportedLanguages

        return languages.compactMap { language -> String? in
            let locale = Locale(identifier: language.maximalIdentifier)

            // Get the display name in the current locale
            if let displayName = locale.localizedString(forIdentifier: language.maximalIdentifier) {
                return displayName
            }

            // Fallback to language code if display name is not available
            return language.languageCode?.identifier
        }.sorted()
    }

    /// Preload the on-device model into memory to reduce the latency of the
    /// first response. Safe to call repeatedly; no-op if the model is
    /// unavailable. Optionally pass the conversation's system instructions so
    /// the warmed session matches the one used for the real request.
    func prewarm(instructions: String? = nil) {
        guard isModelAvailable().available else { return }

        let session: LanguageModelSession
        if let instructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session = LanguageModelSession(model: model, instructions: instructions)
        } else {
            session = LanguageModelSession(model: model)
        }
        session.prewarm()
    }

    /// Convert chat messages to transcript entries.
    ///
    /// The enabled tools must be advertised to the model through the transcript's
    /// `Instructions` entry — passing `tools:` to the session only supplies the
    /// callable implementations, not the schemas the model reasons over. Without
    /// the definitions here the model can't discover the tools and will
    /// hallucinate answers instead of calling them.
    func convertMessagesToTranscript(
        _ messages: [ChatMessage],
        tools: [any Tool] = []
    ) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        let toolDefinitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        var toolsAttached = false

        // Process all messages in order
        for message in messages {
            let textSegment = Transcript.TextSegment(content: message.content)

            switch message.role.lowercased() {
            case "system":
                // Convert system messages to instructions, attaching the tool
                // definitions to the first instructions entry we emit.
                let instructions = Transcript.Instructions(
                    segments: [.text(textSegment)],
                    toolDefinitions: toolsAttached ? [] : toolDefinitions
                )
                toolsAttached = true
                entries.append(.instructions(instructions))

            case "user":
                // Convert user messages to prompts
                let prompt = Transcript.Prompt(
                    segments: [.text(textSegment)]
                )
                entries.append(.prompt(prompt))

            case "assistant":
                // Convert assistant messages to responses
                let response = Transcript.Response(
                    assetIDs: [],
                    segments: [.text(textSegment)]
                )
                entries.append(.response(response))

            default:
                // Treat unknown roles as user messages
                let prompt = Transcript.Prompt(
                    segments: [.text(textSegment)]
                )
                entries.append(.prompt(prompt))
            }
        }

        // If the conversation carried no system message, the tools were never
        // attached above. Prepend a minimal instructions entry so the model can
        // still discover them.
        if !toolsAttached && !toolDefinitions.isEmpty {
            let instructions = Transcript.Instructions(
                segments: [],
                toolDefinitions: toolDefinitions
            )
            entries.insert(.instructions(instructions), at: 0)
        }

        return entries
    }

    // MARK: - Shared session preparation

    /// A ready-to-use session plus the prompt to send it. Shared by the
    /// streaming and non-streaming paths so both build requests identically.
    struct PreparedRequest {
        let session: LanguageModelSession
        let prompt: String
    }

    /// Trims history to the model's real context window, advertises the
    /// user-enabled tools, and builds a session seeded with the prior turns.
    func prepareSession(for messages: [ChatMessage]) async throws -> PreparedRequest {
        guard messages.last != nil else {
            throw Abort(.badRequest, reason: "No messages provided")
        }

        // The tools are resolved once so the same set is advertised in the
        // transcript and wired into the session.
        let tools = AssistantToolFactory.makeTools(for: ToolSettings.currentEnabledIDs())

        let fitted = await fitUsingModelTokenCounts(messages, tools: tools)
        guard let lastMessage = fitted.last else {
            throw Abort(.badRequest, reason: "No messages provided")
        }

        // Everything but the last message becomes transcript history; the last
        // one is the current prompt.
        let previous = fitted.count > 1 ? Array(fitted.dropLast()) : []
        let transcript = Transcript(
            entries: convertMessagesToTranscript(previous, tools: tools))

        let session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
        return PreparedRequest(session: session, prompt: lastMessage.content)
    }

    /// Heuristic trim first (cheap), then — on macOS 26.4+ — refine with the
    /// model's exact token counts, dropping the oldest turns until it fits.
    private func fitUsingModelTokenCounts(
        _ messages: [ChatMessage], tools: [any Tool]
    ) async -> [ChatMessage] {
        let limit = model.contextSize
        var fitted = fitToContextWindow(messages, contextLimit: limit)

        guard #available(macOS 26.4, *) else { return fitted }
        let budget = limit - Self.reservedResponseTokens
        guard budget > 0 else { return fitted }

        while true {
            let entries = convertMessagesToTranscript(fitted, tools: tools)
            guard let count = try? await model.tokenCount(for: entries), count > budget else {
                break  // fits, or the count is unavailable — keep what we have
            }
            // Drop the oldest non-system message, but never the current prompt.
            let conversational = fitted.indices.filter { fitted[$0].role.lowercased() != "system" }
            guard conversational.count > 1, let oldest = conversational.first else { break }
            fitted.remove(at: oldest)
        }
        return fitted
    }

    /// Builds generation options from the optional OpenAI-style parameters.
    static func makeOptions(temperature: Double?, maxTokens: Int?) -> GenerationOptions {
        if let temperature {
            return GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        } else if let maxTokens {
            return GenerationOptions(maximumResponseTokens: maxTokens)
        }
        return GenerationOptions()
    }

    // MARK: - Error mapping

    /// An HTTP-facing description of a model failure.
    struct APIFailure {
        let status: HTTPResponseStatus
        let type: String
        let message: String
    }

    /// Maps FoundationModels errors to meaningful HTTP statuses and OpenAI-style
    /// error types instead of a blanket 422/500.
    static func apiFailure(for error: Error) -> APIFailure {
        if let abort = error as? AbortError {
            return APIFailure(
                status: abort.status, type: "invalid_request_error", message: abort.reason)
        }
        if let error = error as? LanguageModelSession.GenerationError {
            let message = error.localizedDescription
            switch error {
            case .exceededContextWindowSize:
                return APIFailure(
                    status: .badRequest, type: "context_length_exceeded",
                    message: "The conversation is too long for the on-device model. "
                        + "Start a new chat or shorten the message. (\(message))")
            case .guardrailViolation:
                return APIFailure(
                    status: .unprocessableEntity, type: "content_filter",
                    message: "Apple's safety guardrails blocked this request. Try rephrasing. (\(message))")
            case .refusal:
                return APIFailure(
                    status: .unprocessableEntity, type: "refusal", message: message)
            case .unsupportedLanguageOrLocale:
                return APIFailure(
                    status: .badRequest, type: "unsupported_language",
                    message: "The on-device model doesn't support this language. (\(message))")
            case .rateLimited, .concurrentRequests:
                return APIFailure(
                    status: .tooManyRequests, type: "rate_limit_exceeded", message: message)
            case .assetsUnavailable:
                return APIFailure(
                    status: .serviceUnavailable, type: "unavailable_error",
                    message: "The on-device model assets aren't available yet. (\(message))")
            default:
                return APIFailure(
                    status: .unprocessableEntity, type: "generation_error", message: message)
            }
        }
        return APIFailure(
            status: .internalServerError, type: "internal_error",
            message: "Error generating response: \(error.localizedDescription)")
    }

    /// Generate a response for the given messages with conversation context
    func generateResponse(
        for messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil
    ) async throws -> String {
        let (available, reason) = isModelAvailable()
        guard available else {
            throw Abort(
                .serviceUnavailable, reason: reason ?? "Apple Intelligence model is not available")
        }

        let prepared = try await prepareSession(for: messages)
        do {
            let response = try await prepared.session.respond(
                to: prepared.prompt,
                options: Self.makeOptions(temperature: temperature, maxTokens: maxTokens)
            )
            return response.content
        } catch {
            let failure = Self.apiFailure(for: error)
            throw Abort(failure.status, reason: failure.message)
        }
    }

    /// Generate a response for a single prompt (for backward compatibility)
    func generateResponse(for prompt: String, temperature: Double? = nil, maxTokens: Int? = nil)
        async throws -> String
    {
        let messages = [ChatMessage(role: "user", content: prompt)]
        return try await generateResponse(
            for: messages, temperature: temperature, maxTokens: maxTokens)
    }
}

// Global instance of the Apple Intelligence manager
let aiManager = OnDeviceModelManager()
