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
