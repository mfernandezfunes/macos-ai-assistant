import Foundation
import FoundationModels

// MARK: - Guided-generation types

/// The router's structured answer: which tools the latest message needs.
@Generable
struct ToolSelection {
    @Guide(
        description:
            "The tools strictly required to answer the latest user message. Empty for general conversation.",
        .maximumCount(2))
    var tools: [AssistantToolID]
}

// MARK: - Router

/// Picks, per message, which of the user-enabled tools to hand to the model.
///
/// The on-device model has a ~4k-token window and gets confused when many tool
/// definitions compete with the conversation. A cheap guided-generation pass
/// decides which tool (if any) the message needs, so the main session only
/// sees those. The user's enabled set remains the hard upper bound.
enum ToolRouter {
    /// With zero or one enabled tool there is nothing to choose between.
    static func needsRouting(enabledCount: Int) -> Bool { enabledCount > 1 }

    /// Keeps only enabled tools, drops duplicates, preserves the router's order.
    static func resolve(
        selection: [AssistantToolID], enabled: Set<AssistantToolID>
    ) -> [AssistantToolID] {
        var seen = Set<AssistantToolID>()
        return selection.filter { enabled.contains($0) && seen.insert($0).inserted }
    }

    static func instructions(for enabled: [AssistantToolID]) -> String {
        let list = enabled.map { "- \($0.rawValue): \($0.summary)" }.joined(separator: "\n")
        return """
            You decide which tools an assistant needs to answer the user's latest \
            message. Available tools:
            \(list)
            Choose only the tools strictly needed. Choose none for greetings, \
            opinions, or questions answerable from general knowledge. Messages \
            may be in any language.
            """
    }

    /// Returns the tools to use for this request. On any failure falls back to
    /// every enabled tool, so routing can only narrow, never break, tool use.
    static func select(
        model: SystemLanguageModel,
        recentUserMessages: [String],
        enabled: Set<AssistantToolID>
    ) async -> [AssistantToolID] {
        let ordered = enabled.sorted { $0.rawValue < $1.rawValue }
        guard needsRouting(enabledCount: ordered.count), !recentUserMessages.isEmpty else {
            return ordered
        }

        // Include the previous user message so follow-ups ("and tomorrow?")
        // still route to the right tool.
        let prompt = recentUserMessages.suffix(2)
            .map { String($0.prefix(500)) }
            .joined(separator: "\n---\n")

        let session = LanguageModelSession(model: model, instructions: instructions(for: ordered))
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ToolSelection.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return resolve(selection: response.content.tools, enabled: enabled)
        } catch {
            return ordered
        }
    }
}
