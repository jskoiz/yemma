import Foundation
import Observation
import MLX
import MLXLMCommon
import MLXVLM
import OSLog
import Tokenizers

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

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(path: String)
    case assetValidationFailed(Error)
    case processorFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No MLX model bundle is loaded."
        case let .modelLoadFailed(path):
            return "Failed to load the MLX model bundle at \(path)."
        case let .assetValidationFailed(error):
            return "Model asset validation failed.\n\n\(error.localizedDescription)"
        case let .processorFailed(error):
            return "Image/text preprocessing failed.\n\n\(error.localizedDescription)"
        }
    }
}

enum ResponseStylePreset: String, CaseIterable, Identifiable, Sendable {
    case focused
    case balanced
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focused:
            return "Focused"
        case .balanced:
            return "Balanced"
        case .detailed:
            return "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .focused:
            return "Brief, direct answers with minimal filler."
        case .balanced:
            return "Clear answers with a little context when it helps."
        case .detailed:
            return "More depth, tradeoffs, and explanation when useful."
        }
    }

    var temperature: Double {
        switch self {
        case .focused:
            return 0.3
        case .balanced:
            return 0.6
        case .detailed:
            return 0.8
        }
    }

    var maxResponseTokens: Int {
        switch self {
        case .focused:
            return 192
        case .balanced:
            return 512
        case .detailed:
            return 1024
        }
    }

    var legacyTemperature: Double {
        switch self {
        case .focused:
            return 0.4
        case .balanced:
            return 0.7
        case .detailed:
            return 0.9
        }
    }

    var legacyMaxResponseTokens: Int {
        switch self {
        case .focused:
            return 768
        case .balanced:
            return 1024
        case .detailed:
            return 1536
        }
    }

    var instructionPrompt: String {
        switch self {
        case .focused:
            return """
                Response style: Focused.
                Prioritize brevity and directness.
                Give the answer first.
                Prefer one short paragraph.
                Do not include filler, repetition, background, caveats, or extra suggestions unless necessary.
                """
        case .balanced:
            return """
                Response style: Balanced.
                Be clear and moderately concise.
                Give the answer first, then brief explanation if helpful.
                Avoid repetition and unnecessary filler.
                """
        case .detailed:
            return """
                Response style: Detailed.
                Be thorough and well-structured.
                Give the answer first, then explain context, tradeoffs, and important caveats when helpful.
                Use sections or lists only when they improve clarity.
                Do not be verbose for its own sake.
                """
        }
    }

    var lengthTargetPrompt: String {
        switch self {
        case .focused:
            return """
                Length target: 30 to 80 words unless the user explicitly asks for more detail.
                Format: Start with the direct answer. Add at most one short clarification if needed. Stop once the answer is sufficient.
                """
        case .balanced:
            return """
                Length target: 80 to 180 words unless the user explicitly asks for more detail.
                Format: Answer first, then brief explanation if helpful. Prefer 1 to 3 short paragraphs.
                """
        case .detailed:
            return """
                Length target: usually 180 to 400 words when extra detail helps.
                Format: Answer first, then add context, reasoning, tradeoffs, and caveats as needed. Exceed this only when the user clearly asks for depth.
                """
        }
    }

    static func matching(temperature: Double, maxResponseTokens: Int) -> Self? {
        allCases.first { preset in
            abs(preset.temperature - temperature) < 0.05
                && preset.maxResponseTokens == maxResponseTokens
        }
    }
}

private struct Gemma4ConversationMessage: Sendable {
    let role: String
    let content: String
    let imageURLs: [URL]
}

private enum Gemma4InputRoute: String, Sendable {
    case chat
}

private enum PromptTaskHint: String, Sendable {
    case rewrite
    case summarize
    case recommendation
    case coding

    var instructionPrompt: String {
        switch self {
        case .rewrite:
            return """
                Task hint: Rewrite.
                Return the revised text only unless the user explicitly asks for explanation, commentary, or alternatives.
                Keep the original intent and tone constraints intact.
                """
        case .summarize:
            return """
                Task hint: Summarize.
                Start with a short summary first.
                Keep only the essential points and do not add new information.
                """
        case .recommendation:
            return """
                Task hint: Recommendation.
                Give the direct recommendation first, then one brief reason why.
                Mention tradeoffs only if they are important to making the choice.
                """
        case .coding:
            return """
                Task hint: Coding.
                Give the fix, code, or diagnosis first.
                Keep explanation brief unless the user explicitly asks for more detail.
                """
        }
    }
}

private struct FirstTokenCandidate: Sendable {
    let tokenID: Int
    let logit: Float
    let rawDecoded: String
    let cleanedDecoded: String
}

private struct FirstTokenTrace: Sendable {
    let sampledTokenID: Int
    let sampledRawDecoded: String
    let sampledCleanedDecoded: String
    let candidates: [FirstTokenCandidate]
}

private enum MLXRuntimeEnvironment {
    static let lock = NSLock()
    nonisolated(unsafe) static var didPrepare = false
}

final class Gemma4HiddenChannelBudgetProcessor: LogitProcessor, @unchecked Sendable {
    private var baseProcessor: LogitProcessor?
    private let channelStartTokenID: Int?
    private let channelEndTokenID: Int?
    private let hiddenChannelTokenBudget: Int

