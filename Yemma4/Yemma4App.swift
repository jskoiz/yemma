import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public enum Yemma4AppConfiguration {
    public static let bundleIdentifier = "com.avmillabs.yemma4"

#if targetEnvironment(simulator)
    public static let supportsLocalModelRuntime = false
#else
    public static let supportsLocalModelRuntime = true
#endif
}

final class Yemma4AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == "\(Yemma4AppConfiguration.bundleIdentifier).model-download" else {
            completionHandler()
            return
        }

        BackgroundModelDownloadEvents.shared.setCompletionHandler(completionHandler)
    }
}

@main
public struct Yemma4App: App {
    @UIApplicationDelegateAdaptor(Yemma4AppDelegate.self) private var appDelegate
    @AppStorage(AppearancePreference.storageKey) private var appearancePreferenceRaw = AppearancePreference.system.rawValue
    @State private var diagnostics = AppDiagnostics.shared
    @State private var modelDownloader = ModelDownloader()
    @State private var llmService = LLMService()

    public static let bundleIdentifier = Yemma4AppConfiguration.bundleIdentifier

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(diagnostics)
                .environment(modelDownloader)
                .environment(llmService)
                .preferredColorScheme(AppearancePreference.from(appearancePreferenceRaw).colorScheme)
                .tint(AppTheme.accent)
        }
    }
}
