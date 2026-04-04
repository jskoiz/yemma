import Observation
import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(LLMService.self) private var llmService

    @State private var session: ChatSessionController?
    @State private var showSettings = false
    @State private var showConversations = false
    @FocusState private var isComposerFocused: Bool

    private let initialMessages: [ChatMessage]
    private let onShowOnboarding: () -> Void

    public init(
        initialMessages: [ChatMessage] = [],
        onShowOnboarding: @escaping () -> Void = {}
    ) {
        self.initialMessages = initialMessages
        self.onShowOnboarding = onShowOnboarding
    }

    public var body: some View {
        NavigationStack {
            if let session {
                chatContent(session)
            }
        }
        .task {
            if session == nil {
                let controller = ChatSessionController(llmService: llmService)
                controller.messages = initialMessages
                session = controller
            }
        }
    }

    @ViewBuilder
    private func chatContent(_ session: ChatSessionController) -> some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                topBar(session)
                messageList(session)
            }

            if let toastMessage = session.toastMessage {
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
            ComposerBar(
                draft: Binding(
                    get: { session.draft },
                    set: { session.draft = $0 }
                ),
                selectedPhotoItems: Binding(
                    get: { session.selectedPhotoItems },
                    set: { session.selectedPhotoItems = $0 }
                ),
                isComposerFocused: $isComposerFocused,
                pendingAttachments: session.pendingAttachments,
                isGenerating: session.isGenerating,
                isImportingAttachments: session.isImportingAttachments,
                canSubmit: session.canSubmitDraft,
                showQuickPrompts: session.messages.isEmpty,
                showTypingIndicator: session.shouldShowTypingIndicator,
                onSubmit: { session.submitDraft() },
                onStop: {
                    Task { @MainActor in
                        await session.stopGeneration()
                    }
                },
                onRemoveAttachment: { id in
                    session.pendingAttachments.removeAll { $0.id == id }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                onClearConversation: {
                    Task { @MainActor in
                        await session.clearConversation()
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
                        await session.runDebugScenario(scenario)
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $showConversations) {
            ConversationBrowserSheet(
                messages: session.messages,
                onStartFresh: {
                    Task { @MainActor in
                        await session.clearConversation()
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
                await session.stopGeneration()
            }
        }
        .onChange(of: session.selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { @MainActor in
                await session.importSelectedPhotos(from: newItems)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toastMessage)
        .alert(
            "Generation Failed",
            isPresented: Binding(
                get: { session.generationError != nil },
                set: { if !$0 { session.generationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.generationError = nil }
        } message: {
            Text(session.generationError ?? "The model could not generate a response.")
        }
        .alert(
            "Low Memory",
            isPresented: Binding(
                get: { session.memoryAlertMessage != nil },
                set: { if !$0 { session.memoryAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.memoryAlertMessage = nil }
        } message: {
            Text(session.memoryAlertMessage ?? "Your device ran low on memory. Try a shorter conversation.")
        }
    }

    private func topBar(_ session: ChatSessionController) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                CircleIconButton(systemName: "gearshape", action: { showSettings = true })
                CircleIconButton(systemName: "bubble.left.and.bubble.right", action: { showConversations = true })
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(AppTheme.controlFill)
                    .overlay(Capsule().stroke(AppTheme.controlBorder, lineWidth: 1))
            )

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil") {
                Task { @MainActor in
                    await session.clearConversation()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func messageList(_ session: ChatSessionController) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: session.messages.isEmpty ? 26 : 14) {
                    if session.messages.isEmpty {
                        EmptyStateView(
                            isModelLoaded: llmService.isModelLoaded,
                            isModelLoading: llmService.isModelLoading,
                            supportsLocalModelRuntime: Yemma4AppConfiguration.supportsLocalModelRuntime,
                            modelLoadStageText: llmService.modelLoadStage.statusText
                        )
                    } else {
                        ForEach(session.messages, id: \.id) { message in
                            messageRow(message, session: session)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, minHeight: 0)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { isComposerFocused = false }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.messages.count) { _, _ in
                guard let lastID = session.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func messageRow(_ message: ChatMessage, session: ChatSessionController) -> some View {
        HStack {
            if message.user.isCurrentUser {
                Spacer(minLength: 54)
            }

            VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 6) {
                if !message.user.isCurrentUser {
                    Text("Yemma 4")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 2)
                }

                messageBubble(message, session: session)
            }
            .frame(maxWidth: 420, alignment: message.user.isCurrentUser ? .trailing : .leading)

            if !message.user.isCurrentUser {
                Spacer(minLength: 54)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage, session: ChatSessionController) -> some View {
        let text = session.displayText(for: message)
        let shouldRenderText = session.shouldRenderText(for: message, text: text)
        let background: AnyShapeStyle = message.user.isCurrentUser
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [AppTheme.userBubbleTop, AppTheme.userBubbleBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            : AnyShapeStyle(AppTheme.assistantBubble)

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
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } else if session.streamingMessageID == message.id {
                        // Plain text during streaming to avoid costly markdown parsing per token
                        Text(text)
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        RichMessageText(text: text)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.messageBubbleBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func attachmentGrid(for message: ChatMessage) -> some View {
        let attachments = message.attachments.filter { $0.type == .image }

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
                .stroke(AppTheme.messageBubbleBorder, lineWidth: 1)
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
}

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
#endif
