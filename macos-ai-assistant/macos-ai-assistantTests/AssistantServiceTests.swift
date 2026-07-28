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
}
