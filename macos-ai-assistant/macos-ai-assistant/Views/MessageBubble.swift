import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let role: String
    let content: String
    let isStreaming: Bool

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                Circle()
                    .fill(Color(.windowBackgroundColor))
                    .overlay(Text("🤖").font(.caption))
                    .frame(width: 26, height: 26)
                    .alignmentGuide(.bottom) { d in d[.bottom] }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                if isUser {
                    Text(content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Markdown(content + (isStreaming ? " ▌" : ""))
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubble(role: "user", content: "Show me a Python hello world", isStreaming: false)
        MessageBubble(role: "assistant", content: """
        Sure! Here's a simple example:

        ```python
        print("Hello, world!")
        ```

        Run it with `python ejemplo.py` in your terminal.
        """, isStreaming: false)
    }
    .padding()
}
