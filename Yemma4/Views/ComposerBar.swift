import PhotosUI
import SwiftUI
import ExyteChat

#if canImport(UIKit)
import UIKit
#endif

struct ComposerBar: View {
    @Binding var draft: String
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    @FocusState.Binding var isComposerFocused: Bool

    let pendingAttachments: [Attachment]
    let isGenerating: Bool
    let isImportingAttachments: Bool
    let canSubmit: Bool
    let showQuickPrompts: Bool
    let showTypingIndicator: Bool
    let onSubmit: () -> Void
    let onStop: () -> Void
    let onRemoveAttachment: (String) -> Void

    private let quickPrompts: [(title: String, subtitle: String, prompt: String)] = [
        ("Design", "a workout routine", "Design a simple workout routine I can do at home."),
        ("Begin", "meditating", "Begin a meditation habit with a simple 7-day plan."),
        ("Explain", "a complex idea", "Explain a complex idea in a simple way.")
    ]

    var body: some View {
        VStack(spacing: 12) {
            if showQuickPrompts {
                quickPromptStrip
            }

            if showTypingIndicator {
                typingIndicator
            }

            if !pendingAttachments.isEmpty {
                composerAttachmentStrip
            }

            inputBar
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

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            attachmentPickerButton

            TextField("Ask anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit {
                    onSubmit()
                }

            Button {
                if isGenerating {
                    onStop()
                } else {
                    onSubmit()
                }
            } label: {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isGenerating && !canSubmit)
            .opacity((!isGenerating && !canSubmit) ? 0.45 : 1)
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

    // MARK: - Quick Prompts

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

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(AppTheme.textSecondary)

            Text("Yemma 4 is thinking\u{2026}")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 18)
    }

    // MARK: - Attachment Picker

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

    // MARK: - Attachment Strip

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

    private func attachmentPreviewChip(for attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            attachmentTile(for: attachment, height: 76)
                .frame(width: 76)

            Button {
                onRemoveAttachment(attachment.id)
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

    // MARK: - Attachment Tile

    private func attachmentTile(for attachment: Attachment, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.controlFill)
            if attachment.thumbnail.isFileURL,
               let image = UIImage(contentsOfFile: attachment.thumbnail.path) {
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
}
