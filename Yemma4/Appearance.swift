import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    static func from(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .system
    }
}

enum AppHaptics {
    static func selection() {
#if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
    }

    static func softImpact() {
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    static func success() {
#if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
    }
}

enum AppTheme {
    enum Radius {
        static let small: CGFloat = 16
        static let medium: CGFloat = 22
        static let large: CGFloat = 28
    }

    enum Layout {
        static let screenPadding: CGFloat = 16
        static let screenHeaderHorizontalPadding: CGFloat = 20
        static let rowHorizontalPadding: CGFloat = 18
        static let rowVerticalPadding: CGFloat = 15
        static let rowIconSize: CGFloat = 22
        static let controlIconSize: CGFloat = 34
        static let composerActionSize: CGFloat = 42
        static let sectionSpacing: CGFloat = 24
        static let sectionLabelSpacing: CGFloat = 10
        static let bubbleHorizontalPadding: CGFloat = 16
        static let bubbleVerticalPadding: CGFloat = 13
    }

    enum Typography {
        static let brandHero = Font.system(size: 40, weight: .bold, design: .serif)
        static let brandSection = Font.system(size: 28, weight: .bold, design: .serif)
        static let utilityTitle = Font.title2.weight(.semibold)
        static let utilitySectionLabel = Font.footnote.weight(.semibold)
        static let utilityRowTitle = Font.body.weight(.medium)
        static let utilityRowDetail = Font.subheadline.weight(.medium)
        static let utilityCaption = Font.footnote.weight(.medium)
        static let chatLabel = Font.caption.weight(.semibold)
        static let chatComposer = Font.system(size: 18, weight: .medium, design: .rounded)
        static let chatUserMessage = Font.system(size: 16, weight: .medium, design: .rounded)
        static let chatAssistantMessage = Font.system(size: 16, weight: .regular)
    }

    enum ShadowStyle {
        case card
        case floating
    }

    struct ShadowToken {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    static let backgroundTop = dynamicColor(light: rgba(250, 247, 243), dark: rgba(18, 20, 28))
    static let backgroundBottom = dynamicColor(light: rgba(238, 240, 245), dark: rgba(9, 11, 18))
    static let backgroundSheenTop = dynamicColor(light: rgba(255, 255, 255, alpha: 0.12), dark: rgba(255, 255, 255, alpha: 0.02))
    static let backgroundSheenMiddle = dynamicColor(light: rgba(255, 255, 255, alpha: 0.42), dark: rgba(255, 255, 255, alpha: 0.08))

    static let brandCard = dynamicColor(light: rgba(255, 255, 255, alpha: 0.76), dark: rgba(27, 30, 41, alpha: 0.86))
    static let brandCardBorder = dynamicColor(light: rgba(255, 255, 255, alpha: 0.42), dark: rgba(255, 255, 255, alpha: 0.08))
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let groupedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let groupedSurfaceBorder = dynamicColor(light: rgba(67, 79, 104, alpha: 0.08), dark: rgba(255, 255, 255, alpha: 0.06))
    static let utilityTopTint = dynamicColor(light: rgba(111, 95, 214, alpha: 0.09), dark: rgba(124, 108, 228, alpha: 0.10))

