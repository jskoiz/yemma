import SwiftUI
import ExyteChat

struct ConversationBrowserSheet: View {
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
            AppBackground()

            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Text("Conversations")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    CircleIconButton(systemName: "xmark", action: { dismiss() })
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Restart With Intention")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("Use Fresh chat to clear context before switching topics. The current conversation stays previewed below so you can jump back in and keep your place.")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        Spacer()

                        CircleIconButton(systemName: "xmark", filled: false, action: {})
                            .allowsHitTesting(false)
                    }
                }
                .padding(18)
                .glassCard(cornerRadius: 24)
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text("All conversations")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)

                    VStack(spacing: 0) {
                        Button {
                            dismiss()
                        } label: {
                            conversationRow(title: conversationPreview, subtitle: messages.isEmpty ? "Start chatting" : "Current conversation")
                        }

                        Divider()
                            .padding(.leading, 18)
                            .overlay(AppTheme.separator)

                        Button {
                            onStartFresh()
                        } label: {
                            conversationRow(title: "Fresh chat", subtitle: "Clear current thread")
                        }
                    }
                    .glassCard(cornerRadius: 24)
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Spacer()
                }
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .glassCard(cornerRadius: 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private func conversationRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
