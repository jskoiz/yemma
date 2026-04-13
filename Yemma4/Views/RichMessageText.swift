import SwiftUI
import MarkdownUI

#if canImport(UIKit)
import UIKit
#endif

struct RichMessageText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var isStreaming = false
    var foregroundColor: Color = AppTheme.assistantMessageText

    @State private var displayedStreamingText = ""

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
                    Markdown(renderedText)
                        .markdownTheme(chatMarkdownTheme)
                        .markdownSoftBreakMode(.lineBreak)
                        .foregroundStyle(foregroundColor)
                        .tint(AppTheme.accent)
                        .textSelection(.disabled)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Markdown(renderedText)
                        .markdownTheme(chatMarkdownTheme)
                        .markdownSoftBreakMode(.lineBreak)
                        .foregroundStyle(foregroundColor)
                        .tint(AppTheme.accent)
                        .textSelection(.enabled)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isStreaming {
                StreamingRichMessageText(
                    text: renderedText,
                    foregroundColor: foregroundColor
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 2))
                )
            } else {
                PlainRichMessageText(
                    text: renderedText,
                    isStreaming: isStreaming,
                    foregroundColor: foregroundColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isStreaming)
        .task(id: StreamingAnimationKey(targetText: text, isStreaming: isStreaming, reduceMotion: reduceMotion)) {
            await synchronizeDisplayedStreamingText()
        }
    }

    private var shouldRenderMarkdown: Bool {
        MarkdownHeuristics.looksLikeMarkdown(text)
    }

    private var renderedText: String {
        guard isStreaming else { return text }
        return text.hasPrefix(displayedStreamingText) ? displayedStreamingText : text
    }

    @MainActor
    private func synchronizeDisplayedStreamingText() async {
        guard isStreaming, !reduceMotion else {
            displayedStreamingText = text
            return
        }

        guard displayedStreamingText != text else {
            return
        }

        let targetCharacters = Array(text)
        let currentCharacters = Array(displayedStreamingText)

        guard targetCharacters.starts(with: currentCharacters) else {
            displayedStreamingText = text
            return
        }

        var revealedCount = currentCharacters.count

        while revealedCount < targetCharacters.count {
            guard !Task.isCancelled else { return }

            let remainingCharacters = targetCharacters.count - revealedCount
            let revealStep = min(Self.characterRevealStep(for: remainingCharacters), remainingCharacters)

            revealedCount += revealStep
            displayedStreamingText = String(targetCharacters.prefix(revealedCount))

            guard revealedCount < targetCharacters.count else { break }

            do {
                try await Task.sleep(for: Self.characterRevealDelay(for: remainingCharacters))
            } catch {
                return
            }
        }
    }

    private static func characterRevealStep(for remainingCharacters: Int) -> Int {
        switch remainingCharacters {
        case 0...4:
            return 1
        case 5...12:
            return 2
        case 13...24:
            return 3
        default:
            return 4
        }
    }

    private static func characterRevealDelay(for remainingCharacters: Int) -> Duration {
        switch remainingCharacters {
        case 0...6:
            return .milliseconds(18)
        case 7...18:
            return .milliseconds(12)
        default:
            return .milliseconds(8)
        }
    }
}

private struct StreamingAnimationKey: Equatable {
    let targetText: String
    let isStreaming: Bool
    let reduceMotion: Bool
}

