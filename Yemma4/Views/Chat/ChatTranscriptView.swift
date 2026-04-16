import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let messages: [ChatMessage]
    let appSetup: AppSetupSnapshot
    let taskStarters: [ChatStarter]
    let streamingMessageID: String?
    let isGenerating: Bool
    let completedAssistantMessageIDs: Set<String>
    let topInset: CGFloat
    @Binding var isPinnedToBottom: Bool
    @Binding var scrollViewportHeight: CGFloat
    @Binding var latestContentOverflow: CGFloat
    let onTapBackground: () -> Void
    let onJumpToLatest: () -> Void
    let onSelectStarter: (ChatStarter) -> Void
    let primarySetupActionTitle: String?
    let primarySetupAction: (() -> Void)?
    let shouldShowMessageActionStrip: (ChatMessage, Int) -> Bool
    let canRetryAssistantResponse: (ChatMessage, Int) -> Bool
    let onCopyMessageText: (String) -> Void
    let onShareMessageText: (String) -> Void
    let onRetryAssistantResponse: (ChatMessage, Int) -> Void
    let onRefineAssistantResponse: (ChatMessage, AssistantRefinement) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
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
                    .onTapGesture(perform: onTapBackground)
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

                    if shouldShowJumpToLatest {
                        jumpToLatestButton(proxy: proxy)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var bottomAnchorID: String { "conversation-bottom-anchor" }
    private let scrollCoordinateSpaceName = "conversation-scroll"
    private let pinnedThreshold: CGFloat = 48
    private let releasePinnedThreshold: CGFloat = 120

    private var shouldShowJumpToLatest: Bool {
        !messages.isEmpty && latestContentOverflow > 12
    }

    private var emptyState: some View {
        EmptyStateView(
            isModelLoaded: appSetup.isTextModelReady,
            isModelLoading: appSetup.isModelLoading,
            supportsLocalModelRuntime: appSetup.supportsLocalModelRuntime,
            modelLoadStageText: appSetup.chatStatusText,
            statusDetailText: appSetup.chatStatusDetailText,
            statusProgress: appSetup.chatStatusProgress,
            statusIsFailure: appSetup.isShowingChatFailure,
            primarySetupActionTitle: primarySetupActionTitle,
            onPrimarySetupAction: primarySetupAction,
            starters: taskStarters,
            onSelectStarter: onSelectStarter
        )
    }

    private func messageRow(_ message: ChatMessage, index: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.user.isCurrentUser {
                Spacer(minLength: 54)

                ChatUserMessageBubble(message: message)
                    .frame(maxWidth: 420, alignment: .trailing)
            } else {
                let shouldShowActionStrip = shouldShowMessageActionStrip(message, index)
                let canRetry = canRetryAssistantResponse(message, index)

                ChatAssistantMessageBody(
                    message: message,
                    index: index,
                    streamingMessageID: streamingMessageID,
                    isGenerating: isGenerating,
                    completedAssistantMessageIDs: completedAssistantMessageIDs,
                    shouldShowMessageActionStrip: shouldShowActionStrip,
                    canRetryAssistantResponse: canRetry,
                    onCopyMessageText: onCopyMessageText,
                    onShareMessageText: onShareMessageText,
                    onRetryAssistantResponse: onRetryAssistantResponse,
                    onRefineAssistantResponse: onRefineAssistantResponse
                )
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

    private func scrollToBottomIfPinned(
        proxy: ScrollViewProxy,
        animated: Bool,
        animation: Animation? = nil
    ) {
        guard isPinnedToBottom else { return }
        scrollToBottom(proxy: proxy, animated: animated, animation: animation)
    }

    private func scrollToBottom(
        proxy: ScrollViewProxy,
        animated: Bool,
        animation: Animation? = nil
    ) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        if animated {
            if reduceMotion {
                action()
            } else {
                withAnimation(animation ?? .easeOut(duration: 0.18)) {
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
        latestContentOverflow = distanceFromBottom
        let nextPinnedState =
            isPinnedToBottom
            ? distanceFromBottom <= releasePinnedThreshold
            : distanceFromBottom <= pinnedThreshold

        guard nextPinnedState != isPinnedToBottom else { return }
        isPinnedToBottom = nextPinnedState

        guard isGenerating else { return }
        AppDiagnostics.shared.record(
            nextPinnedState
                ? "Transcript latest content visible"
                : "Transcript latest content moved off-screen",
            category: "ui",
            metadata: [
                "distanceFromBottom": Int(distanceFromBottom),
                "messages": messages.count
            ]
        )
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            onJumpToLatest()
            isPinnedToBottom = true
            latestContentOverflow = 0
            scrollToBottom(proxy: proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 58, height: 58)
                .background(
                    Circle()
                        .fill(AppTheme.brandCard)
                )
                .overlay(
                    Circle()
                        .stroke(AppTheme.brandCardBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to latest")
        .accessibilityHint("Jump to the newest part of the conversation.")
        .transition(
            reduceMotion
                ? .opacity
                : .scale(scale: 0.92).combined(with: .opacity)
        )
    }
}

private struct ChatUserMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let text = displayText(for: message, isGenerating: false)
        let shouldRenderText = shouldRenderText(for: message, text: text)

        VStack(
            alignment: .trailing,
            spacing: message.attachments.isEmpty || !shouldRenderText ? 0 : 12
        ) {
            if !message.attachments.isEmpty {
                ChatAttachmentGrid(attachments: imageAttachments(for: message))
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
        .background(
            AnyShapeStyle(
                LinearGradient(
                    colors: [AppTheme.userBubbleTop, AppTheme.userBubbleBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(AppTheme.userBubbleBorder, lineWidth: 1)
        )
    }
}

private struct ChatAssistantMessageBody: View {
    let message: ChatMessage
    let index: Int
    let streamingMessageID: String?
    let isGenerating: Bool
    let completedAssistantMessageIDs: Set<String>
    let shouldShowMessageActionStrip: Bool
    let canRetryAssistantResponse: Bool
    let onCopyMessageText: (String) -> Void
    let onShareMessageText: (String) -> Void
    let onRetryAssistantResponse: (ChatMessage, Int) -> Void
    let onRefineAssistantResponse: (ChatMessage, AssistantRefinement) -> Void

    var body: some View {
        let text = displayText(for: message, isGenerating: isGenerating)
        let shouldRenderText = shouldRenderText(for: message, text: text)
        let isStreaming = message.id == streamingMessageID && isGenerating
        let isActionStripVisible = shouldShowMessageActionStrip

        VStack(alignment: .leading, spacing: 10) {
            if !message.attachments.isEmpty {
                ChatAttachmentGrid(attachments: imageAttachments(for: message))
            }

            if shouldRenderText {
                RichMessageText(text: text, isStreaming: isStreaming)
            }

            if isActionStripVisible {
                ChatMessageActionStrip(
                    messageID: message.id,
                    messageText: message.text,
                    index: index,
                    isGenerating: isGenerating,
                    canRetry: canRetryAssistantResponse,
                    onCopy: { onCopyMessageText(message.text.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    onShare: { onShareMessageText(message.text.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    onRetry: { onRetryAssistantResponse(message, index) },
                    onRefine: { onRefineAssistantResponse(message, $0) }
                )
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
            messageActionMenuItems
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isActionStripVisible)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private var messageActionMenuItems: some View {
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedText.isEmpty {
            Button {
                onCopyMessageText(trimmedText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onShareMessageText(trimmedText)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        if !message.user.isCurrentUser, canRetryAssistantResponse {
            Button {
                onRetryAssistantResponse(message, index)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }

            ForEach([AssistantRefinement.shorter, .moreDetail], id: \.rawValue) { refinement in
                Button {
                    onRefineAssistantResponse(message, refinement)
                } label: {
                    Label(refinement.title, systemImage: refinement.systemImage)
                }
            }
        }
    }
}

private struct ChatAttachmentGrid: View {
    let attachments: [Attachment]

    var body: some View {
        if attachments.count == 1, let attachment = attachments.first {
            ChatAttachmentPreviewTile(attachment: attachment, height: 216)
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(attachments, id: \.id) { attachment in
                    ChatAttachmentPreviewTile(attachment: attachment, height: 112)
                }
            }
        }
    }
}

struct ChatAttachmentPreviewTile: View {
    let attachment: Attachment
    let height: CGFloat

    var body: some View {
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
}

private struct ConversationBottomOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private func displayText(for message: ChatMessage, isGenerating: Bool) -> String {
    if !message.user.isCurrentUser, message.text.isEmpty, isGenerating {
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
