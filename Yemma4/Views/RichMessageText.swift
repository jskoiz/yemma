import SwiftUI
import MarkdownUI

#if canImport(UIKit)
import UIKit
#endif

struct RichMessageText: View {
    let text: String
    var isStreaming = false
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
                .markdownMargin(top: 10, bottom: 14)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 10, bottom: 14)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
                .markdownMargin(top: 8, bottom: 12)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 8)
        }
        .thematicBreak {
            Divider()
                .overlay(AppTheme.separator)
                .markdownMargin(top: 10, bottom: 12)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(nil)
        }
        .codeBlock { configuration in
            ChatCodeBlock(configuration: configuration)
                .markdownMargin(top: 10, bottom: 14)
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
            .markdownMargin(top: 8, bottom: 14)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
            }
            .markdownMargin(top: 10, bottom: 14)
        }

    var body: some View {
        Group {
            if shouldRenderMarkdown {
                if isStreaming {
                    Markdown(text)
                        .markdownTheme(chatMarkdownTheme)
                        .markdownSoftBreakMode(.lineBreak)
                        .foregroundStyle(foregroundColor)
                        .tint(AppTheme.accent)
                        .textSelection(.disabled)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Markdown(text)
                        .markdownTheme(chatMarkdownTheme)
                        .markdownSoftBreakMode(.lineBreak)
                        .foregroundStyle(foregroundColor)
                        .tint(AppTheme.accent)
                        .textSelection(.enabled)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                PlainRichMessageText(
                    text: text,
                    isStreaming: isStreaming,
                    foregroundColor: foregroundColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldRenderMarkdown: Bool {
        MarkdownHeuristics.looksLikeMarkdown(text)
    }
}

private struct PlainRichMessageText: View {
    let text: String
    var isStreaming = false
    var foregroundColor: Color

    private var paragraphs: [String] {
        Self.paragraphs(from: text)
    }

    var body: some View {
        Group {
            if isStreaming {
                content
                    .textSelection(.disabled)
            } else {
                content
                    .textSelection(.enabled)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(AppTheme.Typography.chatAssistantMessage)
                    .foregroundStyle(foregroundColor)
                    .multilineTextAlignment(.leading)
                    .allowsTightening(false)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func paragraphs(from text: String) -> [String] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var currentParagraph: [String] = []

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph.joined(separator: "\n"))
                    currentParagraph.removeAll()
                }
            } else {
                currentParagraph.append(line)
            }
        }

        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.joined(separator: "\n"))
        }

        let trimmedText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if paragraphs.isEmpty, !trimmedText.isEmpty {
            return [trimmedText]
        }

        return paragraphs
    }
}

private enum MarkdownHeuristics {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        if trimmedText.contains("```")
            || trimmedText.contains("`")
            || trimmedText.contains("[")
                && trimmedText.contains("](")
            || trimmedText.contains("**")
            || trimmedText.contains("__")
            || trimmedText.contains("~~")
        {
            return true
        }

        for rawLine in trimmedText.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#")
                || line.hasPrefix(">")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("- [")
                || line.hasPrefix("* [")
                || startsWithOrderedListMarker(line)
            {
                return true
            }
        }

        return false
    }

    private static func startsWithOrderedListMarker(_ line: String) -> Bool {
        let digitPrefix = line.prefix(while: \.isNumber)
        guard !digitPrefix.isEmpty else { return false }

        let remainder = line.dropFirst(digitPrefix.count)
        return remainder.hasPrefix(". ") || remainder.hasPrefix(") ")
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

#Preview("Markdown Chat Dark") {
    ZStack {
        AppBackground()
        RichMessageText(
            text: """
            ## Compact Markdown

            A short answer with `inline code`, a quote, and a tighter code sample.

            > Keep spacing compact and easy to scan.

            ```swift
            func greet(_ name: String) -> String {
                "Hello, \\(name)"
            }
            ```
            """
        )
        .padding(20)
    }
    .preferredColorScheme(.dark)
}
#endif
