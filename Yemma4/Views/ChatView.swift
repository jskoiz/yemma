import Observation
import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore

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
    @State private var isSidebarOpen = false
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var isShowingPhotoPicker = false
    @State private var showArchiveBrowser = false
    @State private var loadedConversationID: UUID?
    @State private var isRestoringConversation = false
    @State private var conversationSaveTask: Task<Void, Never>?
    @State private var sharePayload: SharePayload?
    @FocusState private var isComposerFocused: Bool

    // MARK: - Streaming state
    /// The ID of the assistant message currently being streamed.
    @State private var streamingMessageID: String?
    /// Monotonic counter bumped each time we flush visible text — drives auto-scroll.
    @State private var streamFlushTick: UInt64 = 0
    /// Whether the transcript is currently close enough to the bottom to auto-scroll.
    @State private var isPinnedToBottom = true
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var completedAssistantMessageIDs: Set<String> = []
    @State private var lastStarterPromptIndexByID: [String: Int] = [:]

    private let bottomAnchorID = "conversation-bottom-anchor"
    private let scrollCoordinateSpaceName = "conversation-scroll"
    private let pinnedThreshold: CGFloat = 48
    private let releasePinnedThreshold: CGFloat = 120

    private let taskStarters = ChatStarter.defaults

    private enum AssistantRefinement: String {
        case shorter
        case moreDetail

        var title: String {
            switch self {
            case .shorter:
                return "Shorter"
            case .moreDetail:
                return "More detail"
            }
        }

        var systemImage: String {
            switch self {
            case .shorter:
                return "text.alignleft"
            case .moreDetail:
                return "plus.bubble"
            }
        }

        var prompt: String {
            switch self {
            case .shorter:
                return "Make that shorter and more direct."
            case .moreDetail:
                return "Expand that with a bit more detail and one concrete example."
            }
        }
    }

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

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let sidebarWidth = geometry.size.width
                let sidebarProgress = sidebarRevealProgress(sidebarWidth: sidebarWidth)
                let shellOffset = sidebarProgress * (geometry.size.width + 12)

                ZStack(alignment: .leading) {
                    UtilityBackground()

                    if isSidebarPresented {
                        ChatSidebarView(
                            currentConversationID: loadedConversationID,
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
                        .frame(width: sidebarWidth)
                        .offset(x: sidebarOffset(sidebarWidth: sidebarWidth))
                    }

                    mainShell
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay {
                            if sidebarProgress > 0.001 {
                                Color.black
                                    .opacity(0.06 * sidebarProgress)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    closeSidebar()
                                }
                            }
                        }
                        .offset(x: shellOffset)
                        .allowsHitTesting(!isSidebarPresented)
                        .simultaneousGesture(sidebarGesture(sidebarWidth: sidebarWidth))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showArchiveBrowser) {
                ConversationBrowserSheet(
                    title: "Archive",
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
                topBar
            }

            if let toastMessage {
                VStack {
                    Spacer()
                    toastView(message: toastMessage)
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
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            CircleIconButton(
                systemName: "line.3.horizontal",
                filled: true,
                action: toggleSidebar
            )
            .accessibilityLabel("Open sidebar")
            .accessibilityHint("Browse saved chats and quick settings.")

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil") {
                Task { @MainActor in
                    await startFreshConversation()
                }
            }
            .accessibilityLabel("New chat")
            .accessibilityHint("Start a fresh conversation and keep older chats saved.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    // MARK: - Conversation content with auto-scroll

    private func conversationContent(topInset: CGFloat) -> some View {
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
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                        .animation(
                            reduceMotion
                                ? nil
                                : .spring(response: 0.34, dampingFraction: 0.9),
                            value: messages.map(\.id)
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpaceName)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: topInset)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSidebarPresented {
                            closeSidebar()
                            return
                        }
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

        if previous.user.isCurrentUser == current.user.isCurrentUser {
            return previous.user.isCurrentUser ? 6 : 8
        }

        if previous.user.isCurrentUser && !current.user.isCurrentUser {
            return 22
        }

        return 18
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
            if reduceMotion {
                action()
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    action()
                }
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
            statusDetailText: modelStatusDetailText,
            statusProgress: modelStatusProgress,
            statusIsFailure: isShowingModelFailure,
            primarySetupActionTitle: primarySetupActionTitle,
            onPrimarySetupAction: primarySetupAction,
            starters: taskStarters,
            onSelectStarter: selectStarter
        )
    }

    private func messageRow(_ message: ChatMessage, index: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.user.isCurrentUser {
                Spacer(minLength: 54)

                userMessageBubble(message)
                    .frame(maxWidth: 420, alignment: .trailing)
            } else {
                assistantMessageBody(message, index: index)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.user.isCurrentUser ? .trailing : .leading)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity)
        )
    }

    private func userBubbleBackground() -> some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [AppTheme.userBubbleTop, AppTheme.userBubbleBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private func userMessageBubble(_ message: ChatMessage) -> some View {
        let text = displayText(for: message)
        let shouldRenderText = shouldRenderText(for: message, text: text)

        VStack(
            alignment: .trailing,
            spacing: message.attachments.isEmpty || !shouldRenderText ? 0 : 12
        ) {
            if !message.attachments.isEmpty {
                attachmentGrid(for: message)
            }

            if shouldRenderText {
                Text(text)
                    .font(AppTheme.Typography.chatUserMessage)
                    .foregroundStyle(AppTheme.userMessageText)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, AppTheme.Layout.bubbleHorizontalPadding)
        .padding(.vertical, AppTheme.Layout.bubbleVerticalPadding)
        .background(userBubbleBackground())
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(AppTheme.userBubbleBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func assistantMessageBody(_ message: ChatMessage, index: Int) -> some View {
        let text = displayText(for: message)
        let shouldRenderText = shouldRenderText(for: message, text: text)
        let isStreaming = message.id == streamingMessageID && llmService.isGenerating
        let isActionStripVisible = shouldShowMessageActionStrip(for: message, index: index)

        VStack(alignment: .leading, spacing: 10) {
            if !message.attachments.isEmpty {
                attachmentGrid(for: message)
            }

            if shouldRenderText {
                RichMessageText(text: text, isStreaming: isStreaming)
            }

            if isActionStripVisible {
                messageActionStrip(for: message, index: index)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 3)),
                                removal: .opacity
                            )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            messageContextMenu(for: message, index: index)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isActionStripVisible)
    }

    // MARK: - Composer

    private var composerSection: some View {
        VStack(spacing: 12) {
            if shouldShowTypingIndicator {
                typingIndicator
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.8))
                    )
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
                .accessibilityLabel(llmService.isGenerating ? "Stop response" : "Send message")
                .accessibilityHint(
                    llmService.isGenerating
                        ? "Stops the current assistant response."
                        : "Sends your draft to Yemma."
                )
            }
            .padding(8)
            .inputChrome(cornerRadius: AppTheme.Radius.medium)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
            .onTapGesture {
                if isSidebarPresented {
                    closeSidebar()
                    return
                }
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowTypingIndicator)
    }

    private var attachmentPickerButton: some View {
        Button {
            isShowingPhotoPicker = true
        } label: {
            Image(systemName: isImportingAttachments ? "hourglass" : "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .disabled(isImportingAttachments)
        .accessibilityLabel("Add image")
        .accessibilityHint("Attach up to four images to your next message.")
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
            ThinkingOrbView()
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
        if !supportsLocalModelRuntime {
            return true
        }
        if llmService.isModelLoading {
            return false
        }
        return llmService.isTextModelReady || modelDownloader.isDownloaded
    }

    private var modelStatusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode with mock replies."
        }

        if modelDownloader.isDownloading {
            return "Downloading the Gemma 4 MLX bundle."
        }

        if modelDownloader.canResumeDownload {
            return "Setup paused before the download finished."
        }

        if modelDownloader.error != nil {
            return "The model bundle download needs attention."
        }

        if llmService.isModelLoading {
            return llmService.modelLoadStage.statusText
        }

        if modelDownloader.isDownloaded, llmService.lastError != nil {
            return "Yemma could not finish preparing the MLX model bundle."
        }

        return "Load your on-device Gemma 4 model."
    }

    private var modelStatusDetailText: String? {
        if !supportsLocalModelRuntime {
            return nil
        }

        if modelDownloader.isDownloading {
            let percent = Int(modelDownloader.downloadProgress * 100)
            if let eta = modelDownloader.estimatedSecondsRemaining {
                return "\(percent)% downloaded. \(formatETA(eta)) remaining."
            }
            return "\(percent)% downloaded. Yemma can keep downloading in the background."
        }

        if let error = modelDownloader.error {
            return error
        }

        if modelDownloader.canResumeDownload {
            return "Resume setup to finish preparing Yemma on this device."
        }

        if modelDownloader.isDownloaded, let error = llmService.lastError, !llmService.isModelLoading {
            return error
        }

        if llmService.isModelLoading {
            return "You can keep exploring while Yemma finishes loading in the background."
        }

        if modelDownloader.isDownloaded {
            return "Startup stays responsive. Load the MLX model only when you are ready to chat."
        }

        return nil
    }

    private var modelStatusProgress: Double? {
        guard supportsLocalModelRuntime, modelDownloader.isDownloading else { return nil }
        return modelDownloader.downloadProgress
    }

    private var isShowingModelFailure: Bool {
        supportsLocalModelRuntime && (
            modelDownloader.error != nil
                || (modelDownloader.isDownloaded && llmService.lastError != nil && !llmService.isModelLoading)
        )
    }

    private var primarySetupActionTitle: String? {
        guard supportsLocalModelRuntime else { return nil }

        if modelDownloader.isDownloading {
            return nil
        }

        if modelDownloader.canResumeDownload {
            return "Resume download"
        }

        if modelDownloader.error != nil {
            return "Retry download"
        }

        if modelDownloader.isDownloaded, llmService.lastError != nil, !llmService.isModelLoading {
            return "Retry model load"
        }

        if modelDownloader.isDownloaded, !llmService.isTextModelReady, !llmService.isModelLoading {
            return "Load model"
        }

        return nil
    }

    private var primarySetupAction: (() -> Void)? {
        guard supportsLocalModelRuntime else { return nil }

        if modelDownloader.canResumeDownload || modelDownloader.error != nil {
            return {
                Task { await modelDownloader.downloadModel() }
            }
        }

        if modelDownloader.isDownloaded, llmService.lastError != nil, !llmService.isModelLoading {
            return onRetryModelLoad
        }

        if modelDownloader.isDownloaded, !llmService.isTextModelReady, !llmService.isModelLoading {
            return onRetryModelLoad
        }

        return nil
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 {
            return "less than a minute"
        }

        if s < 3600 {
            let minutes = s / 60
            return "\(minutes) min"
        }

        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    private func selectStarter(_ starter: ChatStarter) {
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

    private func lastUserMessageIndex() -> Int? {
        messages.lastIndex(where: \.user.isCurrentUser)
    }

    private func latestAssistantMessageIndex() -> Int? {
        messages.lastIndex(where: { !$0.user.isCurrentUser })
    }

    private func canEditAndResend(_ message: ChatMessage) -> Bool {
        guard !llmService.isGenerating, message.user.isCurrentUser else { return false }
        guard let lastUserMessageIndex = lastUserMessageIndex() else { return false }
        return message.id == messages[lastUserMessageIndex].id
    }

    private func canRetryAssistantResponse(_ message: ChatMessage, index: Int) -> Bool {
        guard !llmService.isGenerating, !message.user.isCurrentUser else { return false }
        guard index >= 0, index == latestAssistantMessageIndex(), index == messages.indices.last else { return false }
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

    private func messageActionStrip(for message: ChatMessage, index: Int) -> some View {
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 14) {
            if !trimmedText.isEmpty {
                messageActionIconButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    accessibilityHint: "Copy this response."
                ) {
                    copyMessageText(trimmedText)
                }
            }

            if canRetryAssistantResponse(message, index: index) {
                messageActionIconButton(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    accessibilityHint: "Generate the assistant reply again."
                ) {
                    Task { @MainActor in
                        await retryAssistantResponse(message, index: index)
                    }
                }

                messageActionIconButton(
                    title: AssistantRefinement.shorter.title,
                    systemImage: AssistantRefinement.shorter.systemImage,
                    accessibilityHint: "Ask for a shorter version of the latest assistant reply."
                ) {
                    Task { @MainActor in
                        await refineAssistantResponse(message, refinement: .shorter)
                    }
                }
            }

            messageActionOverflowMenu(for: message, index: index, trimmedText: trimmedText)
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }

    private func messageActionIconButton(
        title: String,
        systemImage: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    private func messageActionOverflowMenu(
        for message: ChatMessage,
        index: Int,
        trimmedText: String
    ) -> some View {
        Menu {
            messageActionMenuItems(for: message, index: index, trimmedText: trimmedText)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .accessibilityHint("Shows actions for this response.")
    }

    @ViewBuilder
    private func messageActionMenuItems(
        for message: ChatMessage,
        index: Int,
        trimmedText: String
    ) -> some View {
        if !trimmedText.isEmpty {
            Button {
                copyMessageText(trimmedText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                shareMessageText(trimmedText)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        if canEditAndResend(message) {
            Button {
                editAndResendLastUserTurn(message)
            } label: {
                Label("Edit & Resend", systemImage: "square.and.pencil")
            }
        }

        if canRetryAssistantResponse(message, index: index) {
            Button {
                Task { @MainActor in
                    await retryAssistantResponse(message, index: index)
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }

            ForEach([AssistantRefinement.shorter, .moreDetail], id: \.rawValue) { refinement in
                Button {
                    Task { @MainActor in
                        await refineAssistantResponse(message, refinement: refinement)
                    }
                } label: {
                    Label(refinement.title, systemImage: refinement.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessage, index: Int) -> some View {
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        messageActionMenuItems(for: message, index: index, trimmedText: trimmedText)
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

    private func editAndResendLastUserTurn(_ message: ChatMessage) {
        guard canEditAndResend(message) else { return }
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        AppHaptics.selection()

        AppDiagnostics.shared.record(
            "Last user turn edited",
            category: "ui",
            metadata: [
                "chars": message.text.count,
                "images": message.attachments.count
            ]
        )

        draft = message.text
        pendingAttachments = message.attachments
        selectedPhotoItems = []
        messages.removeSubrange(messageIndex..<messages.endIndex)
        isComposerFocused = true
        scheduleConversationSave(delayMs: 0)
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
        completedAssistantMessageIDs.remove(message.id)
        generationError = nil
        memoryAlertMessage = nil
        isPinnedToBottom = true
        generationTask = Task {
            await streamReply(prompt: prompt, history: history, assistantID: message.id)
        }
        scheduleConversationSave(delayMs: 0)
    }

    private func refineAssistantResponse(_ message: ChatMessage, refinement: AssistantRefinement) async {
        guard !llmService.isGenerating, !message.user.isCurrentUser else { return }
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
        let targetConversationID = conversationStore.currentConversationID ?? conversationStore.ensureCurrentConversation()
        guard force || loadedConversationID != targetConversationID else { return }

        conversationSaveTask?.cancel()
        isRestoringConversation = true
        await stopGeneration()

        guard let snapshot = await conversationStore.loadConversationAsync(id: targetConversationID) else {
            let newConversationID = conversationStore.startFreshConversation()
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
        persistConversationNow()
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
        persistConversationNow()
        await stopGeneration()
        let conversationID = conversationStore.startFreshConversation()
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

    private var isSidebarPresented: Bool {
        isSidebarOpen || sidebarDragOffset > 0
    }

    private func toggleSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isSidebarOpen.toggle()
            sidebarDragOffset = 0
        }
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isSidebarOpen = false
            sidebarDragOffset = 0
        }
    }

    private func sidebarRevealProgress(sidebarWidth: CGFloat) -> CGFloat {
        guard sidebarWidth > 0 else { return 0 }

        let visibleWidth: CGFloat
        if isSidebarOpen {
            visibleWidth = sidebarWidth + min(0, sidebarDragOffset)
        } else {
            visibleWidth = max(0, sidebarDragOffset)
        }

        return min(max(visibleWidth / sidebarWidth, 0), 1)
    }

    private func sidebarOffset(sidebarWidth: CGFloat) -> CGFloat {
        if isSidebarOpen {
            return min(0, sidebarDragOffset)
        }

        return -sidebarWidth + max(0, sidebarDragOffset)
    }

    private func sidebarGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if isSidebarOpen {
                    sidebarDragOffset = max(-sidebarWidth, min(0, value.translation.width))
                } else {
                    guard value.startLocation.x <= 28, value.translation.width > 0 else { return }
                    sidebarDragOffset = min(sidebarWidth, value.translation.width)
                }
            }
            .onEnded { value in
                defer { sidebarDragOffset = 0 }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if isSidebarOpen {
                    let closingDistance = min(value.translation.width, value.predictedEndTranslation.width)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        isSidebarOpen = closingDistance >= -(sidebarWidth * 0.22)
                    }
                } else {
                    guard value.startLocation.x <= 28 else { return }
                    let openingDistance = max(value.translation.width, value.predictedEndTranslation.width)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        isSidebarOpen = openingDistance > sidebarWidth * 0.22
                    }
                }
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
                persistConversationNow()
            }
        }
    }

    private func persistConversationNow() {
        guard !isRestoringConversation else { return }

        let conversationID = conversationStore.saveConversation(
            id: loadedConversationID,
            messages: messages,
            draftText: draft,
            draftAttachments: pendingAttachments
        )
        loadedConversationID = conversationID
        if conversationStore.currentConversationID == nil {
            conversationStore.setCurrentConversation(id: conversationID)
        }
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
                scheduleConversationSave()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground, AppTheme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove image")
            .accessibilityHint("Removes this image from the draft.")
        }
        .padding(.top, 6)
        .padding(.trailing, 2)
    }

    private func promptInput(from message: ChatMessage) -> PromptMessageInput {
        YemmaPromptPlanner.promptInput(from: message)
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
            scheduleConversationSave()
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
        let directory = ConversationAttachmentStore.directoryURL()

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

    @MainActor
    private func submitDraft() {
        let trimmedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard llmService.isTextModelReady || !supportsLocalModelRuntime else {
            if llmService.isModelLoading {
                AppDiagnostics.shared.record("Send deferred because model is still loading", category: "ui")
                showToast("Preparing your on-device model")
                return
            }

            if modelDownloader.isDownloaded {
                AppDiagnostics.shared.record("Send triggered explicit model load", category: "ui")
                onRetryModelLoad?()
                showToast("Preparing your on-device model")
                return
            }

            AppDiagnostics.shared.record("Send blocked because model download is incomplete", category: "ui")
            generationError = "Finish the one-time model download first."
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

        completedAssistantMessageIDs.remove(assistantID)
        streamingMessageID = assistantID
        isPinnedToBottom = true
        generationError = nil
        memoryAlertMessage = nil
        generationTask = Task {
            await streamReply(prompt: prompt, history: history, assistantID: assistantID)
        }
        scheduleConversationSave(delayMs: 0)
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        YemmaPromptPlanner.conversationHistory(from: messages)
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
            persistConversationNow()
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
            completedAssistantMessageIDs.remove(id)
            return
        }

        messages[index].text = text
        completedAssistantMessageIDs.insert(id)
        persistConversationNow()
    }

    // MARK: - Conversation management

    @MainActor
    private func clearConversation() async {
        AppDiagnostics.shared.record("Conversation cleared", category: "ui", metadata: ["previousMessages": messages.count])
        await stopGeneration()
        messages.removeAll()
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
                    text: "Load the local model first, then rerun this debug scenario."
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
        generationTask?.cancel()
        generationTask = nil
        streamingMessageID = nil
        await llmService.stopGeneration()
        persistConversationNow()
    }
}

// MARK: - Thinking indicator

private struct ThinkingOrbView: View {
    var body: some View {
        HStack(spacing: 10) {
            TypingDotsView()
            Text("Thinking")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.controlFill)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(AppTheme.assistantBubbleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow(.floating).color.opacity(0.45), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}

private struct TypingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 6.5
    private let spacing: CGFloat = 5
    private let stepDuration: TimeInterval = 0.28

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : stepDuration)) { context in
            let phase = animationPhase(for: context.date)

            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.textSecondary)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(dotOpacity(for: index, phase: phase))
                        .scaleEffect(dotScale(for: index, phase: phase))
                        .animation(reduceMotion ? nil : .easeInOut(duration: stepDuration * 0.9), value: phase)
                }
            }
        }
    }

    private func animationPhase(for date: Date) -> Int {
        guard !reduceMotion else { return 0 }
        return Int(date.timeIntervalSinceReferenceDate / stepDuration) % 3
    }

    private func dotOpacity(for index: Int, phase: Int) -> Double {
        if reduceMotion {
            return 0.8
        }
        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.5
        default: return 0.25
        }
    }

    private func dotScale(for index: Int, phase: Int) -> CGFloat {
        if reduceMotion {
            return 1.0
        }
        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.85
        default: return 0.7
        }
    }
}