    private var isInsideHiddenChannel = false
    private var hiddenChannelTokenCount = 0

    init(
        tokenizer: any MLXLMCommon.Tokenizer,
        hiddenChannelTokenBudget: Int,
        baseProcessor: LogitProcessor? = nil
    ) {
        self.baseProcessor = baseProcessor
        self.channelStartTokenID = tokenizer.convertTokenToId("<|channel>")
        self.channelEndTokenID = tokenizer.convertTokenToId("<channel|>")
        self.hiddenChannelTokenBudget = hiddenChannelTokenBudget
    }

    func prompt(_ prompt: MLXArray) {
        resetState()
        baseProcessor?.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        let processedLogits = baseProcessor?.process(logits: logits) ?? logits

        let vocabularySize = processedLogits.shape.last ?? 0
        guard let forcedValues = forcedChannelEndLogits(vocabularySize: vocabularySize) else {
            return processedLogits
        }

        return MLXArray(forcedValues)
            .reshaped(processedLogits.shape)
            .asType(processedLogits.dtype)
    }

    func didSample(token: MLXArray) {
        let tokenID = token.item(Int.self)

        defer {
            baseProcessor?.didSample(token: token)
        }

        didSample(tokenID: tokenID)
    }

    func resetState() {
        isInsideHiddenChannel = false
        hiddenChannelTokenCount = 0
    }

    private func didSample(tokenID: Int) {
        guard let channelStartTokenID, let channelEndTokenID else {
            return
        }

        if tokenID == channelStartTokenID {
            isInsideHiddenChannel = true
            hiddenChannelTokenCount = 0
            return
        }

        guard isInsideHiddenChannel else {
            return
        }

        if tokenID == channelEndTokenID {
            isInsideHiddenChannel = false
            hiddenChannelTokenCount = 0
            return
        }

        hiddenChannelTokenCount += 1
    }

    private func forcedChannelEndLogits(vocabularySize: Int) -> [Float]? {
        guard isInsideHiddenChannel,
            hiddenChannelTokenCount >= hiddenChannelTokenBudget,
            let channelEndTokenID,
            vocabularySize > channelEndTokenID
        else {
            return nil
        }

        var forcedValues = Array(repeating: Float(-1_000_000), count: vocabularySize)
        forcedValues[channelEndTokenID] = 0
        return forcedValues
    }
}

private struct Gemma4ResponseTokenParser {
    private enum State {
        case normal
        case suppressing(untilTokenID: Int)
    }

    private static let suppressedBlocks = [
        ("<|channel>", "<channel|>"),
        ("<|tool_call>", "<tool_call|>"),
        ("<|tool>", "<tool|>"),
        ("<|tool_response>", "<tool_response|>"),
    ]

    private static let oneShotControlTokens = [
        "<bos>",
        "<|turn>",
        "<turn|>",
        "<|image>",
        "<image|>",
        "<|audio>",
        "<audio|>",
        "<channel|>",
        "<tool|>",
        "<tool_call|>",
        "<tool_response|>",
        "<|image|>",
        "<|audio|>",
        "<|video|>",
        "<|think|>",
    ]

    private let tokenizer: any MLXLMCommon.Tokenizer
    private let suppressedBlockTokenIDs: [Int: Int]
    private let oneShotControlTokenIDs: Set<Int>
    private var state = State.normal
    private var detokenizer: MLXLMCommon.NaiveStreamingDetokenizer
    private var tokenPreview: [String] = []
    private(set) var totalTokenCount = 0
    private(set) var visibleChunkCount = 0
    private(set) var visibleCharacterCount = 0

    init(tokenizer: any MLXLMCommon.Tokenizer) {
        self.tokenizer = tokenizer
        self.detokenizer = MLXLMCommon.NaiveStreamingDetokenizer(
            tokenizer: tokenizer,
            skipSpecialTokens: true
        )
        self.suppressedBlockTokenIDs = Dictionary(
            uniqueKeysWithValues: Self.suppressedBlocks.compactMap { start, end in
                guard
                    let startID = tokenizer.convertTokenToId(start),
                    let endID = tokenizer.convertTokenToId(end)
                else {
                    return nil
                }
                return (startID, endID)
            }
        )
        self.oneShotControlTokenIDs = Set(
            Self.oneShotControlTokens.compactMap { tokenizer.convertTokenToId($0) }
        )
    }

    mutating func append(tokenID: Int) -> String? {
        totalTokenCount += 1

        if tokenPreview.count < 24 {
            tokenPreview.append(Self.describeToken(tokenID, tokenizer: tokenizer))
        }

        switch state {
        case .normal:
            if let endTokenID = suppressedBlockTokenIDs[tokenID] {
                state = .suppressing(untilTokenID: endTokenID)
                return nil
            }

            if oneShotControlTokenIDs.contains(tokenID) {
                return nil
            }

            detokenizer.append(token: tokenID)
            guard let chunk = detokenizer.next(), !chunk.isEmpty else {
                return nil
            }

            visibleChunkCount += 1
            visibleCharacterCount += chunk.count
            return chunk

        case let .suppressing(untilTokenID):
            if tokenID == untilTokenID {
                state = .normal
            }
            return nil
        }
    }

    var tokenPreviewSummary: String {
        tokenPreview.joined(separator: " | ")
    }

