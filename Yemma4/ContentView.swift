import Observation
import SwiftUI

public struct ContentView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    @State private var isLoadingModel = false
    @State private var modelLoadError: String?
    @State private var loadedModelPath: String?

    public init() {}

    public var body: some View {
        ZStack {
            if modelDownloader.isDownloaded {
                ChatView()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .task(id: modelDownloader.modelPath) {
                        await loadModelIfNeeded()
                    }
            } else {
                OnboardingView()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .task {
            modelDownloader.validateDownloadedModel()
        }
        .animation(.easeInOut(duration: 0.25), value: modelDownloader.isDownloaded)
        .overlay {
            if isLoadingModel {
                loadingOverlay
                    .transition(.opacity)
            }
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

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Loading model...")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @MainActor
    private func loadModelIfNeeded(force: Bool = false) async {
        guard let modelPath = modelDownloader.modelPath else { return }
        guard force || loadedModelPath != modelPath || !llmService.isModelLoaded else { return }

        isLoadingModel = true
        defer { isLoadingModel = false }

        do {
            try llmService.loadModel(from: modelPath)
            loadedModelPath = modelPath
            modelLoadError = nil
        } catch {
            loadedModelPath = nil
            modelLoadError = error.localizedDescription
        }
    }
}
