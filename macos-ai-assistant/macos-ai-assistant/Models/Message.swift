import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID
    var role: String   // "user" | "assistant"
    var content: String
    var createdAt: Date
    var conversation: Conversation?

    init(role: String, content: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.conversation = conversation
    }
}
