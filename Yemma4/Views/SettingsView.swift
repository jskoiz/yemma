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
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @Environment(ConversationStore.self) private var conversationStore
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue

    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false

    private let onShowOnboarding: () -> Void
    private let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?

    public init(
        onShowOnboarding: @escaping () -> Void,
        onRunDebugScenario: ((DebugInferenceScenario) -> Void)? = nil
    ) {
        self.onShowOnboarding = onShowOnboarding
        self.onRunDebugScenario = onRunDebugScenario
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                UtilityBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.sectionSpacing) {
                        header
                        appSection
                        aboutSection
                        moreSection
                    }
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            Text("Yemma 4 will return to the download screen until the model is downloaded again.")
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
            Text("This removes saved local chats and drafts on this iPhone.")
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
        }
        .padding(.horizontal, 4)
    }

    private var appSection: some View {
        UtilitySection("App") {
            infoRow(icon: "shippingbox", title: "Manage models", detail: modelSizeText)
            UtilitySectionSeparator()
            appearanceRow
            UtilitySectionSeparator()
            advancedRow
            UtilitySectionSeparator()
            Button {
                dismiss()
                onShowOnboarding()
            } label: {
                utilityActionRow(icon: "sparkles.rectangle.stack", title: "View onboarding screen")
            }
            .buttonStyle(.plain)
            UtilitySectionSeparator()
            destructiveRow(icon: "trash", title: "Delete conversation history") {
                showClearConversationConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        UtilitySection("About") {
            linkRow(icon: "doc.text", title: "Terms & Conditions", url: URL(string: "https://github.com/jskoiz/yemma-4/blob/main/LICENSE")!)
            UtilitySectionSeparator()
            linkRow(icon: "lock", title: "Privacy Policy", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
            UtilitySectionSeparator()
            linkRow(icon: "books.vertical", title: "Licenses", url: URL(string: "https://github.com/ggml-org/llama.cpp")!)
            UtilitySectionSeparator()
            infoRow(icon: "building.2", title: "Made by", detail: "AVMIL Labs in Honolulu, Hawaii")
            UtilitySectionSeparator()
            infoRow(icon: "info.circle", title: "Version", detail: appVersionText)
        }
    }

    private var moreSection: some View {
        UtilitySection("More") {
            linkRow(icon: "square.and.arrow.up", title: "Share the app", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
            UtilitySectionSeparator()
            linkRow(icon: "link", title: "Project repository", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
            UtilitySectionSeparator()
            destructiveRow(icon: "externaldrive.badge.minus", title: "Delete downloaded model") {
                showDeleteModelConfirmation = true
            }
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
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
        .utilityRowPadding()
    }

    private var advancedRow: some View {
        NavigationLink {
            AdvancedSettingsView(onRunDebugScenario: onRunDebugScenario)
        } label: {
            utilityActionRow(icon: "gearshape.2", title: "Advanced")
        }
        .buttonStyle(.plain)
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

            Picker("Appearance", selection: appearancePreferenceBinding) {
                ForEach(AppearancePreference.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text("Match your iPhone by default, or keep Yemma in light or dark mode.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .utilityRowPadding()
    }

    private func destructiveRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle)
                Spacer()
            }
            .foregroundStyle(AppTheme.destructive)
            .utilityRowPadding()
        }
        .buttonStyle(.plain)
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Link(destination: url) {
            utilityActionRow(icon: icon, title: title)
        }
    }

    private func utilityActionRow(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .utilityRowPadding()
    }

    private var modelSizeText: String {
        let localPaths = [modelDownloader.modelPath, modelDownloader.mmprojPath].compactMap { $0 }
        guard !localPaths.isEmpty else {
            return "Not downloaded"
        }

        let fileManager = FileManager.default
        let totalBytes = localPaths.reduce(into: Int64(0)) { total, path in
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: path),
                let size = attributes[.size] as? NSNumber
            else {
                return
            }
            total += size.int64Value
        }

        guard totalBytes > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private var selectedAppearancePreference: AppearancePreference {
        AppearancePreference.from(appearancePreferenceRaw)
    }

    private var appearancePreferenceBinding: Binding<AppearancePreference> {
        Binding(
            get: { selectedAppearancePreference },
            set: { appearancePreferenceRaw = $0.rawValue }
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
#endif
