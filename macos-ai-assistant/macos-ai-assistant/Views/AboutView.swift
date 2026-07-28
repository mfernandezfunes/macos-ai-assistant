import SwiftUI

struct AboutView: View {
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("macOS AI Assistant")
                .font(.title2)
                .fontWeight(.semibold)

            Text(versionString)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Powered by Apple Intelligence")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Developed by Martin Fernandez Funes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 380)
    }
}

/// Button that lives inside a CommandGroup so it can access openWindow.
struct OpenAboutWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About macOS AI Assistant") {
            openWindow(id: "about")
        }
    }
}

#Preview {
    AboutView()
}
