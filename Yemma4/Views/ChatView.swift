import Observation
import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

public struct ChatView: View {
    @Environment(LLMService.self) private var llmService

    private let supportsLocalModelRuntime = Yemma4AppConfiguration.supportsLocalModelRuntime
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [Attachment] = []
    @State private var isImportingAttachments = false
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
        "<|turn>",
        "<turn|>",
        "<|channel>",
        "<channel|>",
        "<|think|>",
        "<|tool>",
        "<tool|>",
        "<|tool_call>",
        "<tool_call|>",
        "<|tool_response>",
        "<tool_response|>",
        "<eos>",
        "<bos>"
    ]

    private let responseBoundaryMarkers = [
        "<end_of_turn>",
        "<|end_of_turn|>",
        "<turn|>",
        "<start_of_turn>user",
        "<|start_of_turn|>user",
        "<|turn>user",
        "<|turn>system"
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerSection
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    onClearConversation: {
                        Task { @MainActor in
                            await clearConversation()
                        }
                    },
                    onShowOnboarding: {
                        showSettings = false
                        onShowOnboarding()
                    },
                    onRunDebugScenario: { scenario in
                        showSettings = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            await runDebugScenario(scenario)
                        }
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
                        Task { @MainActor in
                            await clearConversation()
                            showConversations = false
                        }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
            }
            .onAppear {
                AppDiagnostics.shared.record(
                    "startup: view_appeared",
                    category: "startup",
                    metadata: ["view": "ChatView", "elapsedMs": StartupTiming.elapsedMs()]
                )
            }
            .onDisappear {
                Task { @MainActor in
                    await stopGeneration()
                }
            }
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { @MainActor in
                    await importSelectedPhotos(from: newItems)
                }
            }
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
                    .fill(AppTheme.controlFill)
                    .overlay(Capsule().stroke(AppTheme.controlBorder, lineWidth: 1))
            )

            Spacer(minLength: 0)

            CircleIconButton(systemName: "square.and.pencil") {
                Task { @MainActor in
                    await clearConversation()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: messages.isEmpty ? 26 : 14) {
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
                Text(modelStatusText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(modelStatusTextColor)
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
                    colors: [AppTheme.userBubbleTop, AppTheme.userBubbleBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(AppTheme.assistantBubble)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        let text = displayText(for: message)
        let shouldRenderText = shouldRenderText(for: message, text: text)

        VStack(
            alignment: message.user.isCurrentUser ? .trailing : .leading,
            spacing: message.attachments.isEmpty || !shouldRenderText ? 0 : 12
        ) {
            if !message.attachments.isEmpty {
                attachmentGrid(for: message)
            }

            if shouldRenderText {
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(messageBubbleBackground(for: message))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.messageBubbleBorder, lineWidth: 1)
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

            if !pendingAttachments.isEmpty {
                composerAttachmentStrip
            }

            HStack(spacing: 10) {
                attachmentPickerButton

                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        submitDraft()
                    }

                Button {
                    if llmService.isGenerating {
                        Task { @MainActor in
                            await stopGeneration()
                        }
                    } else {
                        submitDraft()
                    }
                } label: {
                    Image(systemName: llmService.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.accentForeground)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!llmService.isGenerating && !canSubmitDraft)
                .opacity((!llmService.isGenerating && !canSubmitDraft) ? 0.45 : 1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.inputFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(AppTheme.controlBorder, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                isComposerFocused = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color.clear, AppTheme.composerFadeMiddle, AppTheme.composerFadeBottom],
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

    private var attachmentPickerButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images,
            preferredItemEncoding: .automatic
        ) {
            Image(systemName: isImportingAttachments ? "hourglass" : "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(isImportingAttachments)
    }

    private var composerAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pendingAttachments, id: \.id) { attachment in
                    attachmentPreviewChip(for: attachment)
                }
            }
            .padding(.horizontal, 2)
        }
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

    private var canSubmitDraft: Bool {
        guard !isImportingAttachments else { return false }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasDraft || !pendingAttachments.isEmpty else { return false }
        return llmService.isModelLoaded || !supportsLocalModelRuntime
    }

    private var modelStatusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode: mock replies are enabled so you can test the chat UI without downloading the model."
        }

        if llmService.isModelLoading {
            return llmService.modelLoadStage.statusText
        }

        return "Preparing your on-device model..."
    }

    private var modelStatusTextColor: Color {
        if !supportsLocalModelRuntime {
            return AppTheme.textPrimary
        }

        return AppTheme.textSecondary
    }

    private func toastView(message: String) -> some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.accentForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.toastFill)
            .clipShape(Capsule())
            .shadow(color: AppTheme.toastShadow, radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
    }

    private func displayText(for message: ChatMessage) -> String {
        if !message.user.isCurrentUser, message.text.isEmpty, llmService.isGenerating {
            return " "
        }

        return message.text
    }

    private func shouldRenderText(for message: ChatMessage, text: String) -> Bool {
        if message.user.isCurrentUser {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return !text.isEmpty
    }

    private func imageAttachments(for message: ChatMessage) -> [Attachment] {
        message.attachments.filter { $0.type == .image }
    }

    @ViewBuilder
    private func attachmentGrid(for message: ChatMessage) -> some View {
        let attachments = imageAttachments(for: message)

        if attachments.count == 1, let attachment = attachments.first {
            attachmentTile(for: attachment, height: 216)
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(attachments, id: \.id) { attachment in
                    attachmentTile(for: attachment, height: 112)
                }
            }
        }
    }

    private func attachmentTile(for attachment: Attachment, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.controlFill)

            if
                attachment.thumbnail.isFileURL,
                let image = UIImage(contentsOfFile: attachment.thumbnail.path)
            {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.messageBubbleBorder, lineWidth: 1)
        )
    }

    private func attachmentPreviewChip(for attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            attachmentTile(for: attachment, height: 76)
                .frame(width: 76)

            Button {
                pendingAttachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground, AppTheme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
        .padding(.trailing, 2)
    }

    private func promptInput(from message: ChatMessage) -> PromptMessageInput {
        PromptMessageInput(
            role: message.user.isCurrentUser ? "user" : "assistant",
            text: message.text,
            images: message.attachments.compactMap { attachment in
                guard attachment.type == .image, attachment.full.isFileURL else {
                    return nil
                }

                return PromptImageAsset(
                    id: attachment.id,
                    filePath: attachment.full.path
                )
            }
        )
    }

    @MainActor
    private func importSelectedPhotos(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        isImportingAttachments = true
        defer {
            isImportingAttachments = false
            selectedPhotoItems = []
        }

        var importedAttachments: [Attachment] = []
        var failedCount = 0

        for item in items {
            do {
                if let attachment = try await makeAttachment(from: item) {
                    importedAttachments.append(attachment)
                }
            } catch {
                failedCount += 1
            }
        }

        if !importedAttachments.isEmpty {
            pendingAttachments.append(contentsOf: importedAttachments)
        }

        if failedCount > 0 {
            showToast("Some images could not be added")
        }
    }

    private func makeAttachment(from item: PhotosPickerItem) async throws -> Attachment? {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }

#if canImport(UIKit)
        guard let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let encodedData: Data
        let fileExtension: String

        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            encodedData = jpegData
            fileExtension = "jpg"
        } else if let pngData = image.pngData() {
            encodedData = pngData
            fileExtension = "png"
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
#else
        let encodedData = data
        let fileExtension = "bin"
#endif

        let fileURL = try storeAttachmentData(encodedData, fileExtension: fileExtension)
        return Attachment(id: UUID().uuidString, url: fileURL, type: .image)
    }

    private func storeAttachmentData(_ data: Data, fileExtension: String) throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("chat-attachments", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func submitDraft() {
        let trimmedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard llmService.isModelLoaded || !supportsLocalModelRuntime else {
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
                "images": pendingAttachments.count,
                "existingMessages": messages.count
            ]
        )
        draft = ""
        Task { @MainActor in
            let attachments = pendingAttachments
            pendingAttachments = []
            selectedPhotoItems = []
            await handlePrompt(trimmedText, attachments: attachments)
        }
    }

    @MainActor
    private func handlePrompt(_ trimmedText: String, attachments: [Attachment]) async {
        triggerSendHaptic()
        await stopGeneration()

        let history = conversationHistory(from: messages)
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            user: .user,
            status: .sent,
            createdAt: Date(),
            text: trimmedText,
            attachments: attachments
        )
        messages.append(userMessage)

        let prompt = promptInput(from: userMessage)

        let assistantID = UUID().uuidString
        messages.append(
            ChatMessage(
                id: assistantID,
                user: .yemma,
                status: .sent,
                createdAt: Date(),
                text: "",
                attachments: []
            )
        )

        generationError = nil
        memoryAlertMessage = nil
        generationTask = Task {
            await streamReply(prompt: prompt, history: history, assistantID: assistantID)
        }
    }

    private func conversationHistory(from messages: [ChatMessage]) -> [PromptMessageInput] {
        messages
            .compactMap { message in
                let prompt = promptInput(from: message)
                if prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.images.isEmpty {
                    return nil
                }
                return prompt
            }
    }

    private func streamReply(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
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
                await llmService.stopGeneration()
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
        responseBoundaryMarkers.contains { text.contains($0) }
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        var cleaned = stripLeadingControlPreamble(from: text)
        cleaned = stripThinkingBlocks(from: cleaned)

        if let firstMarkerRange = firstBoundaryMarkerRange(in: cleaned) {
            cleaned = String(cleaned[..<firstMarkerRange.lowerBound])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "<start_of_turn>", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<|start_of_turn|>", with: "")
            .replacingOccurrences(of: "<|end_of_turn|>", with: "")
            .replacingOccurrences(of: "<|turn>", with: "")
            .replacingOccurrences(of: "<turn|>", with: "")
            .replacingOccurrences(of: "<|channel>", with: "")
            .replacingOccurrences(of: "<channel|>", with: "")
            .replacingOccurrences(of: "<|think|>", with: "")
            .replacingOccurrences(of: "<|tool>", with: "")
            .replacingOccurrences(of: "<tool|>", with: "")
            .replacingOccurrences(of: "<|tool_call>", with: "")
            .replacingOccurrences(of: "<tool_call|>", with: "")
            .replacingOccurrences(of: "<|tool_response>", with: "")
            .replacingOccurrences(of: "<tool_response|>", with: "")
            .replacingOccurrences(of: "<eos>", with: "")
            .replacingOccurrences(of: "<bos>", with: "")

        cleaned = stripLeadingLeakedRolePrefix(from: cleaned)
        cleaned = trimTrailingControlPrefix(from: cleaned)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizedAssistantText(_ text: String) -> String {
        sanitizedAssistantText(text)
    }

    private func firstBoundaryMarkerRange(in text: String) -> Range<String.Index>? {
        responseBoundaryMarkers
            .compactMap { marker in text.range(of: marker) }
            .min(by: { $0.lowerBound < $1.lowerBound })
    }

    private func stripLeadingLeakedRolePrefix(from text: String) -> String {
        let prefixes = [
            "model\n",
            "assistant\n",
            "user\n",
            "system\n",
            "<|turn>model\n",
            "<|turn>assistant\n",
            "<|turn>user\n",
            "<|turn>system\n",
            "<start_of_turn>model\n",
            "<start_of_turn>assistant\n",
            "<start_of_turn>user\n",
            "<|start_of_turn|>model\n",
            "<|start_of_turn|>assistant\n",
            "<|start_of_turn|>user\n"
        ]

        for prefix in prefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }

        return text
    }

    private func stripLeadingControlPreamble(from text: String) -> String {
        var cleaned = text

        while true {
            let updated = stripLeadingLeakedRolePrefix(from: cleaned)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if updated == cleaned {
                return cleaned
            }

            cleaned = updated
        }
    }

    private func stripThinkingBlocks(from text: String) -> String {
        guard text.contains("<|channel>") else {
            return text
        }

        var cleaned = text

        while let startRange = cleaned.range(of: "<|channel>") {
            if let endRange = cleaned.range(of: "<channel|>", range: startRange.upperBound..<cleaned.endIndex) {
                cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                cleaned.removeSubrange(startRange.lowerBound..<cleaned.endIndex)
                break
            }
        }

        return cleaned
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
    private func clearConversation() async {
        AppDiagnostics.shared.record("Conversation cleared", category: "ui", metadata: ["previousMessages": messages.count])
        await stopGeneration()
        messages.removeAll()
        draft = ""
        pendingAttachments.removeAll()
        selectedPhotoItems.removeAll()
        isImportingAttachments = false
        generationError = nil
        memoryAlertMessage = nil
        toastMessage = nil
    }

    @MainActor
    private func runDebugScenario(_ scenario: DebugInferenceScenario) async {
        AppDiagnostics.shared.record(
            "Debug scenario triggered",
            category: "debug",
            metadata: ["scenario": scenario.rawValue]
        )
        await clearConversation()

        if let sampleTranscript = scenario.sampleTranscript {
            messages = [
                .previewMessage(user: .user, text: sampleTranscript.user),
                .previewMessage(user: .yemma, text: sampleTranscript.assistant)
            ]
            return
        }

        guard let prompt = scenario.prompt else {
            return
        }

        if !supportsLocalModelRuntime {
            messages = [
                .previewMessage(user: .user, text: prompt),
                .previewMessage(
                    user: .yemma,
                    text: "Simulator mode uses mocked replies. Run this debug scenario on a physical iPhone to judge real inference quality."
                )
            ]
            return
        }

        guard llmService.isModelLoaded else {
            messages = [
                .previewMessage(user: .user, text: prompt),
                .previewMessage(
                    user: .yemma,
                    text: "Load the local model first, then rerun this debug scenario."
                )
            ]
            return
        }

        await handlePrompt(prompt, attachments: [])
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

    @MainActor
    private func stopGeneration() async {
        generationTask?.cancel()
        generationTask = nil
        await llmService.stopGeneration()
    }
}

private extension ChatMessage {
    static func previewMessage(user: ExyteChat.User, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            user: user,
            status: .sent,
            createdAt: .now,
            text: text,
            attachments: []
        )
    }
}

#if DEBUG
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
        let firstUserMessage = messages.first(where: \.user.isCurrentUser)
        let firstUserText = firstUserMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstUserText, !firstUserText.isEmpty {
            return firstUserText
        }

        if let firstUserMessage, !firstUserMessage.attachments.isEmpty {
            return "Image prompt"
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
                            .overlay(AppTheme.separator)

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
