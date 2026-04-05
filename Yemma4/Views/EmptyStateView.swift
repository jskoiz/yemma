import SwiftUI

struct ChatStarter: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let prompt: String
    let systemImage: String

    var id: String { title }

    static let defaults: [ChatStarter] = [
        ChatStarter(
            title: "Plan a 3-day workout",
            subtitle: "Beginner routine at home",
            prompt: "Plan a beginner-friendly 3-day workout split I can do at home in 30 minutes per session.",
            systemImage: "figure.strengthtraining.traditional"
        ),
        ChatStarter(
            title: "Draft a polite reply",
            subtitle: "Reschedule a meeting",
            prompt: "Draft a polite reply saying I can meet Thursday afternoon instead of Wednesday morning.",
            systemImage: "envelope.open"
        ),
        ChatStarter(
            title: "Explain a topic simply",
            subtitle: "Use one short example",
            prompt: "Explain how compound interest works in simple terms with one short example.",
            systemImage: "text.book.closed"
        )
    ]
}

struct EmptyStateView: View {
    let isModelLoaded: Bool
    let isModelLoading: Bool
    let supportsLocalModelRuntime: Bool
    let modelLoadStageText: String
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

                    Text("Private, on-device, no account.")
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
        HStack(spacing: 10) {
            Image(systemName: supportsLocalModelRuntime ? "bolt.circle.fill" : "desktopcomputer")
                .font(.system(size: 14, weight: .semibold))

            Text(statusText)
                .font(AppTheme.Typography.utilityCaption)
                .fixedSize(horizontal: false, vertical: true)
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(starter.subtitle)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
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

        if isModelLoading {
            return modelLoadStageText
        }

        return "Preparing your on-device model."
    }

    private var statusTextColor: Color {
        supportsLocalModelRuntime ? AppTheme.accent : AppTheme.textPrimary
    }

    private var statusBackground: Color {
        supportsLocalModelRuntime ? AppTheme.accentSoft : AppTheme.controlFill
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
            starters: ChatStarter.defaults
        )
        .padding(.horizontal, 16)
    }
    .preferredColorScheme(.dark)
    .previewDevice("iPhone SE (3rd generation)")
}
#endif
