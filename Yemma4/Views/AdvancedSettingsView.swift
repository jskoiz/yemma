import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(LLMService.self) private var llmService
    @Environment(AppDiagnostics.self) private var diagnostics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var diagnosticsCopied = false
    @State private var showEventLog = false

    let onRunDebugScenario: ((DebugInferenceScenario) -> Void)?

    init(onRunDebugScenario: ((DebugInferenceScenario) -> Void)? = nil) {
        self.onRunDebugScenario = onRunDebugScenario
    }

    private let maxTokenOptions: [Int] = [256, 512, 1024, 2048, 4096]

    var body: some View {
        ZStack {
            UtilityBackground()

            ProgressiveBlurHeaderHost(
                initialHeaderHeight: 88,
                maxBlurRadius: 12,
                fadeExtension: 88,
                tintOpacityTop: 0.66,
                tintOpacityMiddle: 0.24
            ) { headerHeight in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppTheme.Layout.sectionSpacing) {
                        overviewSection
                        inferenceSection
                        advancedSection
                        resetSection
                    }
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                }
            } header: {
                header
                    .padding(.horizontal, AppTheme.Layout.screenPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }
        }
        .task {
            await diagnostics.loadPersistedEventsIfNeeded()
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

    private var overviewSection: some View {
        UtilitySection("Model at a glance") {
            infoRow(
                icon: "bolt.circle",
                title: "Response style",
                detail: llmService.activeResponseStyleTitle
            )
            UtilitySectionSeparator()
            infoRow(
                icon: "cube.transparent",
                title: "Runtime",
                detail: "Gemma 4 MLX"
            )
            UtilitySectionSeparator()
            infoRow(
                icon: "photo.on.rectangle",
                title: "Prompt route",
                detail: "Chat multimodal"
            )
        }
    }

    private var inferenceSection: some View {
        UtilitySection("Model controls") {
            temperatureRow
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

            Text("Lower values stay focused. Higher values feel more open-ended.")
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .utilityRowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityHint("Adjusts how inventive the model sounds.")
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

    // MARK: - Advanced

    private var advancedSection: some View {
        UtilitySection("Advanced") {
            diagnosticsContent

#if DEBUG
            if onRunDebugScenario != nil {
                UtilitySectionSeparator()
                debugContent
            }
#endif
        }
        .alert("Diagnostics copied", isPresented: $diagnosticsCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The recent diagnostics log is on the pasteboard.")
        }
    }

    private var diagnosticsContent: some View {
        VStack(spacing: 0) {
            subsectionHeader(
                title: "Diagnostics",
                detail: "Inspect recent events, copy the local log, or clear it."
            )
            UtilitySectionSeparator()
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

    private func subsectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTheme.Typography.utilityRowTitle.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(detail)
                .font(AppTheme.Typography.utilityCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    #if DEBUG
    private var debugContent: some View {
        VStack(spacing: 0) {
            subsectionHeader(
                title: "Debug scenarios",
                detail: "Use canned prompts to probe formatting quality on a physical iPhone."
            )

            if let onRunDebugScenario {
                UtilitySectionSeparator()
                ForEach(DebugInferenceScenario.allCases) { scenario in
                    actionDetailRow(
                        icon: scenario.icon,
                        title: scenario.title,
                        detail: scenario.detail
                    ) {
                        dismiss()
                        onRunDebugScenario(scenario)
                    }

                    if scenario != DebugInferenceScenario.allCases.last {
                        UtilitySectionSeparator()
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
