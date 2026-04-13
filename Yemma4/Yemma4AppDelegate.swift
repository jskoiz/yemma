import UIKit

final class Yemma4AppDelegate: NSObject, UIApplicationDelegate {
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
