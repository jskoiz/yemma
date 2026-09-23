import SwiftUI
import MarkdownUI

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

struct RichMessageText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var isStreaming = false
    var foregroundColor: Color = AppTheme.assistantMessageText

    /// Render mode is decided once when a stream begins and only re-evaluated when
    /// the stream finalizes. Locking it for the stream duration avoids reflowing the
    /// whole subtree the moment the first markdown token arrives mid-stream.
    @State private var lockedRendersMarkdown: Bool?

    private let chatMarkdownTheme = Theme.gitHub
        .text {
            ForegroundColor(nil)
            BackgroundColor(nil)
            FontSize(.em(1))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.08))
                }
                .markdownMargin(top: 10, bottom: 14)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                }
                .markdownMargin(top: 10, bottom: 14)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.94))
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
                        .markdownImageProvider(PrivateChatImageProvider())
                        .markdownInlineImageProvider(PrivateChatImageProvider())
                        .markdownSoftBreakMode(.lineBreak)
                        .font(AppTheme.Typography.chatAssistantMessage)
                        .foregroundStyle(foregroundColor)
                        .tint(AppTheme.accent)
                        .textSelection(.disabled)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Markdown(renderedText)
                        .markdownTheme(chatMarkdownTheme)
                        .markdownImageProvider(PrivateChatImageProvider())
                        .markdownInlineImageProvider(PrivateChatImageProvider())
                        .markdownSoftBreakMode(.lineBreak)
                        .font(AppTheme.Typography.chatAssistantMessage)
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
        .onChange(of: isStreaming, initial: true) { _, streaming in
            // Re-evaluate the render mode only when streaming starts or stops, never
            // mid-stream, so the first markdown token can't reflow the whole subtree.
            if streaming {
                lockMarkdownDecisionIfNeeded()
            } else {
                lockedRendersMarkdown = nil
            }
        }
        .onChange(of: text) { _, _ in
            // While streaming, latch the decision once content first looks like
            // markdown so a later marker doesn't trigger a plain -> markdown swap.
            // The decision is never reverted for the rest of the stream.
            guard isStreaming else { return }
            lockMarkdownDecisionIfNeeded()
        }
    }

    private func lockMarkdownDecisionIfNeeded() {
        // Latch the decision exactly once: as soon as the stream either looks like
        // markdown or has produced real (non-placeholder) content. After it is set
        // it is never changed mid-stream, so no plain <-> markdown reflow occurs.
        guard lockedRendersMarkdown == nil else { return }

        if MarkdownHeuristics.looksLikeMarkdown(text) {
            lockedRendersMarkdown = true
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lockedRendersMarkdown = false
        }
    }

    private var shouldRenderMarkdown: Bool {
        if isStreaming, let lockedRendersMarkdown {
            return lockedRendersMarkdown
        }
        return MarkdownHeuristics.looksLikeMarkdown(text)
    }

    /// The text the policy has already flushed is the single source of truth for what
    /// is on screen. The visible reveal cadence is driven entirely by the upstream
    /// `StreamingUpdatePolicy` flushes plus the per-token transitions below.
    private var renderedText: String {
        text
    }
}

private struct StreamingRichMessageText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var foregroundColor: Color

    private let wordSpacing: CGFloat = 4
    private let lineSpacing: CGFloat = 8
    private let blankLineHeight: CGFloat = 10

    var body: some View {
        let content = Self.content(from: text)

        VStack(alignment: .leading, spacing: lineSpacing) {
            if content.lines.isEmpty {
                Text(" ")
                    .font(AppTheme.Typography.chatAssistantMessage)
                    .hidden()
            } else {
                ForEach(content.lines) { line in
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
                                    isContinuation: token.isContinuation,
                                    foregroundColor: foregroundColor
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: content.animatedSegmentIDs)
    }

    private static func content(from text: String) -> StreamingTextContent {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var nextTokenID = 0

        let lines = normalized.components(separatedBy: "\n").enumerated().map { lineIndex, rawLine in
            let tokens = tokens(
                from: rawLine,
                nextTokenID: &nextTokenID
            )

            return StreamingTextLine(id: lineIndex, tokens: tokens)
        }

        return StreamingTextContent(
            lines: lines,
            animatedSegmentIDs: lines.flatMap { line in line.tokens.map(\.id) }
        )
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
            let parts = StreamingRenderer.streamingTokenParts(current)
            for (partIndex, part) in parts.enumerated() {
                tokens.append(
                    StreamingWordToken(
                        id: nextTokenID,
                        text: part,
                        isContinuation: partIndex > 0
                    )
                )
                nextTokenID += 1
            }
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

private struct StreamingTextContent {
    let lines: [StreamingTextLine]
    let animatedSegmentIDs: [Int]
}

private struct StreamingWordToken: Identifiable {
    let id: Int
    let text: String
    let isContinuation: Bool
}

private struct StreamingWordTokenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let token: String
    let isContinuation: Bool
    let foregroundColor: Color

    var body: some View {
        Text(token)
            .font(AppTheme.Typography.chatAssistantMessage)
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(.leading)
            .allowsTightening(false)
            .fixedSize(horizontal: false, vertical: true)
            .layoutValue(
                key: StreamingTokenSpacingKey.self,
                value: isContinuation ? 0 : 4
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 3))
            )
    }
}

