import Foundation

/// Plain, Codable snapshot of a conversation used for JSON export/import and
/// for rendering Markdown. Independent of SwiftData so it is easy to test.
nonisolated struct ConversationSnapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var role: String
        var content: String
        var createdAt: Date
        var attachments: [String]
    }

    static let currentVersion = 1

    var version: Int = ConversationSnapshot.currentVersion
    var title: String
    var createdAt: Date
    var systemInstructions: String
    var messages: [Entry]
}

nonisolated enum ConversationExport {
    enum ImportError: LocalizedError {
        case invalid
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalid: return "The file is not a valid conversation export."
            case .unsupportedVersion(let v): return "Unsupported export version \(v)."
            }
        }
    }

    static func json(_ snapshot: ConversationSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> ConversationSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: ConversationSnapshot
        do { snapshot = try decoder.decode(ConversationSnapshot.self, from: data) }
        catch { throw ImportError.invalid }
        guard snapshot.version <= ConversationSnapshot.currentVersion else {
            throw ImportError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    static func markdown(_ snapshot: ConversationSnapshot) -> String {
        var lines: [String] = []
        let title = snapshot.title.isEmpty ? "Conversation" : snapshot.title
        lines.append("# \(title)")
        lines.append("")
        lines.append("_\(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))_")
        let instructions = snapshot.systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            lines.append("")
            lines.append("> **System instructions:** " + instructions.replacingOccurrences(of: "\n", with: "\n> "))
        }
        for entry in snapshot.messages {
            lines.append("")
            lines.append("## " + (entry.role.lowercased() == "user" ? "You" : "Assistant"))
            if !entry.attachments.isEmpty {
                lines.append("")
                lines.append("_Attachments: " + entry.attachments.joined(separator: ", ") + "_")
            }
            lines.append("")
            lines.append(entry.content)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A filesystem-safe base name for the exported file.
    static func fileName(for snapshot: ConversationSnapshot) -> String {
        let raw = snapshot.title.isEmpty ? "Conversation" : snapshot.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Conversation" : cleaned).prefix(60))
    }
}

extension Conversation {
    nonisolated var snapshot: ConversationSnapshot {
        ConversationSnapshot(
            title: title, createdAt: createdAt, systemInstructions: systemInstructions,
            messages: messages.sorted { $0.createdAt < $1.createdAt }.map {
                .init(role: $0.role, content: $0.content, createdAt: $0.createdAt,
                      attachments: $0.attachmentNames.split(separator: "\n").map(String.init))
            })
    }

    /// Builds a new (unsaved) conversation from an imported snapshot.
    static func make(from snapshot: ConversationSnapshot) -> (Conversation, [Message]) {
        let conversation = Conversation(title: snapshot.title, systemInstructions: snapshot.systemInstructions)
        conversation.createdAt = snapshot.createdAt
        let messages = snapshot.messages.map { entry -> Message in
            let m = Message(role: MessageRole(rawValueOrUser: entry.role), content: entry.content)
            m.createdAt = entry.createdAt
            m.attachmentNames = entry.attachments.joined(separator: "\n")
            m.conversation = conversation
            return m
        }
        return (conversation, messages)
    }
}

/// Case-insensitive text search over titles and message bodies.
nonisolated enum ConversationSearch {
    static func matches(title: String, messages: [String], query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: q, options: options) != nil { return true }
        return messages.contains { $0.range(of: q, options: options) != nil }
    }
}
