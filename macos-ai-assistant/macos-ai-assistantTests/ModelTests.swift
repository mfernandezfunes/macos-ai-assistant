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

    override func tearDown() async throws {
        container = nil
    }

    func testConversationCreation() throws {
        let ctx = container.mainContext
        let conv = Conversation(title: "Test")
        ctx.insert(conv)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(fetched.count, 1)
        let conv2 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(conv2.title, "Test")
    }

    func testConversationPersistsSystemInstructions() throws {
        let ctx = container.mainContext
        let conv = Conversation(title: "Persona", systemInstructions: "Talk like a pirate.")
        ctx.insert(conv)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Conversation>())
        let conv2 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(conv2.systemInstructions, "Talk like a pirate.")
    }

    func testConversationDefaultsToEmptyInstructions() throws {
        let conv = Conversation(title: "Plain")
        XCTAssertEqual(conv.systemInstructions, "")
    }

    func testMessageBelongsToConversation() throws {
        let ctx = container.mainContext
        let conv = Conversation(title: "Chat")
        let msg = Message(role: .user, content: "Hello", conversation: conv)
        ctx.insert(conv)
        ctx.insert(msg)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Conversation>())
        let conv2 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(conv2.messages.count, 1)
        let msg2 = try XCTUnwrap(conv2.messages.first)
        XCTAssertEqual(msg2.content, "Hello")
    }

    func testCascadeDeleteRemovesMessages() throws {
        let ctx = container.mainContext
        let conv = Conversation(title: "Delete me")
        let msg = Message(role: .user, content: "Bye", conversation: conv)
        ctx.insert(conv)
        ctx.insert(msg)
        try ctx.save()

        ctx.delete(conv)
        try ctx.save()

        let messages = try ctx.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(messages.count, 0, "Cascade delete should remove orphaned messages")
    }
}
