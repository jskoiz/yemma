import Observation
import SwiftUI

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @State private var isStartingDownload = false

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    private let onContinue: (() -> Void)?
    private let onRetryModelLoad: (() -> Void)?
    private let setupFacts = [
        "100% on-device",
        "Wi-Fi recommended",
        "Works offline"
    ]

    public init(
        onContinue: (() -> Void)? = nil,
        onRetryModelLoad: (() -> Void)? = nil
    ) {
        self.onContinue = onContinue
        self.onRetryModelLoad = onRetryModelLoad
    }

    public var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    statusCard
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            AppDiagnostics.shared.record(
                "startup: view_appeared",
                category: "startup",
                metadata: ["view": "OnboardingView", "elapsedMs": StartupTiming.elapsedMs()]
            )
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 8, height: 8)

                Text("Available now on iPhone")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
                    .textCase(.uppercase)
            }

            HStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(AppTheme.accent)

                Image("BrandWordmark")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 28)
                    .foregroundStyle(AppTheme.textPrimary)
                    .accessibilityLabel("Yemma 4")
            }

            Text("No account. No cloud. Just chat.")
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Yemma runs Gemma 4 entirely on your iPhone. Download the model and vision projector once, then every conversation stays on-device.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits {
                HStack(spacing: 10) {
                    ForEach(setupFacts, id: \.self, content: factChip)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(setupFacts, id: \.self, content: factChip)
                }
            }

            if !supportsLocalModelRuntime {
                Text("You’re running in the iOS Simulator. Download is skipped here and chat uses mocked replies so you can test the UI. Use a physical iPhone for real on-device inference.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.controlBorder, lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.accent)
                .textCase(.uppercase)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(statusDescription)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()

                Text(progressString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if modelDownloader.isDownloading {
                AnimatedProgressBar(progress: modelDownloader.downloadProgress)

                HStack {
                    Text("Downloading model")
                    Spacer()
                    if let eta = modelDownloader.estimatedSecondsRemaining {
                        Text(Self.formatETA(eta))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            } else if isPreparingModel {
                ProgressView()
                    .tint(AppTheme.accent)

                HStack(alignment: .top) {
                    Text(llmService.modelLoadStage.statusText)
                    Spacer()
                    Text("Usually a few seconds")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            } else if let error = visibleErrorMessage {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
            primaryAction
        }
        .padding(20)
        .glassCard(cornerRadius: 24)
    }

    private func factChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppTheme.chipFill)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(AppTheme.controlBorder, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let onContinue {
            actionButton(
                title: supportsLocalModelRuntime ? "Open chat" : "Continue in simulator",
                subtitle: supportsLocalModelRuntime ? "The model is ready on this iPhone" : "Mock replies are enabled for UI testing",
                isEnabled: true,
                action: onContinue
            )
        } else if hasModelPreparationError, let onRetryModelLoad {
            actionButton(
                title: "Retry model load",
                subtitle: "Run the local setup again",
                isEnabled: true,
                action: onRetryModelLoad
            )
        } else if isPreparingModel {
            actionButton(
                title: "Preparing model...",
                subtitle: "Finishing first-time setup",
                isEnabled: false,
                action: {}
            )
        } else {
            actionButton(
                title: downloadActionTitle,
                subtitle: downloadActionSubtitle,
                isEnabled: downloadActionEnabled,
                action: {
                    Task { await startDownload() }
                }
            )
        }
    }

    private func actionButton(
        title: String,
        subtitle: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.accentForeground)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.accentSecondaryForeground)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.accentForeground.opacity(0.88))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .background(AppTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var progressString: String {
        if !supportsLocalModelRuntime {
            return "Sim"
        }

        if hasModelPreparationError {
            return "Retry"
        }

        if isPreparingModel {
            return "Prep"
        }

        if modelDownloader.isDownloaded {
            return "Ready"
        }

        return "\(Int(modelDownloader.downloadProgress * 100))%"
    }

    private var downloadActionTitle: String {
        if !supportsLocalModelRuntime {
            return "Unavailable in Simulator"
        }

        if isPreparingModel {
            return "Preparing model..."
        }

        if modelDownloader.isDownloading || isStartingDownload {
            return "Downloading..."
        }

        if modelDownloader.canResumeDownload {
            return "Resume download"
        }

        if modelDownloader.error != nil {
            return "Retry download"
        }

        return "Download model"
    }

    private var downloadActionSubtitle: String {
        if isPreparingModel {
            return "Finishing first-time setup"
        }

        if modelDownloader.canResumeDownload {
            return "Continue where it left off"
        }

        return "One-time setup, saved on this iPhone"
    }

    private var downloadActionEnabled: Bool {
        supportsLocalModelRuntime
            && !modelDownloader.isDownloading
            && !modelDownloader.isDownloaded
            && !isStartingDownload
    }

    private var statusTitle: String {
        if hasModelPreparationError {
            return "Preparation failed"
        }

        if isPreparingModel {
            return "Preparing model"
        }

        if modelDownloader.isDownloaded {
            return "Ready to chat"
        }

        if !supportsLocalModelRuntime {
            return "Simulator mode"
        }

        return "Download model"
    }

    private var statusDescription: String {
        if hasModelPreparationError {
            return "The model file is already downloaded, but the local runtime did not finish preparing."
        }

        if isPreparingModel {
            return "The file is already on this iPhone. Yemma is loading it now so chat opens ready instead of freezing."
        }

        if modelDownloader.isDownloaded {
            return "Setup is done. The model is local and ready whenever you open Yemma."
        }

        if !supportsLocalModelRuntime {
            return "Use the simulator to check the UI flow. Run on a physical iPhone for real on-device inference."
        }

        return "First launch downloads Gemma 4 and its vision projector once, then both stay on this iPhone."
    }

    private var isModelDownloadedNotReady: Bool {
        supportsLocalModelRuntime && modelDownloader.isDownloaded && !llmService.isModelLoaded
    }

    private var hasModelPreparationError: Bool {
        isModelDownloadedNotReady && !llmService.isModelLoading && llmService.lastError != nil
    }

    /// True when the model files are on disk and we're loading (or about to load) into memory.
    /// Covers the race window where isDownloaded just became true but isModelLoading
    /// hasn't flipped yet — in that case lastError is nil and no error state applies.
    private var isPreparingModel: Bool {
        isModelDownloadedNotReady && !hasModelPreparationError
    }

    private var visibleErrorMessage: String? {
        if hasModelPreparationError {
            return llmService.lastError
        }

        return modelDownloader.error
    }

    @MainActor
    private func startDownload() async {
        guard !isStartingDownload else { return }
        isStartingDownload = true
        defer { isStartingDownload = false }
        await modelDownloader.downloadModel()
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 {
            return "Less than a minute"
        } else if s < 3600 {
            let minutes = s / 60
            return "\(minutes) min remaining"
        } else {
            let hours = s / 3600
            let minutes = (s % 3600) / 60
            if minutes == 0 {
                return "\(hours)h remaining"
            }
            return "\(hours)h \(minutes)m remaining"
        }
    }
}

private struct AnimatedProgressBar: View {
    let progress: Double

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width
            let fillWidth = barWidth * min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.controlFill)

                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: fillWidth)
                    .overlay(
                        LinearGradient(
                            colors: [
                                .white.opacity(0),
                                .white.opacity(0.25),
                                .white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .offset(x: shimmerOffset * fillWidth)
                        .clipShape(Capsule())
                    )
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                shimmerOffset = 1
            }
        }
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView()
        .environment(LLMService())
        .environment(ModelDownloader())
}
#endif
