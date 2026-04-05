import Foundation
import Observation
import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class ChatSessionController {

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var draft: String = ""
    var selectedPhotoItems: [PhotosPickerItem] = []
    var pendingAttachments: [Attachment] = []
    var isImportingAttachments: Bool = false
    var generationTask: Task<Void, Never>?
    var generationError: String?
    var memoryAlertMessage: String?
    var toastMessage: String?
    /// ID of the assistant message currently being streamed, nil when not streaming.
    private(set) var streamingMessageID: String?
    private var toastTask: Task<Void, Never>?

    // MARK: - Dependencies

    let llmService: LLMService
    let supportsLocalModelRuntime: Bool

    // MARK: - Init

    init(
        llmService: LLMService,
        supportsLocalModelRuntime: Bool = Yemma4AppConfiguration.supportsLocalModelRuntime
    ) {
        self.llmService = llmService
        self.supportsLocalModelRuntime = supportsLocalModelRuntime
    }

    // MARK: - Computed Properties

    var canSubmitDraft: Bool {
        guard !isImportingAttachments else { return false }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasDraft || !pendingAttachments.isEmpty else { return false }
        return llmService.isTextModelReady || !supportsLocalModelRuntime
    }

    var shouldShowTypingIndicator: Bool {
        guard isGenerating else { return false }
        guard let lastAssistantMessage = messages.last(where: { !$0.user.isCurrentUser }) else {
            return true
        }
        return lastAssistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isGenerating: Bool {
        llmService.isGenerating
    }

    // MARK: - Actions

    func submitDraft() {
        let trimmedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard llmService.isTextModelReady || !supportsLocalModelRuntime else {
            AppDiagnostics.shared.record("Send blocked because model is not loaded", category: "ui")
            generationError = "The model is not loaded yet."
            return
        }
        guard !llmService.isGenerating else {
            AppDiagnostics.shared.record("Send blocked because generation is already active", category: "ui")
            showToast("Please wait for Yemma 4 to finish")
            return
        }

        AppDiagnostics.shared.record(
            "User submitted prompt",
            category: "ui",
            metadata: [
                "chars": trimmedText.count,
                "images": pendingAttachments.count,
                "existingMessages": messages.count
            ]
        )
        draft = ""
        Task { @MainActor in
            let attachments = pendingAttachments
            pendingAttachments = []
            selectedPhotoItems = []
            await handlePrompt(trimmedText, attachments: attachments)
        }
    }

    func handlePrompt(_ trimmedText: String, attachments: [Attachment]) async {
        triggerSendHaptic()
        await stopGeneration()

        let history = conversationHistory(from: messages)
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            user: .user,
            status: .sent,
            createdAt: Date(),
            text: trimmedText,
            attachments: attachments
        )
        messages.append(userMessage)

        let prompt = promptInput(from: userMessage)

        let assistantID = UUID().uuidString
        messages.append(
            ChatMessage(
                id: assistantID,
                user: .yemma,
                status: .sent,
                createdAt: Date(),
                text: "",
                attachments: []
            )
        )

        generationError = nil
        memoryAlertMessage = nil
        generationTask = Task {
            await streamReply(prompt: prompt, history: history, assistantID: assistantID)
        }
    }

    func streamReply(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
        assistantID: String
    ) async {
        var streamingPolicy = StreamingUpdatePolicy()

        streamingMessageID = assistantID

        defer {
            streamingMessageID = nil
            Task { @MainActor in
                self.generationTask = nil
            }
        }

        for await token in llmService.generate(prompt: prompt, history: history) {
            let update = streamingPolicy.append(token)

            if let visibleText = update.visibleText {
                updateMessageText(id: assistantID, text: visibleText)
            }

            if update.shouldStop {
                await llmService.stopGeneration()
                break
            }
        }

        let finalText = streamingPolicy.finalize()
        finalizeAssistantMessage(id: assistantID, text: finalText)

        if let lastError = llmService.lastError {
            if isLowMemoryError(lastError) {
                self.memoryAlertMessage = "Your device ran low on memory. Try a shorter conversation."
            } else {
                self.generationError = lastError
            }
        }
    }

    func stopGeneration() async {
        generationTask?.cancel()
        generationTask = nil
        await llmService.stopGeneration()
    }

    func clearConversation() async {
        AppDiagnostics.shared.record(
            "Conversation cleared",
            category: "ui",
            metadata: ["previousMessages": messages.count]
        )
        await stopGeneration()
        llmService.clearCachedPrefix()
        messages.removeAll()
        draft = ""
        pendingAttachments.removeAll()
        selectedPhotoItems.removeAll()
        isImportingAttachments = false
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
    }

    func runDebugScenario(_ scenario: DebugInferenceScenario) async {
        AppDiagnostics.shared.record(
            "Debug scenario triggered",
            category: "debug",
            metadata: ["scenario": scenario.rawValue]
        )
        await clearConversation()

        if let sampleTranscript = scenario.sampleTranscript {
            messages = [
                .previewMessage(user: .user, text: sampleTranscript.user),
                .previewMessage(user: .yemma, text: sampleTranscript.assistant)
            ]
            return
        }

        guard let prompt = scenario.prompt else {
            return
        }

        if !supportsLocalModelRuntime {
            messages = [
                .previewMessage(user: .user, text: prompt),
                .previewMessage(
                    user: .yemma,
                    text: "Simulator mode uses mocked replies. Run this debug scenario on a physical iPhone to judge real inference quality."
                )
            ]
            return
        }

        guard llmService.isTextModelReady else {
            messages = [
                .previewMessage(user: .user, text: prompt),
                .previewMessage(
                    user: .yemma,
                    text: "Load the local model first, then rerun this debug scenario."
                )
            ]
            return
        }

        await handlePrompt(prompt, attachments: [])
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message

        toastTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.7))
            } catch {
                return
            }

            await MainActor.run {
                toastMessage = nil
                toastTask = nil
            }
        }
    }

    func displayText(for message: ChatMessage) -> String {
        if !message.user.isCurrentUser, message.text.isEmpty, llmService.isGenerating {
            return " "
        }
        return message.text
    }

    func shouldRenderText(for message: ChatMessage, text: String) -> Bool {
        if message.user.isCurrentUser {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !text.isEmpty
    }

    func importSelectedPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        isImportingAttachments = true
        defer {
            isImportingAttachments = false
            selectedPhotoItems = []
        }

        var importedAttachments: [Attachment] = []
        var failedCount = 0

        for item in items {
            do {
                if let attachment = try await makeAttachment(from: item) {
                    importedAttachments.append(attachment)
                }
            } catch {
                failedCount += 1
            }
        }

        if !importedAttachments.isEmpty {
            pendingAttachments.append(contentsOf: importedAttachments)
        }

        if failedCount > 0 {
            showToast("Some images could not be added")
        }
    }

    func makeAttachment(from item: PhotosPickerItem) async throws -> Attachment? {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }

        #if canImport(UIKit)
        guard let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let encodedData: Data
        let fileExtension: String

        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            encodedData = jpegData
            fileExtension = "jpg"
        } else if let pngData = image.pngData() {
            encodedData = pngData
            fileExtension = "png"
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        let encodedData = data
        let fileExtension = "bin"
        #endif

        let fileURL = try storeAttachmentData(encodedData, fileExtension: fileExtension)
        return Attachment(id: UUID().uuidString, url: fileURL, type: .image)
    }

    func storeAttachmentData(_ data: Data, fileExtension: String) throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("chat-attachments", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    // MARK: - Private Helpers

    private func promptInput(from message: ChatMessage) -> PromptMessageInput {
        PromptMessageInput(
            role: message.user.isCurrentUser ? "user" : "assistant",
            text: message.text,
            images: message.attachments.compactMap { attachment in
                guard attachment.type == .image, attachment.full.isFileURL else {
                    return nil
                }
                return PromptImageAsset(
                    id: attachment.id,
                    filePath: attachment.full.path
                )
            }
        )
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        messages.compactMap { message in
            let prompt = promptInput(from: message)
            if prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.images.isEmpty {
                return nil
            }
            return prompt
        }
    }

    private func updateMessageText(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func finalizeAssistantMessage(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        if text.isEmpty {
            messages.remove(at: index)
            return
        }

        messages[index].text = text
    }

    private func isLowMemoryError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("memory")
            || lowercased.contains("oom")
            || lowercased.contains("out of memory")
    }

    private func triggerSendHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

// MARK: - Preview Message Helper

private extension ChatMessage {
    static func previewMessage(user: ExyteChat.User, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            user: user,
            status: .sent,
            createdAt: .now,
            text: text,
            attachments: []
        )
    }
}
