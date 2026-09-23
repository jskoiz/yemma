import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor @Observable
final class AppPrivacyController {
    static let enabledStorageKey = "com.avmillabs.yemma4.appPrivacy.enabled"

    private(set) var enabled: Bool
    private(set) var unlocked = false
    private(set) var isAuthenticating = false
    var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeContext: LAContext?
    @ObservationIgnored private var authenticationRevision: UInt64 = 0

    init(defaults: UserDefaults = PersonalPreferences.defaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledStorageKey)
    }

    @discardableResult
    func enable() async -> Bool {
        guard !enabled else { return true }
        guard let revision = await authenticate(reason: "Confirm your identity to enable Yemma app lock."),
              revision == authenticationRevision else {
            return false
        }

        enabled = true
        unlocked = true
        persistEnabledState()
        return true
    }

    @discardableResult
    func disable() async -> Bool {
        guard enabled else { return true }
        guard let revision = await authenticate(reason: "Confirm your identity to disable Yemma app lock."),
              revision == authenticationRevision else {
            return false
        }

        enabled = false
        unlocked = false
        persistEnabledState()
        return true
    }

    @discardableResult
    func unlock() async -> Bool {
        guard enabled else { return true }
        guard !unlocked else { return true }
        guard let revision = await authenticate(reason: "Unlock Yemma to view your conversations."),
              revision == authenticationRevision else {
            return false
        }

        unlocked = true
        return true
    }

    func lock() {
        authenticationRevision &+= 1
        activeContext?.invalidate()
        activeContext = nil
        unlocked = false
        error = nil
    }

    private func persistEnabledState() {
        defaults.set(enabled, forKey: Self.enabledStorageKey)
    }

    private func authenticate(reason: String) async -> UInt64? {
        guard !isAuthenticating else { return nil }

        isAuthenticating = true
        error = nil
        authenticationRevision &+= 1
        let revision = authenticationRevision

        let context = LAContext()
        activeContext = context
        defer {
            if activeContext === context {
                activeContext = nil
            }
            isAuthenticating = false
        }

        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            if revision == authenticationRevision {
                error = Self.authenticationMessage(for: availabilityError)
            }
            return nil
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard revision == authenticationRevision else { return nil }
            guard success else {
                error = "Authentication was not completed. Tap the button to try again."
                return nil
            }
            return revision
        } catch {
            guard revision == authenticationRevision else { return nil }
            self.error = Self.authenticationMessage(for: error)
            return nil
        }
    }

    private static func authenticationMessage(for error: Error?) -> String {
        guard let error else {
            return "Authentication is unavailable. Check your device passcode and try again."
        }

        let nsError = error as NSError
        if let code = LAError.Code(rawValue: nsError.code) {
            switch code {
            case .userCancel:
                return "Authentication was canceled. Tap the button to try again."
            case .systemCancel, .appCancel:
                return "Authentication was interrupted. Tap the button to try again."
            case .authenticationFailed:
                return "Authentication failed. Tap the button to try again."
            case .passcodeNotSet:
                return "Set a device passcode before using app lock."
            case .biometryNotAvailable, .biometryNotEnrolled:
                return "Face ID or Touch ID is unavailable. You can use your device passcode instead."
            case .biometryLockout:
                return "Biometric unlock is locked. Use your device passcode to continue."
            default:
                break
            }
        }

        return "Yemma could not authenticate you. Tap the button to try again."
    }
}

struct AppPrivacyShield<Content: View>: View {
    @Environment(AppPrivacyController.self) private var privacyController
    @Environment(\.scenePhase) private var scenePhase

    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            content()
                .opacity(shouldMaskContent ? 0 : 1)
                .allowsHitTesting(!shouldMaskContent)
                .accessibilityHidden(shouldMaskContent)

            if shouldMaskContent {
                lockedContent
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            privacyController.lock()
        }
    }

    private var shouldMaskContent: Bool {
        privacyController.enabled && (privacyController.unlocked == false || scenePhase != .active)
    }

    private var lockedContent: some View {
        ZStack {
            AppBackground(atmosphere: .none)

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Yemma is locked")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    Text("Unlock to return to your conversations.")
                        .font(.body)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        _ = await privacyController.unlock()
                    }
                } label: {
                    Group {
                        if privacyController.isAuthenticating {
                            ProgressView()
                                .tint(AppTheme.accentForeground)
                        } else {
                            Label("Unlock", systemImage: "lock.open.fill")
                        }
                    }
                    .frame(minWidth: 132, minHeight: AppTheme.Layout.minimumControlSize)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(privacyController.isAuthenticating)
                .accessibilityHint("Uses Face ID, Touch ID, or your device passcode.")

                if let error = privacyController.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Unlock message: \(error)")
                }
            }
            .padding(32)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Yemma is locked")
    }
}
