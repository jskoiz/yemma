import Foundation

struct PromptImageAsset: Hashable, Sendable {
    let id: String
    let filePath: String
}

struct PromptMessageInput: Sendable {
    let role: String
    let text: String
    let images: [PromptImageAsset]
}

enum ModelLoadStage: Sendable {
    case idle
    case preparingRuntime
    case loadingModel
    case activatingModel
    case ready
    case failed

    var statusText: String {
        switch self {
        case .idle:
            return "Getting Yemma ready."
        case .preparingRuntime:
            return "Preparing your on-device model."
        case .loadingModel:
            return "Loading your model."
        case .activatingModel:
            return "Finishing setup."
        case .ready:
            return "Yemma is ready."
        case .failed:
            return "Yemma could not finish getting ready."
        }
    }
}

struct GenerationDebugStats: Sendable, Equatable {
    let generationID: UUID
    let promptTokenCount: Int
    let generationTokenCount: Int
    let tokensPerSecond: Double?
    let elapsedSeconds: TimeInterval
    let memoryFootprintBytes: UInt64?
    let memoryFootprintDeltaBytes: Int64?
    let stopReason: String
    let isSimulated: Bool
}

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case qwenRuntimeNotSelected
    case modelLoadFailed(path: String)
    case assetValidationFailed(Error)
    case processorFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No MLX model bundle is loaded."
        case .qwenRuntimeNotSelected:
            return "Select Qwen3.5 4B before loading its model bundle."
        case let .modelLoadFailed(path):
            return "Failed to load the MLX model bundle at \(path)."
        case let .assetValidationFailed(error):
            return "Model asset validation failed.\n\n\(error.localizedDescription)"
        case let .processorFailed(error):
            return "Image/text preprocessing failed.\n\n\(error.localizedDescription)"
        }
    }
}

struct ModelLoadTicket: Equatable, Sendable {
    let revision: UInt64
    let path: String
}

struct ModelLoadCoordinator: Sendable {
    private(set) var revision: UInt64 = 0
    private var physicalLoadTicket: ModelLoadTicket?

    var loadingPath: String? {
        physicalLoadTicket?.path
    }

    mutating func begin(path: String) -> ModelLoadTicket? {
        guard physicalLoadTicket == nil else { return nil }

        revision &+= 1
        let ticket = ModelLoadTicket(revision: revision, path: path)
        physicalLoadTicket = ticket
        return ticket
    }

    func isCurrent(_ ticket: ModelLoadTicket) -> Bool {
        revision == ticket.revision && physicalLoadTicket == ticket
    }

    @discardableResult
    mutating func finish(_ ticket: ModelLoadTicket) -> Bool {
        guard physicalLoadTicket == ticket else { return false }

        let wasCurrent = revision == ticket.revision
        physicalLoadTicket = nil
        return wasCurrent
    }

    mutating func invalidate() {
        revision &+= 1
        // Keep the physical ticket until its detached load settles. Logical
        // invalidation prevents activation, while retaining the ticket prevents
        // a second multi-gigabyte load from starting concurrently.
    }
}

struct Qwen35ConversationMessage: Sendable {
    let role: String
    let content: String
    let imageURLs: [URL]
}
