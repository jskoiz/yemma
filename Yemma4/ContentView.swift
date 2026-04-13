import Observation
import SwiftUI

struct AppBackground: View {
    enum Atmosphere {
        case none
        case full
    }

    var atmosphere: Atmosphere = .full

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if atmosphere == .full {
                Circle()
                    .fill(AppTheme.coolGlow)
                    .frame(width: 360, height: 360)
                    .blur(radius: 70)
                    .offset(x: -120, y: -240)

                Circle()
                    .fill(AppTheme.warmGlow)
                    .frame(width: 300, height: 300)
                    .blur(radius: 70)
                    .offset(x: 150, y: -150)
            }

            LinearGradient(
                colors: [
                    AppTheme.backgroundSheenTop,
                    AppTheme.backgroundSheenMiddle,
                    Color.clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
        .ignoresSafeArea()
    }
}

struct CircleIconButton: View {
    let systemName: String
    var filled: Bool = true
    var action: () -> Void

    var body: some View {
        let hitTargetSize = max(AppTheme.Layout.controlIconSize + 14, 48)

        return Button(action: action) {
            ZStack {
                Circle()
                    .fill(filled ? AppTheme.controlFill : Color.clear)

                Circle()
                    .stroke(AppTheme.controlBorder, lineWidth: filled ? 1 : 0)

                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(width: AppTheme.Layout.controlIconSize, height: AppTheme.Layout.controlIconSize)
        }
        .frame(width: hitTargetSize, height: hitTargetSize)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color = AppTheme.chipFill
    var pressedFill: Color = AppTheme.chipPressedFill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? pressedFill : fill)
            .clipShape(Capsule())
    }
}

public struct ContentView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    private let forceOnboardingOnSimulator = Yemma4DebugOptions.forceOnboardingOnSimulator
    @State private var modelLoadError: String?
    @State private var loadedModelSignature: String?
    @State private var launchValidatedModelPath: String?
    @State private var isShowingOnboardingPreview = false
    @State private var didRecordShellVisible = false
    @State private var didRecordTextReady = false
    @State private var didRecordVisionReady = false
    @State private var smokeAutomation = Gemma4SmokeAutomation()

    public init() {}

