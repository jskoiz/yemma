import UIKit
import SwiftUI

@MainActor
final class Yemma4AppDelegate: NSObject, UIApplicationDelegate {
    private var privacyWindows: [String: UIWindow] = [:]

    /// A separate window also covers presented sheets in the app-switcher snapshot.
    func setPrivacyCoverVisible(_ inactive: Bool, lock: AppPrivacyController) {
        let needsUnlock = lock.enabled && !lock.unlocked
        guard inactive || needsUnlock else {
            for window in privacyWindows.values { window.isHidden = true }
            privacyWindows.removeAll()
            return
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let id = scene.session.persistentIdentifier
            let controller: UIViewController
            if !inactive && needsUnlock {
                let root = AppPrivacyShield { Color.clear }
                    .environment(lock)
                    .environment(\.scenePhase, .active)
                    .preferredColorScheme(AppearancePreference.from(PersonalPreferences.defaults.string(forKey: AppearancePreference.storageKey) ?? "system").colorScheme)
                controller = UIHostingController(rootView: root)
            } else {
                controller = UIViewController()
                controller.view.backgroundColor = .systemBackground
                let label = UILabel()
                label.text = "Yemma"
                label.font = .preferredFont(forTextStyle: .title1)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .label
                label.translatesAutoresizingMaskIntoConstraints = false
                controller.view.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
                ])
            }
            controller.view.accessibilityViewIsModal = true
            let window = privacyWindows[id] ?? UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.isUserInteractionEnabled = !inactive && needsUnlock
            window.isHidden = false
            privacyWindows[id] = window
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundModelDownloadCoordinator.shared.registerBackgroundCompletionHandler(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
