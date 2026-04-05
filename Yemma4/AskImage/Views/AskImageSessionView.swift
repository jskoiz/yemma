import SwiftUI
import PhotosUI

/// The active Ask Image session -- attach an image, ask a question, see the streamed answer.
struct AskImageSessionView: View {
    let modelName: String
    let sessionState: AskImageSessionState
    let messages: [AskImageMessage]
    let attachment: AskImageAttachment?
    let onSend: (String) -> Void
    let onPickedImage: (PhotosPickerItem) -> Void
    let onCancel: () -> Void
    let onNewSession: () -> Void
    let onDismiss: () -> Void
    let onRetryError: () -> Void
    var onRedownloadModel: (() -> Void)?

    /// Toast message from the coordinator (image decode errors, etc.).
    var toastMessage: String?

    @State private var draftPrompt = ""
    @State private var selectedPhotoItem: PhotosPickerItem?

    private let presetPrompts = [
        "Describe this image",
        "Read the text in this image",
        "Summarize this scene",
        "Answer my question about this image",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    modelPill
                    errorBanner
                    transcriptArea
                    composerArea
                }

                // Toast overlay for non-fatal errors
                toastOverlay
            }
            .navigationTitle("Ask Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onNewSession) {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newValue in
                if let item = newValue {
                    onPickedImage(item)
                    selectedPhotoItem = nil
                }
            }
        }
    }

    // MARK: - Model Pill

    private var modelPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)

            Text(modelName)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            if sessionState == .warmingModel {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Warming up...")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppTheme.chipFill)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(AppTheme.controlBorder, lineWidth: 1)
        )
        .padding(.top, 8)
    }

    private var statusDotColor: Color {
        switch sessionState {
        case .readyForInput, .generating:
            return .green
        case .error:
            return .red
        case .warmingModel:
            return .orange
        case .idle:
            return .gray
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let sessionError) = sessionState {
            AskImageErrorBanner(
                message: sessionError.userMessage,
                showRedownload: sessionError.shouldOfferRedownload,
                onRetry: onRetryError,
                onRedownload: onRedownloadModel
            )
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Toast Overlay

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = toastMessage {
            VStack {
                Spacer()
                Text(toast)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 80)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
        }
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && attachment == nil {
                        emptyState
                    }

                    if let attachment {
                        attachmentBubble(attachment)
                            .id("attachment")
                    }

                    ForEach(messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: attachment?.id) { _, _ in
                if attachment != nil && messages.isEmpty {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("attachment", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastID = messages.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))

            Text("Attach a photo, then ask a question")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            VStack(spacing: 8) {
                Text("Suggestions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)

                ForEach(presetPrompts, id: \.self) { preset in
                    Button {
                        draftPrompt = preset
                    } label: {
                        Text(preset)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func attachmentBubble(_ attachment: AskImageAttachment) -> some View {
        HStack {
            Spacer(minLength: 60)
            if let thumb = attachment.thumbnailImage {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.separator, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.chipFill)
                    .frame(width: 160, height: 120)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(AppTheme.textSecondary)
                            Text("Image attached")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.separator, lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AskImageMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let attachment = message.attachment, let thumb = attachment.thumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.bottom, 4)
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(AppTheme.textPrimary)
                        .textSelection(.enabled)
                }

                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Generating...")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user
                    ? AppTheme.userBubbleTop
                    : AppTheme.assistantBubble
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.separator, lineWidth: 1)
            )
            .contextMenu {
                if message.role == .assistant && !message.isStreaming && !message.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    ShareLink(item: message.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: 0) {
            Divider()

            // Queued prompt indicator
            if sessionState == .warmingModel && !messages.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Prompt queued -- will send when model is ready")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            // Attached image preview strip
            if let attachment, messages.isEmpty {
                HStack(spacing: 8) {
                    if let thumb = attachment.thumbnailImage {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.chipFill)
                            .frame(width: 40, height: 40)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                    }
                    Text("Image attached")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: attachment != nil ? "photo.fill" : "photo.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(attachment != nil ? AppTheme.accent : AppTheme.textSecondary)
                }

                TextField("Ask about the image...", text: $draftPrompt)
                    .textFieldStyle(.plain)
                    .font(.body)

                if sessionState == .generating {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        let trimmed = draftPrompt.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        onSend(trimmed)
                        draftPrompt = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                canSend
                                    ? AppTheme.accent
                                    : AppTheme.textSecondary.opacity(0.4)
                            )
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.inputFill)
        }
    }

    private var canSend: Bool {
        let hasText = !draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        // Allow sending during warmup (prompt will be queued).
        let isReady = sessionState == .readyForInput
            || sessionState == .idle
            || sessionState == .warmingModel
        return hasText && isReady
    }
}

// MARK: - Error Banner

struct AskImageErrorBanner: View {
    let message: String
    let showRedownload: Bool
    let onRetry: () -> Void
    var onRedownload: (() -> Void)?

    init(
        message: String,
        showRedownload: Bool = false,
        onRetry: @escaping () -> Void,
        onRedownload: (() -> Void)? = nil
    ) {
        self.message = message
        self.showRedownload = showRedownload
        self.onRetry = onRetry
        self.onRedownload = onRedownload
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(3)

            Spacer()

            if showRedownload, let onRedownload {
                Button("Re-download", action: onRedownload)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
            } else {
                Button("Retry", action: onRetry)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(AppTheme.brandCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.brandCardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Previews

#Preview("Session - Empty") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .readyForInput,
        messages: [],
        attachment: nil,
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Warming") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .warmingModel,
        messages: [],
        attachment: nil,
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Streaming") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .generating,
        messages: [
            AskImageMessage(role: .user, text: "What do you see in this image?"),
            AskImageMessage(
                role: .assistant,
                text: "This image shows a scenic landscape with mountains in the background and a lake in the foreground. The lighting suggests",
                isStreaming: true
            ),
        ],
        attachment: AskImageAttachment(originalURL: URL(fileURLWithPath: "/tmp/test.jpg")),
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Completed") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .readyForInput,
        messages: [
            AskImageMessage(role: .user, text: "Describe this image"),
            AskImageMessage(
                role: .assistant,
                text: "This image shows a well-composed scene with clear subject matter. The lighting is natural and the colors are vibrant. I can see several distinct elements that create an interesting visual composition."
            ),
        ],
        attachment: AskImageAttachment(originalURL: URL(fileURLWithPath: "/tmp/test.jpg")),
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Image Attached") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .readyForInput,
        messages: [],
        attachment: AskImageAttachment(originalURL: URL(fileURLWithPath: "/tmp/test.jpg")),
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Error") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .error(.runtimeInitFailed("The device may not have enough memory.")),
        messages: [],
        attachment: nil,
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {}
    )
}

#Preview("Session - Model Missing") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .error(.modelFileMissing("Gemma 4 E2B")),
        messages: [],
        attachment: nil,
        onSend: { _ in },
        onPickedImage: { _ in },
        onCancel: {},
        onNewSession: {},
        onDismiss: {},
        onRetryError: {},
        onRedownloadModel: {}
    )
}
