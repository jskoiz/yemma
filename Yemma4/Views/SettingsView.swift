import SwiftUI

public struct SettingsView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false

    private let onClearConversation: () -> Void

    public init(onClearConversation: @escaping () -> Void) {
        self.onClearConversation = onClearConversation
    }

    public var body: some View {
        List {
            Section(content: {
                LabeledContent("Name") {
                    Text("Gemma 4 E4B Q4_K_M")
                }
                LabeledContent("Stored") {
                    Text(modelSizeText)
                }

                Button(role: .destructive) {
                    showDeleteModelConfirmation = true
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            }, header: {
                Text("Model")
            }, footer: {
                Text("Removing the model frees storage and returns you to the download screen.")
            })

            Section(content: {
                Button(role: .destructive) {
                    showClearConversationConfirmation = true
                } label: {
                    Label("Clear Conversation", systemImage: "trash.circle")
                }
            }, header: {
                Text("Chat")
            }, footer: {
                Text("This clears the current chat thread on this device.")
            })

            Section(content: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(temperatureText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { llmService.temperature },
                            set: { llmService.temperature = $0 }
                        ),
                        in: 0.1...2.0,
                        step: 0.1
                    )

                    Text("Lower values are more focused. Higher values are more creative.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }, header: {
                Text("Advanced")
            })

            Section(content: {
                LabeledContent("Version") {
                    Text(appVersionText)
                }

                Link(destination: URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF")!) {
                    Label("Powered by Gemma 4 (Apache 2.0)", systemImage: "link")
                }

                Link(destination: URL(string: "https://github.com/ggml-org/llama.cpp")!) {
                    Label("Built with llama.cpp (MIT)", systemImage: "link")
                }

                Link(destination: URL(string: "https://github.com/jskoiz/yemma-4")!) {
                    Label("Project Repository", systemImage: "link")
                }
            }, header: {
                Text("About")
            })
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete the downloaded model?",
            isPresented: $showDeleteModelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                modelDownloader.deleteModel()
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
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the current local chat history.")
        }
    }

    private var modelSizeText: String {
        guard let modelPath = modelDownloader.modelPath else {
            return "Not downloaded"
        }

        let fileManager = FileManager.default
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: modelPath),
            let size = attributes[.size] as? NSNumber
        else {
            return "Unknown"
        }

        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private var temperatureText: String {
        String(format: "%.1f", llmService.temperature)
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}
