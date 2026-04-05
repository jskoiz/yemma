import SwiftUI

/// Top-level coordinator for the Ask Image feature.
/// Manages navigation between the model-selection home and the active session.
struct AskImageCoordinator: View {
    @State private var runtime: StubAskImageRuntime = StubAskImageRuntime()
    @State private var modelStore: StubAskImageModelStore = StubAskImageModelStore()

    @State private var selectedModel: LiteRTModelDescriptor?
    @State private var sessionState: AskImageSessionState = .idle
    @State private var messages: [AskImageMessage] = []
    @State private var attachment: AskImageAttachment?
    @State private var generationTask: Task<Void, Never>?

    let onDismiss: () -> Void

    var body: some View {
        if let model = selectedModel {
            AskImageSessionView(
                modelName: model.displayName,
                sessionState: sessionState,
                messages: messages,
                attachment: attachment,
                onSend: { prompt in sendPrompt(prompt, model: model) },
                onAttachImage: { attachStubImage() },
                onCancel: { cancelGeneration() },
                onNewSession: { resetSession() },
                onDismiss: { selectedModel = nil }
            )
        } else {
            AskImageHomeView(
                models: modelStore.availableModels,
                modelState: { modelStore.state(for: $0) },
                onSelectModel: { selectModel($0) },
                onDownloadModel: { downloadModel($0) },
                onDeleteModel: { deleteModel($0) },
                onDismiss: onDismiss
            )
        }
    }

    // MARK: - Actions

    private func selectModel(_ model: LiteRTModelDescriptor) {
        guard modelStore.state(for: model.id).isDownloaded else { return }
        selectedModel = model
        sessionState = .warmingModel

        Task {
            do {
                try await runtime.prepareModel(at: model.localModelPath.path)
                sessionState = .readyForInput
            } catch {
                sessionState = .error(error.localizedDescription)
            }
        }

        AppDiagnostics.shared.record(
            "ask_image: model selected",
            category: "ask_image",
            metadata: ["model": model.id]
        )
    }

    private func downloadModel(_ model: LiteRTModelDescriptor) {
        Task {
            try? await modelStore.download(model)
        }
    }

    private func deleteModel(_ model: LiteRTModelDescriptor) {
        try? modelStore.deleteModel(model.id)
    }

    private func sendPrompt(_ prompt: String, model: LiteRTModelDescriptor) {
        let userMessage = AskImageMessage(role: .user, text: prompt)
        messages.append(userMessage)

        var assistantMessage = AskImageMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        sessionState = .generating

        let imagePath = attachment?.originalURL.path ?? "/tmp/placeholder.jpg"

        AppDiagnostics.shared.record(
            "ask_image: prompt submitted",
            category: "ask_image",
            metadata: ["promptLength": "\(prompt.count)"]
        )

        generationTask = Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            var isFirstChunk = true

            for await chunk in runtime.generate(prompt: prompt, imagePath: imagePath) {
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
            AppDiagnostics.shared.record(
                "ask_image: generation completed",
                category: "ask_image",
                metadata: [
                    "totalMs": "\(totalMs)",
                    "outputLength": "\(messages[assistantIndex].text.count)",
                ]
            )
        }
    }

    private func cancelGeneration() {
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
    }

    private func resetSession() {
        cancelGeneration()
        messages = []
        attachment = nil
        runtime.resetConversation()
        sessionState = .readyForInput
    }

    private func attachStubImage() {
        attachment = AskImageAttachment(
            originalURL: URL(fileURLWithPath: "/tmp/stub-image.jpg")
        )

        AppDiagnostics.shared.record(
            "ask_image: image attached",
            category: "ask_image"
        )
    }
}

// MARK: - Previews

#Preview("Coordinator") {
    AskImageCoordinator(onDismiss: {})
}
