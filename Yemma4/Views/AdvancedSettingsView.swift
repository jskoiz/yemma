import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(LLMService.self) private var llmService
    @Environment(AppDiagnostics.self) private var diagnostics
    @Environment(\.dismiss) private var dismiss

    @State private var needsReload = false
    @State private var diagnosticsCopied = false
    @State private var showEventLog = false

    let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?

    init(onRunDebugScenario: ((DebugInferenceScenario) -> Void)? = nil) {
        self.onRunDebugScenario = onRunDebugScenario
    }

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
                    diagnosticsSection
#if DEBUG
                    if onRunDebugScenario != nil {
                        debugSection
                    }
#endif
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

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        settingsSection("Diagnostics") {
            VStack(spacing: 0) {
                infoRow(icon: "waveform.path.ecg", title: "Recent events", detail: "\(diagnostics.recentEvents.count)")
                separator
                Button {
                    diagnostics.copyToPasteboard()
                    diagnosticsCopied = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 22)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Copy diagnostics log")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                separator
                destructiveRow(icon: "trash", title: "Clear diagnostics log") {
                    diagnostics.clear()
                }

                if !diagnostics.recentEvents.isEmpty {
                    separator
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showEventLog.toggle()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "list.bullet.rectangle")
                                .frame(width: 22)
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("Event log")
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            Text("\(diagnostics.recentEvents.suffix(8).count)")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.textSecondary)
                            Image(systemName: showEventLog ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.plain)

                    if showEventLog {
                        ForEach(Array(diagnostics.recentEvents.suffix(8).reversed())) { event in
                            separator
                            diagnosticEventRow(event)
                        }
                    }
                }
            }
        }
        .alert("Diagnostics copied", isPresented: $diagnosticsCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The recent diagnostics log is on the pasteboard.")
        }
    }

    private func diagnosticEventRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.category.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer()

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Text(event.message)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            if !event.metadata.isEmpty {
                Text(
                    event.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: " • ")
                )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Debug

#if DEBUG
    private var debugSection: some View {
        settingsSection("Debug Scenarios") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use these from a Debug build to probe formatting quality. Run the live prompts on a physical iPhone, since the simulator only returns mocked replies.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                if let onRunDebugScenario {
                    ForEach(DebugInferenceScenario.allCases) { scenario in
                        separator
                        actionDetailRow(
                            icon: scenario.icon,
                            title: scenario.title,
                            detail: scenario.detail
                        ) {
                            dismiss()
                            onRunDebugScenario(scenario)
                        }
                    }
                }
            }
        }
    }
#endif

    private func actionDetailRow(
        icon: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(detail)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 26)
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(AppTheme.textPrimary)

            Text(title)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            Text(detail)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func destructiveRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                Spacer()
            }
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reset

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
