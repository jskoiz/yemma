import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum InferenceRuntime: String, CaseIterable, Identifiable, Sendable {
    case appleFoundationModel
    case qwen35

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleFoundationModel:
            return "Apple"
        case .qwen35:
            return "Qwen3.5 4B Abliterated"
        }
    }

    var detail: String {
        switch self {
        case .appleFoundationModel:
            return "Built into Apple Intelligence. No Yemma model download."
        case .qwen35:
            return "Optional 3.05 GB download with image understanding."
        }
    }

    var runtimeName: String {
        switch self {
        case .appleFoundationModel:
            return "Apple Foundation Models"
        case .qwen35:
            return "Qwen3.5 4B MLX"
        }
    }

    var supportsImageInput: Bool {
        self == .qwen35
    }

    static func initialSelection(
        persistedValue: String?,
        appleAvailability: AppleFoundationModelAvailability
    ) -> InferenceRuntime {
        if let persistedValue, let persisted = InferenceRuntime(rawValue: persistedValue) {
            return persisted
        }

        switch appleAvailability {
        case .requiresIOS26, .deviceNotEligible:
            return .qwen35
        case .available, .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedLocale:
            return .appleFoundationModel
        }
    }
}

enum AppleFoundationModelAvailability: Equatable, Sendable {
    case available
    case requiresIOS26
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale

    var isAvailable: Bool {
        self == .available
    }

    var title: String {
        switch self {
        case .available:
            return "Apple model ready"
        case .requiresIOS26:
            return "Requires iOS 26"
        case .deviceNotEligible:
            return "Apple model unavailable"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off"
        case .modelNotReady:
            return "Apple model is getting ready"
        case .unsupportedLocale:
            return "Language not supported"
        }
    }

    var detail: String {
        switch self {
        case .available:
            return "The system model is ready on this iPhone."
        case .requiresIOS26:
            return "The built-in model requires iOS 26 or newer. Qwen remains available as an optional download."
        case .deviceNotEligible:
            return "This iPhone does not support the Apple Intelligence system model. Qwen remains available as an optional download."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings, or choose Qwen for local chat."
        case .modelNotReady:
            return "iOS is still preparing the built-in model. Yemma will check again when the app becomes active."
        case .unsupportedLocale:
            return "The current app language is not supported by the built-in model. Choose a supported language or use Qwen."
        }
    }
}

enum AppleFoundationModelRuntimeError: LocalizedError {
    case unavailable(AppleFoundationModelAvailability)
    case imagesUnsupported
    case imageHistoryUnsupported
    case contextLimitExceeded
    case nonMonotonicSnapshot

    var errorDescription: String? {
        switch self {
        case let .unavailable(availability):
            return availability.detail
        case .imagesUnsupported:
            return "Image chat currently requires the optional Qwen3.5 4B model."
        case .imageHistoryUnsupported:
            return "This chat contains images. Start a new text chat or switch to Qwen3.5 4B."
        case .contextLimitExceeded:
            return "This request is too long for Apple's on-device context. Shorten the current message or start a new chat."
        case .nonMonotonicSnapshot:
            return "The Apple model returned an unexpected streaming update. Try the request again."
        }
    }
}

enum AppleFoundationModelRuntime {
    static let contextWindowTokenLimit = 4_096
    static let contextSafetyMarginTokens = 256
    static let maximumResponseTokenLimit = 1_024
    static let maximumHistoryCharacters = 8_000

    private static let transcriptEntryOverheadTokens = 4

    static func currentAvailability(locale: Locale = .current) -> AppleFoundationModelAvailability {
#if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return .requiresIOS26
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .available : .unsupportedLocale
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
#else
        return .requiresIOS26
#endif
    }

    static func boundedHistory(
        _ history: [PromptMessageInput],
        maximumCharacters: Int = maximumHistoryCharacters
    ) -> [PromptMessageInput] {
        guard maximumCharacters > 0 else { return [] }

        var result: [PromptMessageInput] = []
        var usedCharacters = 0

        for message in history.reversed() {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let messageCharacters = text.count
            guard usedCharacters + messageCharacters <= maximumCharacters else {
                break
            }

            result.append(message)
            usedCharacters += messageCharacters
        }

        var bounded = Array(result.reversed())
        while bounded.first.map({ $0.role.lowercased() != "user" }) == true {
            bounded.removeFirst()
        }
        return bounded
    }

