import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Apple Intelligence Assistant")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version 1.0")
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
        Button("About Apple Intelligence Assistant") {
            openWindow(id: "about")
        }
    }
}

#Preview {
    AboutView()
}
