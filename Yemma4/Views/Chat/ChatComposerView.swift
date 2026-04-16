import PhotosUI
import SwiftUI
import ExyteChat

struct ChatComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let appSetup: AppSetupSnapshot
    @Binding var draft: String
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    @Binding var pendingAttachments: [Attachment]
    @Binding var isImportingAttachments: Bool
    @Binding var isShowingPhotoPicker: Bool
    let isGenerating: Bool
    let canSubmitDraft: Bool
    let shouldShowTypingIndicator: Bool
    let isComposerFocused: FocusState<Bool>.Binding
    let primarySetupActionTitle: String?
    let primarySetupAction: (() -> Void)?
    let onSubmitDraft: () -> Void
    let onStopGeneration: () -> Void
    let onRemoveAttachment: (Attachment) -> Void

    var body: some View {
        VStack(spacing: 12) {
            if shouldShowTypingIndicator {
                typingIndicator
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.8))
                    )
            }

            if !pendingAttachments.isEmpty {
                composerAttachmentStrip
            }

            if shouldShowComposerSetupNotice {
                composerSetupNotice
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            }

            HStack(spacing: 10) {
                attachmentPickerButton

                TextField("Ask anything", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.chatComposer)
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused(isComposerFocused)
                    .submitLabel(canSubmitDraft ? .send : .return)
                    .onSubmit {
                        guard canSubmitDraft else { return }
                        onSubmitDraft()
                    }

                Button {
                    if isGenerating {
                        onStopGeneration()
                    } else {
                        onSubmitDraft()
                    }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.accentForeground)
                        .frame(width: AppTheme.Layout.composerActionSize, height: AppTheme.Layout.composerActionSize)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isGenerating && !canSubmitDraft)
                .opacity((!isGenerating && !canSubmitDraft) ? 0.45 : 1)
                .accessibilityLabel(isGenerating ? "Stop response" : "Send message")
                .accessibilityHint(sendButtonAccessibilityHint)
            }
            .padding(8)
            .inputChrome(cornerRadius: AppTheme.Radius.medium)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
            .onTapGesture {
                isComposerFocused.wrappedValue = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.clear, AppTheme.composerFadeMiddle, AppTheme.composerFadeBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowTypingIndicator)
    }

    private var shouldShowComposerSetupNotice: Bool {
        appSetup.supportsLocalModelRuntime && !appSetup.isTextModelReady
    }

    private var sendButtonAccessibilityHint: String {
        if isGenerating {
            return "Stops the current assistant response."
        }

        if canSubmitDraft {
            return "Sends your draft to Yemma."
        }

        return "Send unlocks after the on-device model is ready."
    }

    private var composerSetupNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            composerSetupStatusIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(appSetup.chatStatusText)
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                if let detail = appSetup.chatStatusDetailText {
                    Text(detail)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle = primarySetupActionTitle,
               let action = primarySetupAction,
               !appSetup.isModelLoading
            {
                Button(actionTitle, action: action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                .stroke(AppTheme.controlBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var composerSetupStatusIcon: some View {
        if appSetup.isModelLoading {
            ProgressView()
                .tint(AppTheme.accent)
        } else {
            Image(systemName: composerSetupStatusSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(composerSetupStatusTint)
        }
    }

    private var composerSetupStatusSymbol: String {
        if appSetup.isDownloading {
            return "arrow.down.circle.fill"
        }

        if appSetup.canResumeDownload {
            return "pause.circle.fill"
        }

        if appSetup.chatRecoveryAction != nil {
            return "exclamationmark.triangle.fill"
        }

        return "bolt.circle.fill"
    }

    private var composerSetupStatusTint: Color {
        appSetup.chatRecoveryAction == nil ? AppTheme.accent : AppTheme.destructive
    }

    private var attachmentPickerButton: some View {
        Button {
            isShowingPhotoPicker = true
        } label: {
            Image(systemName: isImportingAttachments ? "hourglass" : "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .disabled(isImportingAttachments)
        .accessibilityLabel("Add image")
        .accessibilityHint("Attach up to four images to your next message.")
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
        HStack(spacing: 0) {
            ThinkingOrbView()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func attachmentPreviewChip(for attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            ChatAttachmentPreviewTile(attachment: attachment, height: 76)
                .frame(width: 76)

            Button {
                onRemoveAttachment(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground, AppTheme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove image")
            .accessibilityHint("Removes this image from the draft.")
        }
        .padding(.top, 6)
        .padding(.trailing, 2)
    }
}
