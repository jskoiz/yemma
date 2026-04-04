import Observation
import SwiftUI
import ExyteChat

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

    private let leakedControlMarkers = [
        "<start_of_turn>",
        "<end_of_turn>",
        "<|start_of_turn|>",
        "<|end_of_turn|>",
        "<eos>",
        "<bos>"
    ]

    private let quickPrompts: [(title: String, subtitle: String, prompt: String)] = [
        ("Design", "a workout routine", "Design a simple workout routine I can do at home."),
        ("Begin", "meditating", "Begin a meditation habit with a simple 7-day plan."),
        ("Explain", "a complex idea", "Explain a complex idea in a simple way.")
    ]

    private let onShowOnboarding: () -> Void

    public init(
        initialMessages: [ChatMessage] = [],
        onShowOnboarding: @escaping () -> Void = {}
    ) {
        _messages = State(initialValue: initialMessages)
        self.onShowOnboarding = onShowOnboarding
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    topBar
                    conversationContent
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isComposerFocused = false
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerSection
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    onClearConversation: clearConversation,
                    onShowOnboarding: {
                        showSettings = false
                        onShowOnboarding()
                    }
                )
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
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                isComposerFocused = false
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

                messageBubble(message)
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

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        let text = displayText(for: message)

        Group {
            if message.user.isCurrentUser {
                Text(text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                RichMessageText(text: text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(messageBubbleBackground(for: message))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
        )
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
            AppDiagnostics.shared.record("Send blocked because model is not loaded", category: "ui")
            generationError = "The model is not loaded yet."
            return
        }
        guard !llmService.isGenerating else {
            AppDiagnostics.shared.record("Send blocked because generation is already active", category: "ui")
            showToast("Please wait for Yemma 4 to finish")
            return
        }

        AppDiagnostics.shared.record(
            "User submitted prompt",
            category: "ui",
            metadata: [
                "chars": trimmedText.count,
                "existingMessages": messages.count
            ]
        )
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
            let shouldStop = shouldStopStreaming(for: assistantText)
            let visibleText = sanitizedAssistantText(assistantText)

            await MainActor.run {
                updateMessageText(id: assistantID, text: visibleText)
            }

            if shouldStop {
                stopGeneration()
                break
            }
        }

        let finalText = finalizedAssistantText(assistantText)
        await MainActor.run {
            finalizeAssistantMessage(id: assistantID, text: finalText)
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

    @MainActor
    private func finalizeAssistantMessage(id: String, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }

        if text.isEmpty {
            messages.remove(at: index)
            return
        }

        messages[index].text = text
    }

    private func shouldStopStreaming(for text: String) -> Bool {
        leakedControlMarkers.contains { text.contains($0) }
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        var cleaned = text

        if let firstMarkerRange = firstControlMarkerRange(in: cleaned) {
            cleaned = String(cleaned[..<firstMarkerRange.lowerBound])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "<start_of_turn>", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<|start_of_turn|>", with: "")
            .replacingOccurrences(of: "<|end_of_turn|>", with: "")
            .replacingOccurrences(of: "<eos>", with: "")
            .replacingOccurrences(of: "<bos>", with: "")

        cleaned = stripLeadingLeakedRolePrefix(from: cleaned)
        cleaned = trimTrailingControlPrefix(from: cleaned)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizedAssistantText(_ text: String) -> String {
        sanitizedAssistantText(text)
    }

    private func firstControlMarkerRange(in text: String) -> Range<String.Index>? {
        leakedControlMarkers
            .compactMap { marker in text.range(of: marker) }
            .min(by: { $0.lowerBound < $1.lowerBound })
    }

    private func stripLeadingLeakedRolePrefix(from text: String) -> String {
        let prefixes = ["model\n", "assistant\n", "user\n"]

        for prefix in prefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }

        return text
    }

    private func trimTrailingControlPrefix(from text: String) -> String {
        guard !text.isEmpty else { return text }

        for marker in leakedControlMarkers {
            guard marker.count > 1 else { continue }

            for prefixLength in stride(from: marker.count - 1, through: 1, by: -1) {
                let prefix = String(marker.prefix(prefixLength))
                if text.hasSuffix(prefix) {
                    return String(text.dropLast(prefixLength))
                }
            }
        }

        return text
    }

    @MainActor
    private func clearConversation() {
        AppDiagnostics.shared.record("Conversation cleared", category: "ui", metadata: ["previousMessages": messages.count])
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

#if DEBUG
private extension ChatMessage {
    static func previewMessage(user: ExyteChat.User, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            user: user,
            status: .sent,
            createdAt: .now,
            text: text
        )
    }
}

private extension LLMService {
    static func previewLoaded() -> LLMService {
        let service = LLMService()
        service.isModelLoaded = true
        return service
    }
}

#Preview("Chat") {
    ChatView(
        initialMessages: [
            .previewMessage(
                user: .user,
                text: "Plan me a focused three-day workout split for strength and cardio."
            ),
            .previewMessage(
                user: .yemma,
                text: "Here is a simple split: Day 1 push and intervals, Day 2 lower body and incline walking, Day 3 pull and steady-state cardio. Keep each session around 45 minutes."
            ),
            .previewMessage(
                user: .user,
                text: "Keep it beginner friendly and make the gym version optional."
            )
        ]
    )
    .environment(LLMService.previewLoaded())
    .environment(ModelDownloader())
}
#endif

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
