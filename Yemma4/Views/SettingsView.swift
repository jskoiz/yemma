import SwiftUI

public enum DebugInferenceScenario: String, CaseIterable, Identifiable {
    case rendererCoverage
    case markdownFormatting
    case codeBlocks
    case tablesAndEscaping
    case longFormAnswer

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .rendererCoverage:
            return "textformat.alt"
        case .markdownFormatting:
            return "text.quote"
        case .codeBlocks:
            return "curlybraces.square"
        case .tablesAndEscaping:
            return "tablecells"
        case .longFormAnswer:
            return "doc.plaintext"
        }
    }

    var title: String {
        switch self {
        case .rendererCoverage:
            return "Insert renderer coverage sample"
        case .markdownFormatting:
            return "Run markdown formatting test"
        case .codeBlocks:
            return "Run code block test"
        case .tablesAndEscaping:
            return "Run table and escaping test"
        case .longFormAnswer:
            return "Run long-form answer test"
        }
    }

    var detail: String {
        switch self {
        case .rendererCoverage:
            return "Seeds a local transcript with headings, lists, quotes, links, code, and a table."
        case .markdownFormatting:
            return "Checks headings, emphasis, bullet lists, numbered lists, links, and a fenced Swift block."
        case .codeBlocks:
            return "Checks short explanation flow plus fenced Swift and JSON code blocks."
        case .tablesAndEscaping:
            return "Checks markdown tables, inline backticks, and characters that often break rendering."
        case .longFormAnswer:
            return "Checks section boundaries, multi-part structure, and formatting stability in longer output."
        }
    }

    var prompt: String? {
        switch self {
        case .rendererCoverage:
            return nil
        case .markdownFormatting:
            return #"""
            Return GitHub-flavored Markdown only. Use this exact structure and no extra intro or outro:

            ## Formatting Check
            One short paragraph that includes bold text, italic text, inline code, and a hyperlink to https://example.com labeled Example.

            ## List Check
            A 3-item unordered list.
            A 3-item ordered list.

            ## Quote Check
            A one-sentence blockquote.

            ## Code Check
            One fenced code block tagged swift with a tiny function.
            """#
        case .codeBlocks:
            return #"""
            Explain how to load a local JSON file in Swift. Use this exact structure and nothing else:

            ## Code Review
            Two short sentences.

            ```swift
            // example code only
            ```

            ```json
            { "ok": true, "count": 3 }
            ```

            ### Common mistakes
            - exactly three bullet points
            """#
        case .tablesAndEscaping:
            return #"""
            Respond in Markdown only with this structure:

            ## Table Check
            Two short sentences about comparing Swift string containers.

            | Type | Memory | Speed | Notes |
            | --- | --- | --- | --- |
            | String | ... | ... | ... |
            | Substring | ... | ... | ... |
            | [Character] | ... | ... | ... |

            ## Escaping Check
            One sentence that includes the literal characters `|`, `*`, and `_` inside inline code.

            ## Final Notes
            A 2-item bullet list.
            """#
        case .longFormAnswer:
            return #"""
            Write a compact answer about building an on-device chat app. Use exactly four sections with `##` headings. Each section must have exactly two bullet points, and one section must also include a fenced `swift` code block. Keep the total answer under 260 words and do not add any content before the first heading or after the last bullet.
            """#
        }
    }

    var sampleTranscript: (user: String, assistant: String)? {
        switch self {
        case .rendererCoverage:
            return (
                user: "Show me a rendering sample that covers the main markdown styles this chat UI should handle.",
                assistant: #"""
                ## Rendering Coverage

                This line checks **bold**, *italic*, and `inline code`, plus a link to [Example](https://example.com).

                ### Bullets
                - First item
                - Second item with `embedded code`
                - Third item with **emphasis**

                ### Steps
                1. Open the debug menu.
                2. Trigger a canned test.
                3. Inspect spacing and wrapping.

                ### Quote
                > Blockquotes should keep the accent tint and remain easy to scan.

                ### Swift
                ```swift
                func greet(name: String) -> String {
                    "Hello, \(name)"
                }
                ```

                ### JSON
                ```json
                {
                  "ok": true,
                  "count": 3
                }
                ```

                ### Table
                | Surface | What to inspect |
                | --- | --- |
                | Heading spacing | Consistent top and bottom rhythm |
                | Code block | Horizontal scroll and monospace font |
                | Link tint | Accent color and tap target |
                """#
            )
        default:
            return nil
        }
    }
}

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue

    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false
    @State private var didMigrateFocusedDefault = false

    private let onShowOnboarding: () -> Void
    private let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?

    public init(
        onShowOnboarding: @escaping () -> Void,
        onRunDebugScenario: ((DebugInferenceScenario) -> Void)? = nil
    ) {
        self.onShowOnboarding = onShowOnboarding
        self.onRunDebugScenario = onRunDebugScenario
    }

    private let repositoryURL = URL(string: "https://yemma.chat")!
    private let madeByURL = URL(string: "https://avmillabs.com")!
    private let licenseURL = URL(string: "https://github.com/jskoiz/yemma/blob/main/LICENSE")!
    private let metadataURL = URL(string: "https://github.com/jskoiz/yemma/blob/main/METADATA.md")!
    private let privacyURL = URL(string: "https://yemma.chat/privacy/")!
    private let supportURL = URL(string: "https://yemma.chat/support/")!

    public var body: some View {
        NavigationStack {
            ZStack {
                UtilityBackground()

                ProgressiveBlurHeaderHost(
                    initialHeaderHeight: 88,
                    maxBlurRadius: 12,
                    fadeExtension: 88,
                    tintOpacityTop: 0.66,
                    tintOpacityMiddle: 0.24
                ) { headerHeight in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: AppTheme.Layout.sectionSpacing) {
                            everydaySection
                            modelStorageSection
                            trustSection
                            aboutSection
                        }
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Layout.screenPadding)
                        .padding(.top, 28)
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
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            migrateFocusedResponseStyleIfNeeded()
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
                    dismiss()
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
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved local chats, drafts, and attached images on this iPhone.")
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("Settings")
                .font(AppTheme.Typography.utilityTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            CircleIconButton(systemName: "xmark", action: { dismiss() })
                .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 4)
    }

    private var everydaySection: some View {
        UtilitySection("Everyday") {
            responseStyleRow
            UtilitySectionSeparator()
            appearanceRow
        }
    }

    private var modelStorageSection: some View {
        UtilitySection("Model & Storage") {
            infoRow(
                icon: "shippingbox",
                title: "Local model",
                detail: modelSizeText,
                accessibilityHint: "Shows the amount of space used by the downloaded on-device model."
            )
            UtilitySectionSeparator()
            Button {
                AppHaptics.selection()
                dismiss()
                onShowOnboarding()
            } label: {
                utilityActionRow(
                    icon: "sparkles.rectangle.stack",
                    title: "Setup status",
                    detail: "Check download progress and local setup."
                )
            }
            .buttonStyle(.plain)
            UtilitySectionSeparator()
            advancedRow
            UtilitySectionSeparator()
            destructiveRow(
                icon: "trash",
                title: "Delete conversation history",
                accessibilityHint: "Deletes saved chats and drafts from this iPhone."
            ) {
                showClearConversationConfirmation = true
            }
            UtilitySectionSeparator()
            destructiveRow(
                icon: "externaldrive.badge.minus",
                title: "Delete downloaded model",
                accessibilityHint: "Removes the local model and sends the app back to setup."
            ) {
                showDeleteModelConfirmation = true
            }
        }
    }

    private var trustSection: some View {
        UtilitySection("Privacy & Trust") {
            trustRow
            UtilitySectionSeparator()
            linkRow(
                icon: "doc.text",
                title: "MIT license",
                detail: "Read the app license.",
                url: licenseURL,
                accessibilityHint: "Opens the app license in Safari."
            )
            UtilitySectionSeparator()
            linkRow(
                icon: "shield.lefthalf.filled",
                title: "Model and privacy details",
                detail: "Learn where the model comes from and what stays local.",
                url: metadataURL,
                accessibilityHint: "Opens model and privacy details in Safari."
            )
            UtilitySectionSeparator()
            linkRow(
                icon: "hand.raised.fill",
                title: "Privacy policy",
                detail: "What data stays local and how Yemma handles it.",
                url: privacyURL,
                accessibilityHint: "Opens the privacy policy in Safari."
            )
            UtilitySectionSeparator()
            linkRow(
                icon: "lifepreserver",
                title: "Support and feedback",
                detail: "Support contact, troubleshooting, and privacy help.",
                url: supportURL,
                accessibilityHint: "Opens the support page in Safari."
            )
        }
    }

    private var aboutSection: some View {
        UtilitySection("About") {
            linkRow(
                icon: "link",
                title: "Project page",
                detail: "yemma.chat",
                url: repositoryURL,
                accessibilityHint: "Opens the project page in Safari."
            )
            UtilitySectionSeparator()
            linkRow(
                icon: "building.2",
                title: "Made by",
                detail: "AVMIL Labs in Honolulu 🤙",
                url: madeByURL,
                accessibilityHint: "Opens the maker website in Safari."
            )
            UtilitySectionSeparator()
            infoRow(icon: "info.circle", title: "Version", detail: appVersionText)
        }
    }

    private var trustRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On-device only", systemImage: "lock.shield.fill")
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)

            Text("Chats, attachments, and prompts stay local to this device.")
                .font(AppTheme.Typography.utilityRowDetail)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private var responseStyleRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Response style", systemImage: "bolt.circle")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(llmService.activeResponseStyleTitle)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Text("Choose the default tone, length, and focus for replies.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(ResponseStylePreset.allCases) { preset in
                    Button {
                        applyResponseStylePreset(preset)
                    } label: {
                        responseStyleButton(preset)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
    }

    private func responseStyleButton(_ preset: ResponseStylePreset) -> some View {
        let isSelected = llmService.activeResponseStylePreset == preset

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AppTheme.accentSoft : AppTheme.controlFill)
                    .frame(width: 30, height: 30)

                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(preset.title)
                        .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    if isSelected {
                        Text("Current")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.accentSoft)
                            .clipShape(Capsule())
                    }
                }

                Text(preset.summary)
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .fill(isSelected ? AppTheme.accentSoft : AppTheme.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(isSelected ? AppTheme.accent.opacity(0.35) : AppTheme.separator.opacity(0.75), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.title)
        .accessibilityValue(isSelected ? "Current" : "Not selected")
        .accessibilityHint("Applies \(preset.summary.lowercased())")
    }

    private var advancedRow: some View {
        NavigationLink {
            AdvancedSettingsView(onRunDebugScenario: onRunDebugScenario)
        } label: {
            utilityActionRow(
                icon: "gearshape.2",
                title: "Advanced",
                detail: "Model tuning, storage, diagnostics, and debug tools."
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens advanced model, storage, diagnostics, and debug controls.")
    }

    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(selectedAppearancePreference.title)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

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
                        Text(appearance.title)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text("Match your iPhone by default, or keep Yemma in light or dark mode.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
    }

    private func infoRow(
        icon: String,
        title: String,
        detail: String,
        accessibilityHint: String? = nil
    ) -> some View {
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
        .accessibilityHint(accessibilityHint ?? "")
    }

    private func destructiveRow(
        icon: String,
        title: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            utilityActionRow(icon: icon, title: title, titleColor: AppTheme.destructive, chevronColor: AppTheme.destructive)
                .accessibilityHint(accessibilityHint ?? "")
        }
        .buttonStyle(.plain)
    }

    private func linkRow(
        icon: String,
        title: String,
        detail: String,
        url: URL,
        accessibilityHint: String? = nil
    ) -> some View {
        Link(destination: url) {
            utilityActionRow(icon: icon, title: title, detail: detail)
                .accessibilityHint(accessibilityHint ?? "")
        }
        .buttonStyle(.plain)
    }

    private func utilityActionRow(
        icon: String,
        title: String,
        detail: String? = nil,
        titleColor: Color = AppTheme.textPrimary,
        chevronColor: Color = AppTheme.textSecondary
    ) -> some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(titleColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(titleColor)

                    if let detail {
                        Text(detail)
                            .font(AppTheme.Typography.utilityCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(chevronColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .frame(width: AppTheme.Layout.rowIconSize)
                        .foregroundStyle(titleColor)

                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(titleColor)
                }

                if let detail {
                    Text(detail)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.leading, AppTheme.Layout.rowIconSize + 14)
                }

                HStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(chevronColor)
                }
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private func applyResponseStylePreset(_ preset: ResponseStylePreset) {
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
    }

    private func migrateFocusedResponseStyleIfNeeded() {
        guard !didMigrateFocusedDefault else { return }
        didMigrateFocusedDefault = true

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "llm_temperature") == nil,
              defaults.object(forKey: "llm_maxResponseTokens") == nil else {
            return
        }

        applyResponseStylePreset(.focused)
    }

    private var modelSizeText: String {
        guard let modelPath = modelDownloader.modelPath else {
            return "Not downloaded"
        }

        let totalBytes = Gemma4MLXSupport.directorySize(at: URL(fileURLWithPath: modelPath))
        guard totalBytes > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
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

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(onShowOnboarding: {})
        .environment(ModelDownloader())
        .environment(LLMService())
        .environment(ConversationStore.preview())
}

#Preview("Settings Accessibility") {
    SettingsView(onShowOnboarding: {})
        .environment(ModelDownloader())
        .environment(LLMService())
        .environment(ConversationStore.preview())
        .dynamicTypeSize(.accessibility3)
        .preferredColorScheme(.dark)
}

#Preview("Settings Compact") {
    SettingsView(onShowOnboarding: {})
        .environment(ModelDownloader())
        .environment(LLMService())
        .environment(ConversationStore.preview())
        .preferredColorScheme(.dark)
}
#endif
