import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    /// Optional system instructions applied to the assistant for this
    /// conversation. Injected fresh as a `system` message on each request
    /// (not stored as a persisted `Message`, per the design spec).
    var systemInstructions: String = ""
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]

    init(title: String = "", systemInstructions: String = "") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.systemInstructions = systemInstructions
        self.messages = []
    }
}
