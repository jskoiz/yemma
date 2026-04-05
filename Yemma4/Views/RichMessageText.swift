import SwiftUI
import MarkdownUI

#if canImport(UIKit)
import UIKit
#endif

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
                    FontSize(17)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
                .markdownMargin(top: 3, bottom: 1)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 4)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 0)
        }
        .thematicBreak {
            Divider()
                .overlay(AppTheme.separator)
                .markdownMargin(top: 4, bottom: 4)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(nil)
        }
        .codeBlock { configuration in
            ChatCodeBlock(configuration: configuration)
                .markdownMargin(top: 3, bottom: 6)
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
            .markdownMargin(top: 2, bottom: 4)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
            }
            .markdownMargin(top: 2, bottom: 6)
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
            .font(AppTheme.Typography.chatAssistantMessage)
            .foregroundStyle(foregroundColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChatCodeBlock: View {
    let configuration: CodeBlockConfiguration

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(configuration.language?.uppercased() ?? "CODE")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.assistantLabel)

                Spacer()

                Button {
                    copyCode()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(didCopy ? AppTheme.accent : AppTheme.assistantLabel)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.accentSoft)

            Divider()
                .overlay(AppTheme.assistantBubbleBorder)

            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.84))
                        BackgroundColor(nil)
                    }
                    .padding(12)
            }
        }
        .background(AppTheme.messageCodeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)
                .stroke(AppTheme.assistantBubbleBorder, lineWidth: 1)
        )
    }

    private func copyCode() {
#if canImport(UIKit)
        UIPasteboard.general.string = configuration.content
#endif
        AppDiagnostics.shared.record(
            "Code block copied",
            category: "ui",
            metadata: [
                "chars": configuration.content.count,
                "language": configuration.language ?? "plain"
            ]
        )

        didCopy = true
        Task {
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }

            await MainActor.run {
                didCopy = false
            }
        }
    }
}

#if DEBUG
#Preview("Markdown Chat") {
    ZStack {
        AppBackground()
        RichMessageText(
            text: """
            ## Compact Markdown

            Short paragraph with `inline code`.

            - first bullet
            - second bullet

            ```swift
            struct Example {
                let value = 42
            }
            ```
            """
        )
        .padding(20)
    }
}
#endif
