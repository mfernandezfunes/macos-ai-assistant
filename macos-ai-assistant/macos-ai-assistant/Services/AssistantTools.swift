import Foundation
import FoundationModels

// MARK: - Tool identifiers

/// Stable identifiers for the built-in tools the assistant can use. Persisted
/// (as raw strings) to remember which tools the user enabled.
enum AssistantToolID: String, CaseIterable, Identifiable, Sendable {
    case currentDate
    case spotlightSearch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentDate: return "Date & Time"
        case .spotlightSearch: return "Spotlight File Search"
        }
    }

    var summary: String {
        switch self {
        case .currentDate:
            return "Lets the assistant read the current date and time."
        case .spotlightSearch:
            return "Lets the assistant search files on your Mac with Spotlight."
        }
    }
}

// MARK: - Tool factory

/// Builds concrete `Tool` instances for the enabled identifiers.
enum AssistantToolFactory {
    static func makeTools(for ids: Set<AssistantToolID>) -> [any Tool] {
        ids.sorted { $0.rawValue < $1.rawValue }.map { id in
            switch id {
            case .currentDate: return CurrentDateTool()
            case .spotlightSearch: return SpotlightSearchTool()
            }
        }
    }
}

// MARK: - Current date/time tool

/// Returns the current local date and time. The model has no clock of its own,
/// so this grounds any time-relative answer in reality.
struct CurrentDateTool: Tool {
    let name = "getCurrentDateTime"
    let description = "Returns the current local date and time."

    @Generable
    struct Arguments {
        @Guide(description: "An IANA time zone identifier such as 'America/Argentina/Buenos_Aires'. Leave empty for the device's local time zone.")
        var timeZoneIdentifier: String
    }

    func call(arguments: Arguments) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        let trimmed = arguments.timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let tz = TimeZone(identifier: trimmed) {
            formatter.timeZone = tz
        }
        return "The current date and time is \(formatter.string(from: Date()))."
    }
}

// MARK: - Spotlight file search tool

/// Searches the Mac for files by name or content using Spotlight
/// (`NSMetadataQuery`). Requires the app to run without the App Sandbox to see
/// files outside its container.
struct SpotlightSearchTool: Tool {
    let name = "searchFiles"
    let description = "Searches the user's Mac for files by name or content using Spotlight."

    @Generable
    struct Arguments {
        @Guide(description: "The text to search for in file names and contents.")
        var query: String
        @Guide(description: "Maximum number of files to return.", .range(1...10))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let term = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return "No search term was provided." }

        let results = await SpotlightSearch.run(term: term, limit: max(1, min(arguments.limit, 10)))
        guard !results.isEmpty else {
            return """
                No files matching '\(term)' were found. Note: if the file is in \
                Documents, Downloads, Desktop, iCloud, or a cloud drive, the app \
                may need Full Disk Access (System Settings > Privacy & Security > \
                Full Disk Access) to see it.
                """
        }

        let list = results
            .map { "- \($0.name) (\($0.path))" }
            .joined(separator: "\n")
        return "Found \(results.count) file(s) matching '\(term)':\n\(list)"
    }
}

// MARK: - Spotlight query runner

/// A single Spotlight hit.
struct SpotlightResult: Sendable {
    let name: String
    let path: String
}

/// Wraps `NSMetadataQuery` in a one-shot async call. The query must run on the
/// main run loop, so we hop to the main actor and bridge completion via a
/// notification observer.
///
/// Spotlight can return tens of thousands of hits (a bare `CONTAINS` matches
/// file contents too), so we gather a bounded candidate pool and re-rank it in
/// Swift: name matches beat content-only matches, and files under the user's
/// home folder beat system/`~Library` noise. Only then do we take `limit`.
enum SpotlightSearch {
    /// How many raw hits to inspect before ranking. Large enough to surface the
    /// good matches buried under content hits, small enough to stay cheap.
    private static let candidateCap = 300

    static func run(term: String, limit: Int) async -> [SpotlightResult] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let query = NSMetadataQuery()
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
                // Match against display name or textual content, case/diacritic
                // insensitive. Name matches are preferred at ranking time.
                query.predicate = NSPredicate(
                    format: "kMDItemDisplayName CONTAINS[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@",
                    term, term)
                // No sortDescriptors: NSMetadataQuery silently drops items that
                // lack the sort attribute (e.g. cloud placeholders without a
                // content-change date), so sorting here would hide real matches.
                // We rank in Swift instead.

                var observer: NSObjectProtocol?
                // Guard against double-resume if the notification fires more than once.
                var resumed = false
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering,
                    object: query,
                    queue: .main
                ) { _ in
                    query.stop()
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    guard !resumed else { return }
                    resumed = true

                    let candidates = (0..<query.resultCount)
                        .prefix(Self.candidateCap)
                        .compactMap { index -> SpotlightResult? in
                            guard let item = query.result(at: index) as? NSMetadataItem else {
                                return nil
                            }
                            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey)
                                as? String ?? "Unknown"
                            let path = item.value(forAttribute: NSMetadataItemPathKey)
                                as? String ?? ""
                            return SpotlightResult(name: name, path: path)
                        }

                    let ranked = Self.rank(Array(candidates), term: term).prefix(limit)
                    continuation.resume(returning: Array(ranked))
                }

                query.start()
            }
        }
    }

    /// Orders candidates so the most relevant land first: a term match in the
    /// file name outranks a content-only match, and files under the user's home
    /// folder outrank system/`~Library` files. Stable so Spotlight's recency
    /// ordering breaks ties.
    static func rank(_ results: [SpotlightResult], term: String) -> [SpotlightResult] {
        let home = NSHomeDirectory()
        let library = home + "/Library"

        func score(_ result: SpotlightResult) -> Int {
            var score = 0
            if result.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                score += 100  // name match: the strong signal
            }
            if result.path.hasPrefix(home) { score += 10 }   // prefer the user's files
            if result.path.hasPrefix(library) { score -= 8 }  // demote ~/Library noise
            return score
        }

        return results
            .enumerated()
            .sorted { lhs, rhs in
                let ls = score(lhs.element), rs = score(rhs.element)
                if ls != rs { return ls > rs }
                return lhs.offset < rhs.offset  // stable: keep Spotlight's order
            }
            .map(\.element)
    }
}
