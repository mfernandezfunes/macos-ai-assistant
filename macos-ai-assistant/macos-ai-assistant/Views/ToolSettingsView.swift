import SwiftUI

/// Settings pane where the user enables or disables the built-in tools the
/// assistant can call during a conversation.
struct ToolSettingsView: View {
    @ObservedObject var settings: ToolSettings

    var body: some View {
        Form {
            Section {
                ForEach(AssistantToolID.allCases) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: binding(for: tool)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.displayName)
                                Text(tool.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Ask before each use", isOn: confirmBinding(for: tool))
                            .font(.caption)
                            .disabled(!settings.isEnabled(tool) || !tool.requiresApprovalByDefault || tool.alwaysRequiresApproval)
                    }
                }
            } header: {
                Text("Available Tools")
            } footer: {
                Text("When enabled, the on-device model can call these tools to answer your questions. Spotlight search lets the model see file names and paths on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: shortcutsBinding)
                    .font(.body.monospaced())
                    .frame(height: 70)
                    .disabled(!settings.isEnabled(.shortcuts))
            } header: {
                Text("Allowed Shortcuts")
            } footer: {
                Text("One exact shortcut name per line. The assistant can run only these, and always asks first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 760)
    }

    private var shortcutsBinding: Binding<String> {
        Binding(
            get: { settings.allowedShortcuts.joined(separator: "\n") },
            set: { settings.allowedShortcuts = $0.split(separator: "\n").map(String.init) }
        )
    }

    private func confirmBinding(for tool: AssistantToolID) -> Binding<Bool> {
        Binding(
            get: { settings.requiresConfirmation(tool) },
            set: { settings.setRequiresConfirmation(tool, $0) }
        )
    }

    private func binding(for tool: AssistantToolID) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(tool) },
            set: { settings.setEnabled(tool, $0) }
        )
    }
}

#Preview {
    ToolSettingsView(settings: ToolSettings())
}
