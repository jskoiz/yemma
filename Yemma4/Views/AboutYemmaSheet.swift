import SwiftUI

struct AboutYemmaSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("A little help, right here") {
                    Label("Rewrite a message, summarize text, or think through a decision.", systemImage: "text.bubble")
                    Label("Your prompts and replies are processed on this iPhone.", systemImage: "iphone")
                }
                Section("Choose what you need") {
                    Text("On eligible devices, Apple's built-in model handles text without a Yemma model download.")
                    Text("The optional Qwen3.5 4B model adds image understanding with a 3.05 GB download. Setup starts only when you choose it.")
                    Text("Scan text uses the camera to read words locally. You can review and edit the text before sending it to either model.")
                }
                Section("Good to know") {
                    Text("Yemma can make mistakes and does not browse the web for current information. Check important details.")
                    Text("Chats are saved on this iPhone. You control what you copy, share, save, and delete.")
                }
            }
            .navigationTitle("About Yemma")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
