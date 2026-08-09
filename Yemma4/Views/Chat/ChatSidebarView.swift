import SwiftUI

struct ChatSidebarView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue

    let currentConversationID: UUID?
    let title: String
    let subtitle: String
    let showsChatManagement: Bool
    let onSelectConversation: (UUID) -> Void
    let onStartFresh: () -> Void
    let onShowOnboarding: () -> Void
    let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?
    let onOpenArchive: () -> Void
    let onClose: () -> Void

    @State private var renameConversation: ConversationMetadata?
    @State private var renameTitle = ""
    @State private var deleteConversation: ConversationMetadata?
    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false

    private let repositoryURL = URL(string: "https://yemma.chat")!
    private let madeByURL = URL(string: "https://avmillabs.com")!
    private let privacyURL = URL(string: "https://yemma.chat/privacy/")!
    private let recentConversationLimit = 5

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
                        preferencesSection
                        if showsChatManagement {
                            chatsSection
                        }
                        modelSection
                        aboutSection
                        privacySection
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
        }
        .confirmationDialog(
            "Delete the downloaded model?",
            isPresented: $showDeleteModelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                Task {
                    if llmService.selectedRuntime == .gemma4 {
                        guard await llmService.unloadModel() else { return }
                    }
                    await modelDownloader.deleteModel()
                    if llmService.selectedRuntime == .gemma4 {
                        onShowOnboarding()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the optional Gemma 4 files. Apple's built-in model is unaffected.")
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
                Text(title)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.textPrimary)
                    .shadow(color: Color.white.opacity(0.18), radius: 10, x: 0, y: 2)

                Text(subtitle)
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

    private var preferencesSection: some View {
        UtilitySection("Preferences") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    rowHeader(title: "Response style", detail: llmService.activeResponseStyleTitle)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                        ForEach(ResponseStylePreset.allCases) { preset in
                            responseStyleChip(preset)
                        }
                    }

                    Text(selectedResponseStyleSummary)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        let recentConversations = conversationStore.recentConversations(limit: recentConversationLimit)
        let archivedConversationCount = conversationStore.archivedConversations(limit: recentConversationLimit).count

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
                conversationListRow(metadata)

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
                icon: "cpu",
                title: "Active runtime",
                detail: llmService.selectedRuntime.runtimeName
            )
            UtilitySectionSeparator()
            infoRow(
                icon: "shippingbox",
                title: "Gemma storage",
                detail: modelSizeText
            )
            UtilitySectionSeparator()
            advancedRow
            UtilitySectionSeparator()

            destructiveRow(
                icon: "externaldrive.badge.minus",
                title: "Delete downloaded model",
                subtitle: "Remove the optional Gemma 4 files from this iPhone.",
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

    private var privacySection: some View {
        UtilitySection("Privacy") {
            trustRow
            UtilitySectionSeparator()
            linkRow(
                icon: "hand.raised.fill",
                title: "Privacy policy",
                subtitle: "What stays local and how Yemma handles it.",
                url: privacyURL
            )
            UtilitySectionSeparator()
            destructiveRow(
                icon: "trash",
                title: "Delete conversation history",
                subtitle: "Remove saved local chats, drafts, and attached images."
            ) {
                showClearConversationConfirmation = true
            }
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

    private var selectedResponseStyleSummary: String {
        llmService.activeResponseStylePreset?.summary ?? "Custom mix of reply length and detail."
    }

    private var advancedRow: some View {
        NavigationLink {
            AdvancedSettingsView(
                onShowSetupPage: onShowOnboarding,
                onRunDebugScenario: onRunDebugScenario
            )
        } label: {
            actionRow(
                icon: "gearshape.2",
                title: "Advanced",
                subtitle: "Model controls, setup, diagnostics, and debug tools."
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens advanced model controls, setup, diagnostics, and debug tools.")
    }

    private var trustRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("On-device only")
                    .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Chats, drafts, and attachments stay local to this iPhone.")
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
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
            } label: {
                conversationRow(metadata)
            }
            .buttonStyle(.plain)

            conversationActionsMenu(for: metadata)
                .padding(.trailing, AppTheme.Layout.rowHorizontalPadding)
                .padding(.top, 8)
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

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private static func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
