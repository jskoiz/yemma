import Foundation

/// Download and readiness state for a single LiteRT-LM model.
enum LiteRTModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case validationFailed(reason: String)
    case preparing
    case ready
    case failed(reason: String)

    var isUsable: Bool {
        switch self {
        case .downloaded, .preparing, .ready:
            return true
        default:
            return false
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .downloaded, .preparing, .ready:
            return true
        default:
            return false
        }
    }
}
