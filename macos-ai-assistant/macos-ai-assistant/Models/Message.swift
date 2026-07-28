import Foundation
import SwiftData

/// The role of a chat participant. Stored as a raw `String` for SwiftData
/// compatibility while giving call sites a type-safe API.
enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system

    /// Maps an arbitrary role string to a known role, defaulting to `.user`.
    init(rawValueOrUser raw: String) {
        self = MessageRole(rawValue: raw.lowercased()) ?? .user
    }
}

@Model
final class Message {
    var id: UUID
    var role: String   // raw value of `MessageRole`
    var content: String
    var createdAt: Date
    var conversation: Conversation?

    /// Type-safe accessor over the stored `role` string.
    var messageRole: MessageRole {
        get { MessageRole(rawValueOrUser: role) }
        set { role = newValue.rawValue }
    }

    init(role: MessageRole, content: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role.rawValue
        self.content = content
        self.createdAt = Date()
        self.conversation = conversation
    }
}
