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
            title: "Draft a polished reply",
            subtitle: "Turn a quick thought into a sendable message",
            prompt: "Draft a polite reply saying I can meet Thursday afternoon instead of Wednesday morning.",
            systemImage: "envelope.open"
        ),
        ChatStarter(
            title: "Make a clear plan",
            subtitle: "Organize a goal into practical next steps",
            prompt: "Help me turn a vague goal into a simple step-by-step plan with a short checklist.",
            systemImage: "list.clipboard"
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
                    VStack(spacing: 10) {
                        ForEach(starters) { starter in
                            starterButton(starter)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .brandCard(cornerRadius: AppTheme.Radius.large)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 14, weight: .semibold))

                Text(statusText)
                    .font(AppTheme.Typography.utilityCaption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let statusDetailText {
                Text(statusDetailText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let statusProgress {
                ProgressView(value: min(max(statusProgress, 0), 1))
                    .tint(statusTextColor)
            }

            if let primarySetupActionTitle, let onPrimarySetupAction {
                Button(primarySetupActionTitle, action: onPrimarySetupAction)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accentForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.accent)
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(statusTextColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(statusBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
    }

    private func starterButton(_ starter: ChatStarter) -> some View {
        Button {
            onSelectStarter(starter)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: starter.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(starter.title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)

                    HStack(spacing: 8) {
                        Text(starter.subtitle)
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.textSecondary)

                        if starter.behavior == .promptAndPickImage {
                            Text("Photo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.accentSoft)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .inputChrome(cornerRadius: AppTheme.Radius.small)
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

    private var statusTextColor: Color {
        if !supportsLocalModelRuntime {
            return AppTheme.textPrimary
        }

        return statusIsFailure ? AppTheme.destructive : AppTheme.accent
    }

    private var statusBackground: Color {
        if !supportsLocalModelRuntime {
            return AppTheme.controlFill
        }

        return statusIsFailure ? AppTheme.destructive.opacity(0.12) : AppTheme.accentSoft
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
