import SwiftUI
import PhotosUI

/// The active Ask Image session — attach an image, ask a question, see the streamed answer.
struct AskImageSessionView: View {
    let modelName: String
    let sessionState: AskImageSessionState
    let messages: [AskImageMessage]
    let attachment: AskImageAttachment?
    let onSend: (String) -> Void
    let onAttachImage: () -> Void
    let onCancel: () -> Void
    let onNewSession: () -> Void
    let onDismiss: () -> Void

    @State private var draftPrompt = ""

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
                    transcriptArea
                    composerArea
                }
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
        }
    }

    // MARK: - Model Pill

    private var modelPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sessionState == .readyForInput || sessionState == .generating ? .green : .orange)
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
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))

            Text("Attach an image to get started")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            VStack(spacing: 8) {
                Text("Try asking:")
                    .font(.caption)
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
    }

    @ViewBuilder
    private func attachmentBubble(_ attachment: AskImageAttachment) -> some View {
        HStack {
            if let thumb = attachment.thumbnailImage {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.chipFill)
                    .frame(width: 120, height: 90)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(AppTheme.textSecondary)
                    }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AskImageMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)

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
                    .stroke(AppTheme.messageBubbleBorder, lineWidth: 1)
            )

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 10) {
                Button(action: onAttachImage) {
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
                        guard !draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onSend(draftPrompt)
                        draftPrompt = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? AppTheme.textSecondary.opacity(0.4)
                                    : AppTheme.accent
                            )
                    }
                    .disabled(draftPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.inputFill)
        }
    }
}

// MARK: - Error State

struct AskImageErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)

            Spacer()

            Button("Retry", action: onRetry)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        onAttachImage: {},
        onCancel: {},
        onNewSession: {},
        onDismiss: {}
    )
}

#Preview("Session - Streaming") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .generating,
        messages: [
            AskImageMessage(role: .user, text: "What do you see in this image?"),
            AskImageMessage(role: .assistant, text: "This image shows a scenic landscape with mountains in the background and a lake in the foreground. The lighting suggests", isStreaming: true),
        ],
        attachment: AskImageAttachment(originalURL: URL(fileURLWithPath: "/tmp/test.jpg")),
        onSend: { _ in },
        onAttachImage: {},
        onCancel: {},
        onNewSession: {},
        onDismiss: {}
    )
}

#Preview("Session - Warming") {
    AskImageSessionView(
        modelName: "Gemma 4 E2B",
        sessionState: .warmingModel,
        messages: [],
        attachment: nil,
        onSend: { _ in },
        onAttachImage: {},
        onCancel: {},
        onNewSession: {},
        onDismiss: {}
    )
}
