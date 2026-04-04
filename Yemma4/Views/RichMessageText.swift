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
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(18)
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
                .markdownMargin(top: 6, bottom: 3)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 6)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 1, bottom: 1)
        }
        .thematicBreak {
            Divider()
                .overlay(Color.secondary.opacity(0.2))
                .markdownMargin(top: 6, bottom: 6)
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
                    .padding(12)
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .markdownMargin(top: 4, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 10)
            }
            .markdownMargin(top: 4, bottom: 4)
        }

    var body: some View {
        Markdown(text)
            .markdownTheme(chatMarkdownTheme)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lightweight plain-text view used during streaming to avoid markdown layout churn.
struct StreamingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(AppTheme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
