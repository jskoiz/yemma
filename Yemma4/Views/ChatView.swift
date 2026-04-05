import Observation
import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [Attachment] = []
    @State private var isImportingAttachments = false
    @State private var generationTask: Task<Void, Never>?
    @State private var generationError: String?
    @State private var memoryAlertMessage: String?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showConversations = false
    @FocusState private var isComposerFocused: Bool

    // MARK: - Streaming state
    /// The ID of the assistant message currently being streamed.
    @State private var streamingMessageID: String?
    /// Monotonic counter bumped each time we flush visible text — drives auto-scroll.
    @State private var streamFlushTick: UInt64 = 0
    /// Whether the transcript is currently close enough to the bottom to auto-scroll.
    @State private var isPinnedToBottom = true
    @State private var scrollViewportHeight: CGFloat = 0

    private let bottomAnchorID = "conversation-bottom-anchor"
    private let scrollCoordinateSpaceName = "conversation-scroll"
    private let pinnedThreshold: CGFloat = 48
    private let releasePinnedThreshold: CGFloat = 120

    private let taskStarters = ChatStarter.defaults

    private let onShowOnboarding: () -> Void

    public init(
        initialMessages: [ChatMessage] = [],
        onShowOnboarding: @escaping () -> Void = {}
    ) {
        _messages = State(initialValue: initialMessages)
        self.onShowOnboarding = onShowOnboarding
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    topBar
                    conversationContent
                }

                if let toastMessage {
                    VStack {
                        Spacer()
                        toastView(message: toastMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 116)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerSection
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    onClearConversation: {
                        Task { @MainActor in
                            await clearConversation()
                        }
                    },
                    onShowOnboarding: {
                        showSettings = false
                        onShowOnboarding()
                    },
                    onRunDebugScenario: { scenario in
                        showSettings = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            await runDebugScenario(scenario)
                        }
                    }
                )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $showConversations) {
                ConversationsView(
                    messages: messages,
                    onStartFresh: {
                        Task { @MainActor in
                            await clearConversation()
                            showConversations = false
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
            .onDisappear {
                Task { @MainActor in
                    await stopGeneration()
                }
            }
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { @MainActor in
                    await importSelectedPhotos(from: newItems)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
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
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                CircleIconButton(systemName: "gearshape", filled: false, action: { showSettings = true })
                CircleIconButton(systemName: "bubble.left.and.bubble.right", filled: false, action: { showConversations = true })
            }
            .padding(4)
            .background(
                Capsule()
                    .fill(AppTheme.controlFill)
                    .overlay(Capsule().stroke(AppTheme.inputBorder, lineWidth: 1))
            )
            .floatingShadow()

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil") {
                Task { @MainActor in
                    await clearConversation()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    // MARK: - Conversation content with auto-scroll

    private var conversationContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            if messages.isEmpty {
                                emptyState
                            } else {
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    messageRow(message, index: index)
                                        .padding(.top, messageTopSpacing(at: index))
                                        .id(message.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background(
                                    GeometryReader { bottomProxy in
                                        Color.clear.preference(
                                            key: ConversationBottomOffsetPreferenceKey.self,
                                            value: bottomProxy.frame(in: .named(scrollCoordinateSpaceName)).maxY
                                        )
                                    }
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, minHeight: 0)
                    }
                    .coordinateSpace(name: scrollCoordinateSpaceName)
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isComposerFocused = false
                    }
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        scrollViewportHeight = geometry.size.height
                    }
                    .onChange(of: geometry.size.height) { _, newHeight in
                        scrollViewportHeight = newHeight
                    }
                    .onPreferenceChange(ConversationBottomOffsetPreferenceKey.self) { bottomMaxY in
                        updatePinnedState(bottomMaxY: bottomMaxY)
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottomIfPinned(proxy: proxy, animated: true)
                    }
                    .onChange(of: streamFlushTick) { _, _ in
                        scrollToBottomIfPinned(proxy: proxy, animated: false)
                    }

                    if shouldShowJumpToLatest {
                        jumpToLatestButton(proxy: proxy)
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var shouldShowJumpToLatest: Bool {
        !messages.isEmpty && !isPinnedToBottom
    }

    private func messageTopSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = messages[index - 1]
        let current = messages[index]
        return previous.user.isCurrentUser == current.user.isCurrentUser ? 4 : 14
    }

    private func scrollToBottomIfPinned(proxy: ScrollViewProxy, animated: Bool) {
        guard isPinnedToBottom else { return }
        scrollToBottom(proxy: proxy, animated: animated)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                action()
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
            }
        }
    }

    private func updatePinnedState(bottomMaxY: CGFloat) {
        guard scrollViewportHeight > 0 else { return }

        let distanceFromBottom = max(bottomMaxY - scrollViewportHeight, 0)
        let nextPinnedState =
            isPinnedToBottom
            ? distanceFromBottom <= releasePinnedThreshold
            : distanceFromBottom <= pinnedThreshold

        guard nextPinnedState != isPinnedToBottom else { return }
        isPinnedToBottom = nextPinnedState

        guard llmService.isGenerating else { return }
        AppDiagnostics.shared.record(
            nextPinnedState ? "Transcript auto-scroll resumed" : "Transcript auto-scroll paused",
            category: "ui",
            metadata: [
                "distanceFromBottom": Int(distanceFromBottom),
                "messages": messages.count
            ]
        )
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            AppDiagnostics.shared.record(
                "Transcript jumped to latest",
                category: "ui",
                metadata: ["messages": messages.count]
            )
            scrollToBottom(proxy: proxy, animated: true)
        } label: {
            Label("Latest", systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .brandCard(cornerRadius: AppTheme.Radius.small)
    }

    private var emptyState: some View {
        EmptyStateView(
            isModelLoaded: llmService.isTextModelReady,
            isModelLoading: llmService.isModelLoading,
            supportsLocalModelRuntime: supportsLocalModelRuntime,
            modelLoadStageText: modelStatusText,
            starters: taskStarters,
            onSelectStarter: selectStarter
        )
    }

    // MARK: - Message rows with grouping

    /// Whether to show the "Yemma 4" label above an assistant message.
    /// Suppressed when the previous message is also from the assistant.
    private func shouldShowAssistantLabel(at index: Int) -> Bool {
        guard !messages[index].user.isCurrentUser else { return false }
        if index == 0 { return true }
        return messages[index - 1].user.isCurrentUser
    }

    private func messageRow(_ message: ChatMessage, index: Int) -> some View {
        HStack {
            if message.user.isCurrentUser {
                Spacer(minLength: 54)
            }

            VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 4) {
                if shouldShowAssistantLabel(at: index) {
                    Text("Yemma 4")
                        .font(AppTheme.Typography.chatLabel)
                        .foregroundStyle(AppTheme.assistantLabel)
                        .padding(.horizontal, 2)
                }

                messageBubble(message)
            }
            .frame(
                maxWidth: message.user.isCurrentUser ? 420 : .infinity,
                alignment: message.user.isCurrentUser ? .trailing : .leading
            )

            if !message.user.isCurrentUser {
                Spacer(minLength: 40)
            }
        }
    }

    private func messageBubbleBackground(for message: ChatMessage) -> some ShapeStyle {
        if message.user.isCurrentUser {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [AppTheme.userBubbleTop, AppTheme.userBubbleBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(AppTheme.assistantBubble)
    }

    private func messageBubbleBorder(for message: ChatMessage) -> Color {
        message.user.isCurrentUser ? AppTheme.userBubbleBorder : AppTheme.assistantBubbleBorder
    }

    private func messageTextColor(for message: ChatMessage) -> Color {
        message.user.isCurrentUser ? AppTheme.userMessageText : AppTheme.assistantMessageText
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        let text = displayText(for: message)
        let shouldRenderText = shouldRenderText(for: message, text: text)
        let isStreaming = message.id == streamingMessageID && llmService.isGenerating
        let textColor = messageTextColor(for: message)

        VStack(
            alignment: message.user.isCurrentUser ? .trailing : .leading,
            spacing: message.attachments.isEmpty || !shouldRenderText ? 0 : 12
        ) {
            if !message.attachments.isEmpty {
                attachmentGrid(for: message)
            }

            if shouldRenderText {
                Group {
                    if message.user.isCurrentUser {
                        Text(text)
                            .font(AppTheme.Typography.chatUserMessage)
                            .foregroundStyle(textColor)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } else if isStreaming {
                        StreamingText(text: text, foregroundColor: textColor)
                    } else {
                        RichMessageText(text: text, foregroundColor: textColor)
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.bubbleHorizontalPadding)
        .padding(.vertical, AppTheme.Layout.bubbleVerticalPadding)
        .background(messageBubbleBackground(for: message))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(messageBubbleBorder(for: message), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: isStreaming)
    }

    // MARK: - Composer

    private var composerSection: some View {
        VStack(spacing: 12) {
            if shouldShowTypingIndicator {
                typingIndicator
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if !pendingAttachments.isEmpty {
                composerAttachmentStrip
            }

            HStack(spacing: 10) {
                attachmentPickerButton

                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.chatComposer)
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        submitDraft()
                    }

                Button {
                    if llmService.isGenerating {
                        Task { @MainActor in
                            await stopGeneration()
                        }
                    } else {
                        submitDraft()
                    }
                } label: {
                    Image(systemName: llmService.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.accentForeground)
                        .frame(width: AppTheme.Layout.composerActionSize, height: AppTheme.Layout.composerActionSize)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!llmService.isGenerating && !canSubmitDraft)
                .opacity((!llmService.isGenerating && !canSubmitDraft) ? 0.45 : 1)
            }
            .padding(8)
            .inputChrome(cornerRadius: AppTheme.Radius.medium)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
            .onTapGesture {
                isComposerFocused = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color.clear, AppTheme.composerFadeMiddle, AppTheme.composerFadeBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.2), value: shouldShowTypingIndicator)
    }

    private func composerIcon(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    private var attachmentPickerButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images,
            preferredItemEncoding: .automatic
        ) {
            Image(systemName: isImportingAttachments ? "hourglass" : "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(isImportingAttachments)
    }

    private var composerAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pendingAttachments, id: \.id) { attachment in
                    attachmentPreviewChip(for: attachment)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Typing indicator (animated dots)

    private var typingIndicator: some View {
        HStack(spacing: 0) {
            TypingDotsView()
                .frame(width: 32, height: 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var shouldShowTypingIndicator: Bool {
        guard llmService.isGenerating else { return false }
        guard let lastAssistantMessage = messages.last(where: { !$0.user.isCurrentUser }) else { return true }
        return lastAssistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitDraft: Bool {
        guard !isImportingAttachments else { return false }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasDraft || !pendingAttachments.isEmpty else { return false }
        return llmService.isTextModelReady || !supportsLocalModelRuntime
    }

    private var modelStatusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode with mock replies."
        }

        if llmService.isModelLoading {
            return llmService.modelLoadStage.statusText
        }

        return "Preparing your on-device model."
    }

    private func selectStarter(_ starter: ChatStarter) {
        draft = starter.prompt
        isComposerFocused = true
        AppDiagnostics.shared.record(
            "Starter selected",
            category: "ui",
            metadata: [
                "starter": starter.title,
                "messages": messages.count,
                "textReady": llmService.isTextModelReady
            ]
        )
    }

    private func toastView(message: String) -> some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.accentForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.toastFill)
            .clipShape(Capsule())
            .shadow(color: AppTheme.toastShadow, radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
    }

    private func displayText(for message: ChatMessage) -> String {
        if !message.user.isCurrentUser, message.text.isEmpty, llmService.isGenerating {
            return " "
        }

        return message.text
    }

    private func shouldRenderText(for message: ChatMessage, text: String) -> Bool {
        if message.user.isCurrentUser {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return !text.isEmpty
    }

    private func imageAttachments(for message: ChatMessage) -> [Attachment] {
        message.attachments.filter { $0.type == .image }
    }

    @ViewBuilder
    private func attachmentGrid(for message: ChatMessage) -> some View {
        let attachments = imageAttachments(for: message)

        if attachments.count == 1, let attachment = attachments.first {
            attachmentTile(for: attachment, height: 216)
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(attachments, id: \.id) { attachment in
                    attachmentTile(for: attachment, height: 112)
                }
            }
        }
    }

    private func attachmentTile(for attachment: Attachment, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.controlFill)

            if
                attachment.thumbnail.isFileURL,
                let image = UIImage(contentsOfFile: attachment.thumbnail.path)
            {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.assistantBubbleBorder, lineWidth: 1)
        )
    }

    private func attachmentPreviewChip(for attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            attachmentTile(for: attachment, height: 76)
                .frame(width: 76)

            Button {
                pendingAttachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground, AppTheme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
        .padding(.trailing, 2)
    }

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

    // MARK: - Photo import

    @MainActor
    private func importSelectedPhotos(from items: [PhotosPickerItem]) async {
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

    private func makeAttachment(from item: PhotosPickerItem) async throws -> Attachment? {
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

    private func storeAttachmentData(_ data: Data, fileExtension: String) throws -> URL {
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

    // MARK: - Prompt handling & streaming

    private func submitDraft() {
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

        streamingMessageID = assistantID
        isPinnedToBottom = true
        generationError = nil
        memoryAlertMessage = nil
        generationTask = Task {
            await streamReply(prompt: prompt, history: history, assistantID: assistantID)
        }
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        messages
            .compactMap { message in
                let prompt = promptInput(from: message)
                if prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.images.isEmpty {
                    return nil
                }
                return prompt
            }
    }

    /// Streams tokens into a buffer and flushes visible text at ~50ms intervals or word boundaries.
    private func streamReply(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
        assistantID: String
    ) async {
        var streamingPolicy = StreamingUpdatePolicy()

        defer {
            Task { @MainActor in
                self.generationTask = nil
                self.streamingMessageID = nil
            }
        }

        for await token in llmService.generate(prompt: prompt, history: history) {
            let update = streamingPolicy.append(token)

            if let visibleText = update.visibleText {
                await MainActor.run {
                    updateMessageText(id: assistantID, text: visibleText)
                    streamFlushTick &+= 1
                }
            }

            if update.shouldStop {
                await llmService.stopGeneration()
                break
            }
        }

        // Final flush — applies full sanitization and switches to markdown rendering
        let finalText = streamingPolicy.finalize()
        await MainActor.run {
            finalizeAssistantMessage(id: assistantID, text: finalText)
            streamFlushTick &+= 1
        }

        if let lastError = llmService.lastError {
            await MainActor.run {
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
    private func finalizeAssistantMessage(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        if text.isEmpty {
            messages.remove(at: index)
            return
        }

        messages[index].text = text
    }

    // MARK: - Conversation management

    @MainActor
    private func clearConversation() async {
        AppDiagnostics.shared.record("Conversation cleared", category: "ui", metadata: ["previousMessages": messages.count])
        await stopGeneration()
        messages.removeAll()
        draft = ""
        pendingAttachments.removeAll()
        selectedPhotoItems.removeAll()
        isImportingAttachments = false
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
        streamingMessageID = nil
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
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    private func isLowMemoryError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("memory") || lowercased.contains("oom") || lowercased.contains("out of memory")
    }

    @MainActor
    private func stopGeneration() async {
        generationTask?.cancel()
        generationTask = nil
        streamingMessageID = nil
        await llmService.stopGeneration()
    }
}

// MARK: - Typing Dots Animation

/// A small three-dot "thinking" animation inspired by ChatGPT/Claude iOS apps.
private struct TypingDotsView: View {
    @State private var phase: Int = 0

    private let dotSize: CGFloat = 7
    private let spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.textSecondary)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(dotOpacity(for: index))
                    .scaleEffect(dotScale(for: index))
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.5
        default: return 0.25
        }
    }

    private func dotScale(for index: Int) -> CGFloat {
        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.85
        default: return 0.7
        }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % 3
            }
        }
    }
}

private struct ConversationBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview helpers

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

#if DEBUG
private extension LLMService {
    static func previewLoaded() -> LLMService {
        let service = LLMService()
        service.isModelLoaded = true
        return service
    }

    static func previewWarmShell() -> LLMService {
        let service = LLMService()
        service.isModelLoading = true
        service.modelLoadStage = .loadingModel
        return service
    }
}

#Preview("Chat") {
    ChatView(
        initialMessages: [
            .previewMessage(
                user: .user,
                text: "Plan me a focused three-day workout split for strength and cardio."
            ),
            .previewMessage(
                user: .yemma,
                text: "Here is a simple split: Day 1 push and intervals, Day 2 lower body and incline walking, Day 3 pull and steady-state cardio. Keep each session around 45 minutes."
            ),
            .previewMessage(
                user: .user,
                text: "Keep it beginner friendly and make the gym version optional."
            )
        ]
    )
    .environment(LLMService.previewLoaded())
    .environment(ModelDownloader())
}

#Preview("Warm Shell") {
    ChatView()
        .environment(LLMService.previewWarmShell())
        .environment(ModelDownloader())
}
#endif

private struct ConversationsView: View {
    @Environment(\.dismiss) private var dismiss

    let messages: [ChatMessage]
    let onStartFresh: () -> Void

    private var conversationPreview: String {
        let firstUserMessage = messages.first(where: \.user.isCurrentUser)
        let firstUserText = firstUserMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstUserText, !firstUserText.isEmpty {
            return firstUserText
        }

        if let firstUserMessage, !firstUserMessage.attachments.isEmpty {
            return "Image prompt"
        }

        return "Hello"
    }

    var body: some View {
        ZStack {
            UtilityBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppTheme.Layout.sectionSpacing) {
                    HStack {
                        Spacer()
                        Text("Conversations")
                            .font(AppTheme.Typography.utilityTitle)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        CircleIconButton(systemName: "xmark", action: { dismiss() })
                    }
                    .padding(.horizontal, AppTheme.Layout.screenHeaderHorizontalPadding)
                    .padding(.top, 18)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Stored only on this iPhone", systemImage: "iphone")
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.accent)

                        Text("Start a fresh chat when you want a clean context. Your current local thread stays available here so you can return without losing place.")
                            .font(AppTheme.Typography.utilityRowDetail)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Layout.rowHorizontalPadding)
                    .groupedCard(cornerRadius: AppTheme.Radius.medium)

                    UtilitySection("Current") {
                        Button {
                            dismiss()
                        } label: {
                            conversationRow(
                                title: conversationPreview,
                                subtitle: messages.isEmpty ? "Start chatting" : "Current conversation"
                            )
                        }
                        .buttonStyle(.plain)

                        UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)

                        Button {
                            onStartFresh()
                        } label: {
                            conversationRow(title: "Fresh chat", subtitle: "Clear current thread")
                        }
                        .buttonStyle(.plain)
                    }

                    UtilitySection("Search") {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text("Conversation search is coming soon")
                                .font(AppTheme.Typography.utilityRowTitle)
                                .foregroundStyle(AppTheme.textSecondary)
                            Spacer()
                        }
                        .utilityRowPadding()
                    }
                }
                .padding(.horizontal, AppTheme.Layout.screenPadding)
                .padding(.bottom, 28)
            }
        }
    }

    private func conversationRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(AppTheme.Typography.utilityRowDetail)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .utilityRowPadding()
        .contentShape(Rectangle())
    }
}
