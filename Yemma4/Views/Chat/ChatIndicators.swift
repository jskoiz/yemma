import SwiftUI

struct ThinkingOrbView: View {
    var body: some View {
        HStack(spacing: 10) {
            TypingDotsView()
            Text("Thinking")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.controlFill)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(AppTheme.assistantBubbleBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow(.floating).color.opacity(0.45), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}

struct TypingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 6.5
    private let spacing: CGFloat = 5
    private let stepDuration: TimeInterval = 0.28

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : stepDuration)) { context in
            let phase = animationPhase(for: context.date)

            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.textSecondary)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(dotOpacity(for: index, phase: phase))
                        .scaleEffect(dotScale(for: index, phase: phase))
                        .animation(reduceMotion ? nil : .easeInOut(duration: stepDuration * 0.9), value: phase)
                }
            }
        }
    }

    private func animationPhase(for date: Date) -> Int {
        guard !reduceMotion else { return 0 }
        return Int(date.timeIntervalSinceReferenceDate / stepDuration) % 3
    }

    private func dotOpacity(for index: Int, phase: Int) -> Double {
        if reduceMotion {
            return 0.8
        }

        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.5
        default: return 0.25
        }
    }

    private func dotScale(for index: Int, phase: Int) -> CGFloat {
        if reduceMotion {
            return 1.0
        }

        let offset = (phase - index + 3) % 3
        switch offset {
        case 0: return 1.0
        case 1: return 0.85
        default: return 0.7
        }
    }
}

struct StartupLoadingAnimationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cycleDuration: TimeInterval = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { context in
            let phase = animationPhase(for: context.date)

            ZStack {
                Circle()
                    .stroke(AppTheme.accent.opacity(0.18), lineWidth: 1)
                    .frame(width: 92, height: 92)

                Circle()
                    .stroke(AppTheme.accent.opacity(0.24), lineWidth: 10)
                    .blur(radius: 2)
                    .frame(width: 74, height: 74)
                    .scaleEffect(0.92 + (0.12 * phase))
                    .opacity(0.3 + (0.25 * (1 - phase)))

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.warmGlow, AppTheme.accent, AppTheme.coolGlow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 18, y: 10)
                    .scaleEffect(0.96 + (0.08 * (1 - phase)))

                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accentForeground)
            }
            .frame(width: 104, height: 104)
        }
        .accessibilityHidden(true)
    }

    private func animationPhase(for date: Date) -> CGFloat {
        guard !reduceMotion else { return 0.5 }

        let rawProgress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let eased = 0.5 - (0.5 * cos(rawProgress * .pi * 2))
        return CGFloat(eased)
    }
}

struct ChatStartupLoadingOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let message: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            Rectangle()
                .fill(AppTheme.backgroundBottom.opacity(0.42))
                .ignoresSafeArea()

            VStack(spacing: 22) {
                StartupLoadingAnimationView()

                VStack(spacing: 8) {
                    Text("Loading now")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TypingDotsView()
                    .padding(.top, 2)
            }
            .frame(maxWidth: 280)
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .glassCard(cornerRadius: 30)
            .padding(.horizontal, 28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading now. \(message)")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: message)
    }
}
