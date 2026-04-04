import SwiftUI
import MarkdownUI

struct RichMessageText: View {
    let text: String

    private let chatMarkdownTheme = Theme.gitHub
        .text {
            ForegroundColor(nil)
            BackgroundColor(nil)
            FontSize(16)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(nil)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                        BackgroundColor(nil)
                    }
                    .padding(16)
            }
            .background(Color.clear)
            .markdownMargin(top: 0, bottom: 16)
        }

    var body: some View {
        Markdown(text)
            .markdownTheme(chatMarkdownTheme)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.accent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
