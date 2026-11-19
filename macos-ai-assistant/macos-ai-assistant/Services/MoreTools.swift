import AppKit
import EventKit
import Foundation
import FoundationModels

// MARK: - Calculator

/// Evaluates arithmetic exactly. Small models are unreliable at maths, so this
/// replaces guessing. Uses a hand-written parser: `NSExpression` raises
/// uncatchable Objective-C exceptions on malformed input.
struct CalculatorTool: Tool {
    let name = "calculate"
    let description = "Evaluates an arithmetic expression exactly. Always use it for any calculation instead of computing in your head. Supports + - * / % ^ and parentheses."

    @Generable
    struct Arguments {
        @Guide(description: "The arithmetic expression, for example '(12.5 + 3) * 4 / 7'.")
        var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolGate.run(.calculator, detail: "Calculate \(arguments.expression)") {
            do {
                let value = try ArithmeticParser.evaluate(arguments.expression)
                return "\(arguments.expression) = \(ArithmeticParser.format(value))"
            } catch {
                return "Could not evaluate '\(arguments.expression)': \(error.localizedDescription)"
            }
        }
    }
}

enum ArithmeticError: Error, LocalizedError {
    case unexpected(String)
    case divisionByZero
    case tooLong

    var errorDescription: String? {
        switch self {
        case .unexpected(let what): return "unexpected \(what)"
        case .divisionByZero: return "division by zero"
        case .tooLong: return "expression is too long"
        }
    }
}

