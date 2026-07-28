import SwiftUI

/// Settings pane where the user enables or disables the built-in tools the
/// assistant can call during a conversation.
struct ToolSettingsView: View {
    @ObservedObject var settings: ToolSettings

    var body: some View {
        Form {
            Section {
                ForEach(AssistantToolID.allCases) { tool in
                    Toggle(isOn: binding(for: tool)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.displayName)
                            Text(tool.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Available Tools")
            } footer: {
                Text("When enabled, the on-device model can call these tools to answer your questions. Spotlight search lets the model see file names and paths on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
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
