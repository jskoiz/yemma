import Observation
import SwiftUI

private struct SetupEducationCard: Identifiable {
    let id: String
    let eyebrow: String
    let title: String
    let body: String
    let bullets: [String]
    let systemImage: String

    static let defaults: [SetupEducationCard] = [
        SetupEducationCard(
            id: "setup",
            eyebrow: "Setup Flow",
            title: "Yemma downloads once, then opens straight into chat.",
            body: "The first launch saves the local model bundle on this iPhone so the app is ready when setup finishes.",
            bullets: [
                "Setup can continue in the background after you start it.",
                "If setup is interrupted, reopen Yemma and continue setup.",
                "When setup is done, chat is ready."
            ],
            systemImage: "square.and.arrow.down.fill"
        ),
        SetupEducationCard(
            id: "gemma",
            eyebrow: "What Gemma 4 Is",
            title: "Gemma 4 is the model behind Yemma.",
            body: "Think of it as the AI engine Yemma downloads once so it can answer questions on this device.",
            bullets: [
                "It powers writing, planning, and Q&A.",
                "The first setup is bigger because the model lives locally.",
                "You keep using the same downloaded bundle after setup."
            ],
            systemImage: "sparkles.rectangle.stack.fill"
        ),
        SetupEducationCard(
            id: "after_setup",
            eyebrow: "After Setup",
            title: "Once setup finishes, the app gets out of the way.",
            body: "Yemma keeps setup separate so the main experience stays focused on the conversation.",
            bullets: [
                "Open chat and continue naturally.",
                "Saved chats remain easy to revisit later.",
                "The app stays ready whenever you come back."
            ],
            systemImage: "chat.bubble.text.fill"
        )
    ]
}

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @State private var selectedCardID = SetupEducationCard.defaults.first?.id
    @State private var isStartingDownload = false
    @State private var didRecordInteractiveReady = false
    @State private var didRecordFirstTouch = false

    private enum SetupState: String {
        case simulator
        case intro
        case downloading
        case preparing
        case ready
        case failed

        var systemImage: String {
            switch self {
            case .simulator:
                return "desktopcomputer"
            case .intro:
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
            AppBackground(atmosphere: .none)

            if usesCompactIntroShell {
                compactIntroShell
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        progressModule
                        if shouldShowEducationSection {
                            educationGuideSection
                        }
                        actionSection
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            AppDiagnostics.shared.record(
                "startup: view_appeared",
                category: "startup",
                metadata: ["view": "OnboardingView", "elapsedMs": StartupTiming.elapsedMs()]
            )
            Task { @MainActor in
                await Task.yield()
                if !didRecordInteractiveReady {
                    didRecordInteractiveReady = true
                    AppDiagnostics.shared.record(
                        "startup: onboarding_interactive_ready",
                        category: "startup",
                        metadata: ["elapsedMs": StartupTiming.elapsedMs()]
                    )
                }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    recordFirstTouchIfNeeded()
                }
        )
    }

    private var compactIntroShell: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 14) {
                Label("One-Time Setup", systemImage: SetupState.intro.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusBadgeForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(statusBadgeBackground)
                    .clipShape(Capsule())

                Text("Set up Yemma once")
                    .font(AppTheme.Typography.brandSection)
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Download the Gemma 4 MLX bundle once, then start chatting.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Download size: \(Self.formatBytes(modelDownloader.estimatedDownloadBytes))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            primaryAction

            if !actionFootnote.isEmpty {
                Text(actionFootnote)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

            Text("Finish setup once, then start chatting.")
                .font(AppTheme.Typography.brandHero)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    private var progressModule: some View {
        progressModuleBody
            .padding(20)
            .groupedCard(cornerRadius: AppTheme.Radius.large)
    }

    private var progressModuleBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(statusBadgeText, systemImage: setupState.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusBadgeForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(statusBadgeBackground)
                .clipShape(Capsule())

            Text(statusTitle)
                .font(AppTheme.Typography.brandSection)
                .foregroundStyle(AppTheme.textPrimary)

            Text(statusDescription)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            progressHero

            if shouldShowProgressStats {
                statsGrid
            }

            if let error = visibleErrorMessage, setupState == .failed {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var progressHero: some View {
        switch setupState {
        case .simulator:
            infoRow(systemImage: "desktopcomputer", title: "Mock replies for UI testing", trailing: "Simulator")
        case .intro:
            VStack(alignment: .leading, spacing: 10) {
                AnimatedProgressBar(progress: 0)
                Text("Yemma downloads the local model bundle once, then keeps it on this iPhone for offline chat.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 12) {
                AnimatedProgressBar(progress: modelDownloader.downloadProgress)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Saving the model bundle on this iPhone")
                    Spacer(minLength: 0)

                    Text(progressPercentLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
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
                    Text("The download is complete. Yemma is activating the model locally.")
                        .foregroundStyle(AppTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
        case .ready:
            infoRow(systemImage: "checkmark.circle.fill", title: "Ready to chat", trailing: "Setup complete")
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                AnimatedProgressBar(progress: modelDownloader.downloadProgress)
                Text(
                    hasModelPreparationError
                        ? "The download finished, but local preparation did not."
                        : "Setup paused before Yemma became ready."
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(stats, id: \.title) { stat in
                VStack(alignment: .leading, spacing: 4) {
                    Text(stat.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.3)

                    Text(stat.value)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 72, alignment: .topLeading)
                .padding(14)
                .inputChrome(cornerRadius: AppTheme.Radius.small)
            }
        }
    }

    private var educationGuideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("While setup finishes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        cycleEducationCard(step: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AppTheme.controlFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(previousEducationCardID == nil)
                    .opacity(previousEducationCardID == nil ? 0.45 : 1)

                    Text(educationGuideProgressLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)

                    Button {
                        cycleEducationCard(step: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AppTheme.controlFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(nextEducationCardID == nil)
                    .opacity(nextEducationCardID == nil ? 0.45 : 1)
                }
            }

            SetupEducationCardView(card: selectedEducationCard)
                .id(selectedEducationCard.id)
                .padding(.top, 8)
                .frame(height: 372)
                .clipped()

            HStack(spacing: 8) {
                ForEach(SetupEducationCard.defaults) { card in
                    Capsule()
                        .fill(card.id == selectedCardID ? AppTheme.accent : AppTheme.accentSoft)
                        .frame(width: card.id == selectedCardID ? 22 : 8, height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.2), value: selectedCardID)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if setupState == .downloading && (modelDownloader.isDownloading || !modelDownloader.canResumeDownload) {
                downloadStatusCallout
            } else {
                primaryAction
            }

            if setupState != .ready, supportsLocalModelRuntime, !actionFootnote.isEmpty {
                Text(actionFootnote)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var downloadStatusCallout: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.accentSoft)
                    .frame(width: 36, height: 36)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Setup continues in the background")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("You can come back to Yemma anytime to check progress.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(progressPercentLabel)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 16)
        .groupedCard(cornerRadius: AppTheme.Radius.medium)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let onContinue, setupState == .ready || setupState == .preparing || !supportsLocalModelRuntime {
            actionButton(
                title: supportsLocalModelRuntime ? "Open chat" : "Continue in simulator",
                subtitle: continueActionSubtitle,
                isEnabled: true,
                action: onContinue
            )
        } else if hasModelPreparationError, let onRetryModelLoad {
            actionButton(
                title: "Retry setup",
                subtitle: "Prepare the local model again",
                isEnabled: true,
                action: onRetryModelLoad
            )
        } else {
            actionButton(
                title: actionTitle,
                subtitle: actionSubtitle,
                isEnabled: actionEnabled,
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

        if modelDownloader.isDownloading || isStartingDownload || modelDownloader.canResumeDownload {
            return .downloading
        }

        return .intro
    }

    private var headerSubtitle: String {
        switch setupState {
        case .simulator:
            return "Use the simulator for UI testing. A real device is required for on-device AI."
        case .intro:
            return "Yemma needs a one-time download before chat is ready."
        case .downloading:
            return "Download in progress. You can stay here or come back later."
        case .preparing:
            return "The model bundle is here. Yemma is finishing local setup on this iPhone."
        case .ready:
            return "Everything is ready whenever you open Yemma."
        case .failed:
            return "Setup needs attention before Yemma can open chat."
        }
    }

    private var statusBadgeText: String {
        switch setupState {
        case .simulator:
            return "Simulator"
        case .intro:
            return "One-Time Setup"
        case .downloading:
            return progressPercentLabel
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs Attention"
        }
    }

    private var statusBadgeForeground: Color {
        setupState == .failed ? AppTheme.destructive : AppTheme.accent
    }

    private var statusBadgeBackground: Color {
        setupState == .failed ? AppTheme.destructive.opacity(0.14) : AppTheme.accentSoft
    }

    private var progressPercentLabel: String {
        "\(Int((modelDownloader.downloadProgress * 100).rounded()))%"
    }

    private var statusTitle: String {
        switch setupState {
        case .simulator:
            return "Simulator mode"
        case .intro:
            return "Set up Yemma once"
        case .downloading:
            return "Model download"
        case .preparing:
            return "Preparing Yemma"
        case .ready:
            return "Ready to chat"
        case .failed:
            return "Setup paused"
        }
    }

    private var statusDescription: String {
        switch setupState {
        case .simulator:
            return "Use mock replies here. Run on a physical iPhone for real on-device inference."
        case .intro:
            return "First launch downloads Gemma 4 once. After setup, chat is ready whenever you return."
        case .downloading:
            return "Downloading the Gemma 4 bundle and saving it locally on this iPhone."
        case .preparing:
            return "The download is complete. Yemma is loading the MLX model into memory and finishing local activation."
        case .ready:
            return "Everything is ready whenever you open Yemma."
        case .failed:
            return hasModelPreparationError
                ? "The download finished, but local preparation did not."
                : "The download did not finish successfully."
        }
    }

    private var stats: [(title: String, value: String)] {
        switch setupState {
        case .simulator:
            return [
                ("Mode", "Simulator"),
                ("Replies", "Mocked"),
                ("Download", "Disabled"),
                ("Use case", "UI testing")
            ]
        case .intro:
            return [
                ("Download", Self.formatBytes(modelDownloader.estimatedDownloadBytes)),
                ("After setup", "Ready to chat"),
                ("Flow", "One-time setup"),
                ("Use case", "Conversation")
            ]
        case .downloading:
            return [
                ("Downloaded", Self.formatBytes(max(modelDownloader.downloadedBytes, 1))),
                ("Remaining", Self.formatBytes(modelDownloader.remainingDownloadBytes)),
                ("Time left", modelDownloader.estimatedSecondsRemaining.map(Self.formatETA) ?? "Calculating"),
                ("Speed", modelDownloader.currentDownloadSpeedBytesPerSecond.map(Self.formatSpeed) ?? "Calculating")
            ]
        case .preparing:
            return [
                ("Download", "Complete"),
                ("Current step", llmService.modelLoadStage.statusText),
                ("Storage", Self.formatBytes(modelDownloader.estimatedDownloadBytes)),
                ("Internet", "No longer needed")
            ]
        case .ready:
            return [
                ("Status", "Ready"),
                ("Stored locally", Self.formatBytes(modelDownloader.estimatedDownloadBytes)),
                ("State", "Local setup"),
                ("Offline", "Available")
            ]
        case .failed:
            return [
                ("Downloaded", Self.formatBytes(modelDownloader.downloadedBytes)),
                ("Remaining", Self.formatBytes(modelDownloader.remainingDownloadBytes)),
                ("Saved progress", modelDownloader.canResumeDownload ? "Yes" : "No"),
                ("Next step", hasModelPreparationError ? "Retry setup" : "Resume download")
            ]
        }
    }

    private var actionTitle: String {
        switch setupState {
        case .simulator:
            return "Continue in simulator"
        case .intro:
            return "Start setup"
        case .downloading:
            return modelDownloader.canResumeDownload && !modelDownloader.isDownloading ? "Resume setup" : "Setup in progress"
        case .preparing:
            return "Finishing setup"
        case .ready:
            return "Open chat"
        case .failed:
            return hasModelPreparationError ? "Retry setup" : (modelDownloader.canResumeDownload ? "Resume setup" : "Try setup again")
        }
    }

    private var actionSubtitle: String {
        switch setupState {
        case .simulator:
            return "Mock replies for UI testing"
        case .intro:
            return "Download Gemma 4 once to begin"
        case .downloading:
            return modelDownloader.canResumeDownload && !modelDownloader.isDownloading
                ? "Continue the one-time download"
                : "Yemma is downloading in the background"
        case .preparing:
            return "This usually takes a few seconds"
        case .ready:
            return "Everything is ready"
        case .failed:
            return hasModelPreparationError
                ? "Prepare the local model again"
                : "Resume the one-time setup"
        }
    }

    private var actionEnabled: Bool {
        switch setupState {
        case .simulator:
            return onContinue != nil
        case .intro:
            return true
        case .downloading:
            return modelDownloader.canResumeDownload && !modelDownloader.isDownloading
        case .preparing:
            return false
        case .ready:
            return onContinue != nil
        case .failed:
            return true
        }
    }

    private var actionFootnote: String {
        switch setupState {
        case .simulator:
            return ""
        case .intro:
            return "The first run is larger because the model is stored locally on your iPhone."
        case .downloading:
            return "You can leave and come back later. If setup pauses, Yemma will resume from the saved files."
        case .preparing:
            return "You can open chat while Yemma finishes loading the model locally."
        case .ready:
            return ""
        case .failed:
            return "Yemma will keep any valid downloaded files so setup can continue instead of starting over."
        }
    }

    private var hasModelPreparationError: Bool {
        supportsLocalModelRuntime
            && modelDownloader.isDownloaded
            && !llmService.isTextModelReady
            && !llmService.isModelLoading
            && llmService.lastError != nil
    }

    private var shouldShowEducationSection: Bool {
        setupState != .intro
    }

    private var shouldShowProgressStats: Bool {
        setupState != .intro
    }

    private var usesCompactIntroShell: Bool {
        setupState == .intro
    }

    private var continueActionSubtitle: String {
        if !supportsLocalModelRuntime {
            return "Mock replies for UI testing"
        }

        if setupState == .preparing {
            return "Open chat while the model finishes loading"
        }

        return "Yemma is ready on this iPhone"
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

        if !supportsLocalModelRuntime {
            onContinue?()
            return
        }

        if hasModelPreparationError {
            onRetryModelLoad?()
            return
        }

        guard !modelDownloader.isDownloading else { return }
        isStartingDownload = true
        defer { isStartingDownload = false }
        await modelDownloader.downloadModel()
    }

    private var selectedEducationCard: SetupEducationCard {
        if let selectedCardID,
            let card = SetupEducationCard.defaults.first(where: { $0.id == selectedCardID })
        {
            return card
        }

        return SetupEducationCard.defaults[0]
    }

    private var selectedEducationCardIndex: Int {
        SetupEducationCard.defaults.firstIndex(where: { $0.id == selectedEducationCard.id }) ?? 0
    }

    private var previousEducationCardID: String? {
        let previousIndex = selectedEducationCardIndex - 1
        guard SetupEducationCard.defaults.indices.contains(previousIndex) else { return nil }
        return SetupEducationCard.defaults[previousIndex].id
    }

    private var nextEducationCardID: String? {
        let nextIndex = selectedEducationCardIndex + 1
        guard SetupEducationCard.defaults.indices.contains(nextIndex) else { return nil }
        return SetupEducationCard.defaults[nextIndex].id
    }

    private var educationGuideProgressLabel: String {
        "\(selectedEducationCardIndex + 1)/\(SetupEducationCard.defaults.count)"
    }

    private func cycleEducationCard(step: Int) {
        let nextIndex = selectedEducationCardIndex + step
        guard SetupEducationCard.defaults.indices.contains(nextIndex) else { return }
        selectedCardID = SetupEducationCard.defaults[nextIndex].id
    }

    private func recordFirstTouchIfNeeded() {
        guard !didRecordFirstTouch else { return }
        didRecordFirstTouch = true
        AppDiagnostics.shared.record(
            "startup: onboarding_first_touch_received",
            category: "startup",
            metadata: ["elapsedMs": StartupTiming.elapsedMs()]
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 {
            return "< 1 min"
        } else if s < 3600 {
            let minutes = s / 60
            return "\(minutes) min"
        } else {
            let hours = s / 3600
            let minutes = (s % 3600) / 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }
    }
}

private struct SetupEducationCardView: View {
    let card: SetupEducationCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(card.eyebrow, systemImage: card.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.accentSoft)
                    .clipShape(Capsule())

                Spacer()
            }

            Text(card.title)
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(card.body)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(card.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.top, 1)

                        Text(bullet)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .groupedCard(cornerRadius: AppTheme.Radius.large)
    }
}

private struct AnimatedProgressBar: View {
    let progress: Double

    @State private var shimmerOffset: CGFloat = -1

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var shouldAnimateShimmer: Bool {
        clampedProgress > 0 && clampedProgress < 1
    }

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width
            let fillWidth = barWidth * clampedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.controlFill)

                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: fillWidth)
                    .overlay(
                        Group {
                            if shouldAnimateShimmer {
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0),
                                        .white.opacity(0.25),
                                        .white.opacity(0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .offset(x: shimmerOffset * max(fillWidth, 1))
                                .clipShape(Capsule())
                            }
                        }
                    )
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((clampedProgress * 100).rounded())) percent")
        .onAppear {
            guard shouldAnimateShimmer else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                shimmerOffset = 1
            }
        }
        .onChange(of: shouldAnimateShimmer) { _, shouldAnimate in
            guard shouldAnimate else {
                shimmerOffset = -1
                return
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                shimmerOffset = 1
            }
        }
    }
}
