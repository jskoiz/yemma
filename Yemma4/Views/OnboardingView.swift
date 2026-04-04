import Observation
import SwiftUI

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @State private var isStartingDownload = false

    private let estimatedModelBytes: Int64 = 2_000_000_000

    public init() {}

    public var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    hero
                    statusCard
                    downloadCard
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 90, height: 90)
                .padding(16)
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.82), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 24, x: 0, y: 12)

            Text("Private AI with Yemma 4.")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Download Google's latest Gemma 4 model and chat with an LLM locally on your device without connecting to a provider.")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(.top, 24)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: modelDownloader.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(modelDownloader.isDownloaded ? Color.green.opacity(0.85) : AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(modelDownloader.isDownloaded ? "Model ready" : "Model download")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(modelDownloader.isDownloaded ? "Stored safely on your device and ready to load." : "The model stays on your device after the first download for private local chat.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                Text(progressString)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if modelDownloader.isDownloading {
                ProgressView(value: modelDownloader.downloadProgress)
                    .tint(.black)

                HStack {
                    Text("Downloading...")
                    Spacer()
                    Text(remainingString)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            } else if let error = modelDownloader.error {
                Text(error)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .padding(22)
        .glassCard(cornerRadius: 30)
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Get started")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text("This first-time download is about 2 GB. After that, Yemma 4 can run Gemma 4 locally so your prompts stay on-device instead of being sent to a provider.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            Button {
                Task { await startDownload() }
            } label: {
                HStack {
                    Text(buttonTitle)
                    Spacer()
                    Text("~2 GB")
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(modelDownloader.isDownloading || modelDownloader.isDownloaded || isStartingDownload)
            .opacity(modelDownloader.isDownloading ? 0.5 : 1)

            if modelDownloader.error != nil {
                Button("Retry download") {
                    Task { await startDownload() }
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(22)
        .glassCard(cornerRadius: 30)
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
