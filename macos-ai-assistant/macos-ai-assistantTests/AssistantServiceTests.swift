import XCTest
import FoundationModels
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
        XCTAssertEqual(AssistantService.parseSSELine(line), .token("Hello"))
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

    func testParseSSELineSurfacesServerError() {
        let line = #"data: {"error": {"message": "Model not available", "type": "unavailable_error"}}"#
        XCTAssertEqual(AssistantService.parseSSELine(line), .error("Model not available"))
    }

    func testParseSSELineHandlesEscapedCharactersInError() {
        // A message containing quotes/backslashes must round-trip when the server
        // encodes it via JSONEncoder (fix for unescaped SSE error interpolation).
        let message = #"Bad "input" with \ and newline"#
        let payload = APIErrorResponse(message: message, type: "internal_error")
        let json = String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertEqual(AssistantService.parseSSELine("data: \(json)"), .error(message))
    }

    func testBuildRequestUsesConfiguredEndpoint() throws {
        let config = ServerConfiguration(host: "127.0.0.1", port: 9999)
        let request = try AssistantService(configuration: config)
            .makeTestableRequest(messages: [ChatMessage(role: "user", content: "Hi")])
        XCTAssertEqual(
            request.url?.absoluteString, "http://127.0.0.1:9999/v1/chat/completions")
    }

    // MARK: - Context window trimming

    func testFitToContextWindowKeepsShortHistoryIntact() async {
        let manager = OnDeviceModelManager()
        let messages = [
            ChatMessage(role: "user", content: "Hello"),
            ChatMessage(role: "assistant", content: "Hi there"),
            ChatMessage(role: "user", content: "How are you?"),
        ]
        let fitted = await manager.fitToContextWindow(messages)
        XCTAssertEqual(fitted.count, 3, "Short histories should not be trimmed")
    }

    func testFitToContextWindowDropsOldestTurnsFirst() async {
        let manager = OnDeviceModelManager()
        // Each message is ~1,500 tokens (≈4,500 chars / 3); several exceed the
        // ~3,072-token budget, forcing older turns to be dropped.
        let big = String(repeating: "a", count: 4_500)
        let messages = (0..<6).map { ChatMessage(role: "user", content: "\($0) \(big)") }
        let fitted = await manager.fitToContextWindow(messages)

        XCTAssertLessThan(fitted.count, messages.count, "Old turns should be dropped")
        XCTAssertFalse(fitted.isEmpty, "The most recent turn must always survive")
        XCTAssertEqual(
            fitted.last?.content, messages.last?.content,
            "The newest message (current prompt) must be kept")
    }

    func testFitToContextWindowAlwaysKeepsSystemMessage() async {
        let manager = OnDeviceModelManager()
        let big = String(repeating: "b", count: 4_500)
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: "You are a pirate.")]
        messages += (0..<6).map { ChatMessage(role: "user", content: "\($0) \(big)") }
        let fitted = await manager.fitToContextWindow(messages)

        XCTAssertEqual(
            fitted.first?.role.lowercased(), "system",
            "System instructions must be preserved and kept first")
        XCTAssertLessThan(fitted.count, messages.count)
    }

    // MARK: - Tool advertisement in transcript

    /// The model only discovers tools it sees advertised in the transcript's
    /// `Instructions` entry. Without this the model hallucinates instead of
    /// calling the tool, so guard that the definitions are attached.
    func testTranscriptAttachesToolDefinitionsToSystemInstructions() async {
        let manager = OnDeviceModelManager()
        let messages = [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "Hi"),
        ]
        let tools = AssistantToolFactory.makeTools(for: [.currentDate])
        let entries = await manager.convertMessagesToTranscript(messages, tools: tools)

        var toolCount = 0
        for entry in entries {
            if case .instructions(let instructions) = entry {
                toolCount += instructions.toolDefinitions.count
            }
        }
        XCTAssertEqual(toolCount, 1, "The enabled tool must be advertised exactly once")
    }

    /// When the conversation has no system message we must still prepend an
    /// instructions entry so the tools are discoverable.
    func testTranscriptPrependsInstructionsWhenNoSystemMessage() async {
        let manager = OnDeviceModelManager()
        let messages = [ChatMessage(role: "user", content: "What time is it?")]
        let tools = AssistantToolFactory.makeTools(for: [.currentDate])
        let entries = await manager.convertMessagesToTranscript(messages, tools: tools)

        var toolCount = 0
        for entry in entries {
            if case .instructions(let instructions) = entry {
                toolCount += instructions.toolDefinitions.count
            }
        }
        XCTAssertEqual(
            toolCount, 1,
            "A synthetic instructions entry must carry the tools even without a system message")
    }

    /// With no tools enabled we should not inject a spurious instructions entry.
    func testTranscriptWithoutToolsAddsNoInstructionsEntry() async {
        let manager = OnDeviceModelManager()
        let messages = [ChatMessage(role: "user", content: "Hi")]
        let entries = await manager.convertMessagesToTranscript(messages, tools: [])

        var hasInstructions = false
        for entry in entries {
            if case .instructions = entry { hasInstructions = true }
        }
        XCTAssertFalse(hasInstructions, "No tools means no synthetic instructions entry")
    }
}
