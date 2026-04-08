import Observation
import SwiftUI

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @State private var isStartingDownload = false

    private enum SetupState: String {
        case simulator
        case download
        case downloading
        case preparing
        case ready
        case failed

        var systemImage: String {
            switch self {
            case .simulator:
                return "desktopcomputer"
            case .download:
                return "arrow.down.circle"
            case .downloading:
                return "arrow.down.circle.fill"
            case .preparing:
                return "bolt.circle.fill"
            case .ready:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.triangle.fill"
            }
        }
    }

    private let supportsLocalModelRuntime: Bool
    private let onContinue: (() -> Void)?
    private let onRetryModelLoad: (() -> Void)?

    public init(
        supportsLocalModelRuntime: Bool = Yemma4AppConfiguration.supportsLocalModelRuntime,
        onContinue: (() -> Void)? = nil,
        onRetryModelLoad: (() -> Void)? = nil
    ) {
        self.supportsLocalModelRuntime = supportsLocalModelRuntime
        self.onContinue = onContinue
        self.onRetryModelLoad = onRetryModelLoad
    }

    public var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    setupCard
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Y4")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Yemma 4")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.textPrimary)
                    .accessibilityLabel("Yemma 4")
            }

            Text("Private chat, on your iPhone.")
                .font(AppTheme.Typography.brandHero)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Download once. Then run every chat on-device with no account and no prompts or personal data sent to a third-party AI service.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Private, on-device, no cloud AI, no account.", systemImage: "lock.fill")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            stateBadge

            Text(statusTitle)
                .font(AppTheme.Typography.brandSection)
                .foregroundStyle(AppTheme.textPrimary)

            Text(statusDescription)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            stateDetail

            primaryAction
        }
        .padding(20)
        .brandCard(cornerRadius: AppTheme.Radius.large)
    }

    private var stateBadge: some View {
        Label(statusBadgeText, systemImage: setupState.systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(stateBadgeForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(stateBadgeBackground)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch setupState {
        case .download:
            infoRow(
                systemImage: "iphone",
                title: "One-time model download to this iPhone",
                trailing: ByteCountFormatter.string(fromByteCount: modelDownloader.estimatedDownloadBytes, countStyle: .file)
            )
        case .downloading:
            VStack(alignment: .leading, spacing: 10) {
                AnimatedProgressBar(progress: modelDownloader.downloadProgress)

                HStack(alignment: .top, spacing: 12) {
                    Label("Downloading model files", systemImage: "arrow.down.circle")
                    Spacer()
                    if let eta = modelDownloader.estimatedSecondsRemaining {
                        Text(Self.formatETA(eta))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            }
        case .preparing:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .tint(AppTheme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(llmService.modelLoadStage.statusText)
                    Text("Usually a few seconds.")
                        .foregroundStyle(AppTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
        case .ready:
            infoRow(
                systemImage: "checkmark.circle.fill",
                title: "Saved on this iPhone",
                trailing: "Ready offline"
            )
        case .failed:
            if let error = visibleErrorMessage {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.destructive)
            }
        case .simulator:
            infoRow(
                systemImage: "desktopcomputer",
                title: "Mock replies for UI testing",
                trailing: "Simulator"
            )
        }
    }

    private func infoRow(systemImage: String, title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let onContinue {
            actionButton(
                title: supportsLocalModelRuntime ? "Open chat" : "Continue in simulator",
                subtitle: supportsLocalModelRuntime ? "Model is ready on this iPhone" : "Mock replies for UI testing",
                isEnabled: true,
                action: onContinue
            )
        } else if hasModelPreparationError, let onRetryModelLoad {
            actionButton(
                title: "Try again",
                subtitle: "Prepare the local model again",
                isEnabled: true,
                action: onRetryModelLoad
            )
        } else if isPreparingModel {
            actionButton(
                title: "Preparing model",
                subtitle: "This usually takes a few seconds",
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
        Button {
            AppDiagnostics.shared.record(
                "Onboarding primary action tapped",
                category: "ui",
                metadata: [
                    "state": setupState.rawValue,
                    "title": title
                ]
            )
            action()
        } label: {
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
            .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
            .padding(.vertical, 17)
            .background(AppTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var setupState: SetupState {
        if !supportsLocalModelRuntime {
            return .simulator
        }

        if hasModelPreparationError || modelDownloader.error != nil {
            return .failed
        }

        if modelDownloader.isDownloaded {
            return llmService.isTextModelReady ? .ready : .preparing
        }

        if modelDownloader.isDownloading || isStartingDownload {
            return .downloading
        }

        return .download
    }

    private var statusBadgeText: String {
        switch setupState {
        case .simulator:
            return "Simulator"
        case .download:
            return "Set Up"
        case .downloading:
            return "\(Int(modelDownloader.downloadProgress * 100))%"
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    private var stateBadgeForeground: Color {
        setupState == .failed ? AppTheme.destructive : AppTheme.accent
    }

    private var stateBadgeBackground: Color {
        setupState == .failed ? AppTheme.destructive.opacity(0.14) : AppTheme.accentSoft
    }

    private var downloadActionTitle: String {
        if modelDownloader.isDownloading || isStartingDownload {
            return "Downloading model"
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
        if modelDownloader.isDownloading || isStartingDownload {
            return "First-time setup in progress"
        }

        if modelDownloader.canResumeDownload {
            return "Continue setup on this iPhone"
        }

        if modelDownloader.error != nil {
            return "Start the one-time setup again"
        }

        return "One-time setup on this iPhone"
    }

    private var downloadActionEnabled: Bool {
        supportsLocalModelRuntime
            && !modelDownloader.isDownloading
            && !modelDownloader.isDownloaded
            && !isStartingDownload
    }

    private var statusTitle: String {
        switch setupState {
        case .simulator:
            return "Simulator mode"
        case .download:
            return "Download the local model"
        case .downloading:
            return "Downloading setup files"
        case .preparing:
            return "Preparing Yemma"
        case .ready:
            return "Ready to chat"
        case .failed:
            return "Setup needs attention"
        }
    }

    private var statusDescription: String {
        switch setupState {
        case .simulator:
            return "Use mock replies here. Run on a physical iPhone for real on-device inference."
        case .download:
            return "First launch downloads Gemma 4 once. After setup, prompts, images, and responses stay on this iPhone and are not sent to any third-party AI service."
        case .downloading:
            return "Yemma is downloading model files from Hugging Face and saving them locally on this iPhone."
        case .preparing:
            return "The files are here. Yemma is finishing local setup in the background."
        case .ready:
            return "Everything is local and ready whenever you open Yemma. Your chats stay on this iPhone unless you choose to share them yourself."
        case .failed:
            if hasModelPreparationError {
                return "The download finished, but local preparation did not."
            }
            return "The local model did not finish downloading."
        }
    }

    private var isModelDownloadedNotReady: Bool {
        supportsLocalModelRuntime && modelDownloader.isDownloaded && !llmService.isTextModelReady
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
private extension ModelDownloader {
    static func preview(
        isDownloading: Bool = false,
        isDownloaded: Bool = false,
        canResumeDownload: Bool = false,
        progress: Double = 0,
        estimatedSecondsRemaining: Double? = nil,
        error: String? = nil
    ) -> ModelDownloader {
        let downloader = ModelDownloader()
        downloader.isDownloading = isDownloading
        downloader.isDownloaded = isDownloaded
        downloader.canResumeDownload = canResumeDownload
        downloader.downloadProgress = progress
        downloader.estimatedSecondsRemaining = estimatedSecondsRemaining
        downloader.error = error

        if isDownloaded {
            downloader.modelPath = "/tmp/gemma-4-e2b-it-q4km.gguf"
            downloader.mmprojPath = "/tmp/gemma-4-e2b-it-mmproj-f16.gguf"
        }

        return downloader
    }
}

private extension LLMService {
    static func onboardingPreview(
        isModelLoaded: Bool = false,
        isModelLoading: Bool = false,
        stage: ModelLoadStage = .idle,
        lastError: String? = nil
    ) -> LLMService {
        let service = LLMService()
        service.isModelLoaded = isModelLoaded
        service.isModelLoading = isModelLoading
        service.modelLoadStage = stage
        service.lastError = lastError
        return service
    }
}

private struct OnboardingPreviewScreen: View {
    let supportsLocalModelRuntime: Bool
    let downloader: ModelDownloader
    let llmService: LLMService

    var body: some View {
        OnboardingView(
            supportsLocalModelRuntime: supportsLocalModelRuntime,
            onContinue: downloader.isDownloaded || !supportsLocalModelRuntime ? {} : nil,
            onRetryModelLoad: downloader.isDownloaded ? {} : nil
        )
        .environment(llmService)
        .environment(downloader)
    }
}

#Preview("Setup") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(),
        llmService: .onboardingPreview()
    )
}

#Preview("Downloading") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(
            isDownloading: true,
            progress: 0.42,
            estimatedSecondsRemaining: 840
        ),
        llmService: .onboardingPreview()
    )
}

#Preview("Preparing") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(isDownloaded: true),
        llmService: .onboardingPreview(
            isModelLoading: true,
            stage: .loadingModel
        )
    )
}

#Preview("Ready") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(isDownloaded: true),
        llmService: .onboardingPreview(
            isModelLoaded: true,
            stage: .ready
        )
    )
}

#Preview("Failed") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(isDownloaded: true),
        llmService: .onboardingPreview(
            stage: .failed,
            lastError: "The local runtime ran out of memory while preparing the model."
        )
    )
}

#Preview("Simulator") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: false,
        downloader: .preview(),
        llmService: .onboardingPreview()
    )
}

#Preview("Setup Dark Compact") {
    OnboardingPreviewScreen(
        supportsLocalModelRuntime: true,
        downloader: .preview(),
        llmService: .onboardingPreview()
    )
    .preferredColorScheme(.dark)
}
#endif
