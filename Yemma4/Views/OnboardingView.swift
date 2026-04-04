import Observation
import SwiftUI

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @State private var isStartingDownload = false

    private let estimatedModelBytes: Int64 = 2_000_000_000
    private let onContinue: (() -> Void)?
    private let trustPoints = [
        "Runs entirely on your iPhone",
        "No account setup",
        "Your chats stay on your device"
    ]

    public init(onContinue: (() -> Void)? = nil) {
        self.onContinue = onContinue
    }

    public var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    hero
                    trustStrip
                    statusCard
                    downloadCard

                    if modelDownloader.isDownloaded, let onContinue {
                        Button(action: onContinue) {
                            HStack {
                                Text("Back to chat")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.82), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .padding(10)
                    .background(Color.white.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 1)
                    )

                Image("BrandWordmark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 32)
                    .accessibilityLabel("Yemma 4")
            }

            Text("Private AI on your iPhone.")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Yemma lets you chat with a powerful model right on your phone. No cloud relay, no separate account, and no need to wonder where your prompts went.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("First launch needs a one-time model download, so this part can take a while.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary.opacity(0.78))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.62))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trustStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you’re downloading")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            VStack(spacing: 10) {
                ForEach(trustPoints, id: \.self) { point in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(point)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textSecondary)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: modelDownloader.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(modelDownloader.isDownloaded ? Color.green.opacity(0.85) : AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(modelDownloader.isDownloaded ? "Ready to chat" : "One-time download")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(modelDownloader.isDownloaded ? "The model is stored on this phone and ready whenever you open Yemma." : "This is the actual AI model that runs locally on your device. Once it’s here, day-to-day use feels much faster.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(progressString)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if modelDownloader.isDownloading {
                ProgressView(value: modelDownloader.downloadProgress)
                    .tint(.black)

                HStack {
                    Text("Downloading model")
                    Spacer()
                    Text(remainingString)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            } else if let error = modelDownloader.error {
                Text(error)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why the file is so large")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Yemma downloads the full model to your phone so you can chat privately without sending your requests to somebody else’s servers. It’s a bigger download up front, but that’s what makes the product local.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                detailPill(title: "~2 GB", subtitle: "one-time")
                detailPill(title: "Private", subtitle: "on-device")
                detailPill(title: "No login", subtitle: "just chat")
            }

            Button {
                Task { await startDownload() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(buttonTitle)
                        Text(modelDownloader.canResumeDownload ? "Continue where it left off" : "Download the model to this phone")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    Spacer()
                    Text("~2 GB")
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(modelDownloader.isDownloading || modelDownloader.isDownloaded || isStartingDownload)
            .opacity(modelDownloader.isDownloading ? 0.5 : 1)

            if modelDownloader.error != nil {
                Button(modelDownloader.canResumeDownload ? "Resume download" : "Retry download") {
                    Task { await startDownload() }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 24)
    }

    private func detailPill(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
    }

    private var progressString: String {
        modelDownloader.isDownloaded ? "Ready" : "\(Int(modelDownloader.downloadProgress * 100))%"
    }

    private var remainingString: String {
        let remainingFraction = max(0, 1 - modelDownloader.downloadProgress)
        let remainingBytes = Int64(Double(estimatedModelBytes) * remainingFraction)
        if modelDownloader.isDownloaded {
            return "Stored locally"
        }
        return "\(Self.formattedByteCount(remainingBytes)) remaining"
    }

    private var buttonTitle: String {
        if modelDownloader.isDownloading || isStartingDownload {
            return "Downloading..."
        }

        if modelDownloader.isDownloaded {
            return "Downloaded"
        }

        if modelDownloader.canResumeDownload {
            return "Resume Download"
        }

        return "Download Model"
    }

    @MainActor
    private func startDownload() async {
        guard !isStartingDownload else { return }
        isStartingDownload = true
        defer { isStartingDownload = false }
        await modelDownloader.downloadModel()
    }

    private static func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView()
        .environment(ModelDownloader())
}
#endif
