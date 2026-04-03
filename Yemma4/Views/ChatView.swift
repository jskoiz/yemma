import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(LLMService.self) private var llmService

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var generationTask: Task<Void, Never>?
    @State private var generationError: String?
    @State private var memoryAlertMessage: String?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showConversations = false
    @FocusState private var isComposerFocused: Bool

    private let modelPageURL = URL(string: "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF")!
    private let quickPrompts: [(title: String, subtitle: String, prompt: String)] = [
        ("Design", "a workout routine", "Design a simple workout routine I can do at home."),
        ("Begin", "meditating", "Begin a meditation habit with a simple 7-day plan."),
        ("Explain", "a complex idea", "Explain a complex idea in a simple way.")
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    topBar
                    conversationContent
                    composerSection
                }

                if let toastMessage {
                    VStack {
                        Spacer()
                        toastView(message: toastMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 116)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView(onClearConversation: clearConversation)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $showConversations) {
                ConversationsView(
                    messages: messages,
                    onStartFresh: {
                        clearConversation()
                        showConversations = false
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
            }
            .onDisappear(perform: stopGeneration)
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
            .alert(
                "Generation Failed",
                isPresented: Binding(
                    get: { generationError != nil },
                    set: { if !$0 { generationError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    generationError = nil
                }
            } message: {
                Text(generationError ?? "The model could not generate a response.")
            }
            .alert(
                "Low Memory",
                isPresented: Binding(
                    get: { memoryAlertMessage != nil },
                    set: { if !$0 { memoryAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    memoryAlertMessage = nil
                }
            } message: {
                Text(memoryAlertMessage ?? "Your device ran low on memory. Try a shorter conversation.")
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                CircleIconButton(systemName: "gearshape", action: { showSettings = true })
                CircleIconButton(systemName: "bubble.left.and.bubble.right", action: { showConversations = true })
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.76))
                    .overlay(Capsule().stroke(Color.white.opacity(0.82), lineWidth: 1))
            )

            Link(destination: modelPageURL) {
                HStack(spacing: 8) {
                    Text("Gemma 4 E4B")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil", action: clearConversation)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: messages.isEmpty ? 26 : 14) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages, id: \.id) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, minHeight: 0)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                guard let lastID = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 72)

            VStack(spacing: 18) {
                Text("Meet Yemma 4")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Chat with Google's latest Gemma 4 model entirely on your device. No provider connection, no cloud relay, and no account required.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

            if !llmService.isModelLoaded {
                Text("Loading your on-device model...")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.user.isCurrentUser {
                Spacer(minLength: 54)
            }

            VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 6) {
                if !message.user.isCurrentUser {
                    Text("Yemma 4")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 2)
                }

                Text(displayText(for: message))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(message.user.isCurrentUser ? .trailing : .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(messageBubbleBackground(for: message))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.78), lineWidth: 1)
                    )
            }
            .frame(maxWidth: 420, alignment: message.user.isCurrentUser ? .trailing : .leading)

            if !message.user.isCurrentUser {
                Spacer(minLength: 54)
            }
        }
    }

    private func messageBubbleBackground(for message: ChatMessage) -> some ShapeStyle {
        if message.user.isCurrentUser {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.white.opacity(0.92), Color.white.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(Color.white.opacity(0.62))
    }

    private var composerSection: some View {
        VStack(spacing: 12) {
            if messages.isEmpty {
                quickPromptStrip
            }

            if shouldShowTypingIndicator {
                typingIndicator
            }

            HStack(spacing: 10) {
                composerIcon(systemName: "plus", action: {})

                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($isComposerFocused)

                Button {
                    if llmService.isGenerating {
                        stopGeneration()
                    } else {
                        submitDraft()
                    }
                } label: {
                    Image(systemName: llmService.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!llmService.isGenerating && (!llmService.isModelLoaded || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .opacity((!llmService.isGenerating && (!llmService.isModelLoaded || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) ? 0.45 : 1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.inputFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0), Color.white.opacity(0.5), Color.white.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var quickPromptStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(quickPrompts, id: \.title) { prompt in
                    Button {
                        draft = prompt.prompt
                        isComposerFocused = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(prompt.subtitle)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .frame(width: 154, alignment: .leading)
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func composerIcon(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    private var typingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(AppTheme.textSecondary)

            Text("Yemma 4 is thinking…")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 18)
    }

    private var shouldShowTypingIndicator: Bool {
        guard llmService.isGenerating else { return false }
        guard let lastAssistantMessage = messages.last(where: { !$0.user.isCurrentUser }) else { return true }
        return lastAssistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toastView(message: String) -> some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.82))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
    }

    private func displayText(for message: ChatMessage) -> String {
        if !message.user.isCurrentUser, message.text.isEmpty, llmService.isGenerating {
            return " "
        }

        return message.text
    }

    private func submitDraft() {
        let trimmedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard llmService.isModelLoaded else {
            generationError = "The model is not loaded yet."
            return
        }
        guard !llmService.isGenerating else {
            showToast("Please wait for Yemma 4 to finish")
            return
        }

        draft = ""
        handlePrompt(trimmedText)
    }

    private func handlePrompt(_ trimmedText: String) {
        triggerSendHaptic()
        stopGeneration()

        let history = conversationHistory(from: messages)
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            user: .user,
            status: .sent,
            createdAt: Date(),
            text: trimmedText
        )
        messages.append(userMessage)

        let assistantID = UUID().uuidString
        messages.append(
            ChatMessage(
                id: assistantID,
                user: .yemma,
                status: .sent,
                createdAt: Date(),
                text: ""
            )
        )

        generationError = nil
        memoryAlertMessage = nil
        generationTask = Task {
            await streamReply(prompt: trimmedText, history: history, assistantID: assistantID)
        }
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [(role: String, content: String)] {
        messages
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                (
                    role: $0.user.isCurrentUser ? "user" : "model",
                    content: $0.text
                )
            }
    }

    private func streamReply(
        prompt: String,
        history: [(role: String, content: String)],
        assistantID: String
    ) async {
        var assistantText = ""

        defer {
            Task { @MainActor in
                self.generationTask = nil
            }
        }

        for await token in llmService.generate(prompt: prompt, history: history) {
            assistantText.append(token)
            await MainActor.run {
                updateMessageText(id: assistantID, text: sanitizedAssistantText(assistantText))
            }

            if shouldStopStreaming(for: assistantText) {
                stopGeneration()
                break
            }
        }

        if let lastError = llmService.lastError {
            await MainActor.run {
                if isLowMemoryError(lastError) {
                    self.memoryAlertMessage = "Your device ran low on memory. Try a shorter conversation."
                } else {
                    self.generationError = lastError
                }
            }
        }
    }

    @MainActor
    private func updateMessageText(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func shouldStopStreaming(for text: String) -> Bool {
        text.contains("<start_of_turn>") || text.contains("<end_of_turn>")
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        var cleaned = text

        if let firstMarkerRange = cleaned.range(of: "<start_of_turn>") {
            cleaned = String(cleaned[..<firstMarkerRange.lowerBound])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "<start_of_turn>", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "model\n", with: "")
            .replacingOccurrences(of: "user\n", with: "")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func clearConversation() {
        stopGeneration()
        messages.removeAll()
        draft = ""
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
    }

    @MainActor
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message

        toastTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.7))
            } catch {
                return
            }

            await MainActor.run {
                toastMessage = nil
                toastTask = nil
            }
        }
    }

    private func triggerSendHaptic() {
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    private func isLowMemoryError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("memory") || lowercased.contains("oom") || lowercased.contains("out of memory")
    }

    private func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        llmService.stopGeneration()
    }
}

private struct ConversationsView: View {
    @Environment(\.dismiss) private var dismiss

    let messages: [ChatMessage]
    let onStartFresh: () -> Void

    private var conversationPreview: String {
        let firstUserMessage = messages.first(where: \.user.isCurrentUser)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstUserMessage, !firstUserMessage.isEmpty {
            return firstUserMessage
        }

        return "Hello"
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Text("Conversations")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    CircleIconButton(systemName: "xmark", action: { dismiss() })
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Restart With Intention")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("Use Fresh chat to clear context before switching topics. The current conversation stays previewed below so you can jump back in and keep your place.")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        Spacer()

                        CircleIconButton(systemName: "xmark", filled: false, action: {})
                            .allowsHitTesting(false)
                    }
                }
                .padding(18)
                .glassCard(cornerRadius: 24)
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text("All conversations")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)

                    VStack(spacing: 0) {
                        Button {
                            dismiss()
                        } label: {
                            conversationRow(title: conversationPreview, subtitle: messages.isEmpty ? "Start chatting" : "Current conversation")
                        }

                        Divider()
                            .padding(.leading, 18)

                        Button {
                            onStartFresh()
                        } label: {
                            conversationRow(title: "Fresh chat", subtitle: "Clear current thread")
                        }
                    }
                    .glassCard(cornerRadius: 24)
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Spacer()
                }
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .glassCard(cornerRadius: 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private func conversationRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
