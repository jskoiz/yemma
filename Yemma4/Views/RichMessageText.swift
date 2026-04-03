import SwiftUI
import MarkdownUI

struct RichMessageText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.gitHub)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.accent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
