import SwiftUI

struct DebugModelVariantsView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(AppDiagnostics.self) private var diagnostics
    @Environment(\.dismiss) private var dismiss

    @State private var showCustomModelSheet = false
    @State private var customModelInput = ""
    @State private var isSwitchingModelSource = false
    @State private var modelSourceError: String?
    @State private var pendingModelSourceSwitch: Gemma4ModelSource?

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime

    private struct StatusMetric: Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    private struct ModelStatusAction {
        let title: String
        let detail: String
        let icon: String
        let role: ButtonRole?
        let action: @MainActor () async -> Void
    }

    private var appSetup: AppSetupSnapshot {
        AppSetupSnapshot(
            supportsLocalModelRuntime: supportsLocalModelRuntime,
            modelDownloader: modelDownloader,
            llmService: llmService
        )
    }

    private var activeSourceBoundaryLabel: String {
        modelDownloader.activeModelSourceBoundaryLabel
    }

    private var activeSourceCardTitle: String {
        if modelDownloader.isUsingDefaultModelSource {
            return "App default model"
        }

        return "Custom Hugging Face model"
    }

    private var activeSourceCardSystemImage: String {
        modelDownloader.activeModelSource.isCustom ? "link" : "shippingbox"
    }

    private var downloadActionTitle: String {
        "Download model"
    }

    private var downloadActionDetail: String {
        "Start downloading the current model bundle."
    }

    private var setupState: AppSetupSnapshot.OnboardingPhase {
        appSetup.onboardingPhase()
    }

    private var hasVisibleActions: Bool {
        statusAction != nil || modelDownloader.modelPath != nil
    }

    private var statusBadgeText: String {
        if isSwitchingModelSource {
            return "Switching model"
        }

        switch setupState {
        case .simulator:
            return "Simulator"
        case .intro:
            return "Needs setup"
        case .downloading:
            return progressPercentLabel(appSetup.downloadProgress)
        case .paused:
            return "Paused"
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs attention"
        }
    }

    private var statusTitle: String {
        if isSwitchingModelSource {
            return "Switching model"
        }

        switch setupState {
        case .simulator:
            return "Simulator preview"
        case .intro:
            return "Model needs setup"
        case .downloading:
            return "Downloading model"
        case .paused:
            return "Download paused"
        case .preparing:
            return "Finishing setup"
        case .ready:
            return "Model is ready"
        case .failed:
            return "Model needs attention"
        }
    }

    private var statusMessageText: String {
        if isSwitchingModelSource {
            return "Yemma is unloading the current bundle and preparing the new model."
        }

        switch setupState {
        case .simulator:
            return "Use this page to preview model switching in the simulator. Real downloads and inference still require a physical iPhone."
        case .intro:
            return "This model is not saved on the device yet."
        case .downloading:
            return appSetup.chatStatusDetailText ?? "Yemma is downloading the model now."
        case .paused:
            return appSetup.chatStatusDetailText ?? "Resume setup to finish preparing this model on the device."
        case .preparing:
            return "The bundle is already on this iPhone. Yemma is validating files and waking up the runtime."
        case .ready:
            return "This model has a valid local bundle and can load without downloading again."
        case .failed:
            return appSetup.visibleErrorMessage ?? "This model needs attention before it can run."
        }
    }

    private var statusIconName: String {
        if isSwitchingModelSource {
            return "arrow.triangle.2.circlepath"
        }

        switch setupState {
        case .simulator:
            return "desktopcomputer"
        case .intro:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .preparing:
            return "bolt.circle.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusTintColor: Color {
        setupState == .failed ? AppTheme.destructive : AppTheme.accent
    }

    private var statusBadgeBackground: Color {
        setupState == .failed ? AppTheme.destructive.opacity(0.12) : AppTheme.accentSoft
    }

    private var statusMessageColor: Color {
        setupState == .failed ? AppTheme.destructive : AppTheme.textSecondary
    }

    private var sourceKindText: String {
        activeSourceBoundaryLabel
    }

    private var storedModelSizeText: String {
        guard let modelPath = modelDownloader.modelPath else {
            return "Not saved"
        }

        return Self.formatBytes(Self.modelDirectorySize(at: modelPath))
    }

    private var overviewMetrics: [StatusMetric] {
        switch setupState {
        case .simulator:
            return [
                StatusMetric(title: "Mode", value: "Simulator"),
                StatusMetric(title: "Replies", value: "Mocked"),
                StatusMetric(title: "Runtime", value: "Disabled"),
                StatusMetric(title: "Source", value: sourceKindText)
            ]
        case .intro:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Download size", value: Self.formatBytes(appSetup.estimatedDownloadBytes)),
                StatusMetric(title: "Storage", value: "This iPhone"),
                StatusMetric(title: "After setup", value: "Offline chat")
            ]
        case .downloading:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Downloaded", value: Self.formatBytes(appSetup.downloadedBytes)),
                StatusMetric(title: "Remaining", value: Self.formatBytes(appSetup.remainingDownloadBytes)),
                StatusMetric(
                    title: "Speed",
                    value: appSetup.currentDownloadSpeedBytesPerSecond.map(Self.formatSpeed) ?? "Calculating"
                )
            ]
        case .paused:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Downloaded", value: Self.formatBytes(appSetup.downloadedBytes)),
                StatusMetric(title: "Remaining", value: Self.formatBytes(appSetup.remainingDownloadBytes)),
                StatusMetric(title: "Resume", value: "Saved progress")
            ]
        case .preparing:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Bundle", value: storedModelSizeText),
                StatusMetric(title: "Stage", value: appSetup.modelLoadStage.statusText),
                StatusMetric(title: "Network", value: "Not needed")
            ]
        case .ready:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Bundle", value: storedModelSizeText),
                StatusMetric(title: "Runtime", value: "Ready"),
                StatusMetric(title: "Privacy", value: "On-device")
            ]
        case .failed:
            return [
                StatusMetric(title: "Source", value: sourceKindText),
                StatusMetric(title: "Downloaded", value: Self.formatBytes(appSetup.downloadedBytes)),
                StatusMetric(title: "Remaining", value: Self.formatBytes(appSetup.remainingDownloadBytes)),
                StatusMetric(
                    title: "Recovery",
                    value: appSetup.chatRecoveryAction?.title ?? "Select model again"
                )
            ]
        }
    }

    private var variantsFooterText: String {
        if supportsLocalModelRuntime {
            return "Paste a Hugging Face model URL when you want to try something other than the app default. Yemma reuses any valid cached bundle for that URL."
        }

        return "The simulator only previews the picker flow. Real downloads and inference still require a physical iPhone."
    }

    private var overviewMetricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(overviewMetrics) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    Text(metric.value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 48, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .inputChrome(cornerRadius: AppTheme.Radius.small)
            }
        }
    }

    var body: some View {
        ZStack {
            UtilityBackground()

            ProgressiveBlurHeaderHost(
                initialHeaderHeight: 88,
                maxBlurRadius: 12,
                fadeExtension: 88,
                tintOpacityTop: 0.66,
                tintOpacityMiddle: 0.24
            ) { headerHeight in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.sectionSpacing) {
                        ModelVariantNote(text: "Debug-only surface. Keep the app default model unless you are actively testing another Hugging Face URL.")
                        overviewCard

                        if hasVisibleActions {
                            actionsSection
                        }

                        variantsSection
                    }
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                }
            } header: {
                header
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 0)
                    .padding(.bottom, 8)
            }
        }
        .alert(
            "Unable to Switch Model",
            isPresented: Binding(
                get: { modelSourceError != nil },
                set: { if !$0 { modelSourceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(modelSourceError ?? "Yemma could not switch to that model.")
        }
        .sheet(isPresented: $showCustomModelSheet) {
            customModelSheet
        }
        .confirmationDialog(
            "Switch models?",
            isPresented: Binding(
                get: { pendingModelSourceSwitch != nil },
                set: { if !$0 { pendingModelSourceSwitch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                guard let source = pendingModelSourceSwitch else { return }
                pendingModelSourceSwitch = nil
                Task {
                    await performModelSwitch(to: source)
                }
            }

            Button("Cancel", role: .cancel) {
                pendingModelSourceSwitch = nil
            }
        } message: {
            Text("Yemma will unload the current model before switching. Unsupported repositories may fail validation or load incorrectly.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.controlFill)

                    Circle()
                        .stroke(AppTheme.controlBorder, lineWidth: 1)

                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Back")
            .accessibilityHint("Returns to advanced settings.")

            Text("Model Source")
                .font(AppTheme.Typography.utilityTitle)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: 48, height: 48)
        }
        .frame(height: 48)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ModelVariantChip(
                            text: statusBadgeText,
                            systemImage: statusIconName,
                            foreground: statusTintColor,
                            background: statusBadgeBackground
                        )

                        ModelVariantChip(
                            text: sourceKindText,
                            systemImage: activeSourceCardSystemImage,
                            foreground: AppTheme.textSecondary,
                            background: AppTheme.chipFill
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(activeSourceCardTitle)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(modelDownloader.activeModelSource.repositoryID)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)

                        Text(statusTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(statusMessageText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(statusMessageColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .fill(statusBadgeBackground)
                        .frame(width: 54, height: 54)

                    Image(systemName: statusIconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(statusTintColor)
                }
            }

            Link(destination: modelDownloader.activeModelSource.sourceURL) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Open selected source on Hugging Face")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .inputChrome(cornerRadius: AppTheme.Radius.small)
            }
            .buttonStyle(.plain)

            overviewStatusPanel
            overviewMetricsGrid
        }
        .padding(20)
        .brandCard(cornerRadius: AppTheme.Radius.large)
    }

    private var overviewStatusPanel: some View {
        ModelVariantSurface {
            overviewStatusPanelContent
        }
    }

    @ViewBuilder
    private var overviewStatusPanelContent: some View {
        switch setupState {
        case .simulator:
            VStack(alignment: .leading, spacing: 12) {
                ModelVariantStatusLine(
                    systemImage: "desktopcomputer",
                    title: "UI-only debug preview",
                    trailing: "Simulator"
                )

                Text("Source changes are saved for the debug flow, but local downloads and inference stay disabled on the simulator.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .intro:
                ModelVariantStatusLine(
                    systemImage: "arrow.down.circle",
                    title: "Model needs setup.",
                    trailing: Self.formatBytes(appSetup.estimatedDownloadBytes),
                    detail: "Use the actions section to start saving this model locally on the device."
                )

        case .downloading:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(progressPercentLabel(appSetup.downloadProgress))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer(minLength: 0)

                    if let eta = appSetup.estimatedSecondsRemaining {
                        Text(Self.formatETA(eta))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }

                ModelVariantProgressBar(progress: appSetup.downloadProgress)

                ModelVariantStatusLine(
                    systemImage: "square.and.arrow.down",
                    title: "\(Self.formatBytes(appSetup.downloadedBytes)) of \(Self.formatBytes(appSetup.estimatedDownloadBytes)) saved",
                    trailing: appSetup.currentDownloadSpeedBytesPerSecond.map(Self.formatSpeed)
                )

                if appSetup.remainingDownloadBytes > 0 {
                    ModelVariantStatusLine(
                        systemImage: "hourglass",
                        title: "\(Self.formatBytes(appSetup.remainingDownloadBytes)) remaining"
                    )
                }
            }

        case .paused:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(progressPercentLabel(appSetup.downloadProgress))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer(minLength: 0)

                    Text("Saved progress")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                ModelVariantProgressBar(progress: appSetup.downloadProgress)

                ModelVariantStatusLine(
                    systemImage: "pause.circle.fill",
                    title: "Resume from the current download state",
                    trailing: Self.formatBytes(appSetup.remainingDownloadBytes),
                    detail: "Yemma kept the verified partial files for this model."
                )
            }

        case .preparing:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .tint(AppTheme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appSetup.modelLoadStage.statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Download is complete. Yemma is validating the local files and bringing the runtime online.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

        case .ready:
            ModelVariantStatusLine(
                systemImage: "checkmark.circle.fill",
                title: "Model stored locally",
                trailing: storedModelSizeText,
                detail: "This model can be loaded again without downloading."
            )

        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                if appSetup.downloadProgress > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(progressPercentLabel(appSetup.downloadProgress))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)

                        Spacer(minLength: 0)

                        Text(appSetup.hasModelPreparationError ? "Downloaded" : "Partial download")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textTertiary)
                    }

                    ModelVariantProgressBar(progress: appSetup.downloadProgress)
                }

                ModelVariantStatusLine(
                    systemImage: appSetup.hasModelPreparationError ? "bolt.slash.fill" : "exclamationmark.triangle.fill",
                    title: appSetup.chatRecoveryAction?.title ?? "Select a model again",
                    trailing: appSetup.downloadProgress > 0 ? progressPercentLabel(appSetup.downloadProgress) : nil,
                    detail: appSetup.visibleErrorMessage
                )
            }
        }
    }

    private var actionsSection: some View {
        UtilitySection("Debug actions") {
            if let action = statusAction {
                Button(role: action.role) {
                    Task {
                        await action.action()
                    }
                } label: {
                    utilityActionRow(
                        icon: action.icon,
                        title: action.title,
                        detail: action.detail,
                        titleColor: action.role == .destructive ? AppTheme.destructive : AppTheme.textPrimary,
                        chevronColor: action.role == .destructive ? AppTheme.destructive : AppTheme.textSecondary
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSwitchingModelSource)

                if modelDownloader.modelPath != nil {
                    UtilitySectionSeparator()
                }
            }

            if modelDownloader.modelPath != nil {
                Button(role: .destructive) {
                    Task {
                        await deleteCurrentModel()
                    }
                } label: {
                    utilityActionRow(
                        icon: "externaldrive.badge.minus",
                        title: "Delete selected download",
                        detail: "Remove the currently selected local model bundle.",
                        titleColor: AppTheme.destructive,
                        chevronColor: AppTheme.destructive
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSwitchingModelSource)
            }
        }
    }

    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            UtilitySection("Model source") {
                Button {
                    customModelInput = modelDownloader.activeModelSource.isCustom
                        ? modelDownloader.activeModelSource.sourceURL.absoluteString
                        : ""
                    showCustomModelSheet = true
                } label: {
                    customModelRow
                }
                .buttonStyle(.plain)
                .disabled(isSwitchingModelSource)

                if !modelDownloader.isUsingDefaultModelSource {
                    UtilitySectionSeparator(
                        leadingInset: AppTheme.Layout.rowHorizontalPadding + AppTheme.Layout.rowIconSize + 14
                    )

                    Button {
                        Task {
                            await requestModelSwitch(to: Gemma4MLXSupport.defaultModelSource)
                        }
                    } label: {
                        useDefaultModelRow
                    }
                    .buttonStyle(.plain)
                    .disabled(isSwitchingModelSource)
                }
            }

            ModelVariantNote(text: variantsFooterText)
                .padding(.horizontal, 4)
        }
    }

    private var statusAction: ModelStatusAction? {
        if isSwitchingModelSource {
            return nil
        }

        if !supportsLocalModelRuntime {
            return nil
        }

        if let recoveryAction = appSetup.chatRecoveryAction {
            switch recoveryAction {
            case .resumeDownload:
                return ModelStatusAction(
                    title: recoveryAction.title,
                    detail: "Continue downloading this model from saved progress.",
                    icon: "play.circle",
                    role: nil,
                    action: { await modelDownloader.downloadModel() }
                )
            case .retryDownload:
                return ModelStatusAction(
                    title: recoveryAction.title,
                    detail: "Try downloading this model again.",
                    icon: "arrow.clockwise",
                    role: nil,
                    action: { await modelDownloader.downloadModel() }
                )
            case .retryModelLoad:
                return ModelStatusAction(
                    title: recoveryAction.title,
                    detail: "Retry loading the already downloaded bundle.",
                    icon: "bolt.circle",
                    role: nil,
                    action: { await retryModelLoad() }
                )
            }
        }

        if !modelDownloader.isDownloaded && !modelDownloader.isDownloading {
            return ModelStatusAction(
                title: downloadActionTitle,
                detail: downloadActionDetail,
                icon: "arrow.down.circle",
                role: nil,
                action: { await modelDownloader.downloadModel() }
            )
        }

        return nil
    }

    private var customModelRow: some View {
        let isSelected = modelDownloader.activeModelSource.isCustom
        let detail = isSelected
            ? modelDownloader.activeModelSource.sourceURL.absoluteString
            : "Paste a Hugging Face model URL to try a different model."

        return HStack(spacing: 14) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "link.badge.plus")
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Paste Hugging Face URL")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Text(detail)
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isSelected {
                Text(modelDownloader.isDownloaded ? "Ready" : "Using")
                    .font(AppTheme.Typography.utilityCaption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private var useDefaultModelRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Use app default model")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Switch back to the default bundled model choice.")
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "arrow.uturn.backward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private var customModelSheet: some View {
        NavigationStack {
            ZStack {
                UtilityBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Paste a Hugging Face model URL. Yemma validates the MLX files after download before trying to load the model.")
                            .font(AppTheme.Typography.utilityRowDetail)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField(
                            "https://huggingface.co/owner/repository",
                            text: $customModelInput,
                            axis: .vertical
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .inputChrome()

                        Text("Use a full URL like `https://huggingface.co/owner/repository`.")
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Hugging Face URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCustomModelSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        submitCustomModel()
                    }
                    .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSwitchingModelSource)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func requestModelSwitch(to source: Gemma4ModelSource) async {
        guard !isSwitchingModelSource else { return }
        guard modelDownloader.activeModelSource != source else { return }

        if source == Gemma4MLXSupport.defaultModelSource {
            await performModelSwitch(to: source)
            return
        }

        pendingModelSourceSwitch = source
    }

    @MainActor
    private func performModelSwitch(to source: Gemma4ModelSource) async {
        guard !isSwitchingModelSource else { return }
        guard modelDownloader.activeModelSource != source else { return }

        isSwitchingModelSource = true
        modelSourceError = nil
        diagnostics.record(
            "Debug model switch requested",
            category: "settings",
            metadata: ["repository": source.repositoryID]
        )

        await llmService.unloadModel()
        await modelDownloader.selectModelSource(source)
        if !modelDownloader.isDownloaded {
            await modelDownloader.downloadModel()
        }

        AppHaptics.selection()
        isSwitchingModelSource = false
    }

    @MainActor
    private func retryModelLoad() async {
        guard let modelPath = modelDownloader.modelPath else { return }

        isSwitchingModelSource = true
        defer { isSwitchingModelSource = false }

        do {
            await llmService.unloadModel()
            llmService.signalLoadingIntent()
            try await llmService.loadModel(from: modelPath)
            AppHaptics.selection()
        } catch {
            modelSourceError = error.localizedDescription
        }
    }

    @MainActor
    private func deleteCurrentModel() async {
        await llmService.unloadModel()
        modelDownloader.deleteModel()
        AppHaptics.selection()
    }

    private func submitCustomModel() {
        do {
            let source = try Gemma4ModelSource.fromUserInput(customModelInput)
            showCustomModelSheet = false
            Task {
                await requestModelSwitch(to: source)
            }
        } catch {
            modelSourceError = error.localizedDescription
        }
    }

    private func utilityActionRow(
        icon: String,
        title: String,
        detail: String,
        titleColor: Color = AppTheme.textPrimary,
        chevronColor: Color = AppTheme.textSecondary
    ) -> some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(titleColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(titleColor)

                    Text(detail)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(chevronColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .frame(width: AppTheme.Layout.rowIconSize)
                        .foregroundStyle(titleColor)

                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(titleColor)
                }

                Text(detail)
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, AppTheme.Layout.rowIconSize + 14)

                HStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(chevronColor)
                }
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private func progressPercentLabel(_ progress: Double) -> String {
        "\(Int((progress * 100).rounded()))%"
    }

    private static func modelDirectorySize(at path: String) -> Int64 {
        Gemma4MLXSupport.directorySize(at: URL(fileURLWithPath: path))
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
        }

        if s < 3600 {
            return "\(s / 60) min"
        }

        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}

private struct ModelVariantChip: View {
    let text: String
    let systemImage: String
    let foreground: Color
    let background: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background)
            .clipShape(Capsule())
    }
}

private struct ModelVariantSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .inputChrome(cornerRadius: AppTheme.Radius.medium)
    }
}

private struct ModelVariantStatusLine: View {
    let systemImage: String
    let title: String
    let trailing: String?
    let detail: String?

    init(
        systemImage: String,
        title: String,
        trailing: String? = nil,
        detail: String? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.trailing = trailing
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: detail == nil ? 0 : 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModelVariantNote: View {
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

private struct ModelVariantProgressBar: View {
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
        .accessibilityLabel("Download progress")
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

#if DEBUG
#Preview("Model Variants") {
    DebugModelVariantsView()
        .environment(ModelDownloader())
        .environment(LLMService())
        .environment(AppDiagnostics.shared)
}
#endif
