import SwiftUI

enum ChatStarterBehavior: Hashable {
    case promptOnly
    case promptAndPickImage
}

struct ChatStarter: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let prompt: String
    let systemImage: String
    var behavior: ChatStarterBehavior = .promptOnly
    var sendsImmediately = false

    var id: String { title }

    static let defaults: [ChatStarter] = [
        ChatStarter(
            title: "Describe a photo",
            subtitle: "Upload an image and break down what stands out",
            prompt: "Describe this image clearly. Summarize what is happening, point out the key details, and mention anything easy to miss at a glance.",
            systemImage: "photo.on.rectangle.angled",
            behavior: .promptAndPickImage
        ),
        ChatStarter(
            title: "Teach me something",
            subtitle: "Share a short history or science fact I probably do not know",
            prompt: "Teach me one short surprising fact from history or science that most people do not know. Keep it clear and under three short paragraphs.",
            systemImage: "sparkles",
            sendsImmediately: true
        ),
        ChatStarter(
            title: "Tell me a random fact",
            subtitle: "Give me one interesting fact with a quick explanation",
            prompt: "Tell me one interesting random fact and explain why it is surprising in a few sentences. Keep it concise.",
            systemImage: "lightbulb",
            sendsImmediately: true
        )
    ]
}

struct EmptyStateView: View {
    let isModelLoaded: Bool
    let isModelLoading: Bool
    let supportsLocalModelRuntime: Bool
    let modelLoadStageText: String
    var statusDetailText: String?
    var statusProgress: Double?
    var statusIsFailure: Bool = false
    var primarySetupActionTitle: String?
    var onPrimarySetupAction: (() -> Void)?
    var starters: [ChatStarter] = []
    var onSelectStarter: (ChatStarter) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 48)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Start with a task")
                        .font(AppTheme.Typography.brandSection)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Pick a starting point, or ask in your own words below.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                if !isModelLoaded {
                    statusBanner
                }

                if !starters.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(starters.enumerated()), id: \.element.id) { index, starter in
                            starterButton(starter)

                            if index != starters.count - 1 {
                                Divider()
                                    .overlay(AppTheme.separator)
                                    .padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                            .fill(AppTheme.controlFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                            .stroke(AppTheme.controlBorder, lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.horizontal, 20)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var statusBanner: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(statusIconBackground)
                            .frame(width: 34, height: 34)

                        Image(systemName: statusSystemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(statusAccentColor)
                    }
                    .frame(width: 34)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(statusText)
                            .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                            .foregroundStyle(statusTitleColor)
                            .fixedSize(horizontal: false, vertical: true)

                        if let statusDetailText {
                            Text(statusDetailText)
                                .font(AppTheme.Typography.utilityCaption)
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)

                    if let statusProgressLabel {
                        Text(statusProgressLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusAccentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusIconBackground)
                            .clipShape(Capsule())
                    }
                }

                if let statusProgress {
                    ProgressView(value: min(max(statusProgress, 0), 1))
                        .tint(statusAccentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            if let primarySetupActionTitle, let onPrimarySetupAction {
                Divider()
                    .overlay(AppTheme.separator)
                    .padding(.leading, 62)

                Button(action: onPrimarySetupAction) {
                    HStack(spacing: 12) {
                        Image(systemName: primarySetupActionSystemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(statusAccentColor)
                            .frame(width: 26)

                        Text(primarySetupActionTitle)
                            .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        Spacer()

                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .fill(AppTheme.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(AppTheme.controlBorder, lineWidth: 1)
        )
    }

    private func starterButton(_ starter: ChatStarter) -> some View {
        Button {
            onSelectStarter(starter)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: starter.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(starter.title)
                            .font(AppTheme.Typography.utilityRowTitle)
                            .foregroundStyle(AppTheme.textPrimary)

                        if starter.behavior == .promptAndPickImage {
                            Text("Photo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.accentSoft)
                                .clipShape(Capsule())
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Text(starter.subtitle)
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode with mock replies."
        }

        return modelLoadStageText
    }

    private var statusSystemImage: String {
        if !supportsLocalModelRuntime {
            return "desktopcomputer"
        }

        return statusIsFailure ? "exclamationmark.triangle.fill" : "bolt.circle.fill"
    }

    private var statusAccentColor: Color {
        if !supportsLocalModelRuntime {
            return AppTheme.textSecondary
        }

        return statusIsFailure ? AppTheme.destructive : AppTheme.accent
    }

    private var statusTitleColor: Color {
        statusIsFailure ? AppTheme.destructive : AppTheme.textPrimary
    }

    private var statusIconBackground: Color {
        if !supportsLocalModelRuntime {
            return AppTheme.chipFill
        }

        return statusIsFailure ? AppTheme.destructive.opacity(0.12) : AppTheme.accentSoft
    }

    private var statusProgressLabel: String? {
        guard let statusProgress else { return nil }
        return "\(Int(min(max(statusProgress, 0), 1) * 100))%"
    }

    private var primarySetupActionSystemImage: String {
        guard let title = primarySetupActionTitle?.lowercased() else {
            return "arrow.right.circle.fill"
        }

        if title.contains("resume") || title.contains("download") {
            return "arrow.down.circle.fill"
        }

        if title.contains("retry") {
            return "arrow.clockwise.circle.fill"
        }

        if title.contains("load") {
            return "bolt.circle.fill"
        }

        return "arrow.right.circle.fill"
    }
}

#if DEBUG
#Preview("Warm Shell") {
    ZStack {
        AppBackground()
        EmptyStateView(
            isModelLoaded: false,
            isModelLoading: true,
            supportsLocalModelRuntime: true,
            modelLoadStageText: ModelLoadStage.loadingModel.statusText,
            statusDetailText: "Finishing the local engine setup.",
            starters: ChatStarter.defaults
        )
        .padding(.horizontal, 16)
    }
}

#Preview("Ready") {
    ZStack {
        AppBackground()
        EmptyStateView(
            isModelLoaded: true,
            isModelLoading: false,
            supportsLocalModelRuntime: true,
            modelLoadStageText: ModelLoadStage.ready.statusText,
            starters: ChatStarter.defaults
        )
        .padding(.horizontal, 16)
    }
}

#Preview("Simulator") {
    ZStack {
        AppBackground()
        EmptyStateView(
            isModelLoaded: false,
            isModelLoading: false,
            supportsLocalModelRuntime: false,
            modelLoadStageText: ModelLoadStage.idle.statusText,
            starters: ChatStarter.defaults
        )
        .padding(.horizontal, 16)
    }
}

#Preview("Warm Shell Dark Compact") {
    ZStack {
        AppBackground()
        EmptyStateView(
            isModelLoaded: false,
            isModelLoading: true,
            supportsLocalModelRuntime: true,
            modelLoadStageText: ModelLoadStage.loadingModel.statusText,
            statusDetailText: "Finishing the local engine setup.",
            starters: ChatStarter.defaults
        )
        .padding(.horizontal, 16)
    }
    .preferredColorScheme(.dark)
}
#endif
