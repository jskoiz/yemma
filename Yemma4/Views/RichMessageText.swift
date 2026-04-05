import SwiftUI
import MarkdownUI

struct RichMessageText: View {
    let text: String
    var foregroundColor: Color = AppTheme.assistantMessageText

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
                .overlay(AppTheme.separator)
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
            .background(AppTheme.messageCodeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
            .markdownMargin(top: 4, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.messageQuote)
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
            .foregroundStyle(foregroundColor)
            .tint(AppTheme.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lightweight plain-text view used during streaming to avoid markdown layout churn.
struct StreamingText: View {
    let text: String
    var foregroundColor: Color = AppTheme.assistantMessageText

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(foregroundColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
