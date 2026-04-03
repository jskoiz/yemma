import ExyteChat
import SwiftUI

public struct ChatView: View {
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?

    private let mockResponse = "Hello! I'm Yemma 4, running entirely on your device."

    public init() {}

    public var body: some View {
        ExyteChat.ChatView<AnyView, AnyView, DefaultMessageMenuAction>(
            messages: messages,
            chatType: .conversation,
            replyMode: .quote,
            reactionDelegate: nil,
            messageBuilder: { message, _, _, _, _, _, _ in
                AnyView(messageRow(message))
            },
            inputViewBuilder: { textBinding, _, _, _, inputViewActionClosure, _ in
                AnyView(composerView(textBinding: textBinding, sendAction: inputViewActionClosure))
            },
            messageMenuAction: nil,
            localization: localization,
            didUpdateAttachmentStatus: nil,
            didSendMessage: handleDraft
        )
        .background(backgroundColor.ignoresSafeArea())
    }

    private var backgroundColor: Color {
        Color(red: 0.04, green: 0.05, blue: 0.07)
    }

    private var localization: ChatLocalization {
        ChatLocalization(
            inputPlaceholder: "Message Yemma",
            signatureText: "Add signature...",
            cancelButtonText: "Cancel",
            recentToggleText: "Recents",
            waitingForNetwork: "Waiting for network",
            recordingText: "Recording...",
            replyToText: "Reply to"
        )
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.user.isCurrentUser {
                Spacer(minLength: 44)
            } else {
                avatarCircle
            }

            VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 6) {
                Text(message.text.isEmpty && !message.user.isCurrentUser && isGenerating ? " " : message.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(message.user.isCurrentUser ? .trailing : .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(messageBubbleBackground(for: message))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(message.user.isCurrentUser ? Color.white.opacity(0.08) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            }
            .frame(maxWidth: 280, alignment: message.user.isCurrentUser ? .trailing : .leading)

            if message.user.isCurrentUser {
                avatarSpacer
            } else {
                Spacer(minLength: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var avatarCircle: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.26, green: 0.71, blue: 0.90), Color(red: 0.48, green: 0.35, blue: 0.98)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 28, height: 28)
    }

    private var avatarSpacer: some View {
        Color.clear.frame(width: 28, height: 28)
    }

    private func messageBubbleBackground(for message: ChatMessage) -> Color {
        message.user.isCurrentUser
            ? Color(red: 0.18, green: 0.42, blue: 0.96)
            : Color.white.opacity(0.08)
    }

    private func composerView(
        textBinding: Binding<String>,
        sendAction: @escaping (ExyteChat.InputViewAction) -> Void
    ) -> some View {
        VStack(spacing: 10) {
            if isGenerating {
                typingIndicator
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Yemma", text: textBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    )

                if isGenerating {
                    Button {
                        stopGeneration()
                    } label: {
                        Text("Stop")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.82))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        sendAction(.send)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Color(red: 0.18, green: 0.42, blue: 0.96))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.22))
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.8))
                .scaleEffect(0.8)

            Text("Yemma is typing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func handleDraft(_ draft: ExyteChat.DraftMessage) {
        let trimmedText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stopGeneration()

        let userMessage = ChatMessage(
            id: UUID().uuidString,
            user: .user,
            status: .sent,
            createdAt: Date(),
            text: trimmedText
        )
        messages.append(userMessage)

        let assistantID = UUID().uuidString
        messages.append(
            ChatMessage(
                id: assistantID,
                user: .yemma,
                status: .sent,
                createdAt: Date(),
                text: ""
            )
        )

        isGenerating = true
        generationTask = Task {
            await streamMockReply(into: assistantID)
        }
    }

    private func streamMockReply(into messageID: String) async {
        var currentText = ""
        defer {
            Task { @MainActor in
                self.isGenerating = false
                self.generationTask = nil
            }
        }

        for character in mockResponse {
            if Task.isCancelled {
                return
            }

            currentText.append(character)
            await MainActor.run {
                updateMessageText(id: messageID, text: currentText)
            }

            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func updateMessageText(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }
}
