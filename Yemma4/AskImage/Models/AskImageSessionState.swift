import Foundation

/// High-level state of an Ask Image session.
enum AskImageSessionState: Equatable, Sendable {
    case idle
    case warmingModel
    case readyForInput
    case generating
    case error(String)
}
