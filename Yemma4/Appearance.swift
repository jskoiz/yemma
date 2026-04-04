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

enum AppTheme {
    static let backgroundTop = dynamicColor(light: rgba(250, 247, 243), dark: rgba(18, 20, 28))
    static let backgroundBottom = dynamicColor(light: rgba(238, 240, 245), dark: rgba(9, 11, 18))
    static let backgroundSheenTop = dynamicColor(light: rgba(255, 255, 255, alpha: 0.12), dark: rgba(255, 255, 255, alpha: 0.02))
    static let backgroundSheenMiddle = dynamicColor(light: rgba(255, 255, 255, alpha: 0.42), dark: rgba(255, 255, 255, alpha: 0.08))

    static let card = dynamicColor(light: rgba(255, 255, 255, alpha: 0.72), dark: rgba(28, 31, 41, alpha: 0.84))
    static let cardBorder = dynamicColor(light: rgba(255, 255, 255, alpha: 0.76), dark: rgba(255, 255, 255, alpha: 0.10))
    static let controlFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.84), dark: rgba(35, 39, 51, alpha: 0.92))
    static let controlBorder = dynamicColor(light: rgba(255, 255, 255, alpha: 0.82), dark: rgba(255, 255, 255, alpha: 0.12))
    static let inputFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.82), dark: rgba(20, 23, 32, alpha: 0.94))
    static let chipFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.78), dark: rgba(39, 42, 55, alpha: 0.88))
    static let chipPressedFill = dynamicColor(light: rgba(255, 255, 255, alpha: 0.94), dark: rgba(48, 52, 66, alpha: 0.96))

    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let separator = Color(uiColor: .separator)

    static let accent = dynamicColor(light: rgba(79, 63, 177), dark: rgba(96, 81, 197))
    static let accentForeground = Color.white
    static let accentSecondaryForeground = Color.white.opacity(0.76)

    static let userBubbleTop = dynamicColor(light: rgba(255, 255, 255, alpha: 0.94), dark: rgba(73, 78, 98, alpha: 0.98))
    static let userBubbleBottom = dynamicColor(light: rgba(255, 255, 255, alpha: 0.78), dark: rgba(55, 59, 75, alpha: 0.98))
    static let assistantBubble = dynamicColor(light: rgba(255, 255, 255, alpha: 0.64), dark: rgba(35, 38, 50, alpha: 0.88))
    static let messageBubbleBorder = dynamicColor(light: rgba(255, 255, 255, alpha: 0.78), dark: rgba(255, 255, 255, alpha: 0.08))

    static let composerFadeMiddle = dynamicColor(light: rgba(255, 255, 255, alpha: 0.50), dark: rgba(8, 10, 16, alpha: 0.54))
    static let composerFadeBottom = dynamicColor(light: rgba(255, 255, 255, alpha: 0.82), dark: rgba(8, 10, 16, alpha: 0.88))

    static let warmGlow = dynamicColor(light: rgba(247, 214, 193, alpha: 0.54), dark: rgba(164, 93, 71, alpha: 0.22))
    static let coolGlow = dynamicColor(light: rgba(224, 229, 249, alpha: 0.68), dark: rgba(88, 109, 185, alpha: 0.18))

    static let shadow = dynamicColor(light: rgba(0, 0, 0, alpha: 0.05), dark: rgba(0, 0, 0, alpha: 0.34))
    static let toastFill = dynamicColor(light: rgba(14, 16, 20, alpha: 0.90), dark: rgba(37, 40, 53, alpha: 0.96))
    static let toastShadow = dynamicColor(light: rgba(0, 0, 0, alpha: 0.16), dark: rgba(0, 0, 0, alpha: 0.32))

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
