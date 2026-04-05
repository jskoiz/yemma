import Foundation

/// Feature flag and configuration for the Ask Image feature.
enum AskImageFeature {
    /// Whether Ask Image is available in the UI.
    /// Flip to `false` to hide the feature without touching any other file.
    static let isEnabled = true

    /// Minimum iOS version that supports LiteRT-LM on-device inference.
    static let minimumSupportedOS = "17.0"

    /// Whether the current device supports real LiteRT-LM inference.
    /// Simulator always uses the stub runtime.
    static var supportsNativeRuntime: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}