/// Recursive-descent parser: expr → term (('+'|'-') term)*, term → power
/// (('*'|'/'|'%') power)*, power → unary ('^' power)?, unary → '-'? atom.
enum ArithmeticParser {
    static func evaluate(_ input: String) throws -> Double {
        guard input.count <= 200 else { throw ArithmeticError.tooLong }
        var parser = Parser(chars: Array(input.filter { !$0.isWhitespace }))
        let value = try parser.expression()
        if let extra = parser.peek { throw ArithmeticError.unexpected("'\(extra)'") }
        guard value.isFinite else { throw ArithmeticError.divisionByZero }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0
        init(chars: [Character]) { self.chars = chars }

        var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() throws -> Double {
            var value = try term()
            while let op = peek, op == "+" || op == "-" {
                index += 1
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() throws -> Double {
            var value = try power()
            while let op = peek, op == "*" || op == "/" || op == "%" {
                index += 1
                let rhs = try power()
                switch op {
                case "*": value *= rhs
                case "/":
                    if rhs == 0 { throw ArithmeticError.divisionByZero }
                    value /= rhs
                default:
                    if rhs == 0 { throw ArithmeticError.divisionByZero }
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if peek == "^" {
                index += 1
                return pow(base, try power())  // right-associative
            }
            return base
        }

        mutating func unary() throws -> Double {
            if peek == "-" { index += 1; return -(try unary()) }
            if peek == "+" { index += 1; return try unary() }
            return try atom()
        }

        mutating func atom() throws -> Double {
            if peek == "(" {
                index += 1
                depth += 1
                guard depth < 50 else { throw ArithmeticError.tooLong }
                let value = try expression()
                guard peek == ")" else { throw ArithmeticError.unexpected("end of expression") }
                index += 1
                depth -= 1
                return value
            }
            let start = index
            while let c = peek, c.isNumber || c == "." { index += 1 }
            guard index > start, let value = Double(String(chars[start..<index])) else {
                if let c = peek { throw ArithmeticError.unexpected("'\(c)'") }
                throw ArithmeticError.unexpected("end of expression")
            }
            return value
        }
    }
}

// MARK: - Clipboard

struct ClipboardTool: Tool {
    let name = "readClipboard"
    let description = "Reads the text currently on the user's clipboard."

    @Generable
    struct Arguments {}

    static let maxCharacters = 3_000

    func call(arguments: Arguments) async throws -> String {
        try await ToolGate.run(.clipboard, detail: "Read the clipboard") {
            let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            guard let text, !text.isEmpty else { return "The clipboard has no text." }
            return Self.truncate(text)
        }
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…[truncated, \(text.count) characters total]"
    }
}

// MARK: - Read file

/// Reads a text file under the user's home folder. Sensitive locations are
/// refused outright, and output is capped to fit the ~4k-token context.
struct ReadFileTool: Tool {
    let name = "readFile"
    let description = "Reads the text content of a file in the user's home folder, given its full path."

    @Generable
    struct Arguments {
        @Guide(description: "Absolute path of the file, such as one returned by searchFiles.")
        var path: String
    }

    static let maxCharacters = 3_000

    enum Refusal: Error, LocalizedError {
        case outsideHome, sensitive, notReadable, notText

        var errorDescription: String? {
            switch self {
            case .outsideHome: return "Only files inside the user's home folder can be read."
            case .sensitive: return "That location is protected and cannot be read."
            case .notReadable: return "The file doesn't exist or can't be read."
            case .notText: return "The file isn't readable text."
            }
        }
    }

    /// Resolves symlinks and `..`, then rejects anything outside home or in a
    /// protected directory (hidden folders, ~/Library, key material).
    static func validate(path: String, home: String = NSHomeDirectory()) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let homeURL = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let homePath = homeURL.path.hasSuffix("/") ? homeURL.path : homeURL.path + "/"
        guard url.path.hasPrefix(homePath) else { throw Refusal.outsideHome }

        let relative = url.path.dropFirst(homePath.count).split(separator: "/").map(String.init)
        if relative.first == "Library" || relative.contains(where: { $0.hasPrefix(".") }) {
            throw Refusal.sensitive
        }
        return url
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolGate.run(.readFile, detail: "Read file \(arguments.path)") {
            do {
                let url = try Self.validate(path: arguments.path)
                guard let handle = try? FileHandle(forReadingFrom: url) else { throw Refusal.notReadable }
                defer { try? handle.close() }
                // Read a bounded prefix; never load a huge file into memory.
                let data = (try? handle.read(upToCount: Self.maxCharacters * 4)) ?? Data()
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                      !data.contains(0)
                else { throw Refusal.notText }
                guard text.count > Self.maxCharacters else { return text }
                return String(text.prefix(Self.maxCharacters)) + "\n…[truncated]"
            } catch {
                return "Could not read the file: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Calendar & Reminders

/// Shared EventKit store; one instance keeps authorization state consistent.
enum EventStore {
    static let shared = EKEventStore()
}

struct CalendarEventsTool: Tool {
    let name = "getCalendarEvents"
    let description = "Lists the user's upcoming calendar events. Call it directly whenever the user asks about their schedule, agenda or meetings."

    @Generable
    struct Arguments {
        @Guide(description: "How many days ahead to look, starting now. Use 7 unless the user names a period. Never ask the user for this.", .range(1...30))
        var daysAhead: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let days = max(1, min(arguments.daysAhead, 30))
        return try await ToolGate.run(.calendar, detail: "Read calendar events for the next \(days) day(s)") {
            let store = EventStore.shared
            guard (try? await store.requestFullAccessToEvents()) == true else {
                return "Calendar access was not granted. Enable it in System Settings > Privacy & Security > Calendars."
            }
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            let events = store.events(
                matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
                .prefix(15)
            guard !events.isEmpty else { return "No events in the next \(days) day(s)." }

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return events.map { event in
                let when = event.isAllDay
                    ? formatter.string(from: event.startDate).components(separatedBy: ",").first ?? "all day"
                    : formatter.string(from: event.startDate)
                return "- \(when): \(event.title ?? "Untitled")"
            }.joined(separator: "\n")
        }
    }
}

struct RemindersTool: Tool {
    let name = "getReminders"
    let description = "Lists the user's incomplete reminders (to-dos). Call it directly whenever the user asks about their reminders or to-do list; it needs no input."

    @Generable
    struct Arguments {}

    static let limit = 20

    func call(arguments: Arguments) async throws -> String {
        let limit = Self.limit
        return try await ToolGate.run(.reminders, detail: "Read incomplete reminders") {
            let store = EventStore.shared
            guard (try? await store.requestFullAccessToReminders()) == true else {
                return "Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders."
            }
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            let titles: [String] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: (reminders ?? []).prefix(limit).map { $0.title ?? "Untitled" })
                }
            }
            guard !titles.isEmpty else { return "No incomplete reminders." }
            return titles.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}