    private static func describeToken(
        _ tokenID: Int,
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> String {
        let raw = tokenizer.convertIdToToken(tokenID)
            ?? tokenizer.decode(tokenIds: [tokenID], skipSpecialTokens: false)
        let cleaned = tokenizer.decode(tokenIds: [tokenID], skipSpecialTokens: true)
        let rawText = sanitizedTokenText(raw)
        let cleanedText = sanitizedTokenText(cleaned)
        if rawText == cleanedText {
            return "\(tokenID) '\(rawText)'"
        }
        return "\(tokenID) raw='\(rawText)' clean='\(cleanedText)'"
    }

    private static func sanitizedTokenText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return normalized.isEmpty ? "<empty>" : normalized
    }
}

@Observable
final class LLMService: @unchecked Sendable {
    var isModelLoaded = false
    var isModelLoading = false
    var isVisionReady = false
    var isGenerating = false
    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: Self.temperatureDefaultsKey) }
    }
    var maxResponseTokens: Int {
        didSet { UserDefaults.standard.set(maxResponseTokens, forKey: Self.maxTokensDefaultsKey) }
    }
    var lastError: String?
    var modelLoadStage: ModelLoadStage = .idle

    var isTextModelReady: Bool {
        isModelLoaded
    }

    static let defaultTemperature: Double = ResponseStylePreset.balanced.temperature
    static let defaultMaxResponseTokens: Int = ResponseStylePreset.balanced.maxResponseTokens
    private static let temperatureDefaultsKey = "llm_temperature"
    private static let maxTokensDefaultsKey = "llm_maxResponseTokens"
    private static let baseSystemPrompt = """
        You are Yemma, a helpful on-device assistant.
        Be accurate, clear, and direct.
        Use plain language.
        Do not repeat the user's request.
        Do not use filler, praise, or long transitions.
        Ask a follow-up question only when required to answer correctly.
        Match the user's requested level of detail.
        """

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var loadedModelPath: String?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private let logger = Logger(
        subsystem: Yemma4AppConfiguration.bundleIdentifier,
        category: "LLMService"
    )

    init() {
        let defaults = UserDefaults.standard
        let savedTemperature = defaults.object(forKey: Self.temperatureDefaultsKey) as? Double
        let savedMaxResponseTokens = defaults.object(forKey: Self.maxTokensDefaultsKey) as? Int

        if let migratedPreset = Self.migratedLegacyPreset(
            temperature: savedTemperature,
            maxResponseTokens: savedMaxResponseTokens
        ) {
            temperature = migratedPreset.temperature
            maxResponseTokens = migratedPreset.maxResponseTokens
            defaults.set(temperature, forKey: Self.temperatureDefaultsKey)
            defaults.set(maxResponseTokens, forKey: Self.maxTokensDefaultsKey)
        } else {
            temperature = savedTemperature ?? Self.defaultTemperature
            maxResponseTokens = savedMaxResponseTokens ?? Self.defaultMaxResponseTokens
        }
    }

    deinit {
        stopGenerationSynchronously()
    }

    func resetAdvancedSettings() {
        temperature = Self.defaultTemperature
        maxResponseTokens = Self.defaultMaxResponseTokens
    }

    var activeResponseStylePreset: ResponseStylePreset? {
        ResponseStylePreset.matching(
            temperature: temperature,
            maxResponseTokens: maxResponseTokens
        )
    }

    var activeResponseStyleTitle: String {
        activeResponseStylePreset?.title ?? "Custom"
    }

    func applyResponseStylePreset(_ preset: ResponseStylePreset) {
        temperature = preset.temperature
        maxResponseTokens = preset.maxResponseTokens
    }

    func loadModel(from path: String) async throws {
        let resolvedPath = (path as NSString).expandingTildeInPath

        if withLock({ loadedModelPath == resolvedPath && modelContainer != nil && isModelLoaded }) {
            return
        }

        await stopGeneration()
        await MainActor.run {
            isModelLoading = true
            modelLoadStage = .preparingRuntime
            lastError = nil
        }

        AppDiagnostics.shared.record(
            "Preparing MLX model bundle",
            category: "model",
            metadata: ["path": resolvedPath]
        )

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try await Self.loadContainer(at: URL(fileURLWithPath: resolvedPath))
            }.value

            await MainActor.run {
                modelLoadStage = .activatingModel
            }

            withLock {
                modelContainer = loaded
                loadedModelPath = resolvedPath
            }

            await MainActor.run {
                isModelLoaded = true
                isModelLoading = false
                isVisionReady = true
                modelLoadStage = .ready
                lastError = nil
            }

            AppDiagnostics.shared.record(
                "MLX model bundle loaded",
                category: "model",
                metadata: ["path": resolvedPath]
            )
        } catch {
            logger.error("MLX model load failed: \(error.localizedDescription, privacy: .public)")
            await publishLoadFailure(error)
            throw error
        }
    }

    func generate(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        if !Yemma4AppConfiguration.supportsLocalModelRuntime {
            return makeSimulatorStream(prompt: prompt, history: history)
        }

        let container = withLock { modelContainer }
        guard let container else {
            lastError = LLMServiceError.modelNotLoaded.localizedDescription
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let conversation = Self.promptMessagesForGemma4(from: history + [prompt])
        let promptRoute: Gemma4InputRoute = .chat
        let promptMode = conversation.contains { !$0.imageURLs.isEmpty } ? "multimodal" : "text-only"
        let conversationImageCount = conversation.reduce(into: 0) { $0 += $1.imageURLs.count }
        let roleSummary = "[\(conversation.map(\.role).joined(separator: ","))]"
        let latestUserPrompt = conversation.last(where: { Self.chatRole(for: $0.role) == .user })?.content ?? ""
        let responseStyle = activeResponseStylePreset?.rawValue ?? "custom"
        let taskHint = Self.promptTaskHint(for: latestUserPrompt)

        AppDiagnostics.shared.record(
            "Generation requested",
            category: "generation",
            metadata: [
                "messages": conversation.count,
                "images": conversationImageCount,
                "route": promptRoute.rawValue,
                "mode": promptMode,
                "style": responseStyle,
                "taskHint": taskHint?.rawValue ?? "none"
            ]
        )
        AppDiagnostics.shared.record(
            "Prompt route",
            category: "generation",
            metadata: [
                "route": promptRoute.rawValue,
                "promptMessages": conversation.count,
                "imageAttachments": conversationImageCount,
                "style": responseStyle,
                "taskHint": taskHint?.rawValue ?? "none"
            ]
        )
        AppDiagnostics.shared.record(
            "UserInput route",
            category: "generation",
            metadata: [
                "route": promptRoute.rawValue,
                "roles": roleSummary,
                "latestUser": latestUserPrompt,
                "messageCount": conversation.count,
                "images": conversationImageCount,
                "videos": 0,
                "style": responseStyle,
                "taskHint": taskHint?.rawValue ?? "none"
            ]
        )
        logger.debug(
            "UserInput route=\(promptRoute.rawValue, privacy: .public) mode=\(promptMode, privacy: .public) messages=\(conversation.count, privacy: .public)"
        )

        let stream = AsyncStream<String> { continuation in
            let task = Task {
                do {
                    let parameters = self.generationParameters(for: conversation)
                    let rawTokenStream = try await container.perform { context in
                        let lmInput: LMInput
                        do {
                            let userInput = self.makeGemma4UserInput(from: conversation)
                            lmInput = try await context.processor.prepare(input: userInput)
                        } catch {
                            throw LLMServiceError.processorFailed(error)
                        }

                        let tokenShape = lmInput.text.tokens.shape.map(String.init).joined(separator: "x")
                        let imageShape = lmInput.image?.pixels.shape.map(String.init).joined(separator: "x") ?? "none"
                        AppDiagnostics.shared.record(
                            "Prepared input",
                            category: "generation",
                            metadata: [
                                "tokens": tokenShape,
                                "image": imageShape
                            ]
                        )
                        if let imagePixels = lmInput.image?.pixels {
                            AppDiagnostics.shared.record(
                                "Multimodal image tensor",
                                category: "generation",
                                metadata: ["summary": Self.summarizeImageTensor(imagePixels)]
                            )
                        }

                        if promptMode == "multimodal"
                            && Yemma4AutomationConfiguration.current.multimodalFirstTokenTraceEnabled
                        {
                            do {
                                let firstTokenTrace = try Self.computeFirstTokenTrace(
                                    context: context,
                                    input: lmInput,
                                    parameters: parameters,
                                    processorOverride: self.makeLogitProcessor(
                                        parameters: parameters,
                                        tokenizer: context.tokenizer,
                                        hasImages: lmInput.image != nil
                                    )
                                )
                                AppDiagnostics.shared.record(
                                    "Multimodal first-token trace",
                                    category: "generation",
                                    metadata: [
                                        "summary": Self.summarizeFirstTokenTrace(firstTokenTrace)
                                    ]
                                )
                            } catch {
                                AppDiagnostics.shared.record(
                                    "Multimodal first-token trace failed",
                                    category: "generation",
                                    metadata: ["error": error.localizedDescription]
                                )
                            }
                        }

                        let processor = self.makeLogitProcessor(
                            parameters: parameters,
                            tokenizer: context.tokenizer,
                            hasImages: lmInput.image != nil
                        )
                        let sampler = parameters.sampler()
                        let iterator = try TokenIterator(
                            input: lmInput,
                            model: context.model,
                            cache: context.model.newCache(parameters: parameters),
                            processor: processor,
                            sampler: sampler,
                            prefillStepSize: parameters.prefillStepSize,
                            maxTokens: parameters.maxTokens
                        )
                        return generateTokenTask(
                            promptTokenCount: lmInput.text.tokens.size,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator,
                            includeStopToken: true
                        )
                    }

                    let tokenStream = rawTokenStream.0
                    let completionTask = rawTokenStream.1
                    var parser: Gemma4ResponseTokenParser? = nil

                    for await generation in tokenStream {
                        if Task.isCancelled {
                            break
                        }

                        switch generation {
                        case let .token(tokenID):
                            if parser == nil {
                                let tokenizer = await container.tokenizer
                                parser = Gemma4ResponseTokenParser(tokenizer: tokenizer)
                            }
                            if let chunk = parser?.append(tokenID: tokenID), !chunk.isEmpty {
                                continuation.yield(chunk)
                            }

                        case let .info(info):
                            AppDiagnostics.shared.record(
                                "Generation finished",
                                category: "generation",
                                metadata: [
                                    "promptTokens": info.promptTokenCount,
                                    "generationTokens": info.generationTokenCount,
                                    "tokensPerSecond": String(format: "%.1f", info.tokensPerSecond),
                                    "stopReason": String(describing: info.stopReason)
                                ]
                            )
                            if let parser {
                                if Yemma4AutomationConfiguration.current.rawTokenLoggingEnabled {
                                    logger.debug(
                                        "Gemma4 raw stream mode=\(promptMode, privacy: .public) tokens=\(parser.totalTokenCount, privacy: .public) visibleChunks=\(parser.visibleChunkCount, privacy: .public) visibleChars=\(parser.visibleCharacterCount, privacy: .public) preview=[\(parser.tokenPreviewSummary, privacy: .public)]"
                                    )
                                }
                            }
                        }
                    }

                    if Task.isCancelled {
                        completionTask.cancel()
                    }
                    _ = await completionTask.result
                } catch {
                    if !Task.isCancelled {
                        await self.setLastError(error.localizedDescription)
                        AppDiagnostics.shared.record(
                            "Generation failed",
                            category: "generation",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }

                await self.finishGeneration()
                continuation.finish()
            }

            self.withLock {
                generationTask = task
            }

            Task { @MainActor [weak self] in
                self?.isGenerating = true
                self?.lastError = nil
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return stream
    }

    func stopGeneration() async {
        let task = takeGenerationTask()
        task?.cancel()
        _ = await task?.result
        await MainActor.run {
            isGenerating = false
        }
    }

    func stopGenerationSynchronously() {
        let task = takeGenerationTask()
        task?.cancel()
        isGenerating = false
    }

    func clearCachedPrefix() {
        // MLX generation rebuilds from structured chat each turn. There is no local KV prefix cache to reset here.
    }

    @MainActor
    func signalLoadingIntent() {
        guard !isModelLoading else {
            return
        }

        isModelLoading = true
        modelLoadStage = .preparingRuntime
        lastError = nil
    }

    func unloadModel() async {
        await stopGeneration()
        withLock {
            modelContainer = nil
            loadedModelPath = nil
        }
        await MainActor.run {
            isModelLoaded = false
            isModelLoading = false
            isVisionReady = false
            modelLoadStage = .idle
            lastError = nil
        }
        AppDiagnostics.shared.record("MLX model unloaded", category: "model")
    }

    private func finishGeneration() async {
        withLock {
            generationTask = nil
        }
        await MainActor.run {
            isGenerating = false
        }
    }

    private func publishLoadFailure(_ error: Error) async {
        let hasLoadedModel = withLock { modelContainer != nil }

        await MainActor.run {
            lastError = error.localizedDescription
            isModelLoaded = hasLoadedModel
            isVisionReady = hasLoadedModel
            isModelLoading = false
            modelLoadStage = hasLoadedModel ? .ready : .failed
        }
    }

    private func setLastError(_ message: String) async {
        await MainActor.run {
            lastError = message
            isGenerating = false
        }
    }

    private static func migratedLegacyPreset(
        temperature: Double?,
        maxResponseTokens: Int?
    ) -> ResponseStylePreset? {
        guard let temperature, let maxResponseTokens else { return nil }

        return ResponseStylePreset.allCases.first { preset in
            abs(preset.legacyTemperature - temperature) < 0.01
                && preset.legacyMaxResponseTokens == maxResponseTokens
        }
    }
}

private extension LLMService {
    static let hiddenChannelTokenBudget = 48
    static let recommendedMultimodalMaxTokens = 256

    static func loadContainer(at modelDirectory: URL) async throws -> ModelContainer {
        try await prepareMLXRuntimeInBackground()
        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            let validatedDirectory = try ModelDirectoryValidator.validatedDirectory(at: modelDirectory)
            AppDiagnostics.shared.record(
                "Validated MLX model directory before load",
                category: "model",
                metadata: [
                    "path": validatedDirectory.location.path,
                    "processorConfig": validatedDirectory.processorConfigFileName,
                    "weightFiles": validatedDirectory.weightFileNames.count,
                    "indexedWeightFiles": validatedDirectory.indexedWeightFileNames.count
                ]
            )
            if try Gemma4MLXSupport.normalizeAssetContractIfNeeded(validatedDirectory) {
                AppDiagnostics.shared.record(
                    "Normalized Gemma 4 config for compatibility",
                    category: "model",
                    metadata: [
                        "path": validatedDirectory.configURL.path,
                        "injectedKey": "pad_token_id"
                    ]
                )
            }
            try Gemma4MLXSupport.validateAssetContract(validatedDirectory)
        } catch {
            throw LLMServiceError.assetValidationFailed(error)
        }

        let tokenizerLoader = SwiftTokenizersLoader(
            willLoad: {
                AppDiagnostics.shared.record("Loading tokenizer...", category: "model")
            },
            didLoad: {
                AppDiagnostics.shared.record("Loading model weights...", category: "model")
            }
        )

        let context = try await VLMModelFactory.shared._load(
            configuration: .init(directory: modelDirectory),
            tokenizerLoader: tokenizerLoader
        )
        return ModelContainer(context: context)
    }

    func generationParameters(for messages: [Gemma4ConversationMessage]) -> GenerateParameters {
        if messages.contains(where: { !$0.imageURLs.isEmpty }) {
            return GenerateParameters(
                maxTokens: min(maxResponseTokens, Self.recommendedMultimodalMaxTokens),
                temperature: 0
            )
        }

        return GenerateParameters(
            maxTokens: maxResponseTokens,
            temperature: Float(temperature),
            topP: 0.95,
            topK: 64
        )
    }

    func makeLogitProcessor(
        parameters: GenerateParameters,
        tokenizer: any MLXLMCommon.Tokenizer,
        hasImages: Bool
    ) -> LogitProcessor? {
        let baseProcessor = parameters.processor()
        guard hasImages else {
            return baseProcessor
        }

        return Gemma4HiddenChannelBudgetProcessor(
            tokenizer: tokenizer,
            hiddenChannelTokenBudget: Self.hiddenChannelTokenBudget,
            baseProcessor: baseProcessor
        )
    }

    static func promptMessagesForGemma4(from messages: [PromptMessageInput]) -> [Gemma4ConversationMessage] {
        let promptMessages = messages.compactMap { message -> Gemma4ConversationMessage? in
            let imageURLs = message.images.map { URL(fileURLWithPath: $0.filePath) }
            let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty || !imageURLs.isEmpty else {
                return nil
            }

            return Gemma4ConversationMessage(
                role: message.role,
                content: message.text,
                imageURLs: imageURLs
            )
        }

        guard let latestImageIndex = promptMessages.lastIndex(where: { !$0.imageURLs.isEmpty }) else {
            return promptMessages
        }

        let leadingNonImageMessages = Array(promptMessages.prefix(while: { $0.imageURLs.isEmpty }))
        let trailingMessages = Array(promptMessages[latestImageIndex...])
        let normalizedMessages = leadingNonImageMessages + trailingMessages

        guard let normalizedLatestImageIndex = normalizedMessages.lastIndex(where: { !$0.imageURLs.isEmpty }) else {
            return normalizedMessages
        }

        return normalizedMessages.enumerated().map { index, message in
            let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContent: String
            if index == normalizedLatestImageIndex,
                Self.chatRole(for: message.role) == .user,
                trimmedContent.isEmpty
            {
                normalizedContent = Gemma4MLXSupport.defaultImagePrompt
            } else {
                normalizedContent = message.content
            }

            let normalizedImages =
                index == normalizedLatestImageIndex ? Array(message.imageURLs.prefix(1)) : []

            return Gemma4ConversationMessage(
                role: message.role,
                content: normalizedContent,
                imageURLs: normalizedImages
            )
        }
    }

    func makeGemma4UserInput(
        from messages: [Gemma4ConversationMessage]
    ) -> UserInput {
        let promptMessages = promptInstructionMessages(for: messages) + messages

        return UserInput(
            chat: promptMessages.map { message in
                Chat.Message(
                    role: Self.chatRole(for: message.role),
                    content: message.content,
                    images: message.imageURLs.map(UserInput.Image.url)
                )
            },
            additionalContext: Gemma4MLXSupport.templateContext
        )
    }

    func promptInstructionMessages(
        for conversationMessages: [Gemma4ConversationMessage]
    ) -> [Gemma4ConversationMessage] {
        var instructionMessages = [
            Gemma4ConversationMessage(
                role: "system",
                content: Self.baseSystemPrompt,
                imageURLs: []
            )
        ]

        if let stylePrompt = activeResponseStylePreset?.instructionPrompt {
            instructionMessages.append(
                Gemma4ConversationMessage(
                    role: "developer",
                    content: stylePrompt,
                    imageURLs: []
                )
            )
        }

        if let lengthTargetPrompt = activeResponseStylePreset?.lengthTargetPrompt {
            instructionMessages.append(
                Gemma4ConversationMessage(
                    role: "developer",
                    content: lengthTargetPrompt,
                    imageURLs: []
                )
            )
        }

        if let latestUserPrompt = conversationMessages.last(where: { Self.chatRole(for: $0.role) == .user })?.content,
            let taskHint = Self.promptTaskHint(for: latestUserPrompt)
        {
            instructionMessages.append(
                Gemma4ConversationMessage(
                    role: "developer",
                    content: taskHint.instructionPrompt,
                    imageURLs: []
                )
            )
        }

        return instructionMessages
    }

    static func promptTaskHint(for prompt: String) -> PromptTaskHint? {
        let normalizedPrompt = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedPrompt.isEmpty else { return nil }

        if looksLikeRewriteTask(normalizedPrompt) {
            return .rewrite
        }

        if looksLikeSummarizeTask(normalizedPrompt) {
            return .summarize
        }

        if looksLikeCodingTask(normalizedPrompt) {
            return .coding
        }

        if looksLikeRecommendationTask(normalizedPrompt) {
            return .recommendation
        }

        return nil
    }

    static func looksLikeRewriteTask(_ prompt: String) -> Bool {
        let rewriteIndicators = [
            "rewrite",
            "rephrase",
            "revise",
            "edit this",
            "polish this",
            "improve this writing",
            "make this sound",
            "fix grammar",
            "rewrite this",
            "rewrite my",
            "rewrite the",
        ]

        guard containsAny(rewriteIndicators, in: prompt) else { return false }
        return !looksLikeCodingTask(prompt)
    }

    static func looksLikeSummarizeTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "summarize",
                "summary",
                "tl;dr",
                "tldr",
                "condense",
                "brief summary",
                "short summary",
            ],
            in: prompt
        )
    }

    static func looksLikeRecommendationTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "should i",
                "what should i",
                "which should i",
                "which one should i",
                "recommend",
                "recommendation",
                "best option",
                "best way",
                "which is better",
                "worth it",
                "advice",
                "pick one",
            ],
            in: prompt
        )
    }

    static func looksLikeCodingTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "code",
                "bug",
                "debug",
                "stack trace",
                "exception",
                "compiler",
                "compile",
                "xcode",
                "swift",
                "python",
                "javascript",
                "typescript",
                "react",
                "sql",
                "function",
                "class",
                "error",
                "crash",
                "fix this code",
                "why is my code",
            ],
            in: prompt
        )
    }

    static func containsAny(_ candidates: [String], in prompt: String) -> Bool {
        candidates.contains { prompt.contains($0) }
    }

    static func chatRole(for role: String) -> Chat.Message.Role {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "assistant", "model":
            return .assistant
        case "system", "developer":
            return .system
        default:
            return .user
        }
    }

    func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func takeGenerationTask() -> Task<Void, Never>? {
        withLock {
            let task = generationTask
            generationTask = nil
            return task
        }
    }

    func makeSimulatorStream(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        let transcriptCount = history.count + 1
        let response = Self.simulatorResponse(
            for: prompt,
            transcriptCount: transcriptCount
        )

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                for chunk in response.map(String.init) {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(chunk)
                    try? await Task.sleep(for: .milliseconds(14))
                }

                await self?.finishGeneration()
                continuation.finish()
            }

            withLock {
                generationTask = task
            }

            Task { @MainActor [weak self] in
                self?.isGenerating = true
                self?.lastError = nil
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func simulatorResponse(
        for prompt: PromptMessageInput,
        transcriptCount: Int
    ) -> String {
        let promptText = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = promptText.lowercased()

        if normalizedPrompt.hasPrefix("teach me ") {
            return """
            # Teach Me Something

            The **Anglo-Zanzibar War** in 1896 is widely considered the shortest war in recorded history, lasting about **38 to 45 minutes**.

            ## Why it is surprising
            - A full military conflict started and ended in less time than many lunch breaks.
            - Most people imagine wars unfolding over days, months, or years.
            - The outcome was decided almost immediately once naval bombardment began.

            ## Quick facts

            | Topic | Detail |
            | --- | --- |
            | Conflict | Anglo-Zanzibar War |
            | Date | August 27, 1896 |
            | Approx. duration | 38 to 45 minutes |
            | Main reason it ended fast | British naval superiority |

            **Simulator note:** this is a canned Markdown response so you can test headings, bold text, lists, and tables in the chat UI.
            """
        }

        return """
        Simulator mode reply: the local UI loop is working, but MLX inference still requires a physical iPhone.

        Prompt received: \(promptText.isEmpty ? "[image only]" : promptText)

        Conversation turns in memory: \(transcriptCount)

        Attached images in this turn: \(prompt.images.count)
        """
    }

    static func summarizeImageTensor(_ pixels: MLXArray) -> String {
        let values = pixels.asArray(Float.self)
        guard !values.isEmpty else {
            return "shape=\(pixels.shape.map(String.init).joined(separator: "x")) empty"
        }

        let planeSize = max(1, pixels.dim(2) * pixels.dim(3))
        let firstRed = values[0]
        let firstGreen = values.indices.contains(planeSize) ? values[planeSize] : firstRed
        let firstBlue = values.indices.contains(planeSize * 2) ? values[planeSize * 2] : firstGreen
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let shape = pixels.shape.map(String.init).joined(separator: "x")

        return
            "shape=\(shape) dtype=\(String(describing: pixels.dtype)) range=[\(formatLogit(minValue)),\(formatLogit(maxValue))] firstRGB=[\(formatLogit(firstRed)),\(formatLogit(firstGreen)),\(formatLogit(firstBlue))]"
    }

    static func formatLogit(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    static func summarizeFirstTokenTrace(_ trace: FirstTokenTrace) -> String {
        let sampledDescription = describeFirstTokenCandidate(
            tokenID: trace.sampledTokenID,
            rawDecoded: trace.sampledRawDecoded,
            cleanedDecoded: trace.sampledCleanedDecoded
        )
        let candidates = trace.candidates.map { candidate in
            "\(candidate.tokenID):\(formatLogit(candidate.logit)):\(describeFirstTokenCandidate(tokenID: candidate.tokenID, rawDecoded: candidate.rawDecoded, cleanedDecoded: candidate.cleanedDecoded))"
        }.joined(separator: " | ")
        return "sample=\(sampledDescription) topK=[\(candidates)]"
    }

    static func computeFirstTokenTrace(
        context: ModelContext,
        input: LMInput,
        parameters: GenerateParameters,
        processorOverride: LogitProcessor? = nil,
        topK: Int = 5
    ) throws -> FirstTokenTrace {
        var processor = processorOverride ?? parameters.processor()
        processor?.prompt(input.text.tokens)

        let cache = context.model.newCache(parameters: parameters)
        let prepared = try context.model.prepare(
            input,
            cache: cache,
            windowSize: parameters.prefillStepSize
        )

        let logits: MLXArray
        switch prepared {
        case .logits(let output):
            logits = output.logits
        case .tokens(let tokens):
            let output = context.model(
                tokens[text: .newAxis],
                cache: cache.isEmpty ? nil : cache,
                state: nil
            )
            logits = output.logits
        }

        var nextTokenLogits = logits[0..., -1, 0...]
        nextTokenLogits = processor?.process(logits: nextTokenLogits) ?? nextTokenLogits

        let sampler = parameters.sampler()
        let sampledToken = sampler.sample(logits: nextTokenLogits)
        processor?.didSample(token: sampledToken)

        let sampledTokenID = sampledToken.item(Int.self)
        let sampledRawDecoded = context.tokenizer.decode(
            tokenIds: [sampledTokenID],
            skipSpecialTokens: false
        )
        let sampledCleanedDecoded = context.tokenizer.decode(
            tokenIds: [sampledTokenID],
            skipSpecialTokens: true
        )

        let vocabularySize = nextTokenLogits.dim(-1)
        let candidateCount = Swift.max(1, Swift.min(topK, vocabularySize))
        var indices = argPartition(-nextTokenLogits, kth: candidateCount - 1, axis: -1)[
            .ellipsis, ..<candidateCount
        ]
        var values = takeAlong(nextTokenLogits, indices, axis: -1)
        let order = argSort(-values, axis: -1)
        indices = takeAlong(indices, order, axis: -1)
        values = takeAlong(values, order, axis: -1)
        eval(indices, values)

        let tokenIDs = indices.flattened().asArray(Int.self)
        let logitsValues = values.flattened().asArray(Float.self)
        let candidates = zip(tokenIDs, logitsValues).map { tokenID, logit in
            FirstTokenCandidate(
                tokenID: tokenID,
                logit: logit,
                rawDecoded: context.tokenizer.decode(
                    tokenIds: [tokenID],
                    skipSpecialTokens: false
                ),
                cleanedDecoded: context.tokenizer.decode(
                    tokenIds: [tokenID],
                    skipSpecialTokens: true
                )
            )
        }

        return FirstTokenTrace(
            sampledTokenID: sampledTokenID,
            sampledRawDecoded: sampledRawDecoded,
            sampledCleanedDecoded: sampledCleanedDecoded,
            candidates: candidates
        )
    }

    static func describeFirstTokenCandidate(
        tokenID: Int,
        rawDecoded: String,
        cleanedDecoded: String
    ) -> String {
        let raw = sanitizedTokenText(rawDecoded)
        let cleaned = sanitizedTokenText(cleanedDecoded)
        if raw == cleaned {
            return "\(tokenID) '\(raw)'"
        }
        return "\(tokenID) raw='\(raw)' clean='\(cleaned)'"
    }

    static func sanitizedTokenText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func prepareMLXRuntimeInBackground() async throws {
        try await Task.detached(priority: .userInitiated) {
            try prepareMLXRuntimeIfNeeded()
        }.value
    }

    static func prepareMLXRuntimeIfNeeded() throws {
        MLXRuntimeEnvironment.lock.lock()
        defer { MLXRuntimeEnvironment.lock.unlock() }

        if MLXRuntimeEnvironment.didPrepare {
            return
        }

        guard let source = bundledMetalLibraryURL() else {
            throw LLMServiceError.modelLoadFailed(path: "default.metallib")
        }

        let fileManager = FileManager.default
        let runtimeDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "mlx-runtime", directoryHint: .isDirectory)
            ?? fileManager.temporaryDirectory.appending(path: "mlx-runtime", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let runtimeMetalLib = runtimeDirectory.appending(path: "default.metallib")
        if !fileManager.fileExists(atPath: runtimeMetalLib.path) {
            try? fileManager.removeItem(at: runtimeMetalLib)
            try fileManager.copyItem(at: source, to: runtimeMetalLib)
        }

        guard fileManager.changeCurrentDirectoryPath(runtimeDirectory.path) else {
            throw LLMServiceError.modelLoadFailed(path: runtimeDirectory.path)
        }

        MLXRuntimeEnvironment.didPrepare = true
    }

    static func bundledMetalLibraryURL() -> URL? {
        let directCandidates: [URL?] = [
            Bundle.main.url(
                forResource: "default",
                withExtension: "metallib",
                subdirectory: "mlx-swift_Cmlx.bundle"
            ),
            Bundle.main.resourceURL?.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"),
        ]

        for candidate in directCandidates {
            if let candidate, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let bundles = Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles where bundle.bundleURL.lastPathComponent == "mlx-swift_Cmlx.bundle" {
            if let candidate = bundle.url(forResource: "default", withExtension: "metallib"),
                FileManager.default.fileExists(atPath: candidate.path)
            {
                return candidate
            }
        }

        return nil
    }
}

private struct SwiftTokenizersLoader: TokenizerLoader {
    var willLoad: @Sendable () -> Void = {}
    var didLoad: @Sendable () -> Void = {}

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        willLoad()
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        didLoad()
        return TokenizersAdapter(upstream: tokenizer)
    }
}

private struct TokenizersAdapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
