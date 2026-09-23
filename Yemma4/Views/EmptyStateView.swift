import SwiftUI

enum ChatStarterBehavior: Hashable {
    case promptOnly
    case guided(GuidedTask)
    case promptAndPickImage
}

struct ChatStarter: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let prompt: String
    let systemImage: String
    var promptVariants: [String] = []
    var behavior: ChatStarterBehavior = .promptOnly
    var sendsImmediately = false

    var id: String { title }
    var prompts: [String] { [prompt] + promptVariants }

    static let defaults: [ChatStarter] = [
        ChatStarter(title: "Rewrite", subtitle: "Find the right words and tone", prompt: "", systemImage: "pencil.line", behavior: .guided(.rewrite)),
        ChatStarter(title: "Summarize", subtitle: "Pull out the useful parts of your text", prompt: "", systemImage: "text.alignleft", behavior: .guided(.summarize)),
        ChatStarter(title: "Ask", subtitle: "Bring a question or think something through", prompt: "", systemImage: "questionmark.bubble", behavior: .guided(.ask))
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
    var resumeTitle: String?
    var onResume: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 48)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start with a task")
                        .font(AppTheme.Typography.brandSection)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("A little help with your words, ideas, and questions. All on this iPhone.")
                        .font(AppTheme.Typography.utilityRowDetail)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                if shouldShowStatusBanner {
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
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                            .fill(AppTheme.controlFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                            .stroke(AppTheme.controlBorder, lineWidth: 1)
                    )
                }
                if let resumeTitle, let onResume {
                    Button(action: onResume) {
                        Label("Continue: \(resumeTitle)", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                            .lineLimit(2)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityHint("Opens your most recent saved conversation.")
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
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusAccentColor)
                    .frame(width: 26)

                Text(statusText)
                    .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                    .foregroundStyle(statusTitleColor)
                    .fixedSize(horizontal: false, vertical: true)

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
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, statusDetailText == nil && statusProgress == nil ? 16 : 12)

            if statusDetailText != nil || statusProgress != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let statusDetailText {
                        Text(statusDetailText)
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 38)
                    }

                    if let statusProgress {
                        ProgressView(value: min(max(statusProgress, 0), 1))
                            .tint(statusAccentColor)
                            .padding(.leading, 38)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            if let primarySetupActionTitle, let onPrimarySetupAction {
                Divider()
                    .overlay(AppTheme.separator)
                    .padding(.leading, 52)

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
            HStack(spacing: 10) {
                Image(systemName: starter.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    starterTitle(for: starter)

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
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func starterTitle(for starter: ChatStarter) -> some View {
        if starter.behavior == .promptAndPickImage {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    starterTitleLabel(starter.title)
                    photoBadge
                }

                VStack(alignment: .leading, spacing: 4) {
                    starterTitleLabel(starter.title)
                    photoBadge
                }
            }
        } else {
            starterTitleLabel(starter.title)
        }
    }

    private func starterTitleLabel(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var photoBadge: some View {
        Text("Photo")
            .font(.caption2.weight(.semibold))
            .fixedSize()
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.accentSoft)
            .clipShape(Capsule())
    }

    private var shouldShowStatusBanner: Bool {
        guard !isModelLoaded else { return false }

        if !supportsLocalModelRuntime {
            return true
        }

        if statusIsFailure || statusProgress != nil || primarySetupActionTitle != nil {
            return true
        }

        return !isModelLoading && statusDetailText != nil
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
