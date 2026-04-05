import SwiftUI

struct ConversationBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConversationStore.self) private var conversationStore

    let currentConversationID: UUID?
    let onSelectConversation: (UUID) -> Void
    let onStartFresh: () -> Void

    @State private var renameConversation: ConversationMetadata?
    @State private var renameTitle = ""

    var body: some View {
        ZStack {
            UtilityBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppTheme.Layout.sectionSpacing) {
                    header
                    introCard

                    UtilitySection("Chats") {
                        Button {
                            AppDiagnostics.shared.record("New conversation requested", category: "ui")
                            AppHaptics.selection()
                            onStartFresh()
                            dismiss()
                        } label: {
                            actionRow(
                                icon: "square.and.pencil",
                                title: "New chat",
                                subtitle: "Start another thread and keep the rest"
                            )
                        }
                        .buttonStyle(.plain)

                        if !conversationStore.conversations.isEmpty {
                            UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                        }

                        ForEach(Array(conversationStore.conversations.enumerated()), id: \.element.id) { index, metadata in
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
                                dismiss()
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

                            if index != conversationStore.conversations.count - 1 {
                                UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Layout.screenPadding)
                .padding(.bottom, 28)
            }
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
        HStack {
            Spacer()
            Text("Saved Chats")
                .font(AppTheme.Typography.utilityTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            CircleIconButton(systemName: "xmark", action: { dismiss() })
                .accessibilityLabel("Close saved chats")
        }
        .padding(.horizontal, AppTheme.Layout.screenHeaderHorizontalPadding)
        .padding(.top, 18)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved on this iPhone", systemImage: "iphone")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.accent)

            Text("Switch between chats, keep drafts in place, and rename threads when they need a clearer label.")
                .font(AppTheme.Typography.utilityRowDetail)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Layout.rowHorizontalPadding)
        .groupedCard(cornerRadius: AppTheme.Radius.medium)
    }

    private func conversationRow(_ metadata: ConversationMetadata) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: metadata.id == currentConversationID ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(metadata.id == currentConversationID ? AppTheme.accent : AppTheme.textSecondary)
                .frame(width: AppTheme.Layout.rowIconSize)

            VStack(alignment: .leading, spacing: 6) {
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

                Text(metadata.preview)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)

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
        .utilityRowPadding()
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

    private func statusChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.accentSoft)
            .clipShape(Capsule())
    }

    private static func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
private let browserPreviewCurrentID = UUID()
private let browserPreviewDraftID = UUID()

@MainActor
private func previewBrowserStore() -> ConversationStore {
    ConversationStore.preview(
        currentConversationID: browserPreviewCurrentID,
        conversations: [
            ConversationSnapshot(
                id: browserPreviewCurrentID,
                title: "Interview follow-up",
                messages: [
                    ChatMessage(
                        id: UUID().uuidString,
                        user: .user,
                        status: .sent,
                        createdAt: .now.addingTimeInterval(-1800),
                        text: "Help me tighten a thank-you note after a product interview.",
                        attachments: []
                    ),
                    ChatMessage(
                        id: UUID().uuidString,
                        user: .yemma,
                        status: .sent,
                        createdAt: .now.addingTimeInterval(-1700),
                        text: "Keep it brief, specific to one conversation point, and close with clear interest in next steps.",
                        attachments: []
                    )
                ],
                draftText: "",
                draftAttachments: []
            ),
            ConversationSnapshot(
                id: browserPreviewDraftID,
                title: "Meal prep ideas",
                messages: [
                    ChatMessage(
                        id: UUID().uuidString,
                        user: .user,
                        status: .sent,
                        createdAt: .now.addingTimeInterval(-7200),
                        text: "Give me five high-protein lunches I can prep on Sunday.",
                        attachments: []
                    )
                ],
                draftText: "Make them cheap and grocery-store simple.",
                draftAttachments: []
            )
        ]
    )
}

#Preview("Saved Chats") {
    ConversationBrowserSheet(
        currentConversationID: browserPreviewCurrentID,
        onSelectConversation: { _ in },
        onStartFresh: {}
    )
    .environment(previewBrowserStore())
}

#Preview("Saved Chats Dark Compact") {
    ConversationBrowserSheet(
        currentConversationID: browserPreviewCurrentID,
        onSelectConversation: { _ in },
        onStartFresh: {}
    )
    .environment(previewBrowserStore())
    .preferredColorScheme(.dark)
}
#endif
