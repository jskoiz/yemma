import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(LLMService.self) private var llmService
    @Environment(AppDiagnostics.self) private var diagnostics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            UtilityBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppTheme.Layout.sectionSpacing) {
                    header

                    if needsReload {
                        reloadBanner
                    }

                    overviewSection
                    inferenceSection
                    diagnosticsSection
#if DEBUG
                    if onRunDebugScenario != nil {
                        debugSection
                    }
#endif
                    resetSection
                }
                .padding(.horizontal, AppTheme.Layout.screenPadding)
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
            .accessibilityLabel("Back")
            .accessibilityHint("Returns to the main settings screen.")
            Spacer()
            Text("Advanced")
                .font(AppTheme.Typography.utilityTitle)
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
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.accent)

            Text("Reload the model to apply context or flash attention changes.")
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 14)
        .groupedCard(cornerRadius: AppTheme.Radius.medium)
        .accessibilityElement(children: .combine)
    }

    private var overviewSection: some View {
        UtilitySection("Overview") {
            infoRow(
                icon: "bolt.circle",
                title: "Response style",
                detail: llmService.activeResponseStyleTitle
            )
            UtilitySectionSeparator()
            infoRow(
                icon: "text.alignleft",
                title: "Context window",
                detail: contextSizeLabel(llmService.contextSize)
            )
            UtilitySectionSeparator()
            infoRow(
                icon: "bolt",
                title: "Flash attention",
                detail: llmService.flashAttention ? "On" : "Off"
            )
        }
    }

    private var inferenceSection: some View {
        UtilitySection("Runtime Controls") {
            temperatureRow
            UtilitySectionSeparator()
            contextSizeRow
            UtilitySectionSeparator()
            flashAttentionRow
            UtilitySectionSeparator()
            maxResponseTokensRow
        }
    }

    private var temperatureRow: some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Creativity", systemImage: "slider.horizontal.3")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(String(format: "%.1f", llmService.temperature))
                    .font(AppTheme.Typography.utilityRowDetail)
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
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityHint("Adjusts how inventive the model sounds.")
    }

    private var contextSizeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Context Window", systemImage: "text.alignleft")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(contextSizeLabel(llmService.contextSize))
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Menu {
                ForEach(contextSizeOptions, id: \.self) { size in
                    Button(contextSizeLabel(size)) {
                        guard llmService.contextSize != size else { return }
                        llmService.contextSize = size
                        needsReload = true
                        AppHaptics.selection()
                        diagnostics.record(
                            "Context window changed",
                            category: "settings",
                            metadata: [
                                "contextSize": size,
                                "reloadRequired": true
                            ]
                        )
                    }
                }
            } label: {
                HStack {
                    Text(contextSizeLabel(llmService.contextSize))
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Higher values use more memory. Requires model reload.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityHint("Changes how much recent conversation the model can keep in memory.")
    }

    private var flashAttentionRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { llmService.flashAttention },
                set: {
                    guard llmService.flashAttention != $0 else { return }
                    llmService.flashAttention = $0
                    needsReload = true
                    AppHaptics.selection()
                    diagnostics.record(
                        "Flash attention changed",
                        category: "settings",
                        metadata: [
                            "enabled": $0,
                            "reloadRequired": true
                        ]
                    )
                }
            )) {
                Label("Flash Attention", systemImage: "bolt")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(AppTheme.accent)

            Text("Hardware-accelerated attention. Improves speed on supported devices. Requires model reload.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
    }

    private var maxResponseTokensRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Max Response", systemImage: "text.word.spacing")
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(tokenLabel(llmService.maxResponseTokens))
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Menu {
                ForEach(maxTokenOptions, id: \.self) { count in
                    Button(tokenLabel(count)) {
                        guard llmService.maxResponseTokens != count else { return }
                        llmService.maxResponseTokens = count
                        AppHaptics.selection()
                        diagnostics.record(
                            "Max response changed",
                            category: "settings",
                            metadata: ["maxResponseTokens": count]
                        )
                    }
                }
            } label: {
                HStack {
                    Text(tokenLabel(llmService.maxResponseTokens))
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Maximum tokens the model can generate per reply.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityHint("Sets the longest reply the model is allowed to produce.")
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        UtilitySection("Diagnostics") {
            infoRow(icon: "waveform.path.ecg", title: "Recent events", detail: "\(diagnostics.recentEvents.count)")
            UtilitySectionSeparator()
            Button {
                diagnostics.copyToPasteboard()
                diagnosticsCopied = true
            } label: {
                utilityActionRow(icon: "doc.on.doc", title: "Copy diagnostics log")
            }
            .buttonStyle(.plain)
            UtilitySectionSeparator()
            destructiveRow(icon: "trash", title: "Clear diagnostics log") {
                diagnostics.clear()
            }

            if !diagnostics.recentEvents.isEmpty {
                UtilitySectionSeparator()
                Button {
                    if reduceMotion {
                        showEventLog.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showEventLog.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "list.bullet.rectangle")
                            .frame(width: AppTheme.Layout.rowIconSize)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Event log")
                            .font(AppTheme.Typography.utilityRowTitle)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text("\(diagnostics.recentEvents.suffix(8).count)")
                            .font(AppTheme.Typography.utilityRowDetail)
                            .foregroundStyle(AppTheme.textSecondary)
                        Image(systemName: showEventLog ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .utilityRowPadding()
                }
                .buttonStyle(.plain)

                if showEventLog {
                    ForEach(Array(diagnostics.recentEvents.suffix(8).reversed())) { event in
                        UtilitySectionSeparator(leadingInset: AppTheme.Layout.rowHorizontalPadding)
                        diagnosticEventRow(event)
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
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer()

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Text(event.message)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            if !event.metadata.isEmpty {
                Text(
                    event.metadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: " • ")
                )
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.vertical, 14)
    }

    // MARK: - Debug

#if DEBUG
    private var debugSection: some View {
        UtilitySection("Debug Scenarios") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use these from a Debug build to probe formatting quality. Run the live prompts on a physical iPhone, since the simulator only returns mocked replies.")
                    .font(AppTheme.Typography.utilityCaption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .utilityRowPadding()

            if let onRunDebugScenario {
                ForEach(DebugInferenceScenario.allCases) { scenario in
                    UtilitySectionSeparator()
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
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(detail)
                        .font(AppTheme.Typography.utilityCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .utilityRowPadding()
        }
        .buttonStyle(.plain)
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                    .foregroundStyle(AppTheme.textPrimary)

                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Text(detail)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .frame(width: AppTheme.Layout.rowIconSize)
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(title)
                        .font(AppTheme.Typography.utilityRowTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                }

                Text(detail)
                    .font(AppTheme.Typography.utilityRowDetail)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, AppTheme.Layout.rowIconSize + 14)
            }
        }
        .utilityRowPadding()
        .accessibilityElement(children: .combine)
    }

    private func destructiveRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: AppTheme.Layout.rowIconSize)
                Text(title)
                    .font(AppTheme.Typography.utilityRowTitle)
                Spacer()
            }
            .foregroundStyle(AppTheme.destructive)
            .utilityRowPadding()
        }
        .buttonStyle(.plain)
    }

    private func utilityActionRow(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: AppTheme.Layout.rowIconSize)
                .foregroundStyle(AppTheme.textPrimary)
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
        }
        .utilityRowPadding()
    }

    // MARK: - Reset

    private var resetSection: some View {
        UtilitySection("Reset") {
            Button {
                llmService.resetAdvancedSettings()
                needsReload = true
                AppHaptics.selection()
                diagnostics.record("Advanced settings reset", category: "settings")
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: AppTheme.Layout.rowIconSize)
                    Text("Reset to Defaults")
                        .font(AppTheme.Typography.utilityRowTitle)
                    Spacer()
                }
                .foregroundStyle(AppTheme.accent)
                .utilityRowPadding()
            }
            .buttonStyle(.plain)
        }
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

#if DEBUG
#Preview("Advanced Settings") {
    AdvancedSettingsView()
        .environment(LLMService())
        .environment(AppDiagnostics.shared)
}

#Preview("Advanced Settings Accessibility") {
    AdvancedSettingsView()
        .environment(LLMService())
        .environment(AppDiagnostics.shared)
        .dynamicTypeSize(.accessibility3)
        .preferredColorScheme(.dark)
}
#endif
