import Foundation

enum PersonalPreferences {
    static let storageKey = "com.avmillabs.yemma4.personalPreferences"
    static let characterLimit = 500

    static var defaults: UserDefaults {
#if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["YEMMA_UI_TEST_SESSION"],
           let session = UUID(uuidString: value),
           let isolated = UserDefaults(suiteName: "yemma.ui-tests.\(session.uuidString)") {
            return isolated
        }
#endif
        return .standard
    }

    /// Returns the prompt instruction Yemma can add before subsequent responses.
    /// The saved text remains user-editable local state in UserDefaults.
    static func instruction(defaults: UserDefaults = PersonalPreferences.defaults) -> String? {
        let preferences = savedText(defaults: defaults)
        guard !preferences.isEmpty else { return nil }

        return """
        Apply these explicit user preferences to subsequent responses until the user edits or clears them:
        \(preferences)
        If the current request conflicts with these preferences, follow the current request.
        """
    }

    static func savedText(defaults: UserDefaults = PersonalPreferences.defaults) -> String {
        guard let stored = defaults.string(forKey: storageKey) else { return "" }
        return normalized(stored)
    }

    static func save(_ text: String, defaults: UserDefaults = PersonalPreferences.defaults) {
        let value = normalized(text)
        if value.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(value, forKey: storageKey)
        }
    }

    static func normalized(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(characterLimit))
    }
}
