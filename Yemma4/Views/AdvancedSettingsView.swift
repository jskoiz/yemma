import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(LLMService.self) private var llmService
    @Environment(\.dismiss) private var dismiss

    @State private var needsReload = false

    private let contextSizeOptions: [UInt32] = [2048, 4096, 8192, 16384, 32768]
    private let maxTokenOptions: [Int] = [256, 512, 1024, 2048, 4096]

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header

                    if needsReload {
                        reloadBanner
                    }

                    inferenceSection
                    resetSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Spacer()
            Text("Advanced")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            // Balance the back button
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.clear)
        }
        .padding(.horizontal, 4)
    }

    private var reloadBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)

            Text("Reload model to apply changes.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 20)
    }

    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inference")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                temperatureRow
                separator
                contextSizeRow
                separator
                flashAttentionRow
                separator
                maxResponseTokensRow
            }
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 26)
        }
    }

    private var temperatureRow: some View {
        @Bindable var service = llmService
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Creativity", systemImage: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(String(format: "%.1f", llmService.temperature))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { llmService.temperature },
                    set: { llmService.temperature = $0 }
                ),
                in: 0.1...2.0,
                step: 0.1
            )
            .tint(AppTheme.accent)

            Text("Lower values stay focused. Higher values improvise more.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var contextSizeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Context Window", systemImage: "text.alignleft")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(contextSizeLabel(llmService.contextSize))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Picker("Context Window", selection: Binding(
                get: { llmService.contextSize },
                set: {
                    llmService.contextSize = $0
                    needsReload = true
                }
            )) {
                ForEach(contextSizeOptions, id: \.self) { size in
                    Text(contextSizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)

            Text("Higher values use more memory. Requires model reload.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var flashAttentionRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { llmService.flashAttention },
                set: {
                    llmService.flashAttention = $0
                    needsReload = true
                }
            )) {
                Label("Flash Attention", systemImage: "bolt")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(AppTheme.accent)

            Text("Hardware-accelerated attention. Improves speed on supported devices. Requires model reload.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var maxResponseTokensRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Max Response", systemImage: "text.word.spacing")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(tokenLabel(llmService.maxResponseTokens))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Picker("Max Response Tokens", selection: Binding(
                get: { llmService.maxResponseTokens },
                set: { llmService.maxResponseTokens = $0 }
            )) {
                ForEach(maxTokenOptions, id: \.self) { count in
                    Text(tokenLabel(count)).tag(count)
                }
            }
            .pickerStyle(.segmented)

            Text("Maximum tokens the model can generate per reply.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                Button {
                    llmService.resetAdvancedSettings()
                    needsReload = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 22)
                        Text("Reset to Defaults")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                        Spacer()
                    }
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 26)
        }
    }

    private var separator: some View {
        Divider()
            .padding(.leading, 52)
            .overlay(AppTheme.separator)
    }

    private func contextSizeLabel(_ size: UInt32) -> String {
        if size >= 1024 {
            return "\(size / 1024)K"
        }
        return "\(size)"
    }

    private func tokenLabel(_ count: Int) -> String {
        if count >= 1024 {
            return String(format: "%.1fK", Double(count) / 1024.0)
        }
        return "\(count)"
    }
}
