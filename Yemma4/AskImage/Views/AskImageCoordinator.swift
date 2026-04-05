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
                onRetryError: { viewModel.retryAfterError() },
                onRedownloadModel: { viewModel.redownloadCurrentModel() },
                toastMessage: viewModel.toastMessage
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

    /// Toast message shown briefly for non-fatal errors (e.g. image decode failure).
    var toastMessage: String?

    // Internal
    private var generationTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    /// Prompt queued while model is still warming up. Auto-sent once ready.
    private var pendingPrompt: String?

    /// Throttle interval for streaming UI updates.
    private static let streamFlushInterval: TimeInterval = 0.05 // 50ms

    /// Maximum image dimension (longest edge) before downscaling.
    private static let maxImageDimension: CGFloat = 1024

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

        // Verify the model file actually exists on disk.
        guard FileManager.default.fileExists(atPath: model.localModelPath.path) else {
            sessionState = .error(.modelFileMissing(model.displayName))
            selectedModel = model
            AppDiagnostics.shared.record(
                "ask_image: model file missing",
                category: "ask_image",
                metadata: ["model": model.id, "path": model.localModelPath.path]
            )
            return
        }

        selectedModel = model
        sessionState = .warmingModel
        pendingPrompt = nil

        AppDiagnostics.shared.record(
            "ask_image: model selected",
            category: "ask_image",
            metadata: ["model": model.id]
        )

        Task {
            let prepareStart = CFAbsoluteTimeGetCurrent()
            do {
                try await runtime.prepareModel(at: model.localModelPath.path)
                let prepareMs = Int((CFAbsoluteTimeGetCurrent() - prepareStart) * 1000)
                sessionState = .readyForInput
                AppDiagnostics.shared.record(
                    "ask_image: model ready",
                    category: "ask_image",
                    metadata: ["model": model.id, "prepareMs": "\(prepareMs)"]
                )

                // If the user queued a prompt while warming, send it now.
                if let queued = pendingPrompt {
                    pendingPrompt = nil
                    sendPrompt(queued)
                }
            } catch {
                sessionState = .error(.runtimeInitFailed(error.localizedDescription))
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
        pendingPrompt = nil
        Task {
            await runtime.unloadModel()
        }
        selectedModel = nil
        sessionState = .idle
        messages = []
        attachment = nil
        toastMessage = nil

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

    /// Re-download the current model after a "file missing/corrupted" error.
    func redownloadCurrentModel() {
        guard let model = selectedModel else { return }
        // Clean up any partial file
        try? modelStore.deleteModel(model.id)
        sessionState = .idle
        selectedModel = nil

        // Kick off download, then the user can re-select.
        downloadModel(model)

        AppDiagnostics.shared.record(
            "ask_image: re-download initiated",
            category: "ask_image",
            metadata: ["model": model.id]
        )
    }

    // MARK: - Image Attachment

    func handlePickedImage(_ item: PhotosPickerItem) {
        Task {
            let preprocessStart = CFAbsoluteTimeGetCurrent()

            guard let data = try? await item.loadTransferable(type: Data.self) else {
                showToast("Could not load the selected image.")
                AppDiagnostics.shared.record(
                    "ask_image: image load failed",
                    category: "ask_image"
                )
                return
            }

            // Move heavy image work off the main thread.
            let result: ImagePreprocessResult? = await Task.detached(priority: .userInitiated) {
                guard let uiImage = UIImage(data: data) else { return nil }

                // Downscale if the image exceeds the max dimension.
                let processed = Self.downscaleIfNeeded(
                    uiImage,
                    maxDimension: Self.maxImageDimension
                )

                // JPEG encode for the runtime.
                guard let jpegData = processed.jpegData(compressionQuality: 0.85) else {
                    return nil
                }

                // Thumbnail for display (always small).
                let thumbnailData = Self.generateThumbnail(from: processed, maxSize: 320)

                return ImagePreprocessResult(
                    jpegData: jpegData,
                    thumbnailData: thumbnailData,
                    originalWidth: Int(uiImage.size.width),
                    originalHeight: Int(uiImage.size.height),
                    processedWidth: Int(processed.size.width),
                    processedHeight: Int(processed.size.height)
                )
            }.value

            guard let result else {
                showToast("Could not decode the image. Try a different photo.")
                AppDiagnostics.shared.record(
                    "ask_image: image decode failed",
                    category: "ask_image"
                )
                return
            }

            // Write to temp file (light I/O, fine on main).
            guard let imageURL = try? AskImageTempFiles.store(result.jpegData) else {
                showToast("Could not save the image for processing.")
                AppDiagnostics.shared.record(
                    "ask_image: image write failed",
                    category: "ask_image"
                )
                return
            }

            attachment = AskImageAttachment(
                originalURL: imageURL,
                thumbnailData: result.thumbnailData
            )

            let preprocessMs = Int((CFAbsoluteTimeGetCurrent() - preprocessStart) * 1000)
            AppDiagnostics.shared.record(
                "ask_image: image attached",
                category: "ask_image",
                metadata: [
                    "originalSize": "\(data.count)",
                    "originalDim": "\(result.originalWidth)x\(result.originalHeight)",
                    "processedDim": "\(result.processedWidth)x\(result.processedHeight)",
                    "jpegBytes": "\(result.jpegData.count)",
                    "preprocessMs": "\(preprocessMs)",
                ]
            )
        }
    }

    /// Downscale a UIImage if its longest edge exceeds `maxDimension`.
    /// Returns the original image if no downscaling is needed.
    private static func downscaleIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maxDimension else { return image }

        let scale = maxDimension / longestEdge
        let newSize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func generateThumbnail(from image: UIImage, maxSize: CGFloat) -> Data? {
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

        // If the model is still warming up, queue the prompt for auto-send.
        if sessionState == .warmingModel {
            pendingPrompt = prompt
            let userMessage = AskImageMessage(role: .user, text: prompt)
            messages.append(userMessage)
            AppDiagnostics.shared.record(
                "ask_image: prompt queued (model warming)",
                category: "ask_image",
                metadata: ["promptLength": "\(prompt.count)"]
            )
            return
        }

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
            var buffer = ""
            var lastFlush = startTime
            var ttftMs: Int?

            for await chunk in runtime.generate(prompt: prompt, imagePath: imagePath) {
                guard !Task.isCancelled else { break }

                if isFirstChunk {
                    ttftMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                    AppDiagnostics.shared.record(
                        "ask_image: first token",
                        category: "ask_image",
                        metadata: ["ttftMs": "\(ttftMs!)"]
                    )
                    isFirstChunk = false
                }

                buffer += chunk

                // Throttled UI updates: flush every 50ms to avoid excessive redraws.
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastFlush >= Self.streamFlushInterval {
                    messages[assistantIndex].text += buffer
                    buffer = ""
                    lastFlush = now
                }
            }

            // Flush any remaining buffer.
            if !buffer.isEmpty {
                messages[assistantIndex].text += buffer
            }

            messages[assistantIndex].isStreaming = false

            // Check for empty output (generation failure that produced nothing).
            if messages[assistantIndex].text.isEmpty && !Task.isCancelled {
                sessionState = .error(.generationEmptyOutput)
                AppDiagnostics.shared.record(
                    "ask_image: generation produced empty output",
                    category: "ask_image"
                )
                return
            }

            sessionState = .readyForInput

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let outputLength = messages[assistantIndex].text.count
            let charsPerSec = totalMs > 0 ? Double(outputLength) / (Double(totalMs) / 1000.0) : 0
            AppDiagnostics.shared.record(
                "ask_image: generation completed",
                category: "ask_image",
                metadata: [
                    "totalMs": "\(totalMs)",
                    "outputLength": "\(outputLength)",
                    "charsPerSec": String(format: "%.1f", charsPerSec),
                    "ttftMs": "\(ttftMs ?? -1)",
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
        pendingPrompt = nil
        messages = []
        attachment = nil
        toastMessage = nil
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

        // For model-file-missing errors, trigger re-download instead of retry.
        if case .error(.modelFileMissing) = sessionState {
            redownloadCurrentModel()
            return
        }

        sessionState = .warmingModel
        pendingPrompt = nil

        AppDiagnostics.shared.record(
            "ask_image: retrying after error",
            category: "ask_image",
            metadata: ["model": model.id]
        )

        Task {
            let prepareStart = CFAbsoluteTimeGetCurrent()
            do {
                try await runtime.prepareModel(at: model.localModelPath.path)
                let prepareMs = Int((CFAbsoluteTimeGetCurrent() - prepareStart) * 1000)
                sessionState = .readyForInput
                AppDiagnostics.shared.record(
                    "ask_image: retry succeeded",
                    category: "ask_image",
                    metadata: ["prepareMs": "\(prepareMs)"]
                )
            } catch {
                sessionState = .error(.runtimeInitFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toastMessage = message
        // Auto-dismiss after 3 seconds.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Image Preprocessing Result

/// Container for results of off-main-thread image preprocessing.
private struct ImagePreprocessResult: Sendable {
    let jpegData: Data
    let thumbnailData: Data?
    let originalWidth: Int
    let originalHeight: Int
    let processedWidth: Int
    let processedHeight: Int
}

// MARK: - Previews

#Preview("Coordinator") {
    AskImageCoordinator(onDismiss: {})
}
