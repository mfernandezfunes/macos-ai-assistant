import Foundation
import Combine

// MARK: - Events

/// One tool invocation, surfaced in the chat so the user can see what the
/// model did on their behalf.
struct ToolEvent: Identifiable, Equatable {
    enum Status: Equatable {
        case awaitingApproval
        case running
        case completed
        case denied
        case failed(String)
    }

    let id: UUID
    let tool: AssistantToolID
    let detail: String
    let startedAt: Date
    var status: Status
}

/// A pending "may the model use this tool?" question shown to the user.
struct ToolApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let tool: AssistantToolID
    let detail: String
}

// MARK: - Activity center

/// Tracks tool calls made by the on-device model and brokers user approval.
///
/// Tools run inside the in-process model session, so they report here rather
/// than going through the HTTP layer. If nobody answers an approval prompt
/// (e.g. the request came from an external API client with the window closed)
/// it is denied after `approvalTimeout`.
@MainActor
final class ToolActivityCenter: ObservableObject {
    static let shared = ToolActivityCenter()

    @Published private(set) var events: [ToolEvent] = []
    @Published private(set) var pendingApproval: ToolApprovalRequest?

    private var queue: [ToolApprovalRequest] = []
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    static let maxEvents = 50
    var approvalTimeout: Duration = .seconds(60)

    // MARK: Events

    func begin(_ tool: AssistantToolID, detail: String) -> UUID {
        let event = ToolEvent(
            id: UUID(), tool: tool, detail: detail, startedAt: Date(), status: .running)
        events.append(event)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        return event.id
    }

    func update(_ id: UUID, status: ToolEvent.Status) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].status = status
    }

    // MARK: Approval

    /// Suspends until the user allows or denies the call (or the timeout hits).
    func requestApproval(for eventID: UUID, tool: AssistantToolID, detail: String) async -> Bool {
        update(eventID, status: .awaitingApproval)
        let request = ToolApprovalRequest(id: eventID, tool: tool, detail: detail)

        let approved = await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            queue.append(request)
            pendingApproval = queue.first
            Task { [weak self, timeout = approvalTimeout] in
                try? await Task.sleep(for: timeout)
                self?.resolve(request.id, approved: false)
            }
        }
        update(eventID, status: approved ? .running : .denied)
        return approved
    }

    /// Answers a pending request. Idempotent: later calls (timeout after the
    /// user already answered) are ignored.
    func resolve(_ id: UUID, approved: Bool) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        queue.removeAll { $0.id == id }
        pendingApproval = queue.first
        continuation.resume(returning: approved)
    }
}

// MARK: - Gate used by the tools

enum ToolGate {
    static let denialMessage =
        "The user declined to let you use this tool. Do not retry it; answer without it and say you were not given access."

    /// Wraps a tool body: records the call, asks for approval when the tool is
    /// configured to require it, then runs the body and records the outcome.
    static func run(
        _ tool: AssistantToolID,
        detail: String,
        body: () async throws -> String
    ) async throws -> String {
        let center = await ToolActivityCenter.shared
        let id = await center.begin(tool, detail: detail)

        if ToolSettings.currentConfirmationIDs().contains(tool) {
            let approved = await center.requestApproval(for: id, tool: tool, detail: detail)
            guard approved else { return denialMessage }
        }

        do {
            let result = try await body()
            await center.update(id, status: .completed)
            return result
        } catch {
            await center.update(id, status: .failed(error.localizedDescription))
            throw error
        }
    }
}