private enum StreamingTokenSpacingKey: LayoutValueKey {
    static let defaultValue: CGFloat = 4
}

private struct StreamingTokenFlowLayout: Layout {
    var itemSpacing: CGFloat = 4
    var lineSpacing: CGFloat = 8

    struct Cache {
        var maxWidth: CGFloat?
        var arrangement: StreamingTokenFlowArrangement?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(maxWidth: nil, arrangement: nil)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache(maxWidth: nil, arrangement: nil)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let layout = cachedArrangement(
            for: subviews,
            maxWidth: proposal.width ?? .greatestFiniteMagnitude,
            cache: &cache
        )

        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let layout = cachedArrangement(
            for: subviews,
            maxWidth: bounds.width,
            cache: &cache
        )

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

    private func cachedArrangement(
        for subviews: Subviews,
        maxWidth: CGFloat,
        cache: inout Cache
    ) -> StreamingTokenFlowArrangement {
        let resolvedMaxWidth = max(maxWidth, 1)
        if cache.maxWidth == resolvedMaxWidth, let arrangement = cache.arrangement {
            return arrangement
        }

        let arrangement = arrangedRows(for: subviews, maxWidth: resolvedMaxWidth)
        cache.maxWidth = resolvedMaxWidth
        cache.arrangement = arrangement
        return arrangement
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
            let idealSize = subviews[index].sizeThatFits(.unspecified)
            let spacingBefore = currentItems.isEmpty
                ? 0
                : (subviews[index][StreamingTokenSpacingKey.self] == 0 ? 0 : itemSpacing)
            let proposedWidth = currentItems.isEmpty
                ? idealSize.width
                : currentRowWidth + spacingBefore + idealSize.width

            if !currentItems.isEmpty, proposedWidth > resolvedMaxWidth {
                commitRow()
            }

            let spacing = currentItems.isEmpty
                ? 0
                : (subviews[index][StreamingTokenSpacingKey.self] == 0 ? 0 : itemSpacing)
            let size = idealSize.width > resolvedMaxWidth
                ? subviews[index].sizeThatFits(
                    ProposedViewSize(width: resolvedMaxWidth, height: nil)
                )
                : idealSize
            let originX = currentItems.isEmpty ? 0 : currentRowWidth + spacing
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

enum MarkdownHeuristics {
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        let lines = trimmedText.components(separatedBy: "\n")

        if trimmedText.contains("```")
            || trimmedText.contains("`")
            || trimmedText.contains("[")
                && trimmedText.contains("](")
            || trimmedText.contains("**")
            || trimmedText.contains("__")
            || trimmedText.contains("~~")
            || containsDelimitedEmphasis(in: trimmedText, marker: "*")
            || containsDelimitedEmphasis(in: trimmedText, marker: "_")
            || containsTableSyntax(in: lines)
        {
            return true
        }

        for rawLine in lines {
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

    private static func containsDelimitedEmphasis(in text: String, marker: Character) -> Bool {
        let characters = Array(text)
        var delimiterCount = 0

        for index in characters.indices where characters[index] == marker {
            let previous = index > characters.startIndex ? characters[index - 1] : nil
            let nextIndex = characters.index(after: index)
            let next = nextIndex < characters.endIndex ? characters[nextIndex] : nil

            let canOpen = next?.isWhitespace == false
            let canClose = previous?.isWhitespace == false
            guard canOpen || canClose else { continue }
            delimiterCount += 1
        }

        return delimiterCount >= 2 && delimiterCount.isMultiple(of: 2)
    }

    private static func containsTableSyntax(in lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }

        for index in 0..<(lines.count - 1) {
            let header = lines[index].trimmingCharacters(in: .whitespaces)
            let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
            guard header.contains("|") else { continue }

            let separatorCells = separator.split(separator: "|", omittingEmptySubsequences: true)
            guard !separatorCells.isEmpty else { continue }

            let isDelimiterRow = separatorCells.allSatisfy { cell in
                let value = cell.trimmingCharacters(in: .whitespaces)
                let dashCount = value.filter { $0 == "-" }.count
                let nonDelimiterCharacters = value.filter { $0 != "-" && $0 != ":" && !$0.isWhitespace }
                return dashCount >= 3 && nonDelimiterCharacters.isEmpty
            }

            if isDelimiterRow {
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
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    copyCode()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(didCopy ? AppTheme.accent : AppTheme.assistantLabel)
                        .fixedSize()
                        .frame(minWidth: 80, minHeight: AppTheme.Layout.minimumControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
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
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: configuration.content]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120)
            ]
        )
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

/// Model-generated Markdown must never fetch an image, including inline images.
/// User-selected photos are rendered separately from their local attachments.
struct PrivateChatImageProvider: ImageProvider, InlineImageProvider {
    func makeImage(url: URL?) -> some View {
        Image(systemName: "photo")
            .accessibilityLabel("Remote image blocked")
    }

    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}
