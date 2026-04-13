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
            if isStreaming {
                StreamingRichMessageText(
                    text: text,
                    foregroundColor: foregroundColor
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 2))
                )
            } else if shouldRenderMarkdown {
                Markdown(text)
                    .markdownTheme(chatMarkdownTheme)
                    .markdownSoftBreakMode(.lineBreak)
                    .foregroundStyle(foregroundColor)
                    .tint(AppTheme.accent)
                    .textSelection(.enabled)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PlainRichMessageText(
                    text: text,
                    isStreaming: isStreaming,
                    foregroundColor: foregroundColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isStreaming)
    }

    private var shouldRenderMarkdown: Bool {
        MarkdownHeuristics.looksLikeMarkdown(text)
    }
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
            line.segments.compactMap { segment in
                segment.kind == .content ? segment.id : nil
            }
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
                    if line.segments.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: blankLineHeight, alignment: .leading)
                    } else {
                        StreamingTokenFlowLayout(
                            itemSpacing: wordSpacing,
                            lineSpacing: lineSpacing
                        ) {
                            ForEach(line.segments) { segment in
                                StreamingTextSegmentView(
                                    segment: segment,
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
        var nextSegmentID = 0

        return normalized.components(separatedBy: "\n").enumerated().map { lineIndex, rawLine in
            let segments = segments(
                from: rawLine.replacingOccurrences(of: "\t", with: "    "),
                nextSegmentID: &nextSegmentID
            )

            return StreamingTextLine(id: lineIndex, segments: segments)
        }
    }

    private static func segments(
        from line: String,
        nextSegmentID: inout Int
    ) -> [StreamingTextSegment] {
        guard !line.isEmpty else { return [] }

        var segments: [StreamingTextSegment] = []
        var current = ""
        var currentKind: StreamingTextSegmentKind?

        func appendCurrentSegment() {
            guard let currentKind, !current.isEmpty else { return }
            segments.append(
                StreamingTextSegment(
                    id: nextSegmentID,
                    text: current,
                    kind: currentKind
                )
            )
            nextSegmentID += 1
            current.removeAll(keepingCapacity: true)
        }

        for character in line {
            if character.isWhitespace {
                if currentKind != .whitespace {
                    appendCurrentSegment()
                    currentKind = .whitespace
                }
                current.append(character)
                continue
            }

            if StreamingRenderer.isStandaloneStreamingUnit(character) {
                appendCurrentSegment()
                currentKind = .content
                current = String(character)
                appendCurrentSegment()
                currentKind = nil
                continue
            }

            if currentKind != .content {
                appendCurrentSegment()
                currentKind = .content
            }
            current.append(character)
        }

        appendCurrentSegment()
        return segments
    }
}

private struct StreamingTextLine: Identifiable {
    let id: Int
    let segments: [StreamingTextSegment]
}

private struct StreamingTextSegment: Identifiable {
    let id: Int
    let text: String
    let kind: StreamingTextSegmentKind
}

private enum StreamingTextSegmentKind {
    case content
    case whitespace
}

private struct StreamingTextSegmentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let segment: StreamingTextSegment
    let foregroundColor: Color

    var body: some View {
        Group {
            if segment.kind == .whitespace {
                Text(segment.text)
                    .font(AppTheme.Typography.chatAssistantMessage)
                    .hidden()
                    .accessibilityHidden(true)
            } else {
                Text(segment.text)
                    .font(AppTheme.Typography.chatAssistantMessage)
                    .foregroundStyle(foregroundColor)
                    .multilineTextAlignment(.leading)
                    .allowsTightening(false)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: 3))
                    )
            }
        }
        .fixedSize()
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