    static let controlFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.86), dark: rgba(37, 41, 53, alpha: 0.92))
    static let controlBorder = dynamicColor(light: rgba(67, 79, 104, alpha: 0.08), dark: rgba(255, 255, 255, alpha: 0.09))
    static let inputFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.92), dark: rgba(24, 27, 37, alpha: 0.96))
    static let inputBorder = dynamicColor(light: rgba(67, 79, 104, alpha: 0.10), dark: rgba(255, 255, 255, alpha: 0.08))
    static let chipFill = dynamicColor(light: rgba(111, 95, 214, alpha: 0.10), dark: rgba(124, 108, 228, alpha: 0.20))
    static let chipPressedFill = dynamicColor(light: rgba(111, 95, 214, alpha: 0.16), dark: rgba(124, 108, 228, alpha: 0.28))

    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let separator = dynamicColor(light: rgba(67, 79, 104, alpha: 0.12), dark: rgba(255, 255, 255, alpha: 0.08))

    static let accent = dynamicColor(light: rgba(90, 73, 198), dark: rgba(124, 108, 228))
    static let accentStrong = dynamicColor(light: rgba(72, 56, 170), dark: rgba(104, 88, 210))
    static let accentSoft = dynamicColor(light: rgba(90, 73, 198, alpha: 0.16), dark: rgba(124, 108, 228, alpha: 0.24))
    static let accentForeground = Color.white
    static let accentSecondaryForeground = Color.white.opacity(0.76)
    static let destructive = dynamicColor(light: rgba(191, 43, 55), dark: rgba(255, 107, 122))

    static let userBubbleTop = accent
    static let userBubbleBottom = accentStrong
    static let userBubbleBorder = dynamicColor(light: rgba(72, 56, 170, alpha: 0.24), dark: rgba(255, 255, 255, alpha: 0.12))
    static let assistantBubble = dynamicColor(light: rgba(255, 255, 255, alpha: 0.84), dark: rgba(33, 37, 49, alpha: 0.94))
    static let assistantBubbleBorder = dynamicColor(light: rgba(67, 79, 104, alpha: 0.08), dark: rgba(255, 255, 255, alpha: 0.06))
    static let assistantLabel = dynamicColor(light: rgba(94, 104, 128), dark: rgba(166, 174, 194))
    static let userMessageText = Color.white
    static let assistantMessageText = textPrimary
    static let messageCodeBlockBackground = dynamicColor(light: rgba(22, 29, 49, alpha: 0.05), dark: rgba(255, 255, 255, alpha: 0.05))
    static let messageQuote = dynamicColor(light: rgba(90, 73, 198, alpha: 0.30), dark: rgba(124, 108, 228, alpha: 0.40))

    static let composerFadeMiddle = dynamicColor(light: rgba(255, 255, 255, alpha: 0.50), dark: rgba(8, 10, 16, alpha: 0.54))
    static let composerFadeBottom = dynamicColor(light: rgba(255, 255, 255, alpha: 0.82), dark: rgba(8, 10, 16, alpha: 0.88))

    static let warmGlow = dynamicColor(light: rgba(247, 214, 193, alpha: 0.54), dark: rgba(164, 93, 71, alpha: 0.22))
    static let coolGlow = dynamicColor(light: rgba(224, 229, 249, alpha: 0.68), dark: rgba(88, 109, 185, alpha: 0.18))

    static let toastFill = dynamicColor(light: rgba(14, 16, 20, alpha: 0.90), dark: rgba(37, 40, 53, alpha: 0.96))
    static let toastShadow = dynamicColor(light: rgba(0, 0, 0, alpha: 0.16), dark: rgba(0, 0, 0, alpha: 0.32))

    static func shadow(_ style: ShadowStyle) -> ShadowToken {
        switch style {
        case .card:
            return ShadowToken(
                color: dynamicColor(light: rgba(20, 24, 36, alpha: 0.08), dark: rgba(0, 0, 0, alpha: 0.26)),
                radius: 24,
                y: 16
            )
        case .floating:
            return ShadowToken(
                color: dynamicColor(light: rgba(20, 24, 36, alpha: 0.12), dark: rgba(0, 0, 0, alpha: 0.34)),
                radius: 18,
                y: 10
            )
        }
    }

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }
}

enum AppPanelStyle {
    case brand
    case grouped
}

private struct AppPanelModifier: ViewModifier {
    let style: AppPanelStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let fill: Color
        let stroke: Color
        let shadowStyle: AppTheme.ShadowStyle?

        switch style {
        case .brand:
            fill = AppTheme.brandCard
            stroke = AppTheme.brandCardBorder
            shadowStyle = .card
        case .grouped:
            fill = AppTheme.groupedSurface
            stroke = AppTheme.groupedSurfaceBorder
            shadowStyle = nil
        }

        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(stroke, lineWidth: 1)
                    )
            )
            .modifier(OptionalShadowModifier(style: shadowStyle))
    }
}

private struct OptionalShadowModifier: ViewModifier {
    let style: AppTheme.ShadowStyle?

    func body(content: Content) -> some View {
        guard let style else { return AnyView(content) }
        let token = AppTheme.shadow(style)
        return AnyView(
            content.shadow(color: token.color, radius: token.radius, x: 0, y: token.y)
        )
    }
}

private struct InputChromeModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.inputFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.inputBorder, lineWidth: 1)
                    )
            )
    }
}

struct UtilityBackground: View {
    var body: some View {
        ZStack {
            AppTheme.groupedBackground

            LinearGradient(
                colors: [AppTheme.utilityTopTint, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(AppTheme.accentSoft)
                .frame(width: 240, height: 240)
                .blur(radius: 60)
                .offset(x: 120, y: -210)
        }
        .ignoresSafeArea()
    }
}

struct UtilitySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Layout.sectionLabelSpacing) {
            Text(title)
                .font(AppTheme.Typography.utilitySectionLabel)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .groupedCard(cornerRadius: AppTheme.Radius.medium)
        }
    }
}

struct UtilitySectionSeparator: View {
    var leadingInset: CGFloat = AppTheme.Layout.rowHorizontalPadding + AppTheme.Layout.rowIconSize + 14

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .overlay(AppTheme.separator)
    }
}

extension View {
    func brandCard(cornerRadius: CGFloat = AppTheme.Radius.large) -> some View {
        modifier(AppPanelModifier(style: .brand, cornerRadius: cornerRadius))
    }

    func groupedCard(cornerRadius: CGFloat = AppTheme.Radius.medium) -> some View {
        modifier(AppPanelModifier(style: .grouped, cornerRadius: cornerRadius))
    }

    func inputChrome(cornerRadius: CGFloat = AppTheme.Radius.medium) -> some View {
        modifier(InputChromeModifier(cornerRadius: cornerRadius))
    }

    func utilityRowPadding() -> some View {
        padding(.horizontal, AppTheme.Layout.rowHorizontalPadding)
            .padding(.vertical, AppTheme.Layout.rowVerticalPadding)
    }

    func floatingShadow() -> some View {
        let token = AppTheme.shadow(.floating)
        return shadow(color: token.color, radius: token.radius, x: 0, y: token.y)
    }

    func glassCard(cornerRadius: CGFloat = AppTheme.Radius.large) -> some View {
        brandCard(cornerRadius: cornerRadius)
    }
}
