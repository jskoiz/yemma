import SwiftUI

enum ConversationBrowserScope {
    case archive(recentLimit: Int)

    var title: String {
        switch self {
        case .archive:
            return "Archive"
        }
    }

    var emptyTitle: String {
        switch self {
        case .archive:
            return "No archived chats"
        }
    }

    var emptyDetail: String {
        switch self {
        case .archive:
            return "Older chats show up here once your recent list fills up."
        }
    }

    var bulkDeleteTitle: String? {
        switch self {
        case .archive:
            return "Delete archived chats"
        }
    }

    @MainActor
    func conversations(in store: ConversationStore) -> [ConversationMetadata] {
        switch self {
        case let .archive(recentLimit):
            return store.archivedConversations(limit: recentLimit)
        }
    }
}

struct ConversationBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConversationStore.self) private var conversationStore

    let scope: ConversationBrowserScope
    let currentConversationID: UUID?
    let onSelectConversation: (UUID) -> Void
    let onStartFresh: () -> Void

    @State private var renameConversation: ConversationMetadata?
    @State private var renameTitle = ""
    @State private var deleteConversation: ConversationMetadata?
    @State private var showDeleteArchivedConfirmation = false

    var body: some View {
        ZStack {
            UtilityBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppTheme.Layout.sectionSpacing) {
                    header

                    UtilitySection(scope.title) {
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

                        if !displayedConversations.isEmpty {
                            UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                        }

                        if displayedConversations.isEmpty {
                            emptyStateRow
                        } else {
                            ForEach(Array(displayedConversations.enumerated()), id: \.element.id) { index, metadata in
                                conversationListRow(metadata)

                                if index != displayedConversations.count - 1 || scope.bulkDeleteTitle != nil {
                                    UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                                }
                            }
                        }

                        if let bulkDeleteTitle = scope.bulkDeleteTitle, !displayedConversations.isEmpty {
                            Button {
                                showDeleteArchivedConfirmation = true
                            } label: {
                                destructiveActionRow(
                                    icon: "archivebox.fill",
                                    title: bulkDeleteTitle,
                                    subtitle: "Remove older local chats and keep your recent threads."
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Layout.screenPadding)
                .padding(.bottom, 28)
            }
        }
        .task {
            await conversationStore.loadIndexIfNeeded()
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
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deleteConversation != nil },
                set: { if !$0 { deleteConversation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                guard let deleteConversation else { return }
                AppDiagnostics.shared.record(
                    "Conversation deleted",
                    category: "ui",
                    metadata: ["conversationID": deleteConversation.id.uuidString]
                )
                conversationStore.deleteConversation(id: deleteConversation.id)
                self.deleteConversation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the chat from local history on this iPhone.")
        }
        .confirmationDialog(
            "Delete archived chats?",
            isPresented: $showDeleteArchivedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Archived Chats", role: .destructive) {
                guard case let .archive(recentLimit) = scope else { return }
                let removedCount = conversationStore.deleteArchivedConversations(keepingRecentLimit: recentLimit)
                AppDiagnostics.shared.record(
                    "Archived conversations deleted",
                    category: "ui",
                    metadata: ["conversations": removedCount]
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps your recent chats and removes older local threads on this iPhone.")
        }
    }

    private var displayedConversations: [ConversationMetadata] {
        scope.conversations(in: conversationStore)
    }

    private var header: some View {
        HStack {
            Spacer()
            Text(scope.title)
                .font(AppTheme.Typography.utilityTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            CircleIconButton(systemName: "xmark", action: { dismiss() })
                .accessibilityLabel("Close archive")
        }
        .padding(.horizontal, AppTheme.Layout.screenHeaderHorizontalPadding)
        .padding(.top, 18)
    }

    private var emptyStateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scope.emptyTitle)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(scope.emptyDetail)
                .font(AppTheme.Typography.utilityRowDetail)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .utilityRowPadding()
    }

    private func conversationListRow(_ metadata: ConversationMetadata) -> some View {
        HStack(alignment: .top, spacing: 0) {
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

            conversationActionsMenu(for: metadata)
                .padding(.trailing, AppTheme.Layout.rowHorizontalPadding)
                .padding(.top, 10)
        }
    }

    private func conversationActionsMenu(for metadata: ConversationMetadata) -> some View {
        Menu {
            Button {
                renameConversation = metadata
                renameTitle = metadata.title
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteConversation = metadata
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat actions")
        .accessibilityHint("Rename or delete this chat.")
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

    private func destructiveActionRow(icon: String, title: String, subtitle: String) -> some View {
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

#Preview("Archive") {
    ConversationBrowserSheet(
        scope: .archive(recentLimit: 1),
        currentConversationID: browserPreviewCurrentID,
        onSelectConversation: { _ in },
        onStartFresh: {}
    )
    .environment(previewBrowserStore())
}

#Preview("Archive Dark Compact") {
    ConversationBrowserSheet(
        scope: .archive(recentLimit: 1),
        currentConversationID: browserPreviewCurrentID,
        onSelectConversation: { _ in },
        onStartFresh: {}
    )
    .environment(previewBrowserStore())
    .preferredColorScheme(.dark)
}
#endif
