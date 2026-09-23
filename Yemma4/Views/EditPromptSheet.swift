import SwiftUI

struct EditPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let onSave: (String) -> Void
    @State private var text: String

    init(message: ChatMessage, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your question") {
                    TextEditor(text: $text).frame(minHeight: 180)
                        .accessibilityLabel("Edit question")
                }
                Section {
                    Text("This creates a new chat with the earlier context and your edited question as a draft. Your original chat stays saved.")
                    if !message.attachments.isEmpty {
                        Text("Attached images will be copied to the new chat.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Edit question")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create draft") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty)
                }
            }
        }
    }
}
