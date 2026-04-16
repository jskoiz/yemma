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

struct ChatMessageActionStrip: View {
    let messageID: String
    let messageText: String
    let index: Int
    let isGenerating: Bool
    let canRetry: Bool
    let onCopy: () -> Void
    let onShare: () -> Void
    let onRetry: () -> Void
    let onRefine: (AssistantRefinement) -> Void

    var body: some View {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: 14) {
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
