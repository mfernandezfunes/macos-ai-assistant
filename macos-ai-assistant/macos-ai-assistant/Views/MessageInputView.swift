import SwiftUI

struct MessageInputView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onKeyPress { keyPress in
                    // Return sends; Shift+Return inserts a newline.
                    guard keyPress.key == .return else { return .ignored }
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    submit()
                    return .handled
                }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(12)
        .background(.bar)
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}

#Preview {
    MessageInputView(text: .constant(""), isStreaming: false, onSend: {})
}
