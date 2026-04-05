import Observation
import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: AppTheme.Layout.controlIconSize, height: AppTheme.Layout.controlIconSize)
                .background(
                    Circle()
                        .fill(filled ? AppTheme.controlFill : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(AppTheme.controlBorder, lineWidth: filled ? 1 : 0)
                )
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var modelLoadError: String?
    @State private var loadedModelSignature: String?
    @State private var hasValidatedLocalModel = false
    @State private var isShowingOnboardingPreview = false
    @State private var didRecordShellVisible = false
    @State private var didRecordTextReady = false
    @State private var didRecordVisionReady = false

    public init() {}

    public var body: some View {
        ZStack {
            if shouldShowChat {
                ChatView(
                    onShowOnboarding: {
                        isShowingOnboardingPreview = true
                    }
                )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .trailing))
                    )
            } else {
                OnboardingView(
                    onContinue: canContinueFromOnboarding ? {
                        isShowingOnboardingPreview = false
                    } : nil,
                    onRetryModelLoad: modelDownloader.isDownloaded ? {
                        Task { await loadModelIfNeeded(force: true) }
                    } : nil
                )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .leading))
                    )
            }
        }
        .onAppear {
            AppDiagnostics.shared.record(
                "startup: view_appeared",
                category: "startup",
                metadata: ["view": "ContentView", "elapsedMs": StartupTiming.elapsedMs()]
            )
            recordStartupMilestonesIfNeeded()
        }
        .task {
            guard !hasValidatedLocalModel else { return }
            hasValidatedLocalModel = true
            await Task.yield()
            await modelDownloader.validateDownloadedModel()
        }
        .task(id: "\(modelDownloader.modelPath ?? "")|\(modelDownloader.mmprojPath ?? "")") {
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: modelDownloader.isDownloaded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: llmService.isModelLoaded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: llmService.isModelLoading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isShowingOnboardingPreview)
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

    private var shouldShowChat: Bool {
        !isShowingOnboardingPreview && (hasWarmShell || !supportsLocalModelRuntime)
    }

    private var canContinueFromOnboarding: Bool {
        modelDownloader.isDownloaded || !supportsLocalModelRuntime
    }

    private var hasWarmShell: Bool {
        modelDownloader.isDownloaded && !hasModelPreparationError
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

        guard
            let modelPath = modelDownloader.modelPath,
            let mmprojPath = modelDownloader.mmprojPath
        else {
            return
        }

        let signature = "\(modelPath)|\(mmprojPath)"
        guard force || loadedModelSignature != signature || (!llmService.isModelLoaded && !llmService.isModelLoading) else { return }

        do {
            // Signal loading state immediately so OnboardingView shows "Preparing model"
            // before the heavy work begins — prevents the "Download model" flash.
            await llmService.signalLoadingIntent()
            await Task.yield()
            try await llmService.loadModel(from: modelPath, mmprojPath: mmprojPath)

            await MainActor.run {
                loadedModelSignature = signature
                modelLoadError = nil
            }

            await MainActor.run {
                recordStartupMilestonesIfNeeded()
            }
        } catch {
            await MainActor.run {
                loadedModelSignature = nil
                modelLoadError = error.localizedDescription
            }
        }
    }
}
