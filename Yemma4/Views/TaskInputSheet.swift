import SwiftUI

enum GuidedTask: String, Identifiable, CaseIterable {
    case rewrite, summarize, ask, decide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rewrite: return "Rewrite"
        case .summarize: return "Summarize"
        case .ask: return "Ask"
        case .decide: return "Help me decide"
        }
    }
    var symbol: String {
        switch self {
        case .rewrite: return "pencil.line"
        case .summarize: return "text.alignleft"
        case .ask: return "questionmark.bubble"
        case .decide: return "arrow.triangle.branch"
        }
    }
    var inputLabel: String {
        switch self {
        case .rewrite: return "Text to rewrite"
        case .summarize: return "Text to summarize"
        case .ask: return "Your question"
        case .decide: return "Your options and what matters to you"
        }
    }
    func prompt(input: String, tone: String = "Natural") -> String {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .rewrite:
            return "Rewrite the text below in a \(tone.lowercased()) tone. Preserve its meaning and facts. Return the rewritten text.\n\n\(source)"
        case .summarize:
            return "Summarize the text below clearly. Include the main points and any stated next steps. Do not add facts that are not in the source.\n\n\(source)"
        case .ask: return source
        case .decide:
            return "Help me compare these options using the priorities I describe. Explain the main tradeoffs and ask about missing information if it would change the decision.\n\n\(source)"
        }
    }
}

struct TaskInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: GuidedTask
    let onUsePrompt: (String) -> Void
    @State private var input: String
    @State private var tone = "Natural"
    @FocusState private var isFocused: Bool
    static let maximumCharacters = 12_000

    init(task: GuidedTask, initialText: String = "", onUsePrompt: @escaping (String) -> Void) {
        self.task = task
        self.onUsePrompt = onUsePrompt
        _input = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(task.inputLabel) {
                    TextEditor(text: $input).frame(minHeight: 180)
                        .focused($isFocused).accessibilityLabel(task.inputLabel)
                }
                if task == .rewrite {
                    Picker("Tone", selection: $tone) {
                        ForEach(["Natural", "Friendly", "Professional"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Text("Review the draft in chat before sending. Longer text may need to be split into smaller parts for your on-device model.")
                        .foregroundStyle(.secondary)
                    Text("\(input.count.formatted()) / \(Self.maximumCharacters.formatted()) characters")
                        .foregroundStyle(input.count > Self.maximumCharacters ? Color.red : Color.secondary)
                }
            }
            .navigationTitle(task.title)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }
                        .accessibilityIdentifier("taskInputKeyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use draft") { onUsePrompt(task.prompt(input: input, tone: tone)); dismiss() }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.count > Self.maximumCharacters)
                }
            }
            .task { isFocused = true }
        }
    }
}
