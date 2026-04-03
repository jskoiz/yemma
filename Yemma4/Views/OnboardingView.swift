import Observation
import SwiftUI

public struct OnboardingView: View {
    @Environment(ModelDownloader.self) private var modelDownloader
    @State private var isStartingDownload = false

    private let estimatedModelBytes: Int64 = 2_000_000_000

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                statusCard
                actionCard
            }
            .frame(maxWidth: .infinity, minHeight: 600)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .background(background)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.08),
                Color(red: 0.08, green: 0.09, blue: 0.12),
                Color(red: 0.03, green: 0.04, blue: 0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 104, height: 104)
                .shadow(color: Color(red: 0.22, green: 0.47, blue: 0.96).opacity(0.28), radius: 18, x: 0, y: 8)

            Text("Yemma 4")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Private AI on your iPhone")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))

            Text("No cloud. No account. No data leaves your device.")
                .font(.system(size: 15, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.68))
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: modelDownloader.isDownloaded ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(modelDownloader.isDownloaded ? .green : .cyan)

                Text(modelDownloader.isDownloaded ? "Model ready" : "Model download")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text(progressString)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

            if modelDownloader.isDownloading {
                ProgressView(value: modelDownloader.downloadProgress)
                    .tint(Color(red: 0.24, green: 0.52, blue: 0.96))

                HStack {
                    Text("Downloading...")
                    Spacer()
                    Text(remainingString)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
            } else if modelDownloader.isDownloaded {
                Label("Ready to chat", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
            } else if let error = modelDownloader.error {
                Text(error)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.red.opacity(0.95))
                    .multilineTextAlignment(.leading)
            } else {
                Text("The model stays on-device after the first download.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private var actionCard: some View {
        VStack(spacing: 14) {
            Button {
                Task { await startDownload() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: modelDownloader.isDownloading ? "hourglass" : "arrow.down.circle.fill")
                    Text(buttonTitle)
                    Spacer(minLength: 0)
                    Text("~2 GB")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: modelDownloader.isDownloading
                            ? [Color.white.opacity(0.18), Color.white.opacity(0.12)]
                            : [Color(red: 0.33, green: 0.70, blue: 1.00), Color(red: 0.20, green: 0.46, blue: 0.98)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(modelDownloader.isDownloading || modelDownloader.isDownloaded || isStartingDownload)
            .opacity(modelDownloader.isDownloading ? 0.78 : 1)

            if let error = modelDownloader.error {
                VStack(spacing: 12) {
                    Text(error)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.red.opacity(0.95))
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        Task { await startDownload() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 4)
            }

            Text("The model stays on-device after the first download.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(18)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var progressString: String {
        "\(Int(modelDownloader.downloadProgress * 100))%"
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
