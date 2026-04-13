import Observation
import SwiftUI

private struct SetupCopy {
    let badgeText: String
    let title: String
    let message: String
    let note: String?
    let actionTitle: String
    let actionSubtitle: String
}

private struct SetupStat: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct SetupBenefit: Identifiable {
    let title: String
    let systemImage: String

    var id: String { title }
}

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingHeader(
                        subtitle: headerSubtitle
                    )

                    SetupProgressCard(
                        badgeText: setupCopy.badgeText,
                        badgeSystemImage: setupState.systemImage,
                        badgeTint: statusBadgeForeground,
                        badgeBackground: statusBadgeBackground,
                        title: setupCopy.title,
                        message: setupCopy.message,
                        note: setupCopy.note,
                        errorMessage: setupState == .failed ? visibleErrorMessage : nil,
                        stats: stats
                    ) {
                        progressStatus
                    }

                    SetupBenefitsRow(items: setupBenefits)

                    if shouldShowPrimaryAction {
                        SetupPrimaryButton(
                            title: setupCopy.actionTitle,
                            subtitle: setupCopy.actionSubtitle,
                            isEnabled: actionEnabled,
                            action: handlePrimaryAction
                        )
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
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

    @ViewBuilder
    private var progressStatus: some View {
        switch setupState {
        case .simulator:
            SetupStatusRow(
                systemImage: "desktopcomputer",
                title: "Mock replies for UI testing",
                trailing: "Simulator"
            )
        case .intro:
            VStack(alignment: .leading, spacing: 10) {
                AnimatedProgressBar(progress: 0)

                SetupStatusRow(
                    systemImage: "iphone",
                    title: "Saved locally on this iPhone",
                    trailing: Self.formatBytes(modelDownloader.estimatedDownloadBytes)
                )
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(progressPercentLabel)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer(minLength: 0)

                    Text("Saving on this iPhone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                AnimatedProgressBar(progress: modelDownloader.downloadProgress)
            }
        case .preparing:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .tint(AppTheme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(llmService.modelLoadStage.statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Local setup is finishing now.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
        case .ready:
            SetupStatusRow(
                systemImage: "checkmark.circle.fill",
                title: "Stored on this iPhone",
                trailing: "Ready"
            )
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                AnimatedProgressBar(progress: modelDownloader.downloadProgress)

                SetupStatusRow(
                    systemImage: hasModelPreparationError ? "bolt.slash.fill" : "arrow.clockwise",
                    title: hasModelPreparationError
                        ? "Retry local preparation"
                        : (modelDownloader.canResumeDownload ? "Resume from saved progress" : "Start setup again"),
                    trailing: hasModelPreparationError ? "100%" : progressPercentLabel
                )
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
        if !supportsLocalModelRuntime {
            return "Use the simulator for UI testing. A real iPhone is required for on-device AI."
        }

        return "One-time setup downloads the model locally. After that, chats stay on this device and work offline."
    }

    private var setupCopy: SetupCopy {
        switch setupState {
        case .simulator:
            return SetupCopy(
                badgeText: "Simulator",
                title: "UI preview mode",
                message: "Use mocked replies here. Run Yemma on a physical iPhone for real on-device AI.",
                note: nil,
                actionTitle: "Continue in simulator",
                actionSubtitle: "Mock replies for UI testing"
            )
        case .intro:
            return SetupCopy(
                badgeText: "One-time setup",
                title: "Get Yemma ready",
                message: "First launch downloads the model to this iPhone. Setup only happens once.",
                note: nil,
                actionTitle: "Start setup",
                actionSubtitle: "Saved locally on this iPhone"
            )
        case .downloading:
            return SetupCopy(
                badgeText: progressPercentLabel,
                title: "Setting up Yemma",
                message: "Downloading the on-device model.",
                note: "Setup keeps running in the background. You can leave this screen and come back later.",
                actionTitle: "Resume setup",
                actionSubtitle: "Continue from saved progress"
            )
        case .preparing:
            return SetupCopy(
                badgeText: "Almost ready",
                title: "Almost ready",
                message: "Finalizing the model so chat opens faster.",
                note: "Yemma keeps finishing setup in the background after you open chat.",
                actionTitle: "Open chat",
                actionSubtitle: "Yemma keeps finishing setup in the background"
            )
        case .ready:
            return SetupCopy(
                badgeText: "Ready",
                title: "Yemma is ready",
                message: "The model is stored on this iPhone. Chats stay local.",
                note: nil,
                actionTitle: "Open chat",
                actionSubtitle: "Everything is ready on this iPhone"
            )
        case .failed:
            let message: String
            let note: String?
            let actionTitle: String
            let actionSubtitle: String

            if hasModelPreparationError {
                message = "The download finished, but local preparation paused. Retry to finish setup."
                note = "Your downloaded model is still on this iPhone."
                actionTitle = "Retry setup"
                actionSubtitle = "Finish local preparation"
            } else if modelDownloader.canResumeDownload {
                message = "Yemma kept your saved progress. Resume instead of starting over."
                note = "Valid files stay in place so setup can continue."
                actionTitle = "Resume setup"
                actionSubtitle = "Continue from saved progress"
            } else {
                message = "The download stopped before Yemma was ready. Start setup again to continue."
                note = nil
                actionTitle = "Try setup again"
                actionSubtitle = "Restart the one-time setup"
            }

            return SetupCopy(
                badgeText: "Setup paused",
                title: "Setup paused",
                message: message,
                note: note,
                actionTitle: actionTitle,
                actionSubtitle: actionSubtitle
            )
        }
    }

    private var statusBadgeForeground: Color {
        setupState == .failed ? AppTheme.destructive : AppTheme.accent
    }

    private var statusBadgeBackground: Color {
        setupState == .failed ? AppTheme.destructive.opacity(0.14) : AppTheme.accentSoft
    }

    private var stats: [SetupStat] {
        switch setupState {
        case .simulator:
            return [
                SetupStat(title: "Mode", value: "Simulator"),
                SetupStat(title: "Replies", value: "Mocked"),
                SetupStat(title: "Download", value: "Disabled"),
                SetupStat(title: "Device", value: "Real iPhone")
            ]
        case .intro:
            return [
                SetupStat(title: "Download size", value: Self.formatBytes(modelDownloader.estimatedDownloadBytes)),
                SetupStat(title: "Storage", value: "This iPhone"),
                SetupStat(title: "Privacy", value: "No cloud"),
                SetupStat(title: "After setup", value: "Offline chat")
            ]
        case .downloading:
            return [
                SetupStat(title: "Downloaded", value: Self.formatBytes(modelDownloader.downloadedBytes)),
                SetupStat(title: "Remaining", value: Self.formatBytes(modelDownloader.remainingDownloadBytes)),
                SetupStat(
                    title: "Time left",
                    value: modelDownloader.estimatedSecondsRemaining.map(Self.formatETA) ?? "Calculating"
                ),
                SetupStat(
                    title: "Speed",
                    value: modelDownloader.currentDownloadSpeedBytesPerSecond.map(Self.formatSpeed) ?? "Calculating"
                )
            ]
        case .preparing:
            return [
                SetupStat(title: "Download", value: "Complete"),
                SetupStat(title: "Current step", value: llmService.modelLoadStage.statusText),
                SetupStat(title: "Internet", value: "Not needed"),
                SetupStat(title: "Chat shell", value: "Ready now")
            ]
        case .ready:
            return [
                SetupStat(title: "Status", value: "Ready"),
                SetupStat(title: "Stored locally", value: Self.formatBytes(modelDownloader.estimatedDownloadBytes)),
                SetupStat(title: "Privacy", value: "On-device"),
                SetupStat(title: "Offline", value: "Available")
            ]
        case .failed:
            return [
                SetupStat(title: "Downloaded", value: Self.formatBytes(modelDownloader.downloadedBytes)),
                SetupStat(title: "Remaining", value: Self.formatBytes(modelDownloader.remainingDownloadBytes)),
                SetupStat(title: "Saved progress", value: modelDownloader.canResumeDownload ? "Yes" : "No"),
                SetupStat(
                    title: "Next step",
                    value: hasModelPreparationError
                        ? "Retry setup"
                        : (modelDownloader.canResumeDownload ? "Resume setup" : "Start again")
                )
            ]
        }
    }

    private var setupBenefits: [SetupBenefit] {
        if !supportsLocalModelRuntime {
            return [
                SetupBenefit(title: "UI testing", systemImage: "desktopcomputer"),
                SetupBenefit(title: "Mock replies", systemImage: "bubble.left.and.bubble.right"),
                SetupBenefit(title: "Real inference on iPhone", systemImage: "iphone")
            ]
        }

        return [
            SetupBenefit(title: "Runs locally", systemImage: "iphone"),
            SetupBenefit(title: "No cloud", systemImage: "icloud.slash"),
            SetupBenefit(title: "Works offline, even in airplane mode", systemImage: "airplane")
        ]
    }

    private var shouldShowPrimaryAction: Bool {
        switch setupState {
        case .simulator, .preparing, .ready:
            return onContinue != nil
        case .downloading:
            return !modelDownloader.isDownloading && !isStartingDownload && modelDownloader.canResumeDownload
        case .intro, .failed:
            return true
        }
    }

    private var actionEnabled: Bool {
        switch setupState {
        case .simulator, .preparing, .ready:
            return onContinue != nil
        case .downloading:
            return modelDownloader.canResumeDownload && !modelDownloader.isDownloading && !isStartingDownload
        case .intro, .failed:
            return true
        }
    }

    private var hasModelPreparationError: Bool {
        supportsLocalModelRuntime
            && modelDownloader.isDownloaded
            && !llmService.isTextModelReady
            && !llmService.isModelLoading
            && llmService.lastError != nil
    }

    private var visibleErrorMessage: String? {
        if hasModelPreparationError {
            return llmService.lastError
        }

        return modelDownloader.error
    }

    private var progressPercentLabel: String {
        "\(Int((modelDownloader.downloadProgress * 100).rounded()))%"
    }

    private func handlePrimaryAction() {
        AppDiagnostics.shared.record(
            "Onboarding primary action tapped",
            category: "ui",
            metadata: [
                "state": setupState.rawValue,
                "title": setupCopy.actionTitle
            ]
        )

        switch setupState {
        case .simulator, .preparing, .ready:
            onContinue?()
        case .failed where hasModelPreparationError:
            onRetryModelLoad?()
        case .intro, .downloading, .failed:
            Task { await startDownload() }
        }
    }

    @MainActor
    private func startDownload() async {
        guard !isStartingDownload else { return }
        guard supportsLocalModelRuntime else { return }
        guard !hasModelPreparationError else { return }
        guard !modelDownloader.isDownloading else { return }

        isStartingDownload = true
        defer { isStartingDownload = false }
        await modelDownloader.downloadModel()
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

private struct OnboardingHeader: View {
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Y4")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Yemma 4")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.textPrimary)
                    .accessibilityLabel("Yemma 4")
            }

            Text("Private AI chat on your iPhone")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupProgressCard<StatusContent: View>: View {
    let badgeText: String
    let badgeSystemImage: String
    let badgeTint: Color
    let badgeBackground: Color
    let title: String
    let message: String
    let note: String?
    let errorMessage: String?
    let stats: [SetupStat]
    let statusContent: StatusContent

    init(
        badgeText: String,
        badgeSystemImage: String,
        badgeTint: Color,
        badgeBackground: Color,
        title: String,
        message: String,
        note: String?,
        errorMessage: String?,
        stats: [SetupStat],
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        self.badgeText = badgeText
        self.badgeSystemImage = badgeSystemImage
        self.badgeTint = badgeTint
        self.badgeBackground = badgeBackground
        self.title = title
        self.message = message
        self.note = note
        self.errorMessage = errorMessage
        self.stats = stats
        self.statusContent = statusContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(badgeText, systemImage: badgeSystemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(badgeBackground)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusContent

            CompactStatsGrid(stats: stats)

            if let note {
                SetupInlineNote(text: note)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .groupedCard(cornerRadius: AppTheme.Radius.large)
    }
}

private struct CompactStatsGrid: View {
    let stats: [SetupStat]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    Text(stat.value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 46, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .inputChrome(cornerRadius: AppTheme.Radius.small)
            }
        }
    }
}

private struct SetupBenefitsRow: View {
    let items: [SetupBenefit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.count >= 2 {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(items.prefix(2))) { item in
                        benefitChip(item)
                    }
                }
            }

            if let supportingLine = items.dropFirst(2).first {
                benefitLine(supportingLine)
            }
        }
    }

    private func benefitChip(_ item: SetupBenefit) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
    }

    private func benefitLine(_ item: SetupBenefit) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }
}

private struct SetupPrimaryButton: View {
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.accentForeground)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.accentSecondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.accentForeground.opacity(0.88))
            }
            .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
            .padding(.vertical, 16)
            .background(AppTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct SetupStatusRow: View {
    let systemImage: String
    let title: String
    let trailing: String?

    var body: some View {
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
                    .lineLimit(1)
            }
        }
    }
}

private struct SetupInlineNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
