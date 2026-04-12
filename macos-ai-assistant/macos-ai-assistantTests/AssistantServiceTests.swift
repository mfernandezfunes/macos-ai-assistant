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
