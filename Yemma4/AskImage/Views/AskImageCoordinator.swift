import SwiftUI
import PhotosUI

/// Top-level coordinator for the Ask Image feature.
/// Manages navigation between the model-selection home and the active session.
struct AskImageCoordinator: View {
    @State private var viewModel = AskImageCoordinatorViewModel()
    let onDismiss: () -> Void

    var body: some View {
        if let model = viewModel.selectedModel {
            AskImageSessionView(
                modelName: model.displayName,
                sessionState: viewModel.sessionState,
                messages: viewModel.messages,
                attachment: viewModel.attachment,
                onSend: { viewModel.sendPrompt($0) },
                onPickedImage: { viewModel.handlePickedImage($0) },
                onCancel: { viewModel.cancelGeneration() },
                onNewSession: { viewModel.resetSession() },
                onDismiss: { viewModel.goBackToHome() },
                onRetryError: { viewModel.retryAfterError() }
            )
        } else {
            AskImageHomeView(
                models: viewModel.modelStore.availableModels,
                modelState: { viewModel.modelStore.state(for: $0) },
                onSelectModel: { viewModel.selectModel($0) },
                onDownloadModel: { viewModel.downloadModel($0) },
                onCancelDownload: { viewModel.cancelDownload($0) },
                onDeleteModel: { viewModel.deleteModel($0) },
                onDismiss: onDismiss
            )
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class AskImageCoordinatorViewModel {
    // Dependencies
    let runtime: any AskImageRuntime
    let modelStore: any AskImageModelStore

    // Navigation
    var selectedModel: LiteRTModelDescriptor?

    // Session
    var sessionState: AskImageSessionState = .idle
    var messages: [AskImageMessage] = []
    var attachment: AskImageAttachment?

    // Internal
    private var generationTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    init(
        runtime: (any AskImageRuntime)? = nil,
        modelStore: (any AskImageModelStore)? = nil
    ) {
        if let runtime {
            self.runtime = runtime
        } else if AskImageFeature.supportsNativeRuntime {
            self.runtime = LiteRTLMRuntime()
        } else {
            self.runtime = StubAskImageRuntime()
        }
        self.modelStore = modelStore ?? LiteRTModelDownloader()
    }

    // MARK: - Model Selection

    func selectModel(_ model: LiteRTModelDescriptor) {
        guard modelStore.state(for: model.id).isDownloaded else { return }
        selectedModel = model
        sessionState = .warmingModel

        AppDiagnostics.shared.record(
            "ask_image: model selected",
            category: "ask_image",
            metadata: ["model": model.id]
        )

        Task {
            do {
                try await runtime.prepareModel(at: model.localModelPath.path)
                sessionState = .readyForInput
                AppDiagnostics.shared.record(
                    "ask_image: model ready",
                    category: "ask_image",
                    metadata: ["model": model.id]
                )
            } catch {
                sessionState = .error(error.localizedDescription)
                AppDiagnostics.shared.record(
                    "ask_image: model prepare failed",
                    category: "ask_image",
                    metadata: ["model": model.id, "error": error.localizedDescription]
                )
            }
        }
    }

    func goBackToHome() {
        cancelGeneration()
        Task {
            await runtime.unloadModel()
        }
        selectedModel = nil
        sessionState = .idle
        messages = []
        attachment = nil

        AppDiagnostics.shared.record(
            "ask_image: returned to home",
            category: "ask_image"
        )
    }

    // MARK: - Model Download

    func downloadModel(_ model: LiteRTModelDescriptor) {
        downloadTask = Task {
            do {
                try await modelStore.download(model)
                AppDiagnostics.shared.record(
                    "ask_image: model downloaded",
                    category: "ask_image",
                    metadata: ["model": model.id]
                )
            } catch {
                AppDiagnostics.shared.record(
                    "ask_image: model download failed",
                    category: "ask_image",
                    metadata: ["model": model.id, "error": error.localizedDescription]
                )
            }
        }
    }

    func cancelDownload(_ model: LiteRTModelDescriptor) {
        modelStore.cancelDownload(model.id)
        downloadTask?.cancel()
        downloadTask = nil
    }

    func deleteModel(_ model: LiteRTModelDescriptor) {
        try? modelStore.deleteModel(model.id)
        AppDiagnostics.shared.record(
            "ask_image: model deleted",
            category: "ask_image",
            metadata: ["model": model.id]
        )
    }

    // MARK: - Image Attachment

    func handlePickedImage(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                AppDiagnostics.shared.record(
                    "ask_image: image load failed",
                    category: "ask_image"
                )
                return
            }

            guard let uiImage = UIImage(data: data) else {
                AppDiagnostics.shared.record(
                    "ask_image: image decode failed",
                    category: "ask_image"
                )
                return
            }

            // Write full-size JPEG via temp file manager
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.85),
                  let imageURL = try? AskImageTempFiles.store(jpegData) else {
                AppDiagnostics.shared.record(
                    "ask_image: image write failed",
                    category: "ask_image"
                )
                return
            }

            // Generate thumbnail for display
            let thumbnailData = generateThumbnail(from: uiImage, maxSize: 320)

            attachment = AskImageAttachment(
                originalURL: imageURL,
                thumbnailData: thumbnailData
            )

            AppDiagnostics.shared.record(
                "ask_image: image attached",
                category: "ask_image",
                metadata: [
                    "imageSize": "\(data.count)",
                    "width": "\(Int(uiImage.size.width))",
                    "height": "\(Int(uiImage.size.height))",
                ]
            )
        }
    }