    static func inputTokenBudget(maximumResponseTokens: Int) -> Int {
        let responseTokens = min(max(maximumResponseTokens, 1), maximumResponseTokenLimit)
        return max(
            1,
            contextWindowTokenLimit - contextSafetyMarginTokens - responseTokens
        )
    }

    static func estimatedTokenCount(_ text: String) -> Int {
        PromptTokenEstimator.estimate(text)
    }

    /// Bounds the complete Apple request, including instructions, the current
    /// prompt, recent history, and a response reserve. History may be omitted
    /// from the front, but the current prompt is never truncated.
    static func boundedRequestHistory(
        instructions: String,
        history: [PromptMessageInput],
        prompt: PromptMessageInput,
        maximumResponseTokens: Int
    ) throws -> [PromptMessageInput] {
        let budget = inputTokenBudget(maximumResponseTokens: maximumResponseTokens)
        let instructionTokens = PromptTokenEstimator.estimate(instructions)
            + transcriptEntryOverheadTokens
        let promptTokens = PromptTokenEstimator.estimate(prompt.text)
            + (prompt.text.isEmpty ? 0 : transcriptEntryOverheadTokens)

        guard instructionTokens + promptTokens <= budget else {
            throw AppleFoundationModelRuntimeError.contextLimitExceeded
        }

        var remainingTokens = budget - instructionTokens - promptTokens
        var result: [PromptMessageInput] = []

        for message in history.reversed() {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let messageTokens = PromptTokenEstimator.estimate(text)
                + transcriptEntryOverheadTokens
            guard messageTokens <= remainingTokens else {
                break
            }

            result.append(message)
            remainingTokens -= messageTokens
        }

        var bounded = Array(result.reversed())
        while bounded.first.map({ $0.role.lowercased() != "user" }) == true {
            bounded.removeFirst()
        }
        return bounded
    }

    @discardableResult
    static func validateRequest(
        instructions: String,
        history: [PromptMessageInput],
        prompt: PromptMessageInput,
        maximumResponseTokens: Int
    ) throws -> [PromptMessageInput] {
        guard prompt.images.isEmpty else {
            throw AppleFoundationModelRuntimeError.imagesUnsupported
        }
        guard history.allSatisfy({ $0.images.isEmpty }) else {
            throw AppleFoundationModelRuntimeError.imageHistoryUnsupported
        }

        return try boundedRequestHistory(
            instructions: instructions,
            history: history,
            prompt: prompt,
            maximumResponseTokens: maximumResponseTokens
        )
    }

    static func snapshotDelta(previous: String, current: String) throws -> String {
        guard current.hasPrefix(previous) else {
            throw AppleFoundationModelRuntimeError.nonMonotonicSnapshot
        }
        return String(current.dropFirst(previous.count))
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func streamResponse(
        instructions: String,
        history: [PromptMessageInput],
        prompt: PromptMessageInput,
        temperature: Double,
        maximumResponseTokens: Int,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let availability = currentAvailability()
        guard availability.isAvailable else {
            throw AppleFoundationModelRuntimeError.unavailable(availability)
        }
        let boundedHistory = try validateRequest(
            instructions: instructions,
            history: history,
            prompt: prompt,
            maximumResponseTokens: maximumResponseTokens
        )
        let transcript = makeTranscript(instructions: instructions, history: boundedHistory)
        let session = LanguageModelSession(
            model: .default,
            tools: [],
            transcript: transcript
        )
        let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: min(maximumResponseTokens, maximumResponseTokenLimit)
        )

        var previousSnapshot = ""
        for try await snapshot in session.streamResponse(to: prompt.text, options: options) {
            try Task.checkCancellation()
            let currentSnapshot = snapshot.content
            let delta = try snapshotDelta(previous: previousSnapshot, current: currentSnapshot)
            previousSnapshot = currentSnapshot
            if !delta.isEmpty {
                onDelta(delta)
            }
        }
    }

    @available(iOS 26.0, *)
    private static func makeTranscript(
        instructions: String,
        history: [PromptMessageInput]
    ) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: instructions))],
                    toolDefinitions: []
                )
            )
        ]

        for message in history {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segments: [Transcript.Segment] = [
                .text(Transcript.TextSegment(content: text))
            ]

            switch message.role.lowercased() {
            case "assistant", "yemma":
                entries.append(
                    .response(
                        Transcript.Response(assetIDs: [], segments: segments)
                    )
                )
            case "user":
                entries.append(
                    .prompt(
                        Transcript.Prompt(segments: segments)
                    )
                )
            default:
                continue
            }
        }

        return Transcript(entries: entries)
    }
#endif
}