private struct ConversationBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
}

private struct ChatSidebarView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore
    @Environment(AppDiagnostics.self) private var diagnostics
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue

    let currentConversationID: UUID?
    let onSelectConversation: (UUID) -> Void
    let onStartFresh: () -> Void
    let onShowOnboarding: () -> Void
    let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?
    let onOpenArchive: () -> Void
    let onClose: () -> Void

    @State private var renameConversation: ConversationMetadata?
    @State private var renameTitle = ""
    @State private var showAdvancedControls = false
    @State private var showEventLog = false
    @State private var diagnosticsCopied = false
    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false

    private let repositoryURL = URL(string: "https://yemma.chat")!
    private let madeByURL = URL(string: "https://avmillabs.com")!
    private let maxTokenOptions: [Int] = [256, 512, 1024, 2048, 4096]
    private let recentConversationLimit = 10

    var body: some View {
        ZStack {
            UtilityBackground()

            ProgressiveBlurHeaderHost(
                initialHeaderHeight: 116,
                maxBlurRadius: 14,
                fadeExtension: 92,
                tintOpacityTop: 0.68,
                tintOpacityMiddle: 0.28
            ) { headerHeight in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.sectionSpacing) {
                        everydaySection
                        chatsSection
                        modelSection
                        aboutSection
                    }
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 34)
                    .padding(.bottom, 28)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                }
            } header: {
                header
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }
        }
        .task {
            await conversationStore.loadIndexIfNeeded()
            await diagnostics.loadPersistedEventsIfNeeded()
        }
        .alert("Diagnostics copied", isPresented: $diagnosticsCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The recent diagnostics log is on the pasteboard.")
        }
        .confirmationDialog(
            "Delete the downloaded model?",
            isPresented: $showDeleteModelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                Task {
                    await llmService.unloadModel()
                    modelDownloader.deleteModel()
                    onShowOnboarding()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Yemma will return to setup until the model is downloaded again.")
        }
        .confirmationDialog(
            "Delete conversation history?",
            isPresented: $showClearConversationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete History", role: .destructive) {
                AppDiagnostics.shared.record("Conversation history cleared", category: "ui")
                conversationStore.deleteAllConversations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved local chats, drafts, and attached images on this iPhone.")
        }
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { renameConversation != nil },
                set: { if !$0 { renameConversation = nil } }
            )
        ) {
            TextField("Chat name", text: $renameTitle)
            Button("Save") {
                guard let renameConversation else { return }
                let trimmedTitle = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTitle.isEmpty else { return }
                AppDiagnostics.shared.record(
                    "Conversation renamed",
                    category: "ui",
                    metadata: ["conversationID": renameConversation.id.uuidString]
                )
                AppHaptics.selection()
                conversationStore.renameConversation(id: renameConversation.id, title: trimmedTitle)
                self.renameConversation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this chat a shorter, easier-to-scan name.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Yemma 4")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.textPrimary)
                    .shadow(color: Color.white.opacity(0.18), radius: 10, x: 0, y: 2)

                Text("Chats and quick controls")
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(AppTheme.controlFill)

                Circle()
                    .stroke(AppTheme.controlBorder, lineWidth: 1)

                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Close sidebar")
            .accessibilityHint("Returns to the chat.")
        }
    }

    private var everydaySection: some View {
        UtilitySection("Everyday") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    rowHeader(title: "Response style", detail: llmService.activeResponseStyleTitle)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                        ForEach(ResponseStylePreset.allCases) { preset in
                            responseStyleChip(preset)
                        }
                    }
                }

                UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)

                VStack(alignment: .leading, spacing: 10) {
                    rowHeader(title: "Appearance", detail: selectedAppearancePreference.title)

                    if dynamicTypeSize.isAccessibilitySize {
                        Menu {
                            ForEach(AppearancePreference.allCases) { appearance in
                                Button(appearance.title) {
                                    appearancePreferenceBinding.wrappedValue = appearance
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedAppearancePreference.title)
                                    .font(AppTheme.Typography.utilityRowTitle)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(AppTheme.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Picker("Appearance", selection: appearancePreferenceBinding) {
                            ForEach(AppearancePreference.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .utilityRowPadding()
        }
    }

    private var chatsSection: some View {
        let recentConversations = Array(conversationStore.conversations.prefix(recentConversationLimit))
        let archivedConversationCount = max(conversationStore.conversations.count - recentConversationLimit, 0)

        return UtilitySection("Chats") {
            Button {
                AppDiagnostics.shared.record("New conversation requested", category: "ui")
                AppHaptics.selection()
                onStartFresh()
            } label: {
                actionRow(
                    icon: "square.and.pencil",
                    title: "New chat",
                    subtitle: "Start fresh without losing your other threads"
                )
            }
            .buttonStyle(.plain)

            if !recentConversations.isEmpty {
                UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
            }

            ForEach(Array(recentConversations.enumerated()), id: \.element.id) { index, metadata in
                Button {
                    AppDiagnostics.shared.record(
                        "Conversation selected",
                        category: "ui",
                        metadata: [
                            "conversationID": metadata.id.uuidString,
                            "messageCount": metadata.messageCount
                        ]
                    )
                    AppHaptics.selection()
                    onSelectConversation(metadata.id)
                } label: {
                    conversationRow(metadata)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        renameConversation = metadata
                        renameTitle = metadata.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }

                if index != recentConversations.count - 1 || archivedConversationCount > 0 {
                    UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                }
            }

            if archivedConversationCount > 0 {
                Button {
                    AppDiagnostics.shared.record(
                        "Archive opened",
                        category: "ui",
                        metadata: ["count": archivedConversationCount]
                    )
                    AppHaptics.selection()
                    onOpenArchive()
                } label: {
                    compactArchiveRow(count: archivedConversationCount)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modelSection: some View {
        UtilitySection("Model & Storage") {
            infoRow(
                icon: "shippingbox",
                title: "Local model",
                detail: modelSizeText
            )
            UtilitySectionSeparator()

            Button {
                AppHaptics.selection()
                onShowOnboarding()
            } label: {
                actionRow(
                    icon: "sparkles.rectangle.stack",
                    title: "Setup status",
                    subtitle: setupStatusDetail
                )
            }
            .buttonStyle(.plain)

            UtilitySectionSeparator()

            Button {
                if reduceMotion {
                    showAdvancedControls.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showAdvancedControls.toggle()
                    }
                }
                AppHaptics.selection()
            } label: {
                disclosureRow(
                    icon: "gearshape.2",
                    title: "Advanced",
                    subtitle: "Model tuning, diagnostics, and debug tools.",
                    isExpanded: showAdvancedControls
                )
            }
            .buttonStyle(.plain)

            if showAdvancedControls {
                UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                advancedCard
            }

            UtilitySectionSeparator()

            destructiveRow(
                icon: "trash",
                title: "Delete conversation history",
                subtitle: "Remove saved local chats, drafts, and attached images."
            ) {
                showClearConversationConfirmation = true
            }

            UtilitySectionSeparator()

            destructiveRow(
                icon: "externaldrive.badge.minus",
                title: "Delete downloaded model",
                subtitle: "Remove the local model and send Yemma back to setup.",
                isDisabled: modelDownloader.modelPath == nil
            ) {
                showDeleteModelConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        UtilitySection("About") {
            linkRow(
                icon: "link",
                title: "Project page",
                subtitle: "yemma.chat",
                url: repositoryURL
            )
            UtilitySectionSeparator()
            linkRow(
                icon: "building.2",
                title: "Made by",
                subtitle: "AVMIL Labs in Honolulu 🤙",
                url: madeByURL
            )
            UtilitySectionSeparator()
            infoRow(icon: "info.circle", title: "Version", detail: appVersionText)
        }
    }

    private func rowHeader(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            Text(detail)
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func responseStyleChip(_ preset: ResponseStylePreset) -> some View {
        let isSelected = llmService.activeResponseStylePreset == preset

        return Button {
            guard llmService.activeResponseStylePreset != preset else { return }
            llmService.applyResponseStylePreset(preset)
            AppHaptics.selection()
            AppDiagnostics.shared.record(
                "Response style preset applied",
                category: "settings",
                metadata: [
                    "preset": preset.rawValue,
                    "temperature": preset.temperature,
                    "maxResponseTokens": preset.maxResponseTokens
                ]
            )
        } label: {
            Text(preset.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? AppTheme.accentForeground : AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isSelected ? AppTheme.accent : AppTheme.controlFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? AppTheme.accent.opacity(0.2) : AppTheme.controlBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func conversationRow(_ metadata: ConversationMetadata) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: metadata.id == currentConversationID ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(metadata.id == currentConversationID ? AppTheme.accent : AppTheme.textSecondary)
                .frame(width: AppTheme.Layout.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(metadata.title)
                        .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    if metadata.id == currentConversationID {
                        statusChip("Current")
                    } else if metadata.hasDraft {
                        statusChip("Draft")
                    }
                }

                if !metadata.preview.isEmpty {
                    Text(metadata.preview)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(Self.relativeDateText(for: metadata.updatedAt))
                    Text("·")
                    Text("\(metadata.messageCount) \(metadata.messageCount == 1 ? "message" : "messages")")
                }
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func compactArchiveRow(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: AppTheme.Layout.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("Archive")
                    .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("\(count) older chats")
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func actionRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(subtitle)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()
        }
        .utilityRowPadding()
        .contentShape(Rectangle())
    }

    private func disclosureRow(
        icon: String,
        title: String,
        subtitle: String,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(subtitle)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .utilityRowPadding()
        .contentShape(Rectangle())
    }

    private var advancedCard: some View {
        VStack(spacing: 0) {
            advancedSubsectionHeader(
                title: "Model controls",
                detail: "Fine-tune response length and creativity when you want something more custom than the preset."
            )
            advancedDivider()
            advancedTemperatureRow
            advancedDivider()
            advancedMaxResponseRow
            advancedDivider()
            diagnosticsSection

#if DEBUG
            if onRunDebugScenario != nil {
                advancedDivider()
                debugScenariosRow
            }
#endif

            advancedDivider()
            resetDefaultsRow
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .fill(AppTheme.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(AppTheme.controlBorder, lineWidth: 1)
        )
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 14)
    }

    private func advancedSubsectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(detail)
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func advancedDivider() -> some View {
        Divider()
            .padding(.leading, 16)
            .overlay(AppTheme.separator)
    }

    private var advancedTemperatureRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Creativity", systemImage: "slider.horizontal.3")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(String(format: "%.1f", llmService.temperature))
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { llmService.temperature },
                    set: { llmService.temperature = $0 }
                ),
                in: 0.1...2.0,
                step: 0.1
            )
            .tint(AppTheme.accent)

            Text("Lower stays tighter. Higher feels more open-ended.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var advancedMaxResponseRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Max response", systemImage: "text.word.spacing")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(tokenLabel(llmService.maxResponseTokens))
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Menu {
                ForEach(maxTokenOptions, id: \.self) { count in
                    Button(tokenLabel(count)) {
                        guard llmService.maxResponseTokens != count else { return }
                        llmService.maxResponseTokens = count
                        AppHaptics.selection()
                        diagnostics.record(
                            "Max response changed",
                            category: "settings",
                            metadata: ["maxResponseTokens": count]
                        )
                    }
                }
            } label: {
                HStack {
                    Text(tokenLabel(llmService.maxResponseTokens))
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Maximum tokens the model can generate per reply.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var diagnosticsSection: some View {
        VStack(spacing: 0) {
            advancedSubsectionHeader(
                title: "Diagnostics",
                detail: "Inspect recent events, copy the local log, or clear it."
            )
            advancedDivider()
            advancedInfoRow(
                icon: "waveform.path.ecg",
                title: "Recent events",
                detail: "\(diagnostics.recentEvents.count)"
            )
            advancedDivider()
            Button {
                diagnostics.copyToPasteboard()
                diagnosticsCopied = true
            } label: {
                advancedActionRow(
                    icon: "doc.on.doc",
                    title: "Copy diagnostics log",
                    detail: "Put the recent local event log on the pasteboard."
                )
            }
            .buttonStyle(.plain)
            advancedDivider()
            Button {
                diagnostics.clear()
            } label: {
                advancedActionRow(
                    icon: "trash",
                    title: "Clear diagnostics log",
                    detail: "Remove recent local event history from the app.",
                    titleColor: AppTheme.destructive,
                    trailingColor: AppTheme.destructive
                )
            }
            .buttonStyle(.plain)

            if !diagnostics.recentEvents.isEmpty {
                advancedDivider()

                Button {
                    if reduceMotion {
                        showEventLog.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showEventLog.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "list.bullet.rectangle")
                            .frame(width: AppTheme.Layout.rowIconSize)
                            .foregroundStyle(AppTheme.textPrimary)

                        Text("Event log")
                            .font(AppTheme.Typography.utilityRowTitle)
                            .foregroundStyle(AppTheme.textPrimary)

                        Spacer()

                        Text("\(diagnostics.recentEvents.suffix(6).count)")
                            .font(AppTheme.Typography.utilityRowDetail)
                            .foregroundStyle(AppTheme.textSecondary)

                        Image(systemName: showEventLog ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                if showEventLog {
                    ForEach(Array(diagnostics.recentEvents.suffix(6).reversed())) { event in
                        advancedDivider()
                        diagnosticEventRow(event)
                    }
                }
            }
        }
    }

#if DEBUG
    private var debugScenariosRow: some View {
        Menu {
            ForEach(DebugInferenceScenario.allCases) { scenario in
                Button {
                    AppHaptics.selection()
                    onRunDebugScenario?(scenario)
                } label: {
                    Label(scenario.title, systemImage: scenario.icon)
                }
            }
        } label: {
            advancedActionRow(
                icon: "wrench.and.screwdriver",
                title: "Debug scenarios",
                detail: "Run canned prompts to check formatting and rendering."
            )
        }
        .buttonStyle(.plain)
    }
#endif

    private var resetDefaultsRow: some View {
        Button {
            llmService.resetAdvancedSettings()
            AppHaptics.selection()
            diagnostics.record("Advanced settings reset", category: "settings")
        } label: {
            advancedActionRow(
                icon: "arrow.counterclockwise",
                title: "Reset to defaults",
                detail: "Restore the focused default tuning.",
                titleColor: AppTheme.accent,
                trailingColor: AppTheme.accent
            )
        }
        .buttonStyle(.plain)
    }

    private func advancedInfoRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)

            Text(title)
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            Text(detail)
                .font(AppTheme.Typography.utilityRowDetail)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func advancedActionRow(
        icon: String,
        title: String,
        detail: String,
        titleColor: Color = AppTheme.textPrimary,
        trailingColor: Color = AppTheme.textSecondary
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(titleColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(titleColor)

                Text(detail)
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func diagnosticEventRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.category.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer()

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Text(event.message)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            if !event.metadata.isEmpty {
                Text(
                    event.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: " • ")
                )
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(AppTheme.textPrimary)

                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(detail)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .frame(width: AppTheme.Layout.rowIconSize)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                }

                Text(detail)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, AppTheme.Layout.rowIconSize + 14)
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private func destructiveRow(
        icon: String,
        title: String,
        subtitle: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(AppTheme.destructive)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                        .foregroundStyle(AppTheme.destructive)

                    Text(subtitle)
                        .font(AppTheme.Typography.utilityRowDetail)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()
            }
            .utilityRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    private func linkRow(
        icon: String,
        title: String,
        subtitle: String,
        url: URL
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(subtitle)
                        .font(AppTheme.Typography.utilityRowDetail)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .utilityRowPadding()
        }
        .buttonStyle(.plain)
    }

    private func statusChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.accentSoft)
            .clipShape(Capsule())
    }

    private var selectedAppearancePreference: AppearancePreference {
        AppearancePreference.from(appearancePreferenceRaw)
    }

    private var appearancePreferenceBinding: Binding<AppearancePreference> {
        Binding(
            get: { selectedAppearancePreference },
            set: { newValue in
                guard appearancePreferenceRaw != newValue.rawValue else { return }
                appearancePreferenceRaw = newValue.rawValue
                AppHaptics.selection()
                AppDiagnostics.shared.record(
                    "Appearance preference changed",
                    category: "settings",
                    metadata: ["appearance": newValue.rawValue]
                )
            }
        )
    }

    private var modelSizeText: String {
        guard let modelPath = modelDownloader.modelPath else {
            return "Not downloaded"
        }

        let totalBytes = Gemma4MLXSupport.directorySize(at: URL(fileURLWithPath: modelPath))
        guard totalBytes > 0 else {
            return "Unknown"
        }

        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private var setupStatusDetail: String {
        if modelDownloader.isDownloading {
            return "\(Int(modelDownloader.downloadProgress * 100))% downloaded locally."
        }

        if modelDownloader.canResumeDownload {
            return "Resume the model download and setup."
        }

        if modelDownloader.error != nil {
            return "The local model setup needs attention."
        }

        if llmService.isModelLoading {
            return "Loading the local model into memory."
        }

        if llmService.isTextModelReady {
            return "Ready to chat fully on-device."
        }

        if modelDownloader.isDownloaded {
            return "Downloaded locally. Load it when you are ready to chat."
        }

        return "Check download progress and local setup."
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private func tokenLabel(_ count: Int) -> String {
        if count >= 1024 {
            return String(format: "%.1fK", Double(count) / 1024.0)
        }
        return "\(count)"
    }

    private static func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#if canImport(UIKit)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

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
private let previewConversationID = UUID()

@MainActor
private func previewChatStore(
    currentConversationID: UUID = previewConversationID,
    title: String,
    messages: [ChatMessage],
    draftText: String = ""
) -> ConversationStore {
    ConversationStore.preview(
        currentConversationID: currentConversationID,
        conversations: [
            ConversationSnapshot(
                id: currentConversationID,
                title: title,
                messages: messages,
                draftText: draftText,
                draftAttachments: []
            )
        ]
    )
}

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
    ChatView()
        .environment(LLMService.previewLoaded())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "Workout split",
                messages: [
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
        )
}

#Preview("Warm Shell") {
    ChatView()
        .environment(LLMService.previewWarmShell())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "New chat",
                messages: [],
                draftText: "Draft a short thank-you note after an interview."
            )
        )
}

#Preview("Chat Dark Compact") {
    ChatView()
        .environment(LLMService.previewLoaded())
        .environment(ModelDownloader())
        .environment(
            previewChatStore(
                title: "Travel plans",
                messages: [
                    .previewMessage(
                        user: .user,
                        text: "Build me a two-day Honolulu itinerary with food, beach time, and one rainy-day backup."
                    ),
                    .previewMessage(
                        user: .yemma,
                        text: "Day 1 can stay centered around Kakaako, Ala Moana, and Waikiki. Day 2 can lean east side with Hanauma Bay timing, a casual lunch, and a museum backup if weather turns."
                    )
                ],
                draftText: "Keep the budget moderate and avoid rental-car-only stops."
            )
        )
        .preferredColorScheme(.dark)
}
#endif
