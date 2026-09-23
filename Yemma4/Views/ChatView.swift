import Observation
import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore
    @AppStorage(DebugPreferences.showsAssistantResponseStatsKey) private var showsAssistantResponseStats = false

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var messages: [ChatMessage] = []
    @State private var assistantResponseStats: [String: GenerationDebugStats] = [:]
    @State private var draft = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [Attachment] = []
    @State private var isImportingAttachments = false
    @State private var generationTask: Task<Void, Never>?
    @State private var activeGenerationSessionID: UUID?
    @State private var generationError: String?
    @State private var memoryAlertMessage: String?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var isSidebarOpen = false
    @State private var isShowingPhotoPicker = false
    @State private var showQwenImageRequirement = false
    @State private var showArchiveBrowser = false
    @State private var loadedConversationID: UUID?
    @State private var isRestoringConversation = false
    @State private var conversationSaveTask: Task<Void, Never>?
    @State private var sharePayload: SharePayload?
    @FocusState private var isComposerFocused: Bool

    // MARK: - Streaming state
    /// The ID of the assistant message currently being streamed.
    @State private var streamingMessageID: String?
    /// Whether the newest transcript content is currently in view.
    @State private var isPinnedToBottom = true
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var latestContentOverflow: CGFloat = 0
    @State private var completedAssistantMessageIDs: Set<String> = []
    @State private var lastStarterPromptIndexByID: [String: Int] = [:]

    private let taskStarters = ChatStarter.defaults

    private let onShowOnboarding: () -> Void
    private let onRetryModelLoad: (() -> Void)?

    public init(
        initialMessages: [ChatMessage] = [],
        onShowOnboarding: @escaping () -> Void = {},
        onRetryModelLoad: (() -> Void)? = nil
    ) {
        _messages = State(initialValue: initialMessages)
        self.onShowOnboarding = onShowOnboarding
        self.onRetryModelLoad = onRetryModelLoad
    }

    private var appSetup: AppSetupSnapshot {
        AppSetupSnapshot(
            supportsLocalModelRuntime: supportsLocalModelRuntime,
            modelDownloader: modelDownloader,
            llmService: llmService
        )
    }

    public var body: some View {
        NavigationStack {
            ChatNavigationShell(isSidebarOpen: $isSidebarOpen) {
                mainShell
            } sidebar: {
                ChatSidebarView(
                    currentConversationID: loadedConversationID,
                    title: "Yemma 4",
                    subtitle: "Chats and quick controls",
                    showsChatManagement: true,
                    onSelectConversation: { conversationID in
                        Task { @MainActor in
                            await switchConversation(to: conversationID)
                            closeSidebar()
                        }
                    },
                    onStartFresh: {
                        Task { @MainActor in
                            await startFreshConversation()
                            closeSidebar()
                        }
                    },
                    onShowOnboarding: {
                        closeSidebar()
                        onShowOnboarding()
                    },
                    onRunDebugScenario: { scenario in
                        closeSidebar()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            await runDebugScenario(scenario)
                        }
                    },
                    onOpenArchive: {
                        closeSidebar()
                        showArchiveBrowser = true
                    },
                    onClose: {
                        closeSidebar()
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showArchiveBrowser) {
                ConversationBrowserSheet(
                    scope: .archive(recentLimit: 5),
                    currentConversationID: loadedConversationID,
                    onSelectConversation: { conversationID in
                        Task { @MainActor in
                            await switchConversation(to: conversationID)
                            showArchiveBrowser = false
                        }
                    },
                    onStartFresh: {
                        Task { @MainActor in
                            await startFreshConversation()
                            showArchiveBrowser = false
                        }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
            }
            .onAppear {
                AppDiagnostics.shared.record(
                    "startup: view_appeared",
                    category: "startup",
                    metadata: ["view": "ChatView", "elapsedMs": StartupTiming.elapsedMs()]
                )
            }
            .task {
                await restoreConversationIfNeeded(force: true)
            }
            .onDisappear {
                Task { @MainActor in
                    persistConversationNow()
                    await stopGeneration()
                }
            }
            .onChange(of: conversationStore.currentConversationID) { _, _ in
                Task { @MainActor in
                    await restoreConversationIfNeeded(force: true)
                }
            }
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { @MainActor in
                    await importSelectedPhotos(from: newItems)
                }
            }
            .onChange(of: draft) { _, _ in
                scheduleConversationSave()
            }
            .onChange(of: pendingAttachments.map(\.id)) { _, _ in
                scheduleConversationSave()
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: toastMessage)
            .alert("Chat Could Not Be Saved", isPresented: Binding(
                get: { conversationStore.storageError != nil },
                set: { if !$0 { conversationStore.storageError = nil } }
            )) {
                Button("Try Again") {
                    conversationStore.storageError = nil
                    persistConversationNow()
                }
                Button("OK", role: .cancel) { conversationStore.storageError = nil }
            } message: {
                Text(conversationStore.storageError ?? "Please try saving again.")
            }
            .alert(
                "Generation Failed",
                isPresented: Binding(
                    get: { generationError != nil },
                    set: { if !$0 { generationError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    generationError = nil
                }
            } message: {
                Text(generationError ?? "The model could not generate a response.")
            }
            .alert(
                "Low Memory",
                isPresented: Binding(
                    get: { memoryAlertMessage != nil },
                    set: { if !$0 { memoryAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    memoryAlertMessage = nil
                }
            } message: {
                Text(memoryAlertMessage ?? "Your device ran low on memory. Try a shorter conversation.")
            }
            .confirmationDialog(
                "Use Qwen3.5 4B for image chat?",
                isPresented: $showQwenImageRequirement,
                titleVisibility: .visible
            ) {
                Button("Use Qwen3.5 4B") {
                    selectQwenRuntime()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Qwen3.5 4B adds image understanding through an optional 3.05 GB download. Selecting it does not start the download.")
            }
            .sheet(item: $sharePayload) { payload in
                ActivityShareSheet(activityItems: [payload.text])
            }
        }
    }

    private var mainShell: some View {
        ZStack {
            AppBackground()

            ProgressiveBlurHeaderHost(
                initialHeaderHeight: 68,
                maxBlurRadius: 10,
                fadeExtension: 60,
                tintOpacityTop: 0.26,
                tintOpacityMiddle: 0.08
            ) { headerHeight in
                conversationContent(topInset: headerHeight)
            } header: {
                ChatTopBar(onToggleSidebar: toggleSidebar, onStartFresh: {
                    Task { @MainActor in await startFreshConversation() }
                })
            }

            if let toastMessage {
                VStack {
                    Spacer()
                    ChatToast(message: toastMessage)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        .padding(.bottom, 116)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerSection
        }
        .allowsHitTesting(!shouldBlockStartupInteraction)
        .overlay {
            if shouldShowStartupOverlay {
                startupLoadingOverlay
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: shouldShowStartupOverlay)
    }

    // MARK: - Conversation content

    private func conversationContent(topInset: CGFloat) -> some View {
        ChatTranscriptView(
            messages: messages,
            appSetup: appSetup,
            taskStarters: taskStarters,
            streamingMessageID: streamingMessageID,
            isGenerating: llmService.isGenerating,
            completedAssistantMessageIDs: completedAssistantMessageIDs,
            assistantResponseStats: assistantResponseStats,
            showsAssistantResponseStats: showsAssistantResponseStats,
            topInset: topInset,
            isPinnedToBottom: $isPinnedToBottom,
            scrollViewportHeight: $scrollViewportHeight,
            latestContentOverflow: $latestContentOverflow,
            onTapBackground: handleConversationBackgroundTap,
            onJumpToLatest: recordJumpToLatest,
            onSelectStarter: selectStarter,
            primarySetupActionTitle: primarySetupActionTitle,
            primarySetupAction: primarySetupAction,
            shouldShowMessageActionStrip: shouldShowMessageActionStrip(for:index:),
            canRetryAssistantResponse: canRetryAssistantResponse(_:index:),
            onCopyMessageText: copyMessageText,
            onShareMessageText: shareMessageText,
            onRetryAssistantResponse: triggerRetryAssistantResponse,
            onRefineAssistantResponse: triggerRefineAssistantResponse
        )
    }

    private func handleConversationBackgroundTap() {
        if isSidebarOpen {
            closeSidebar()
            return
        }
        isComposerFocused = false
    }

    private func recordJumpToLatest() {
        AppDiagnostics.shared.record(
            "Transcript jumped to latest",
            category: "ui",
            metadata: ["messages": messages.count]
        )
    }

    // MARK: - Composer

    private var composerSection: some View {
        ChatComposerView(
            appSetup: appSetup,
            draft: $draft,
            selectedPhotoItems: $selectedPhotoItems,
            pendingAttachments: $pendingAttachments,
            isImportingAttachments: $isImportingAttachments,
            isShowingPhotoPicker: $isShowingPhotoPicker,
            isGenerating: llmService.isGenerating,
            canSubmitDraft: canSubmitDraft,
            shouldShowTypingIndicator: shouldShowTypingIndicator,
            isComposerFocused: $isComposerFocused,
            supportsImageInput: llmService.supportsImageInput || !supportsLocalModelRuntime,
            inputBlockReason: imageInputBlockReason,
            inputBlockActionTitle: imageInputBlockReason == nil ? nil : "Use Qwen",
            inputBlockAction: imageInputBlockReason == nil ? nil : selectQwenRuntime,
            primarySetupActionTitle: primarySetupActionTitle,
            primarySetupAction: primarySetupAction,
            onUnavailableImageInput: {
                showQwenImageRequirement = true
            },
            onSubmitDraft: submitDraft,
            onStopGeneration: triggerStopGeneration,
            onRemoveAttachment: removePendingAttachment
        )
    }

    private var shouldShowTypingIndicator: Bool {
        guard llmService.isGenerating else { return false }
        guard let lastAssistantMessage = messages.last(where: { !$0.user.isCurrentUser }) else { return true }
        return lastAssistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitDraft: Bool {
        guard !isImportingAttachments else { return false }
        guard !llmService.isSwitchingRuntime else { return false }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasDraft || !pendingAttachments.isEmpty else { return false }
        if !appSetup.supportsLocalModelRuntime {
            return true
        }
        return appSetup.isTextModelReady && imageInputBlockReason == nil
    }

    private var imageInputBlockReason: String? {
        guard supportsLocalModelRuntime, !llmService.supportsImageInput else {
            return nil
        }

        if !pendingAttachments.isEmpty {
            return "This draft contains images. Keep it here and switch to Qwen3.5 4B to send it."
        }

        if messages.contains(where: { !$0.attachments.isEmpty }) {
            return "This chat contains images. Start a new text chat or switch to Qwen3.5 4B."
        }

        return nil
    }

    private func selectQwenRuntime() {
        Task { @MainActor in
            let didSelect = await llmService.selectRuntime(.qwen35)
            if !didSelect {
                showToast(llmService.lastError ?? "Try switching again in a moment")
            }
        }
    }

    private var primarySetupActionTitle: String? {
        appSetup.chatRecoveryAction?.title
    }

    private var primarySetupAction: (() -> Void)? {
        switch appSetup.chatRecoveryAction {
        case .resumeDownload, .retryDownload:
            return {
                Task { await modelDownloader.downloadModel() }
            }
        case .retryModelDeletion:
            return {
                Task { _ = await modelDownloader.deleteModel() }
            }
        case .retryModelLoad:
            return onRetryModelLoad
        case nil:
            return nil
        }
    }

    private var shouldShowStartupOverlay: Bool {
        appSetup.shouldShowStartupOverlay
    }

    private var shouldBlockStartupInteraction: Bool {
        shouldShowStartupOverlay || isSidebarOpen
    }

    private var startupLoadingOverlay: some View {
        ChatStartupLoadingOverlayView(message: startupLoadingMessage)
    }

    private var startupLoadingMessage: String {
        if appSetup.isDeletingModel {
            return "Removing the downloaded model from this iPhone."
        }

        switch llmService.modelLoadStage {
        case .idle, .preparingRuntime:
            return "Getting Yemma ready on this iPhone."
        case .loadingModel:
            return "Loading your on-device model."
        case .activatingModel:
            return "Finishing the last few setup steps."
        case .ready:
            return "Yemma is ready."
        case .failed:
            return "Yemma could not finish getting ready."
        }
    }

    private func selectStarter(_ starter: ChatStarter) {
        if starter.behavior == .promptAndPickImage,
           supportsLocalModelRuntime,
           !llmService.supportsImageInput
        {
            isComposerFocused = false
            showQwenImageRequirement = true
            return
        }

        draft = resolvedPrompt(for: starter)
        if starter.behavior == .promptAndPickImage {
            isComposerFocused = false
            isShowingPhotoPicker = true
        } else if starter.sendsImmediately {
            isComposerFocused = false
            Task { @MainActor in
                submitDraft()
            }
        } else {
            isComposerFocused = true
        }
        AppDiagnostics.shared.record(
            "Starter selected",
            category: "ui",
            metadata: [
                "starter": starter.title,
                "messages": messages.count,
                "textReady": llmService.isTextModelReady
            ]
        )
        scheduleConversationSave()
    }

    private func resolvedPrompt(for starter: ChatStarter) -> String {
        let prompts = starter.prompts
        guard let firstPrompt = prompts.first else {
            return starter.prompt
        }

        guard prompts.count > 1 else {
            lastStarterPromptIndexByID[starter.id] = 0
            return firstPrompt
        }

        let previousIndex = lastStarterPromptIndexByID[starter.id]
        let candidateIndices = prompts.indices.filter { $0 != previousIndex }
        let nextIndex = candidateIndices.randomElement() ?? 0
        lastStarterPromptIndexByID[starter.id] = nextIndex
        return prompts[nextIndex]
    }

    private func indexForMessage(_ message: ChatMessage) -> Int {
        messages.firstIndex(where: { $0.id == message.id }) ?? -1
    }

    private func latestAssistantMessageIndex() -> Int? {
        messages.lastIndex(where: { !$0.user.isCurrentUser })
    }

    private func canRetryAssistantResponse(_ message: ChatMessage, index: Int) -> Bool {
        guard !llmService.isGenerating, !message.user.isCurrentUser else { return false }
        guard index >= 0, index == latestAssistantMessageIndex(), index == messages.indices.last else { return false }
        if supportsLocalModelRuntime,
           !llmService.supportsImageInput,
           messages.prefix(index).contains(where: { !$0.attachments.isEmpty })
        {
            return false
        }
        return userPromptIndex(forAssistantAt: index) != nil
    }

    private func shouldShowMessageActionStrip(for message: ChatMessage, index: Int) -> Bool {
        guard !message.user.isCurrentUser else { return false }
        if message.id == streamingMessageID, llmService.isGenerating {
            return false
        }
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText else { return false }
        return completedAssistantMessageIDs.contains(message.id)
    }

    private func triggerStopGeneration() {
        Task { @MainActor in
            await stopGeneration()
        }
    }

    private func triggerRetryAssistantResponse(_ message: ChatMessage, _ index: Int) {
        Task { @MainActor in
            await retryAssistantResponse(message, index: index)
        }
    }

    private func triggerRefineAssistantResponse(_ message: ChatMessage, _ refinement: AssistantRefinement) {
        Task { @MainActor in
            await refineAssistantResponse(message, refinement: refinement)
        }
    }

    private func removePendingAttachment(_ attachment: Attachment) {
        guard let attachmentIndex = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) else {
            return
        }

        pendingAttachments.remove(at: attachmentIndex)
        // Commit the draft metadata first. If the process is suspended after
        // the unlink, the next launch must not restore a reference to a file
        // that has already been removed.
        guard persistConversationNow() else {
            pendingAttachments.insert(attachment, at: attachmentIndex)
            return
        }
        let removedFileCount = ConversationAttachmentStore.removeFiles(
            at: [attachment.thumbnail, attachment.full]
        )
        if removedFileCount > 0 {
            AppDiagnostics.shared.record(
                "Removed draft attachment files",
                category: "storage",
                metadata: ["files": removedFileCount]
            )
        }
    }

    private func copyMessageText(_ text: String) {
        AppHaptics.success()
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
        AppDiagnostics.shared.record(
            "Message copied",
            category: "ui",
            metadata: ["chars": text.count]
        )
        showToast("Copied")
    }

    private func shareMessageText(_ text: String) {
        AppHaptics.selection()
        AppDiagnostics.shared.record(
            "Message shared",
            category: "ui",
            metadata: ["chars": text.count]
        )
        sharePayload = SharePayload(text: text)
    }

    private func userPromptIndex(forAssistantAt index: Int) -> Int? {
        guard index > 0 else { return nil }
        return messages[..<index].lastIndex(where: \.user.isCurrentUser)
    }

    private func retryAssistantResponse(_ message: ChatMessage, index: Int) async {
        guard canRetryAssistantResponse(message, index: index) else { return }
        guard let userIndex = userPromptIndex(forAssistantAt: index) else { return }
        AppHaptics.selection()

        let prompt = promptInput(from: messages[userIndex])
        let history = conversationHistory(from: Array(messages.prefix(userIndex)))

        AppDiagnostics.shared.record(
            "Assistant response retried",
            category: "ui",
            metadata: [
                "assistantID": message.id,
                "historyCount": history.count
            ]
        )

        await stopGeneration()
        updateMessageText(id: message.id, text: "")
        assistantResponseStats.removeValue(forKey: message.id)
        completedAssistantMessageIDs.remove(message.id)
        generationError = nil
        memoryAlertMessage = nil
        isPinnedToBottom = true
        startGeneration(prompt: prompt, history: history, assistantID: message.id)
        scheduleConversationSave(delayMs: 0)
    }

    private func refineAssistantResponse(_ message: ChatMessage, refinement: AssistantRefinement) async {
        guard !llmService.isGenerating, !message.user.isCurrentUser else { return }
        guard imageInputBlockReason == nil else {
            showToast("Use Qwen3.5 4B for this image chat")
            return
        }
        guard let latestAssistantMessageIndex = latestAssistantMessageIndex() else { return }
        guard message.id == messages[latestAssistantMessageIndex].id else { return }
        AppHaptics.selection()

        AppDiagnostics.shared.record(
            "Assistant refinement requested",
            category: "ui",
            metadata: [
                "assistantID": message.id,
                "refinement": refinement.rawValue
            ]
        )

        draft = ""
        pendingAttachments.removeAll()
        selectedPhotoItems = []
        await handlePrompt(refinement.prompt, attachments: [])
    }

    @MainActor
    private func restoreConversationIfNeeded(force: Bool = false) async {
        let targetConversationID: UUID
        do {
            targetConversationID = try conversationStore.ensureCurrentConversation()
        } catch {
            conversationStore.reportStorageError(error)
            return
        }
        guard force || loadedConversationID != targetConversationID else { return }

        conversationSaveTask?.cancel()
        isRestoringConversation = true
        await stopGeneration()

        guard let snapshot = await conversationStore.loadConversationAsync(id: targetConversationID) else {
            let newConversationID: UUID
            do {
                newConversationID = try conversationStore.startFreshConversation()
            } catch {
                conversationStore.reportStorageError(error)
                isRestoringConversation = false
                return
            }
            guard let fallbackSnapshot = await conversationStore.loadConversationAsync(id: newConversationID) else {
                isRestoringConversation = false
                return
            }
            applyConversationSnapshot(fallbackSnapshot)
            return
        }

        applyConversationSnapshot(snapshot)
    }

    private func applyConversationSnapshot(_ snapshot: ConversationSnapshot) {
        loadedConversationID = snapshot.id
        messages = snapshot.messages
        assistantResponseStats = [:]
        completedAssistantMessageIDs = Set(
            snapshot.messages
                .filter { !$0.user.isCurrentUser && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.id)
        )
        draft = snapshot.draftText
        pendingAttachments = snapshot.draftAttachments
        selectedPhotoItems = []
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
        streamingMessageID = nil
        isPinnedToBottom = true
        isRestoringConversation = false
    }

    @MainActor
    private func switchConversation(to conversationID: UUID) async {
        guard persistConversationNow() else { return }
        guard conversationStore.currentConversationID != conversationID else { return }
        await stopGeneration()
        conversationStore.setCurrentConversation(id: conversationID)
        if let snapshot = conversationStore.loadConversation(id: conversationID) {
            applyConversationSnapshot(snapshot)
        } else {
            await restoreConversationIfNeeded(force: true)
        }
    }

    @MainActor
    private func startFreshConversation() async {
        guard persistConversationNow() else { return }
        await stopGeneration()
        let conversationID: UUID
        do {
            conversationID = try conversationStore.startFreshConversation()
        } catch {
            conversationStore.reportStorageError(error)
            return
        }
        conversationSaveTask?.cancel()
        applyConversationSnapshot(
            ConversationSnapshot(
                id: conversationID,
                title: "New chat",
                messages: [],
                draftText: "",
                draftAttachments: []
            )
        )
        AppDiagnostics.shared.record(
            "Fresh conversation started",
            category: "ui",
            metadata: ["conversationID": conversationID.uuidString]
        )
    }

    private func toggleSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isSidebarOpen.toggle()
        }
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isSidebarOpen = false
        }
    }

    private func scheduleConversationSave(delayMs: Int = 280) {
        guard !isRestoringConversation else { return }

        conversationSaveTask?.cancel()
        conversationSaveTask = Task {
            if delayMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMs))
                } catch {
                    return
                }
            }

            await MainActor.run {
                _ = persistConversationNow()
            }
        }
    }

    @discardableResult
    private func persistConversationNow() -> Bool {
        guard !isRestoringConversation else { return false }
        do {
            let conversationID = try conversationStore.saveConversation(
                id: loadedConversationID,
                messages: messages,
                draftText: draft,
                draftAttachments: pendingAttachments
            )
            loadedConversationID = conversationID
            if conversationStore.currentConversationID == nil {
                conversationStore.setCurrentConversation(id: conversationID)
            }
            return true
        } catch {
            conversationStore.reportStorageError(error)
            return false
        }
    }

    private func promptInput(from message: ChatMessage) -> PromptMessageInput {
        YemmaPromptPlanner.promptInput(from: message)
    }

    // MARK: - Photo import

    @MainActor
    private func importSelectedPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        guard llmService.supportsImageInput || !supportsLocalModelRuntime else {
            selectedPhotoItems = []
            showToast("Image chat requires Qwen3.5 4B")
            return
        }

        isImportingAttachments = true
        defer {
            isImportingAttachments = false
            selectedPhotoItems = []
        }

        var importedAttachments: [Attachment] = []
        var failedCount = 0

        for item in items {
            do {
                if let attachment = try await ChatAttachmentImagePipeline.makeAttachment(from: item) {
                    importedAttachments.append(attachment)
                }
            } catch {
                failedCount += 1
            }
        }

        if !importedAttachments.isEmpty {
            pendingAttachments.append(contentsOf: importedAttachments)
            scheduleConversationSave()
        }

        if failedCount > 0 {
            showToast("Some images could not be added")
        }
    }

    // MARK: - Prompt handling & streaming

    @MainActor
    private func submitDraft() {
        let trimmedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !llmService.isSwitchingRuntime else {
            showToast("The on-device model is still switching")
            return
        }
        guard imageInputBlockReason == nil else {
            showToast("Use Qwen3.5 4B for this image chat")
            return
        }
        guard appSetup.isTextModelReady || !appSetup.supportsLocalModelRuntime else {
            AppDiagnostics.shared.record(
                "Send ignored because model is not ready",
                category: "ui",
                metadata: [
                    "isDownloaded": appSetup.isDownloaded,
                    "isModelLoading": appSetup.isModelLoading,
                    "recoveryAction": appSetup.chatRecoveryAction?.title ?? "none"
                ]
            )
            if let recoveryAction = primarySetupAction, !appSetup.isModelLoading {
                recoveryAction()
            }
            return
        }
        guard !llmService.isGenerating else {
            AppDiagnostics.shared.record("Send blocked because generation is already active", category: "ui")
            showToast("Please wait for the current response")
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
        isComposerFocused = false
        Task { @MainActor in
            let attachments = pendingAttachments
            pendingAttachments = []
            selectedPhotoItems = []
            await handlePrompt(trimmedText, attachments: attachments)
        }
    }

    @MainActor
    private func handlePrompt(_ trimmedText: String, attachments: [Attachment]) async {
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

        assistantResponseStats.removeValue(forKey: assistantID)
        completedAssistantMessageIDs.remove(assistantID)
        isPinnedToBottom = true
        latestContentOverflow = 0
        generationError = nil
        memoryAlertMessage = nil
        startGeneration(prompt: prompt, history: history, assistantID: assistantID)
        scheduleConversationSave(delayMs: 0)
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        YemmaPromptPlanner.conversationHistory(from: messages)
    }

    @MainActor
    private func startGeneration(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
        assistantID: String
    ) {
        let sessionID = UUID()
        activeGenerationSessionID = sessionID
        streamingMessageID = assistantID
        generationTask = Task {
            await streamReply(
                prompt: prompt,
                history: history,
                assistantID: assistantID,
                sessionID: sessionID
            )
        }
    }

    /// Streams tokens into a buffer and flushes visible text at ~50ms intervals or word boundaries.
    private func streamReply(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
        assistantID: String,
        sessionID: UUID
    ) async {
        var streamingPolicy = StreamingUpdatePolicy()
        let previousGenerationID = llmService.lastGenerationStats?.generationID

        defer {
            Task { @MainActor in
                finishGenerationSessionIfCurrent(sessionID: sessionID, assistantID: assistantID)
            }
        }

        for await token in llmService.generate(prompt: prompt, history: history) {
            guard !Task.isCancelled else { return }

            let update = streamingPolicy.append(token)

            let isCurrent = await MainActor.run {
                guard isCurrentGenerationSession(sessionID: sessionID, assistantID: assistantID) else {
                    return false
                }

                if let visibleText = update.visibleText {
                    updateMessageText(id: assistantID, text: visibleText)
                }
                return true
            }
            guard isCurrent, !Task.isCancelled else { return }

            if update.shouldStop {
                await llmService.stopGeneration()
                break
            }
        }

        guard !Task.isCancelled else { return }

        // Final flush — applies full sanitization and switches to markdown rendering
        let finalText = streamingPolicy.finalize()
        let responseStats = llmService.lastGenerationStats?.generationID == previousGenerationID
            ? nil
            : llmService.lastGenerationStats
        await MainActor.run {
            guard isCurrentGenerationSession(sessionID: sessionID, assistantID: assistantID) else {
                return
            }
            finalizeAssistantMessage(
                id: assistantID,
                text: finalText,
                responseStats: responseStats
            )
            persistConversationNow()
        }

        guard !Task.isCancelled else { return }

        if let lastError = llmService.lastError {
            await MainActor.run {
                guard isCurrentGenerationSession(sessionID: sessionID, assistantID: assistantID) else {
                    return
                }
                if isLowMemoryError(lastError) {
                    self.memoryAlertMessage = "Your device ran low on memory. Try a shorter conversation."
                } else {
                    self.generationError = lastError
                }
            }
        }
    }

    @MainActor
    private func updateMessageText(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    @MainActor
    private func finalizeAssistantMessage(
        id: String,
        text: String,
        responseStats: GenerationDebugStats?
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        if text.isEmpty {
            messages.remove(at: index)
            completedAssistantMessageIDs.remove(id)
            assistantResponseStats.removeValue(forKey: id)
            return
        }

        messages[index].text = text
        completedAssistantMessageIDs.insert(id)
        if let responseStats {
            assistantResponseStats[id] = responseStats
        } else {
            assistantResponseStats.removeValue(forKey: id)
        }
    }

    @MainActor
    private func isCurrentGenerationSession(sessionID: UUID, assistantID: String) -> Bool {
        activeGenerationSessionID == sessionID && streamingMessageID == assistantID
    }

    @MainActor
    private func finishGenerationSessionIfCurrent(sessionID: UUID, assistantID: String) {
        guard isCurrentGenerationSession(sessionID: sessionID, assistantID: assistantID) else {
            return
        }

        activeGenerationSessionID = nil
        generationTask = nil
        streamingMessageID = nil
    }

    // MARK: - Conversation management

    @MainActor
    private func clearConversation() async {
        AppDiagnostics.shared.record("Conversation cleared", category: "ui", metadata: ["previousMessages": messages.count])
        await stopGeneration()
        messages.removeAll()
        assistantResponseStats.removeAll()
        completedAssistantMessageIDs.removeAll()
        draft = ""
        pendingAttachments.removeAll()
        selectedPhotoItems.removeAll()
        isImportingAttachments = false
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
        streamingMessageID = nil
        persistConversationNow()
    }

    @MainActor
    private func runDebugScenario(_ scenario: DebugInferenceScenario) async {
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
            persistConversationNow()
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
            persistConversationNow()
            return
        }

        guard llmService.isTextModelReady else {
            messages = [
                .previewMessage(user: .user, text: prompt),
                .previewMessage(
                    user: .yemma,
                    text: "Choose a ready on-device model, then rerun this debug scenario."
                )
            ]
            persistConversationNow()
            return
        }

        await handlePrompt(prompt, attachments: [])
    }

    @MainActor
    private func showToast(_ message: String) {
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

    private func triggerSendHaptic() {
        AppHaptics.softImpact()
    }

    private func isLowMemoryError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("memory") || lowercased.contains("oom") || lowercased.contains("out of memory")
    }

    @MainActor
    private func stopGeneration() async {
        activeGenerationSessionID = nil
        generationTask?.cancel()
        generationTask = nil
        streamingMessageID = nil
        await llmService.stopGeneration()
        persistConversationNow()
    }
}
