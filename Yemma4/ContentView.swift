import Observation
import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.98, green: 0.97, blue: 0.96)
    static let backgroundBottom = Color(red: 0.94, green: 0.94, blue: 0.96)
    static let card = Color.white.opacity(0.72)
    static let cardBorder = Color.white.opacity(0.7)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let textSecondary = Color(red: 0.47, green: 0.48, blue: 0.52)
    static let inputFill = Color.white.opacity(0.78)
    static let chipFill = Color.white.opacity(0.78)
    static let accent = Color.black
    static let warmGlow = Color(red: 0.97, green: 0.85, blue: 0.76).opacity(0.58)
    static let coolGlow = Color(red: 0.88, green: 0.90, blue: 0.98).opacity(0.65)
}

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
                    Color.white.opacity(0.1),
                    Color.white.opacity(0.45),
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
            .shadow(color: Color.black.opacity(0.05), radius: 30, x: 0, y: 18)
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
                        .fill(filled ? Color.white.opacity(0.86) : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.72), lineWidth: filled ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color = AppTheme.chipFill
    var pressedFill: Color = Color.white.opacity(0.92)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? pressedFill : fill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.74), lineWidth: 1)
            )
    }
}

public struct ContentView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var modelLoadError: String?
    @State private var loadedModelPath: String?
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
        .task(id: modelDownloader.modelPath) {
            await loadModelIfNeeded()
        }
        .animation(.easeInOut(duration: 0.25), value: modelDownloader.isDownloaded)
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
        !isShowingOnboardingPreview && (modelDownloader.isDownloaded || !supportsLocalModelRuntime)
    }

    private var canContinueFromOnboarding: Bool {
        modelDownloader.isDownloaded || !supportsLocalModelRuntime
    }

    private func loadModelIfNeeded(force: Bool = false) async {
        guard Yemma4AppConfiguration.supportsLocalModelRuntime else {
            await MainActor.run {
                loadedModelPath = nil
                modelLoadError = nil
            }
            return
        }

        guard let modelPath = modelDownloader.modelPath else { return }
        guard force || loadedModelPath != modelPath || (!llmService.isModelLoaded && !llmService.isModelLoading) else { return }

        do {
            // Let the download-state transition render before heavy model setup begins.
            await Task.yield()
            try await llmService.loadModel(from: modelPath)

            await MainActor.run {
                loadedModelPath = modelPath
                modelLoadError = nil
            }
        } catch {
            await MainActor.run {
                loadedModelPath = nil
                modelLoadError = error.localizedDescription
            }
        }
    }
}
