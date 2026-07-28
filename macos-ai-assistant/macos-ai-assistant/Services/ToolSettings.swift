import Foundation
import Combine

/// Persists which built-in assistant tools are enabled. Backed by
/// `UserDefaults` so both the settings UI and the model manager can read it.
@MainActor
final class ToolSettings: ObservableObject {
    static let shared = ToolSettings()

    private static let defaultsKey = "enabledAssistantTools"

    @Published var enabled: Set<AssistantToolID> {
        didSet { persist() }
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
    }

    private let defaults: UserDefaults

    func isEnabled(_ id: AssistantToolID) -> Bool { enabled.contains(id) }

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
}
