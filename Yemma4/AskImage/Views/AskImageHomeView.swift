import SwiftUI

/// Landing screen for Ask Image -- shows available models, download state, and entry point.
struct AskImageHomeView: View {
    let models: [LiteRTModelDescriptor]
    let modelState: (String) -> LiteRTModelState
    let onSelectModel: (LiteRTModelDescriptor) -> Void
    let onDownloadModel: (LiteRTModelDescriptor) -> Void
    let onCancelDownload: (LiteRTModelDescriptor) -> Void
    let onDeleteModel: (LiteRTModelDescriptor) -> Void
    let onDismiss: () -> Void

    @State private var modelToDelete: LiteRTModelDescriptor?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        modelCardsSection
                        privacyNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Ask Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDismiss() }
                }
            }
            .confirmationDialog(
                "Delete Model",
                isPresented: Binding(
                    get: { modelToDelete != nil },
                    set: { if !$0 { modelToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let model = modelToDelete {
                    Button("Delete \(model.displayName)", role: .destructive) {
                        onDeleteModel(model)
                        modelToDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        modelToDelete = nil
                    }
                }
            } message: {
                Text("This will remove the downloaded model from your device. You can re-download it later.")
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.accent)

            Text("Ask about any image")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Select a model to get started. Everything runs on-device.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var modelCardsSection: some View {
        VStack(spacing: 12) {
            ForEach(models) { model in
                AskImageModelCard(
                    model: model,
                    state: modelState(model.id),
                    onSelect: { onSelectModel(model) },
                    onDownload: { onDownloadModel(model) },
                    onCancelDownload: { onCancelDownload(model) },
                    onDelete: { modelToDelete = model }
                )
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("All processing happens on your device. No data leaves your phone.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Model Card

struct AskImageModelCard: View {
    let model: LiteRTModelDescriptor
    let state: LiteRTModelState
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(model.parameterLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.15))
                            .foregroundStyle(AppTheme.accent)
                            .clipShape(Capsule())

                        if model.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }

                    Text(model.shortDescription)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()
            }

            actionButton
        }
        .padding(16)
        .glassCard(cornerRadius: 16)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notDownloaded:
            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)

        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(AppTheme.accent)
                HStack {
                    Text("Downloading... \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Button("Cancel", action: onCancelDownload)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

        case .downloaded, .ready:
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    Label("Open", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing...")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }

        case .validationFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Re-download", action: onDownload)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry", action: onDownload)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Previews

#Preview("Home - Mixed States") {
    AskImageHomeView(
        models: [.gemma4E2B, .gemma4E4B],
        modelState: { id in
            id == LiteRTModelDescriptor.gemma4E2B.id ? .downloaded : .notDownloaded
        },
        onSelectModel: { _ in },
        onDownloadModel: { _ in },
        onCancelDownload: { _ in },
        onDeleteModel: { _ in },
        onDismiss: {}
    )
}

#Preview("Home - Downloading") {
    AskImageHomeView(
        models: [.gemma4E2B, .gemma4E4B],
        modelState: { id in
            id == LiteRTModelDescriptor.gemma4E2B.id
                ? .downloading(progress: 0.65)
                : .notDownloaded
        },
        onSelectModel: { _ in },
        onDownloadModel: { _ in },
        onCancelDownload: { _ in },
        onDeleteModel: { _ in },
        onDismiss: {}
    )
}

#Preview("Home - All Downloaded") {
    AskImageHomeView(
        models: [.gemma4E2B, .gemma4E4B],
        modelState: { _ in .downloaded },
        onSelectModel: { _ in },
        onDownloadModel: { _ in },
        onCancelDownload: { _ in },
        onDeleteModel: { _ in },
        onDismiss: {}
    )
}
