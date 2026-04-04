import SwiftUI

struct EmptyStateView: View {
    let isModelLoaded: Bool
    let isModelLoading: Bool
    let supportsLocalModelRuntime: Bool
    let modelLoadStageText: String

    var body: some View {
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

            if !isModelLoaded {
                Text(statusText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var statusText: String {
        if !supportsLocalModelRuntime {
            return "Simulator mode: mock replies are enabled so you can test the chat UI without downloading the model."
        }

        if isModelLoading {
            return modelLoadStageText
        }

        return "Preparing your on-device model..."
    }

    private var statusTextColor: Color {
        supportsLocalModelRuntime ? AppTheme.textSecondary : AppTheme.textPrimary
    }
}
