import SwiftUI

struct MessageInputView: View {
    @Binding var text: String
    let isStreaming: Bool
    var attachments: [String] = []
    var onAttach: (() -> Void)? = nil
    var onRemoveAttachment: ((Int) -> Void)? = nil
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(name).lineLimit(1)
                                Button { onRemoveAttachment?(index) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.controlBackgroundColor), in: Capsule())
                        }
                    }
                }
            }
            inputRow
        }
        .padding(12)
        .background(.bar)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let onAttach {
                Button(action: onAttach) {
                    Image(systemName: "paperclip").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Attach a PDF, image or text file")
                .disabled(isStreaming)
            }
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
    }

    private var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !isStreaming }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}

#Preview {
    MessageInputView(text: .constant(""), isStreaming: false, onSend: {})
}
