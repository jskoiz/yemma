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

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.cardBorder, lineWidth: 1)
                    )
            )
            .shadow(color: AppTheme.shadow, radius: 30, x: 0, y: 18)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 28) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
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
                .frame(width: 34, height: 34)
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
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.controlBorder, lineWidth: 1)
            )
    }
}

public struct ContentView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var modelLoadError: String?
    @State private var loadedModelSignature: String?
    @State private var hasValidatedLocalModel = false
    @State private var isShowingOnboardingPreview = false

    public init() {}

    public var body: some View {
        ZStack {
            if shouldShowChat {
                ChatView(
                    onShowOnboarding: {
                        isShowingOnboardingPreview = true
                    }
                )
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                OnboardingView(
                    onContinue: canContinueFromOnboarding ? {
                        isShowingOnboardingPreview = false
                    } : nil,
                    onRetryModelLoad: modelDownloader.isDownloaded ? {
                        Task { await loadModelIfNeeded(force: true) }
                    } : nil
                )
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
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
        .animation(.easeInOut(duration: 0.25), value: modelDownloader.isDownloaded)
        .animation(.easeInOut(duration: 0.25), value: llmService.isModelLoaded)
        .animation(.easeInOut(duration: 0.25), value: llmService.isModelLoading)
        .animation(.easeInOut(duration: 0.25), value: isShowingOnboardingPreview)
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
        !isShowingOnboardingPreview && (isReadyForChat || !supportsLocalModelRuntime)
    }

    private var canContinueFromOnboarding: Bool {
        isReadyForChat || !supportsLocalModelRuntime
    }

    private var isReadyForChat: Bool {
        modelDownloader.isDownloaded && llmService.isModelLoaded
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
            // Let the download-state transition render before heavy model setup begins.
            await Task.yield()
            try await llmService.loadModel(from: modelPath, mmprojPath: mmprojPath)

            await MainActor.run {
                loadedModelSignature = signature
                modelLoadError = nil
            }
        } catch {
            await MainActor.run {
                loadedModelSignature = nil
                modelLoadError = error.localizedDescription
            }
        }
    }
}
