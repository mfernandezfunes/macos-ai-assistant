import Foundation
import Combine

/// Persists which built-in assistant tools are enabled. Backed by
/// `UserDefaults` so both the settings UI and the model manager can read it.
@MainActor
final class ToolSettings: ObservableObject {
    static let shared = ToolSettings()

    private static let defaultsKey = "enabledAssistantTools"
    private static let skipConfirmationKey = "skipConfirmationAssistantTools"

    private static let shortcutsKey = "allowedShortcutNames"

    /// Shortcut names the model may run. Empty by default (nothing allowed).
    @Published var allowedShortcuts: [String] {
        didSet { defaults.set(allowedShortcuts, forKey: Self.shortcutsKey) }
    }

    @Published var enabled: Set<AssistantToolID> {
        didSet { persist() }
    }

    /// Tools whose per-call approval the user has switched off. Stored as
    /// opt-outs so newly added sensitive tools prompt by default.
    @Published var skipConfirmation: Set<AssistantToolID> {
        didSet { defaults.set(skipConfirmation.map(\.rawValue), forKey: Self.skipConfirmationKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.defaultsKey) as? [String] {
            self.enabled = Set(stored.compactMap(AssistantToolID.init(rawValue:)))
        } else {
            // Default on first launch: date/time on (safe), Spotlight off (opt-in
            // since it exposes local files to the model).
            self.enabled = [.currentDate]
        }
        self.skipConfirmation = Self.currentSkippedConfirmationIDs(defaults: defaults)
        self.allowedShortcuts = Self.currentAllowedShortcuts(defaults: defaults)
    }

    private let defaults: UserDefaults

    func isEnabled(_ id: AssistantToolID) -> Bool { enabled.contains(id) }

    func requiresConfirmation(_ id: AssistantToolID) -> Bool {
        id.alwaysRequiresApproval || (id.requiresApprovalByDefault && !skipConfirmation.contains(id))
    }

    func setRequiresConfirmation(_ id: AssistantToolID, _ on: Bool) {
        if on { skipConfirmation.remove(id) } else { skipConfirmation.insert(id) }
    }

    func setEnabled(_ id: AssistantToolID, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
    }

    private func persist() {
        defaults.set(enabled.map(\.rawValue), forKey: Self.defaultsKey)
    }

    /// Reads the currently-enabled tool IDs directly from `UserDefaults`, for
    /// non-main-actor callers (e.g. the model manager). Falls back to the
    /// first-launch default.
    nonisolated static func currentEnabledIDs(defaults: UserDefaults = .standard) -> Set<AssistantToolID> {
        guard let stored = defaults.array(forKey: defaultsKey) as? [String] else {
            return [.currentDate]
        }
        return Set(stored.compactMap(AssistantToolID.init(rawValue:)))
    }

    nonisolated private static func currentSkippedConfirmationIDs(defaults: UserDefaults) -> Set<AssistantToolID> {
        let stored = defaults.array(forKey: skipConfirmationKey) as? [String] ?? []
        return Set(stored.compactMap(AssistantToolID.init(rawValue:)))
    }

    /// Tools that must be approved by the user on each call: sensitive tools
    /// the user hasn't opted out of.
    nonisolated static func currentConfirmationIDs(defaults: UserDefaults = .standard) -> Set<AssistantToolID> {
        let skipped = currentSkippedConfirmationIDs(defaults: defaults)
        return Set(AssistantToolID.allCases.filter {
            $0.alwaysRequiresApproval || ($0.requiresApprovalByDefault && !skipped.contains($0))
        })
    }

    nonisolated static func currentAllowedShortcuts(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: shortcutsKey) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
