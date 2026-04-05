import Foundation

/// Categorised error kinds for the Ask Image session,
/// enabling targeted recovery actions in the UI.
enum AskImageSessionError: Equatable, Sendable {
    /// The model file is missing or corrupted on disk. Offer re-download.
    case modelFileMissing(String) // model display name

    /// The runtime failed to initialise. Offer retry.
    case runtimeInitFailed(String) // underlying message

    /// Generation completed but produced no output. Offer retry.
    case generationEmptyOutput

    /// Generic / unclassified error.
    case generic(String)

    var userMessage: String {
        switch self {
        case .modelFileMissing(let name):
            "The \(name) model file is missing or corrupted. Re-download to fix this."
        case .runtimeInitFailed(let detail):
            "Runtime failed to start: \(detail)"
        case .generationEmptyOutput:
            "The model returned an empty response. Try again or reset the session."
        case .generic(let message):
            message
        }
    }

    /// Whether the UI should show a "Re-download" action instead of plain "Retry".
    var shouldOfferRedownload: Bool {
        if case .modelFileMissing = self { return true }
        return false
    }
}

/// High-level state of an Ask Image session.
enum AskImageSessionState: Equatable, Sendable {
    case idle
    case warmingModel
    case readyForInput
    case generating
    case error(AskImageSessionError)
}