    private func generateThumbnail(from image: UIImage, maxSize: CGFloat) -> Data? {
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumbnailImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return thumbnailImage.jpegData(compressionQuality: 0.7)
    }

    // MARK: - Prompt & Generation

    func sendPrompt(_ prompt: String) {
        guard let model = selectedModel else { return }

        let userMessage = AskImageMessage(role: .user, text: prompt)
        messages.append(userMessage)

        let assistantMessage = AskImageMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        sessionState = .generating

        let imagePath = attachment?.originalURL.path ?? ""

        AppDiagnostics.shared.record(
            "ask_image: prompt submitted",
            category: "ask_image",
            metadata: [
                "model": model.id,
                "promptLength": "\(prompt.count)",
                "hasImage": "\(attachment != nil)",
            ]
        )

        generationTask = Task { [runtime] in
            let startTime = CFAbsoluteTimeGetCurrent()
            var isFirstChunk = true

            for await chunk in runtime.generate(prompt: prompt, imagePath: imagePath) {
                guard !Task.isCancelled else { break }

                if isFirstChunk {
                    let ttft = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    AppDiagnostics.shared.record(
                        "ask_image: first token",
                        category: "ask_image",
                        metadata: ["ttftMs": "\(ttft)"]
                    )
                    isFirstChunk = false
                }

                messages[assistantIndex].text += chunk
            }

            messages[assistantIndex].isStreaming = false
            sessionState = .readyForInput

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let outputLength = messages[assistantIndex].text.count
            AppDiagnostics.shared.record(
                "ask_image: generation completed",
                category: "ask_image",
                metadata: [
                    "totalMs": "\(totalMs)",
                    "outputLength": "\(outputLength)",
                ]
            )
        }
    }

    // MARK: - Cancel & Reset

    func cancelGeneration() {
        runtime.cancelGeneration()
        generationTask?.cancel()
        generationTask = nil

        if let lastIndex = messages.indices.last, messages[lastIndex].isStreaming {
            messages[lastIndex].isStreaming = false
            if messages[lastIndex].text.isEmpty {
                messages.removeLast()
            }
        }
        sessionState = .readyForInput

        AppDiagnostics.shared.record(
            "ask_image: generation cancelled",
            category: "ask_image"
        )
    }

    func resetSession() {
        cancelGeneration()
        messages = []
        attachment = nil
        runtime.resetConversation()
        AskImageTempFiles.removeAll()
        sessionState = .readyForInput

        AppDiagnostics.shared.record(
            "ask_image: session reset",
            category: "ask_image"
        )
    }

    func retryAfterError() {
        guard let model = selectedModel else { return }
        sessionState = .warmingModel

        AppDiagnostics.shared.record(
            "ask_image: retrying after error",
            category: "ask_image",
            metadata: ["model": model.id]
        )

        Task {
            do {
                try await runtime.prepareModel(at: model.localModelPath.path)
                sessionState = .readyForInput
            } catch {
                sessionState = .error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Previews

#Preview("Coordinator") {
    AskImageCoordinator(onDismiss: {})
}
