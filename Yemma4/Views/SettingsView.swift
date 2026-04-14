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
            ChatSidebarView(
                currentConversationID: nil,
                title: "Settings",
                subtitle: "Preferences, privacy, and local model controls",
                showsChatManagement: false,
                onSelectConversation: { _ in },
                onStartFresh: {},
                onShowOnboarding: {
                    dismiss()
                    onShowOnboarding()
                },
                onRunDebugScenario: onRunDebugScenario,
                onOpenArchive: {},
                onClose: { dismiss() }
            )
            .toolbar(.hidden, for: .navigationBar)
        }
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
