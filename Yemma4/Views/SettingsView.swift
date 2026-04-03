import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelDownloader.self) private var modelDownloader
    @Environment(LLMService.self) private var llmService

    @State private var showDeleteModelConfirmation = false
    @State private var showClearConversationConfirmation = false

    private let onClearConversation: () -> Void

    public init(onClearConversation: @escaping () -> Void) {
        self.onClearConversation = onClearConversation
    }

    public var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    appSection
                    aboutSection
                    moreSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .confirmationDialog(
            "Delete the downloaded model?",
            isPresented: $showDeleteModelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                modelDownloader.deleteModel()
                dismiss()
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
                temperatureRow
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
                infoRow(icon: "info.circle", title: "Version", detail: appVersionText)
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

    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Creativity", systemImage: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(temperatureText)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { llmService.temperature },
                    set: { llmService.temperature = $0 }
                ),
                in: 0.1...2.0,
                step: 0.1
            )
            .tint(.black)

            Text("Lower values stay focused. Higher values improvise more.")
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

    private var separator: some View {
        Divider()
            .padding(.leading, 52)
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
