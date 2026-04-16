import SwiftUI

enum AssistantRefinement: String {
    case shorter
    case moreDetail

    var title: String {
        switch self {
        case .shorter:
            return "Shorter"
        case .moreDetail:
            return "More detail"
        }
    }

    var systemImage: String {
        switch self {
        case .shorter:
            return "text.alignleft"
        case .moreDetail:
            return "plus.bubble"
        }
    }

    var prompt: String {
        switch self {
        case .shorter:
            return "Make that shorter and more direct."
        case .moreDetail:
            return "Expand that with a bit more detail and one concrete example."
        }
    }
}

struct ChatResponseStatsLabel: View {
    let stats: GenerationDebugStats

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(fullText)
            Text(compactText)
            Text(minimalText ?? "\(tokenLabel(stats.generationTokenCount)) tok")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(AppTheme.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .accessibilityLabel(accessibilityText)
    }

    private var fullText: String {
        let parts: [String] = [
            "\(tokenLabel(stats.generationTokenCount)) tok",
            minimalText,
            memoryText
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        return parts.joined(separator: " • ")
    }

    private var compactText: String {
        let parts: [String] = [
            minimalText,
            memoryText
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        if parts.isEmpty {
            return "\(tokenLabel(stats.generationTokenCount)) tok"
        }

        return parts.joined(separator: " • ")
    }

    private var minimalText: String? {
        let parts = [
            stats.tokensPerSecond.map { String(format: "%.1f tok/s", $0) },
            elapsedText(stats.elapsedSeconds)
        ]
        .compactMap { $0 }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private var memoryText: String? {
        guard let memoryFootprintBytes = stats.memoryFootprintBytes else { return nil }
        return "RAM \(ByteCountFormatter.string(fromByteCount: Int64(memoryFootprintBytes), countStyle: .memory))"
    }

    private var accessibilityText: String {
        var parts = ["\(tokenLabel(stats.generationTokenCount)) generated tokens"]

        if let tokensPerSecond = stats.tokensPerSecond {
            parts.append(String(format: "%.1f tokens per second", tokensPerSecond))
        }

        if let elapsedText = elapsedText(stats.elapsedSeconds) {
            parts.append("Elapsed \(elapsedText)")
        }

        if let memoryText {
            parts.append(memoryText)
        }

        if let memoryDeltaBytes = stats.memoryFootprintDeltaBytes {
            let sign = memoryDeltaBytes >= 0 ? "up" : "down"
            let delta = ByteCountFormatter.string(
                fromByteCount: Int64(abs(memoryDeltaBytes)),
                countStyle: .memory
            )
            parts.append("Memory \(sign) \(delta)")
        }

        return parts.joined(separator: ", ")
    }

    private func tokenLabel(_ count: Int) -> String {
        if count >= 1024 {
            return String(format: "%.1fK", Double(count) / 1024.0)
        }
        return "\(count)"
    }

    private func elapsedText(_ elapsedSeconds: TimeInterval) -> String? {
        guard elapsedSeconds > 0 else { return nil }

        if elapsedSeconds < 10 {
            return String(format: "%.1fs", elapsedSeconds)
        }

        return String(format: "%.0fs", elapsedSeconds.rounded())
    }
}

struct ChatMessageActionStrip: View {
    let messageID: String
    let messageText: String
    let index: Int
    let isGenerating: Bool
    let canRetry: Bool
    let showsResponseStats: Bool
    let responseStats: GenerationDebugStats?
    let onCopy: () -> Void
    let onShare: () -> Void
    let onRetry: () -> Void
    let onRefine: (AssistantRefinement) -> Void

    var body: some View {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: 14) {
            if let responseStats, showsResponseStats {
                ChatResponseStatsLabel(stats: responseStats)
                Spacer(minLength: 0)
            }

            if !trimmedText.isEmpty {
                actionButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    accessibilityHint: "Copy this response.",
                    action: onCopy
                )
            }

            if canRetry && !isGenerating {
                actionButton(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    accessibilityHint: "Generate the assistant reply again.",
                    action: onRetry
                )

                actionButton(
                    title: AssistantRefinement.shorter.title,
                    systemImage: AssistantRefinement.shorter.systemImage,
                    accessibilityHint: "Ask for a shorter version of the latest assistant reply.",
                    action: { onRefine(.shorter) }
                )
            }

            actionOverflowMenu(trimmedText: trimmedText)
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    private func actionOverflowMenu(trimmedText: String) -> some View {
        Menu {
            if !trimmedText.isEmpty {
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if canRetry && !isGenerating {
                Button {
                    onRetry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }

                ForEach([AssistantRefinement.shorter, .moreDetail], id: \.rawValue) { refinement in
                    Button {
                        onRefine(refinement)
                    } label: {
                        Label(refinement.title, systemImage: refinement.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .accessibilityHint("Shows actions for this response.")
    }
}