    public var body: some View {
        currentRootScreen
        .onAppear {
            if launchValidatedModelPath == nil {
                launchValidatedModelPath = modelDownloader.modelPath
            }
            AppDiagnostics.shared.record(
                "startup: view_appeared",
                category: "startup",
                metadata: ["view": "ContentView", "elapsedMs": StartupTiming.elapsedMs()]
            )
            recordStartupMilestonesIfNeeded()
        }
        .task {
            AppDiagnostics.shared.record(
                "startup: launch_validation_deferred",
                category: "startup",
                metadata: [
                    "cachedModelPath": modelDownloader.modelPath ?? "nil",
                    "elapsedMs": StartupTiming.elapsedMs()
                ]
            )
        }
        .task(id: modelDownloader.modelPath ?? "") {
            guard let modelPath = modelDownloader.modelPath else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard modelPath != launchValidatedModelPath else { return }
            guard !llmService.isTextModelReady && !llmService.isModelLoading else {
                await loadModelIfNeeded()
                return
            }

            if supportsLocalModelRuntime, modelDownloader.isDownloaded {
                // Let the shell become interactive before the heavy local warmup starts.
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard !Task.isCancelled else { return }
            await loadModelIfNeeded()
        }
        .onChange(of: shouldShowChat) { _, _ in
            recordStartupMilestonesIfNeeded()
        }
        .onChange(of: llmService.isTextModelReady) { _, _ in
            recordStartupMilestonesIfNeeded()
        }
        .onChange(of: llmService.isVisionReady) { _, _ in
            recordStartupMilestonesIfNeeded()
        }
        .alert(
            "Unable to Load Model",
            isPresented: Binding(
                get: { modelLoadError != nil },
                set: { if !$0 { modelLoadError = nil } }
            )
        ) {
            Button("Retry") {
                Task { await loadModelIfNeeded(force: true) }
            }
            Button("Dismiss", role: .cancel) {
                modelLoadError = nil
            }
        } message: {
            Text(modelLoadError ?? "The model could not be loaded.")
        }
    }

    @ViewBuilder
    private var currentRootScreen: some View {
        if shouldShowChat {
            ChatView(
                onShowOnboarding: {
                    isShowingOnboardingPreview = true
                },
                onRetryModelLoad: modelDownloader.isDownloaded ? {
                    Task { await loadModelIfNeeded(force: true) }
                } : nil
            )
        } else {
            OnboardingView(
                supportsLocalModelRuntime: supportsLocalSetupExperience,
                onContinue: canContinueFromOnboarding ? {
                    isShowingOnboardingPreview = false
                } : nil,
                onRetryModelLoad: modelDownloader.isDownloaded ? {
                    Task { await loadModelIfNeeded(force: true) }
                } : nil
            )
        }
    }

    private var shouldShowChat: Bool {
        guard !forceOnboardingOnSimulator else { return false }
        return !isShowingOnboardingPreview && (canOpenChatShell || !supportsLocalModelRuntime)
    }

    private var canContinueFromOnboarding: Bool {
        guard !forceOnboardingOnSimulator else { return false }
        return canOpenChatShell || !supportsLocalModelRuntime
    }

    private var supportsLocalSetupExperience: Bool {
        supportsLocalModelRuntime || forceOnboardingOnSimulator
    }

    private var canOpenChatShell: Bool {
        supportsLocalModelRuntime
            && (
                modelDownloader.isDownloaded
                    || llmService.isModelLoading
                    || llmService.isTextModelReady
            )
    }

    private var isSetupComplete: Bool {
        supportsLocalModelRuntime
            && modelDownloader.isDownloaded
            && llmService.isTextModelReady
    }

    private var hasModelPreparationError: Bool {
        supportsLocalModelRuntime
            && modelDownloader.isDownloaded
            && !llmService.isTextModelReady
            && !llmService.isModelLoading
            && llmService.lastError != nil
    }

    @MainActor
    private func recordStartupMilestonesIfNeeded() {
        if shouldShowChat && !didRecordShellVisible {
            didRecordShellVisible = true
            AppDiagnostics.shared.record(
                "startup: shell_visible",
                category: "startup",
                metadata: ["shellVisibleMs": StartupTiming.elapsedMs()]
            )
        }

        if llmService.isTextModelReady && !didRecordTextReady {
            didRecordTextReady = true
            let elapsedMs = StartupTiming.elapsedMs()
            AppDiagnostics.shared.record(
                "startup: text_ready",
                category: "startup",
                metadata: ["textReadyMs": elapsedMs]
            )
            AppDiagnostics.shared.record(
                "startup: ready_for_input",
                category: "startup",
                metadata: ["totalElapsedMs": elapsedMs]
            )
        }

        if llmService.isVisionReady && !didRecordVisionReady {
            didRecordVisionReady = true
            AppDiagnostics.shared.record(
                "startup: vision_ready",
                category: "startup",
                metadata: ["visionReadyMs": StartupTiming.elapsedMs()]
            )
        }
    }

    private func loadModelIfNeeded(force: Bool = false) async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            await MainActor.run {
                loadedModelSignature = nil
                modelLoadError = nil
            }
            return
        }

        guard let modelPath = modelDownloader.modelPath else {
            return
        }

        let signature = modelPath
        guard force || loadedModelSignature != signature || (!llmService.isModelLoaded && !llmService.isModelLoading) else { return }

        do {
            // Signal loading state immediately so OnboardingView shows "Preparing model"
            // before the heavy work begins — prevents the "Download model" flash.
            llmService.signalLoadingIntent()
            await Task.yield()
            try await llmService.loadModel(from: modelPath)

            await MainActor.run {
                loadedModelSignature = signature
                modelLoadError = nil
            }

            await MainActor.run {
                recordStartupMilestonesIfNeeded()
            }

            await smokeAutomation.runIfNeeded(llmService: llmService)
        } catch {
            await MainActor.run {
                loadedModelSignature = nil
                modelLoadError = error.localizedDescription
            }
        }
    }
}
