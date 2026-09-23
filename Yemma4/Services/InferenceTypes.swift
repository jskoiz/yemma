import Foundation

struct PromptImageAsset: Hashable, Sendable {
    let id: String
    let filePath: String
}

struct PromptMessageInput: Sendable, Equatable {
    let role: String
    let text: String
    let images: [PromptImageAsset]
}

enum PromptBudgetError: LocalizedError, Sendable, Equatable {
    case currentPromptTooLong(estimatedTokens: Int, budget: Int)
    case currentImagesTooMany(count: Int, maximum: Int)
    case currentPromptAndImagesTooLarge(estimatedTokens: Int, budget: Int)

    var errorDescription: String? {
        switch self {
        case .currentPromptTooLong:
            return "This message is too long for the selected on-device model. Shorten it or start a new chat."
        case let .currentImagesTooMany(_, maximum):
            return "This request has too many images for the selected on-device model. Remove an image or start a new chat. The limit is \(maximum)."
        case .currentPromptAndImagesTooLarge:
            return "This message and its images are too large for the selected on-device model. Shorten the message or remove an image."
        }
    }
}

enum PromptTokenEstimator {
    /// A preflight estimate used before a runtime tokenizer is available. The
    /// scalar heuristic is paired with a UTF-8 byte upper bound so unusual
    /// byte-level tokenization cannot make the request look smaller than it is.
    /// The runtime performs a second check with its prepared token count before
    /// inference starts.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiScalarCount = 0
        var nonASCIIScalarCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value <= 0x7F {
                asciiScalarCount += 1
            } else {
                nonASCIIScalarCount += 1
            }
        }

        let scalarEstimate = (asciiScalarCount + 2) / 3 + nonASCIIScalarCount
        return max(1, max(scalarEstimate, text.utf8.count))
    }

    static func estimate(_ message: PromptMessageInput) -> Int {
        estimate(message.text)
    }
}

struct Qwen35PromptBudget: Sendable, Equatable {
    static let contextWindowTokens = 8_192
    static let safetyMarginTokens = 512
    static let maximumInputTokens = 4_096
    static let imageTokenEstimate = 768
    static let maximumImages = 4
    static let messageOverheadTokens = 4

    static func inputTokenBudget(maximumResponseTokens: Int) -> Int {
        let responseTokens = max(maximumResponseTokens, 1)
        let available = contextWindowTokens - safetyMarginTokens - responseTokens
        return max(1, min(maximumInputTokens, available))
    }

    static func messageTokenCost(content: String, imageCount: Int) -> Int {
        PromptTokenEstimator.estimate(content)
            + max(imageCount, 0) * imageTokenEstimate
            + messageOverheadTokens
    }
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
    case generationStillStopping
    case modelLoadFailed(path: String)
    case assetValidationFailed(Error)
    case processorFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No MLX model bundle is loaded."
        case .qwenRuntimeNotSelected:
            return "Select Qwen3.5 4B before loading its model bundle."
        case .generationStillStopping:
            return "The previous response is still stopping. Try loading the model again in a moment."
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

    var hasPhysicalLoad: Bool {
        physicalLoadTicket != nil
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
