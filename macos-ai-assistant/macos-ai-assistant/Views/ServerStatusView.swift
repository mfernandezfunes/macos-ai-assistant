import SwiftUI

struct ServerStatusView: View {
    @EnvironmentObject var serverManager: VaporServerManager
    @State private var isModelAvailable = false
    @State private var modelUnavailableReason: String?

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { serverManager.isRunning },
            set: { newValue in
                Task {
                    if newValue {
                        await serverManager.startServer(configuration: .default)
                    } else {
                        await serverManager.stopServer()
                    }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            // Apple Intelligence availability
            HStack(spacing: 4) {
                Circle()
                    .fill(isModelAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("Apple Intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(isModelAvailable
                  ? "Apple Intelligence: Available"
                  : "Apple Intelligence: \(modelUnavailableReason ?? "Not available")")

            Divider().frame(height: 14)

            // Model name
            Text("apple-on-device")
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            // Server status + toggle
            HStack(spacing: 4) {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(serverManager.isRunning ? "Server :\(ServerConfiguration.default.port)" : "Server stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: toggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            // Refresh availability periodically so the indicator reflects changes
            // (e.g. Apple Intelligence being enabled or a model finishing download).
            while !Task.isCancelled {
                await refreshAvailability()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: serverManager.isRunning) {
            Task { await refreshAvailability() }
        }
    }

    private func refreshAvailability() async {
        let (available, reason) = await aiManager.isModelAvailable()
        isModelAvailable = available
        modelUnavailableReason = reason
    }
}