private struct StreamingRichMessageText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var foregroundColor: Color

    private let wordSpacing: CGFloat = 4
    private let lineSpacing: CGFloat = 8
    private let blankLineHeight: CGFloat = 10

    private var lines: [StreamingTextLine] {
        Self.lines(from: text)
    }

    private var animatedSegmentIDs: [Int] {
        lines.flatMap { line in
            line.tokens.map(\.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            if lines.isEmpty {
                Text(" ")
                    .font(AppTheme.Typography.chatAssistantMessage)
                    .hidden()
            } else {
                ForEach(lines) { line in
                    if line.tokens.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: blankLineHeight, alignment: .leading)
                    } else {
                        StreamingTokenFlowLayout(
                            itemSpacing: wordSpacing,
                            lineSpacing: lineSpacing
                        ) {
                            ForEach(line.tokens) { token in
                                StreamingWordTokenView(
                                    token: token.text,
                                    foregroundColor: foregroundColor
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: animatedSegmentIDs)
    }

    private static func lines(from text: String) -> [StreamingTextLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var nextTokenID = 0

        return normalized.components(separatedBy: "\n").enumerated().map { lineIndex, rawLine in
            let tokens = tokens(
                from: rawLine,
                nextTokenID: &nextTokenID
            )

            return StreamingTextLine(id: lineIndex, tokens: tokens)
        }
    }

    private static func tokens(
        from line: String,
        nextTokenID: inout Int
    ) -> [StreamingWordToken] {
        guard !line.isEmpty else { return [] }

        var tokens: [StreamingWordToken] = []
        var current = ""

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(
                StreamingWordToken(
                    id: nextTokenID,
                    text: current
                )
            )
            nextTokenID += 1
            current.removeAll(keepingCapacity: true)
        }

        for character in line {
            if character.isWhitespace {
                appendCurrentToken()
                continue
            }

            if StreamingRenderer.isStandaloneStreamingUnit(character) {
                appendCurrentToken()
                current = String(character)
                appendCurrentToken()
                continue
            }

            current.append(character)
        }

        appendCurrentToken()
        return tokens
    }
}

private struct StreamingTextLine: Identifiable {
    let id: Int
    let tokens: [StreamingWordToken]
}

private struct StreamingWordToken: Identifiable {
    let id: Int
    let text: String
}

private struct StreamingWordTokenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let token: String
    let foregroundColor: Color

    var body: some View {
        Text(token)
            .font(AppTheme.Typography.chatAssistantMessage)
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(.leading)
            .allowsTightening(false)
            .fixedSize()
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 3))
            )
    }
}

private struct StreamingTokenFlowLayout: Layout {
    var itemSpacing: CGFloat = 4
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let layout = arrangedRows(
            for: subviews,
            maxWidth: proposal.width ?? .greatestFiniteMagnitude
        )

        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let layout = arrangedRows(for: subviews, maxWidth: bounds.width)

        for row in layout.rows {
            for item in row.items {
                let position = CGPoint(
                    x: bounds.minX + item.origin.x,
                    y: bounds.minY + item.origin.y
                )
                subviews[item.index].place(
                    at: position,
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func arrangedRows(
        for subviews: Subviews,
        maxWidth: CGFloat
    ) -> StreamingTokenFlowArrangement {
        let resolvedMaxWidth = max(maxWidth, 1)
        var rows: [StreamingTokenFlowRow] = []
        var currentItems: [StreamingTokenFlowItem] = []
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var currentY: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        func commitRow() {
            guard !currentItems.isEmpty else { return }

            rows.append(
                StreamingTokenFlowRow(
                    items: currentItems,
                    height: currentRowHeight
                )
            )
            maxRowWidth = max(maxRowWidth, currentRowWidth)
            currentY += currentRowHeight + lineSpacing
            currentItems.removeAll(keepingCapacity: true)
            currentRowWidth = 0
            currentRowHeight = 0
        }

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = currentItems.isEmpty ? size.width : currentRowWidth + itemSpacing + size.width

            if !currentItems.isEmpty, proposedWidth > resolvedMaxWidth {
                commitRow()
            }

            let originX = currentItems.isEmpty ? 0 : currentRowWidth + itemSpacing
            let originY = currentY

            currentItems.append(
                StreamingTokenFlowItem(
                    index: index,
                    size: size,
                    origin: CGPoint(x: originX, y: originY)
                )
            )
            currentRowWidth = originX + size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }

        commitRow()

        let height: CGFloat
        if let lastRow = rows.last {
            height = lastRow.items.first.map { $0.origin.y + lastRow.height } ?? 0
        } else {
            height = 0
        }

        return StreamingTokenFlowArrangement(
            rows: rows,
            width: maxRowWidth,
            height: height
        )
    }
}

private struct StreamingTokenFlowArrangement {
    let rows: [StreamingTokenFlowRow]
    let width: CGFloat
    let height: CGFloat
}

private struct StreamingTokenFlowRow {
    let items: [StreamingTokenFlowItem]
    let height: CGFloat
}

private struct StreamingTokenFlowItem {
    let index: Int
    let size: CGSize
    let origin: CGPoint
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
