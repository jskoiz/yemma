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
    @Environment(AppDiagnostics.self) private var diagnostics
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue

    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false
    @State private var diagnosticsCopied = false

    private let onClearConversation: () -> Void
    private let onShowOnboarding: () -> Void
    private let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?

    public init(
        onClearConversation: @escaping () -> Void,
        onShowOnboarding: @escaping () -> Void,
        onRunDebugScenario: ((DebugInferenceScenario) -> Void)? = nil
    ) {
        self.onClearConversation = onClearConversation
        self.onShowOnboarding = onShowOnboarding
        self.onRunDebugScenario = onRunDebugScenario
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header
                        appSection
                        diagnosticsSection
#if DEBUG
                        if onRunDebugScenario != nil {
                            debugSection
                        }
#endif
                        aboutSection
                        moreSection
                    }
                    .padding(.horizontal, 16)
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
            "Clear the current conversation?",
            isPresented: $showClearConversationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Conversation", role: .destructive) {
                onClearConversation()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the current local chat history.")
        }
        .alert("Diagnostics copied", isPresented: $diagnosticsCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The recent diagnostics log is on the pasteboard.")
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("Settings")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            CircleIconButton(systemName: "xmark", action: { dismiss() })
        }
        .padding(.horizontal, 4)
    }

    private var appSection: some View {
        settingsSection("App") {
            VStack(spacing: 0) {
                infoRow(icon: "shippingbox", title: "Manage models", detail: modelSizeText)
                separator
                appearanceRow
                separator
                advancedRow
                separator
                Button {
                    dismiss()
                    onShowOnboarding()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .frame(width: 22)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("View onboarding screen")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                separator
                destructiveRow(icon: "trash", title: "Delete conversation history") {
                    showClearConversationConfirmation = true
                }
            }
        }
    }

    private var aboutSection: some View {
        settingsSection("About") {
            VStack(spacing: 0) {
                linkRow(icon: "doc.text", title: "Term & Conditions", url: URL(string: "https://github.com/jskoiz/yemma-4/blob/main/LICENSE")!)
                separator
                linkRow(icon: "lock", title: "Privacy Policy", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
                separator
                linkRow(icon: "books.vertical", title: "Licenses", url: URL(string: "https://github.com/ggml-org/llama.cpp")!)
                separator
                infoRow(icon: "building.2", title: "Made by", detail: "AVMIL Labs in Honolulu, Hawaii")
                separator
                infoRow(icon: "info.circle", title: "Version", detail: appVersionText)
            }
        }
    }

    private var diagnosticsSection: some View {
        settingsSection("Diagnostics") {
            VStack(spacing: 0) {
                infoRow(icon: "waveform.path.ecg", title: "Recent events", detail: "\(diagnostics.recentEvents.count)")
                separator
                Button {
                    diagnostics.copyToPasteboard()
                    diagnosticsCopied = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 22)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Copy diagnostics log")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                separator
                destructiveRow(icon: "trash", title: "Clear diagnostics log") {
                    diagnostics.clear()
                }

                if diagnostics.recentEvents.isEmpty {
                    separator
                    infoRow(icon: "info.circle", title: "Latest", detail: "No events yet")
                } else {
                    ForEach(Array(diagnostics.recentEvents.suffix(8).reversed())) { event in
                        separator
                        diagnosticEventRow(event)
                    }
                }
            }
        }
    }

    private var moreSection: some View {
        settingsSection("More") {
            VStack(spacing: 0) {
                linkRow(icon: "square.and.arrow.up", title: "Share the app", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
                separator
                linkRow(icon: "link", title: "Project repository", url: URL(string: "https://github.com/jskoiz/yemma-4")!)
                separator
                destructiveRow(icon: "externaldrive.badge.minus", title: "Delete downloaded model") {
                    showDeleteModelConfirmation = true
                }
            }
        }
    }

#if DEBUG
    private var debugSection: some View {
        settingsSection("Debug") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use these from a Debug build to probe formatting quality. Run the live prompts on a physical iPhone, since the simulator only returns mocked replies.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                if let onRunDebugScenario {
                    ForEach(DebugInferenceScenario.allCases) { scenario in
                        separator
                        actionDetailRow(
                            icon: scenario.icon,
                            title: scenario.title,
                            detail: scenario.detail
                        ) {
                            dismiss()
                            onRunDebugScenario(scenario)
                        }
                    }
                }
            }
        }
    }
#endif

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 26)
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(AppTheme.textPrimary)

            Text(title)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            Text(detail)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var advancedRow: some View {
        NavigationLink {
            AdvancedSettingsView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "gearshape.2")
                    .frame(width: 22)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Advanced")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    private func actionDetailRow(
        icon: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(detail)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(selectedAppearancePreference.title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
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
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func destructiveRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                Spacer()
            }
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(title)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private func diagnosticEventRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.category.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer()

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Text(event.message)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            if !event.metadata.isEmpty {
                Text(
                    event.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: " • ")
                )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var separator: some View {
        Divider()
            .padding(.leading, 52)
            .overlay(AppTheme.separator)
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
