import Foundation
import Observation
import LlamaSwift
import CryptoKit
import os

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
            return "Waiting to prepare the model."
        case .preparingRuntime:
            return "Preparing the local runtime."
        case .loadingModel:
            return "Loading the model into memory."
        case .activatingModel:
            return "Finalizing the local chat engine."
        case .ready:
            return "Model ready."
        case .failed:
            return "Model preparation failed."
        }
    }
}

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case multimodalRuntimeUnavailable
    case modelLoadFailed(path: String)
    case contextCreationFailed(path: String)
    case samplerCreationFailed
    case tokenizationFailed
    case promptTooLong(tokenCount: Int, limit: Int)
    case decodeFailed(status: Int32)
    case tokenConversionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded."
        case .multimodalRuntimeUnavailable:
            return "The multimodal runtime is not available for image input."
        case let .modelLoadFailed(path):
            return "Failed to load the GGUF model at \(path)."
        case let .contextCreationFailed(path):
            return "Failed to create a llama context for \(path)."
        case .samplerCreationFailed:
            return "Failed to create the sampler chain."
        case .tokenizationFailed:
            return "Failed to tokenize the prompt."
        case let .promptTooLong(tokenCount, limit):
            return "This conversation is too long for the model context (\(tokenCount) tokens, limit \(limit)). Start a new chat or shorten your message."
        case let .decodeFailed(status):
            return "llama_decode returned error status \(status)."
        case .tokenConversionFailed:
            return "Failed to convert a token to text."
        }
    }
}

@Observable
final class LLMService: @unchecked Sendable {
    var isModelLoaded = false
    var isModelLoading = false
    var isGenerating = false
    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "llm_temperature") }
    }
    var contextSize: UInt32 {
        didSet { UserDefaults.standard.set(Int(contextSize), forKey: "llm_contextSize") }
    }
    var flashAttention: Bool {
        didSet { UserDefaults.standard.set(flashAttention, forKey: "llm_flashAttention") }
    }
    var maxResponseTokens: Int {
        didSet { UserDefaults.standard.set(maxResponseTokens, forKey: "llm_maxResponseTokens") }
    }
    var lastError: String?
    var modelLoadStage: ModelLoadStage = .idle

    static let defaultTemperature: Double = 0.7
    static let defaultContextSize: UInt32 = 8192
    static let defaultFlashAttention: Bool = true
    static let defaultMaxResponseTokens: Int = 1024

    @ObservationIgnored private var model: OpaquePointer?
    @ObservationIgnored private var context: OpaquePointer?
    @ObservationIgnored private var vocab: OpaquePointer?
    @ObservationIgnored private var multimodalRuntime: YemmaMultimodalRuntime?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGroup: DispatchGroup?
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private var samplerConfig = SamplerConfig.defaults
    /// Tokens from the last successful generation (prompt + response) used for KV cache reuse.
    @ObservationIgnored private var cachedPromptTokens: [llama_token] = []

    @ObservationIgnored private static let backendInitialized: Void = {
        llama_backend_init()
    }()

    init() {
        let defaults = UserDefaults.standard
        temperature = defaults.object(forKey: "llm_temperature") as? Double ?? Self.defaultTemperature
        contextSize = UInt32(defaults.object(forKey: "llm_contextSize") as? Int ?? Int(Self.defaultContextSize))
        flashAttention = defaults.object(forKey: "llm_flashAttention") as? Bool ?? Self.defaultFlashAttention
        maxResponseTokens = defaults.object(forKey: "llm_maxResponseTokens") as? Int ?? Self.defaultMaxResponseTokens
    }

    func resetAdvancedSettings() {
        temperature = Self.defaultTemperature
        contextSize = Self.defaultContextSize
        flashAttention = Self.defaultFlashAttention
        maxResponseTokens = Self.defaultMaxResponseTokens
    }

    deinit {
        stopGenerationSynchronously()
        freeLoadedModel()
    }

    func loadModel(from path: String, mmprojPath: String) async throws {
        let resolvedPath = (path as NSString).expandingTildeInPath
        let resolvedMMProjPath = (mmprojPath as NSString).expandingTildeInPath
        let loadStart = Date()
        await stopGeneration()
        await MainActor.run {
            isModelLoading = true
            modelLoadStage = .preparingRuntime
            lastError = nil
        }
        AppDiagnostics.shared.record(
            "Loading model",
            category: "model",
            metadata: [
                "path": resolvedPath,
                "mmprojPath": resolvedMMProjPath
            ]
        )

        do {
            let preparedResources = try await Task.detached(priority: .utility) { [weak self] in
                let backendStart = Date()
                Self.ensureBackendInitialized()
                let backendInitMs = Int(Date().timeIntervalSince(backendStart) * 1000)
                AppDiagnostics.shared.record(
                    "Model runtime prepared",
                    category: "model",
                    metadata: [
                        "path": resolvedPath,
                        "mmprojPath": resolvedMMProjPath,
                        "backendInitMs": backendInitMs
                    ]
                )

                await self?.setModelLoadStage(.loadingModel)

                // Log model file info
                if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
                   let fileSize = fileAttrs[.size] as? Int64 {
                    let fileSizeMB = Int(fileSize / (1024 * 1024))
                    var sha256 = "unavailable"
                    if let fileHandle = FileHandle(forReadingAtPath: resolvedPath) {
                        var hasher = SHA256()
                        while autoreleasepool(invoking: {
                            let chunk = fileHandle.readData(ofLength: 8 * 1024 * 1024)
                            guard !chunk.isEmpty else { return false }
                            hasher.update(data: chunk)
                            return true
                        }) {}
                        fileHandle.closeFile()
                        sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    }
                    AppDiagnostics.shared.record(
                        "Model file info",
                        category: "model",
                        metadata: ["fileSizeMB": fileSizeMB, "sha256": sha256]
                    )
                }

                let memoryBeforeMB = Self.availableMemoryMB()
                AppDiagnostics.shared.record(
                    "Memory before model load",
                    category: "model",
                    metadata: ["availableMemoryMB": memoryBeforeMB]
                )

                let resourceLoadStart = Date()
                let ctxSize = await MainActor.run { self?.contextSize ?? Self.defaultContextSize }
                let flashAttn = await MainActor.run { self?.flashAttention ?? Self.defaultFlashAttention }
                let loadedResources = try Self.loadResources(
                    modelPath: resolvedPath,
                    mmprojPath: resolvedMMProjPath,
                    contextSize: ctxSize,
                    flashAttention: flashAttn
                )
                let resourceLoadMs = Int(Date().timeIntervalSince(resourceLoadStart) * 1000)

                let memoryAfterMB = Self.availableMemoryMB()
                AppDiagnostics.shared.record(
                    "Memory after model load",
                    category: "model",
                    metadata: ["availableMemoryMB": memoryAfterMB]
                )

                AppDiagnostics.shared.record(
                    "Model weights loaded",
                    category: "model",
                    metadata: [
                        "path": resolvedPath,
                        "mmprojPath": resolvedMMProjPath,
                        "resourceLoadMs": resourceLoadMs
                    ]
                )

                return PreparedResources(
                    loadedResources: loadedResources,
                    backendInitMs: backendInitMs,
                    resourceLoadMs: resourceLoadMs
                )
            }.value

            await setModelLoadStage(.activatingModel)

            let oldResources: (model: OpaquePointer?, context: OpaquePointer?, multimodalRuntime: YemmaMultimodalRuntime?) = withLock {
                let old = (model: model, context: context, multimodalRuntime: multimodalRuntime)
                model = preparedResources.loadedResources.model
                context = preparedResources.loadedResources.context
                vocab = preparedResources.loadedResources.vocab
                multimodalRuntime = preparedResources.loadedResources.multimodalRuntime
                samplerConfig = preparedResources.loadedResources.samplerConfig
                cachedPromptTokens = []
                return old
            }

            Self.freeResources(
                model: oldResources.model,
                context: oldResources.context,
                multimodalRuntime: oldResources.multimodalRuntime
            )

            await MainActor.run {
                temperature = preparedResources.loadedResources.samplerConfig.temperature
                isModelLoaded = true
                isModelLoading = false
                modelLoadStage = .ready
                lastError = nil
            }

            let loadDurationMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            AppDiagnostics.shared.record(
                "Model loaded",
                category: "model",
                metadata: [
                    "path": resolvedPath,
                    "mmprojPath": resolvedMMProjPath,
                    "context": llama_n_ctx(preparedResources.loadedResources.context),
                    "batch": llama_n_batch(preparedResources.loadedResources.context),
                    "temperature": preparedResources.loadedResources.samplerConfig.temperature,
                    "topK": preparedResources.loadedResources.samplerConfig.topK,
                    "topP": preparedResources.loadedResources.samplerConfig.topP,
                    "loadMs": loadDurationMs,
                    "backendInitMs": preparedResources.backendInitMs,
                    "resourceLoadMs": preparedResources.resourceLoadMs,
                    "threads": preparedResources.loadedResources.threadCounts.decode,
                    "batchThreads": preparedResources.loadedResources.threadCounts.batch
                ]
            )
        } catch {
            await publishLoadFailure(error)
            throw error
        }
    }

    func generate(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        Self.ensureBackendInitialized()

#if targetEnvironment(simulator)
        return makeSimulatorStream(prompt: prompt, history: history)
#else
        let currentResources = withLock {
            (model: model, context: context, vocab: vocab, multimodalRuntime: multimodalRuntime)
        }

        guard
            isModelLoaded,
            let currentModel = currentResources.model,
            let currentContext = currentResources.context,
            let currentVocab = currentResources.vocab
        else {
            let error = LLMServiceError.modelNotLoaded
            Task { [weak self] in
                await self?.setLastError(error.localizedDescription)
            }
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let formattedPrompt = Self.formatPrompt(
            prompt: prompt,
            history: history,
            model: currentModel
        )
        let generationConfig = withLock { samplerConfig.withTemperatureOverride(temperature) }
        AppDiagnostics.shared.record(
            "Generation requested",
            category: "generation",
            metadata: [
                "historyCount": history.count,
                "promptChars": prompt.text.count,
                "promptImages": prompt.images.count,
                "historyImages": history.reduce(into: 0) { count, message in
                    count += message.images.count
                },
                "temperature": generationConfig.temperature,
                "topK": generationConfig.topK,
                "topP": generationConfig.topP
            ]
        )

        let completionGroup = CompletionGroupBox()
        completionGroup.enter()

        let previousCached = withLock { cachedPromptTokens }

        let stream = AsyncStream<String> { continuation in
            let continuationBox = StreamContinuationBox(continuation)
            let job = GenerationJob(
                service: self,
                formattedPrompt: formattedPrompt,
                context: currentContext,
                vocab: currentVocab,
                multimodalRuntime: currentResources.multimodalRuntime,
                samplerConfig: generationConfig,
                maxGeneratedTokens: self.maxResponseTokens,
                continuation: continuationBox,
                completionGroup: completionGroup,
                previousCachedTokens: previousCached
            )
            let task = Task {
                await Self.runGeneration(job)
            }

            self.withLock {
                generationTask = task
                generationGroup = completionGroup.group
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
#endif
    }

    func stopGeneration() async {
        let taskAndGroup = takeGenerationHandles()
        taskAndGroup.task?.cancel()
        if let group = taskAndGroup.group {
            await Self.waitForGroup(group)
        }
        await MainActor.run {
            isGenerating = false
        }
    }

    func stopGenerationSynchronously() {
        let taskAndGroup = takeGenerationHandles()
        taskAndGroup.task?.cancel()
        taskAndGroup.group?.wait()
        isGenerating = false
    }

    /// Invalidates the KV cache prefix so the next generation does a full rebuild.
    func clearCachedPrefix() {
        withLock { cachedPromptTokens = [] }
    }

    func makeSimulatorStream(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        let transcriptCount = history.count + 1
        let response = """
        Simulator mode reply: the local UI loop is working, and the model file is present.

        Prompt received: \(prompt.text.isEmpty ? "[image only]" : prompt.text)

        Conversation turns in memory: \(transcriptCount)

        Attached images in this turn: \(prompt.images.count)

        Real Gemma inference still needs a physical iPhone. Use the simulator for UI, download state, settings, and chat-shell iteration.
        """

        return AsyncStream { continuation in
            let chunks = response.map(String.init)
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                for chunk in chunks {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(chunk)

                    do {
                        try await Task.sleep(for: .milliseconds(14))
                    } catch {
                        break
                    }
                }

                await self.finishGeneration()
                continuation.finish()
            }

            self.withLock {
                generationTask = task
                generationGroup = nil
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
}

private extension LLMService {
    static let mediaPromptMarker = "<__media__>"

    struct ModelLoadThreadCounts: Sendable {
        let decode: Int32
        let batch: Int32
    }

    struct FormattedPrompt: Sendable {
        let text: String
        let images: [PromptImageAsset]
    }

    struct LoadedResources: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let multimodalRuntime: YemmaMultimodalRuntime
        let samplerConfig: SamplerConfig
        let threadCounts: ModelLoadThreadCounts
    }

    struct PreparedResources: @unchecked Sendable {
        let loadedResources: LoadedResources
        let backendInitMs: Int
        let resourceLoadMs: Int
    }

    static func ensureBackendInitialized() {
        _ = backendInitialized
    }

    static func thermalStateLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory() / (1024 * 1024))
    }

    static func recommendedThreadCounts() -> ModelLoadThreadCounts {
        let activeCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let decodeThreads = max(1, activeCores - 2)
        let batchThreads = max(1, min(4, decodeThreads))
        return ModelLoadThreadCounts(
            decode: Int32(decodeThreads),
            batch: Int32(batchThreads)
        )
    }

    static func loadResources(
        modelPath: String,
        mmprojPath: String,
        contextSize: UInt32 = defaultContextSize,
        flashAttention: Bool = defaultFlashAttention
    ) throws -> LoadedResources {
        var modelParams = llama_model_default_params()
#if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
#else
        modelParams.n_gpu_layers = 99
#endif

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextSize
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.flash_attn_type = flashAttention ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED

        let threadCounts = recommendedThreadCounts()
        contextParams.n_threads = threadCounts.decode
        contextParams.n_threads_batch = threadCounts.batch

        guard let newModel = modelPath.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            throw LLMServiceError.modelLoadFailed(path: modelPath)
        }

        guard let newContext = llama_init_from_model(newModel, contextParams) else {
            llama_model_free(newModel)
            throw LLMServiceError.contextCreationFailed(path: modelPath)
        }

        guard let newVocab = llama_model_get_vocab(newModel) else {
            llama_free(newContext)
            llama_model_free(newModel)
            throw LLMServiceError.contextCreationFailed(path: modelPath)
        }

        let runtime: YemmaMultimodalRuntime
        do {
            runtime = try YemmaMultimodalRuntime(
                mmProjPath: mmprojPath,
                model: UnsafeMutableRawPointer(newModel)
            )
        } catch {
            llama_free(newContext)
            llama_model_free(newModel)
            throw error
        }

        return LoadedResources(
            model: newModel,
            context: newContext,
            vocab: newVocab,
            multimodalRuntime: runtime,
            samplerConfig: samplerConfig(for: newModel),
            threadCounts: threadCounts
        )
    }

    final class CompletionGroupBox: @unchecked Sendable {
        let group = DispatchGroup()

        func enter() {
            group.enter()
        }

        func leave() {
            group.leave()
        }
    }

    final class GenerationJob: @unchecked Sendable {
        weak var service: LLMService?
        let formattedPrompt: FormattedPrompt
        let context: OpaquePointer
        let vocab: OpaquePointer
        let multimodalRuntime: YemmaMultimodalRuntime?
        let samplerConfig: SamplerConfig
        let maxGeneratedTokens: Int
        let continuation: StreamContinuationBox<String>
        let completionGroup: CompletionGroupBox
        let previousCachedTokens: [llama_token]

        init(
            service: LLMService,
            formattedPrompt: FormattedPrompt,
            context: OpaquePointer,
            vocab: OpaquePointer,
            multimodalRuntime: YemmaMultimodalRuntime?,
            samplerConfig: SamplerConfig,
            maxGeneratedTokens: Int,
            continuation: StreamContinuationBox<String>,
            completionGroup: CompletionGroupBox,
            previousCachedTokens: [llama_token] = []
        ) {
            self.service = service
            self.formattedPrompt = formattedPrompt
            self.context = context
            self.vocab = vocab
            self.multimodalRuntime = multimodalRuntime
            self.samplerConfig = samplerConfig
            self.maxGeneratedTokens = maxGeneratedTokens
            self.continuation = continuation
            self.completionGroup = completionGroup
            self.previousCachedTokens = previousCachedTokens
        }
    }

    struct SamplerConfig: Sendable {
        var topK: Int32
        var topP: Float
        var minP: Float
        var temperature: Double

        static let defaults = SamplerConfig(
            topK: 64,
            topP: 0.95,
            minP: 0.0,
            temperature: 0.7
        )

        func withTemperatureOverride(_ value: Double) -> SamplerConfig {
            var copy = self
            copy.temperature = value
            return copy
        }
    }

    final class StreamContinuationBox<Element: Sendable>: @unchecked Sendable {
        private let continuation: AsyncStream<Element>.Continuation

        init(_ continuation: AsyncStream<Element>.Continuation) {
            self.continuation = continuation
        }

        func yield(_ value: Element) {
            continuation.yield(value)
        }

        func finish() {
            continuation.finish()
        }
    }

    static func runGeneration(_ job: GenerationJob) async {
        defer {
            job.completionGroup.leave()
        }

        guard let service = job.service else {
            job.continuation.finish()
            return
        }

        do {
            AppDiagnostics.shared.record(
                "Thermal state at generation start",
                category: "generation",
                metadata: ["thermalState": thermalStateLabel()]
            )

            let generationStartTime = Date()

            let sampler = try Self.makeSampler(config: job.samplerConfig)
            defer { llama_sampler_free(sampler) }

            let contextLimit = max(1, Int(llama_n_ctx(job.context)))
            let promptPositionLimit = max(1, contextLimit - job.maxGeneratedTokens)
            let promptTokenCount: Int
            let promptPositionCount: Int
            var nextPosition: Int32
            var allPromptTokens: [llama_token] = []

            if job.formattedPrompt.images.isEmpty {
                let promptTokens = try Self.tokenize(job.formattedPrompt.text, vocab: job.vocab)
                promptTokenCount = promptTokens.count
                promptPositionCount = promptTokens.count

                guard promptPositionCount <= promptPositionLimit else {
                    throw LLMServiceError.promptTooLong(tokenCount: promptPositionCount, limit: promptPositionLimit)
                }

                // KV cache reuse: find how many tokens match the cached prefix
                let cached = job.previousCachedTokens
                var commonPrefixLen = 0
                if !cached.isEmpty {
                    let limit = min(cached.count, promptTokens.count)
                    while commonPrefixLen < limit && cached[commonPrefixLen] == promptTokens[commonPrefixLen] {
                        commonPrefixLen += 1
                    }
                }

                if commonPrefixLen > 0 {
                    // Trim KV cache entries after the common prefix
                    let memory = llama_get_memory(job.context)
                    let removed = llama_memory_seq_rm(memory, 0, Int32(commonPrefixLen), -1)

                    if removed {
                        let newTokens = Array(promptTokens[commonPrefixLen...])
                        if !newTokens.isEmpty {
                            try Self.decodeFromPosition(tokens: newTokens, startPosition: Int32(commonPrefixLen), context: job.context)
                        }

                        AppDiagnostics.shared.record(
                            "KV cache reused",
                            category: "generation",
                            metadata: [
                                "cachedTokens": cached.count,
                                "commonPrefix": commonPrefixLen,
                                "newTokensDecoded": promptTokens.count - commonPrefixLen
                            ]
                        )
                    } else {
                        // Partial removal failed, fall back to full rebuild
                        Self.resetContextMemory(job.context)
                        try Self.decode(tokens: promptTokens, context: job.context)
                    }
                } else {
                    // Full rebuild: no usable cached prefix
                    Self.resetContextMemory(job.context)
                    try Self.decode(tokens: promptTokens, context: job.context)
                }

                allPromptTokens = promptTokens
                nextPosition = Int32(promptTokens.count)
            } else {
                // Multimodal path: always do full rebuild (image embeddings can't be prefix-matched)
                Self.resetContextMemory(job.context)
                service.withLock { service.cachedPromptTokens = [] }
                guard let multimodalRuntime = job.multimodalRuntime else {
                    throw LLMServiceError.multimodalRuntimeUnavailable
                }

                var tokenCount = Int32(0)
                var positionCount = Int32(0)
                var evaluatedPosition = Int32(0)
                let promptImages = job.formattedPrompt.images.map {
                    YemmaPromptImageInput(identifier: $0.id, filePath: $0.filePath)
                }

                try multimodalRuntime.evaluatePrompt(
                    job.formattedPrompt.text,
                    images: promptImages,
                    context: UnsafeMutableRawPointer(job.context),
                    promptPositionLimit: Int32(promptPositionLimit),
                    promptTokenCount: &tokenCount,
                    promptPositionCount: &positionCount,
                    nPast: 0,
                    nBatch: Int32(llama_n_batch(job.context)),
                    newNPast: &evaluatedPosition
                )

                promptTokenCount = Int(tokenCount)
                promptPositionCount = Int(positionCount)
                nextPosition = evaluatedPosition
            }

            AppDiagnostics.shared.record(
                "Prompt tokenized",
                category: "generation",
                metadata: [
                    "promptTokens": promptTokenCount,
                    "promptPositions": promptPositionCount,
                    "contextLimit": contextLimit,
                    "promptPositionLimit": promptPositionLimit,
                    "promptImages": job.formattedPrompt.images.count
                ]
            )
            var emittedTokenCount = 0
            var generatedTokens: [llama_token] = []

            while !Task.isCancelled {
                guard emittedTokenCount < job.maxGeneratedTokens else {
                    break
                }
                guard nextPosition < Int32(contextLimit) else {
                    break
                }

                let nextToken = llama_sampler_sample(sampler, job.context, -1)

                if llama_vocab_is_eog(job.vocab, nextToken) {
                    break
                }

                llama_sampler_accept(sampler, nextToken)
                generatedTokens.append(nextToken)

                let piece = try Self.tokenText(for: nextToken, vocab: job.vocab)
                if !piece.isEmpty {
                    job.continuation.yield(piece)
                }

                try Self.decodeSingleToken(
                    token: nextToken,
                    position: nextPosition,
                    context: job.context
                )
                nextPosition += 1
                emittedTokenCount += 1
                if nextPosition >= Int32(contextLimit) {
                    break
                }
            }

            // Update the cached prefix for next generation's KV cache reuse.
            // Only cache for text-only prompts; multimodal prompts clear the cache above.
            if !allPromptTokens.isEmpty && !Task.isCancelled {
                let fullSequence = allPromptTokens + generatedTokens
                service.withLock { service.cachedPromptTokens = fullSequence }
            } else if Task.isCancelled {
                // KV cache may be in a partial state after cancellation
                service.withLock { service.cachedPromptTokens = [] }
            }

            let generationDuration = Date().timeIntervalSince(generationStartTime)
            let tokensPerSec = generationDuration > 0
                ? Double(emittedTokenCount) / generationDuration
                : 0
            let contextFillPercent = contextLimit > 0
                ? Double(nextPosition) / Double(contextLimit) * 100
                : 0

            AppDiagnostics.shared.record(
                "Generation finished",
                category: "generation",
                metadata: [
                    "emittedTokens": emittedTokenCount,
                    "finalPosition": nextPosition,
                    "contextLimit": contextLimit,
                    "tokensPerSec": String(format: "%.1f", tokensPerSec),
                    "contextFillPercent": String(format: "%.1f", contextFillPercent),
                    "thermalState": thermalStateLabel()
                ]
            )
        } catch {
            // Invalidate cache on error -- KV cache state may be inconsistent
            service.withLock { service.cachedPromptTokens = [] }
            if !Task.isCancelled {
                AppDiagnostics.shared.record(
                    "Generation failed",
                    category: "generation",
                    metadata: ["error": error.localizedDescription]
                )
                await service.setLastError(error.localizedDescription)
            }
        }

        await service.finishGeneration()
        job.continuation.finish()
    }

    func finishGeneration() async {
        withLock {
            generationTask = nil
            generationGroup = nil
        }

        await MainActor.run {
            isGenerating = false
        }
    }

    func setLastError(_ message: String) async {
        await MainActor.run {
            lastError = message
            isGenerating = false
        }
        AppDiagnostics.shared.record("Service error recorded", category: "generation", metadata: ["error": message])
    }

    func setModelLoadStage(_ stage: ModelLoadStage) async {
        await MainActor.run {
            modelLoadStage = stage
        }
    }

    func publishLoadFailure(_ error: Error) async {
        let stillHasLoadedModel = withLock {
            model != nil && context != nil && vocab != nil && multimodalRuntime != nil
        }

        await MainActor.run {
            isModelLoading = false
            isModelLoaded = stillHasLoadedModel
            modelLoadStage = stillHasLoadedModel ? .ready : .failed
            lastError = error.localizedDescription
        }
    }

    func freeLoadedModel() {
        let resources = withLock {
            let current = (model: model, context: context, multimodalRuntime: multimodalRuntime)
            model = nil
            context = nil
            vocab = nil
            multimodalRuntime = nil
            isModelLoaded = false
            cachedPromptTokens = []
            return current
        }

        Self.freeResources(
            model: resources.model,
            context: resources.context,
            multimodalRuntime: resources.multimodalRuntime
        )
    }

    static func freeResources(
        model: OpaquePointer?,
        context: OpaquePointer?,
        multimodalRuntime: YemmaMultimodalRuntime?
    ) {
        _ = multimodalRuntime

        if let context {
            llama_free(context)
        }

        if let model {
            llama_model_free(model)
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    func takeGenerationHandles() -> (task: Task<Void, Never>?, group: DispatchGroup?) {
        withLock {
            let pair = (task: generationTask, group: generationGroup)
            generationTask = nil
            generationGroup = nil
            return pair
        }
    }

    static func waitForGroup(_ group: DispatchGroup) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                continuation.resume()
            }
        }
    }

    static func formatPrompt(
        prompt: PromptMessageInput,
        history: [PromptMessageInput],
        model: OpaquePointer
    ) -> FormattedPrompt {
        let conversation = history + [prompt]
        let serializedConversation = conversation.map {
            (
                role: $0.role,
                content: serializedContent(for: $0)
            )
        }
        let images = conversation.flatMap(\.images)

        if let templatedPrompt = tryApplyChatTemplate(conversation: serializedConversation, model: model) {
            return FormattedPrompt(text: templatedPrompt, images: images)
        }

        if let gemmaPrompt = tryApplyGemma4Template(conversation: conversation, model: model) {
            return gemmaPrompt
        }

        var pieces = ["<bos>"]
        pieces.reserveCapacity((serializedConversation.count * 2) + 2)

        for message in serializedConversation {
            let role = serializedRole(message.role)
            pieces.append("<|turn>\(role)\n\(message.content)<turn|>\n")
        }

        pieces.append("<|turn>model\n")
        return FormattedPrompt(text: pieces.joined(), images: images)
    }

    static func serializedContent(for message: PromptMessageInput) -> String {
        let baseText = templateRole(message.role) == "assistant"
            ? stripThinkingBlocks(from: message.text)
            : message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerSection = Array(
            repeating: mediaPromptMarker,
            count: message.images.count
        )
        .joined(separator: "\n")

        switch (markerSection.isEmpty, baseText.isEmpty) {
        case (true, _):
            return baseText
        case (false, true):
            return markerSection
        case (false, false):
            return markerSection + "\n" + baseText
        }
    }

    static func tryApplyChatTemplate(
        conversation: [(role: String, content: String)],
        model: OpaquePointer
    ) -> String? {
        guard let templatePointer = llama_model_chat_template(model, nil) else {
            AppDiagnostics.shared.record(
                "Model chat template unavailable",
                category: "generation"
            )
            return nil
        }

        var rolePointers: [UnsafeMutablePointer<CChar>?] = []
        var contentPointers: [UnsafeMutablePointer<CChar>?] = []
        var messages: [llama_chat_message] = []
        rolePointers.reserveCapacity(conversation.count)
        contentPointers.reserveCapacity(conversation.count)
        messages.reserveCapacity(conversation.count)

        for message in conversation {
            let role = strdup(templateRole(message.role))
            let content = strdup(message.content)

            rolePointers.append(role)
            contentPointers.append(content)
            messages.append(
                llama_chat_message(
                    role: UnsafePointer(role),
                    content: UnsafePointer(content)
                )
            )
        }

        defer {
            rolePointers.forEach { free($0) }
            contentPointers.forEach { free($0) }
        }

        var capacity = max(
            512,
            (conversation.reduce(into: 0) { partialResult, message in
                partialResult += message.role.utf8.count + message.content.utf8.count
            } * 2) + 128
        )

        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = llama_chat_apply_template(
                templatePointer,
                messages,
                messages.count,
                true,
                &buffer,
                Int32(buffer.count)
            )

            if length < 0 {
                AppDiagnostics.shared.record(
                    "Chat template application failed",
                    category: "generation",
                    metadata: ["messageCount": conversation.count]
                )
                return nil
            }

            if Int(length) < buffer.count {
                let prompt = String(cString: buffer)
                AppDiagnostics.shared.record(
                    "Applied model chat template",
                    category: "generation",
                    metadata: [
                        "messageCount": conversation.count,
                        "formattedChars": prompt.count
                    ]
                )
                return prompt
            }

            capacity = Int(length) + 1
        }
    }

    static func isGemma4Template(_ template: String) -> Bool {
        template.contains("<start_of_turn>") && template.contains("<end_of_turn>")
    }

    static func tryApplyGemma4Template(
        conversation: [PromptMessageInput],
        model: OpaquePointer
    ) -> FormattedPrompt? {
        guard let templatePointer = llama_model_chat_template(model, nil) else {
            return nil
        }

        let template = String(cString: templatePointer)
        guard isGemma4Template(template) else {
            return nil
        }

        var pieces: [String] = []
        pieces.reserveCapacity((conversation.count * 2) + 2)

        for message in conversation {
            let role = gemmaRole(message.role)
            let content = serializedContent(for: message)
            pieces.append("<start_of_turn>\(role)\n\(content)<end_of_turn>\n")
        }

        pieces.append("<start_of_turn>model\n")
        let prompt = pieces.joined()
        let images = conversation.flatMap(\.images)

        AppDiagnostics.shared.record(
            "Applied Gemma 4 chat template manually",
            category: "generation",
            metadata: [
                "messageCount": conversation.count,
                "formattedChars": prompt.count
            ]
        )

        return FormattedPrompt(text: prompt, images: images)
    }

    static func gemmaRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "model"
        case "system", "developer":
            return "user"
        default:
            return "user"
        }
    }

    static func resetContextMemory(_ context: OpaquePointer) {
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
    }

    static func templateRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "model"
        case "system", "developer":
            return "system"
        default:
            return "user"
        }
    }

    static func serializedRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "model"
        case "system", "developer":
            return "system"
        default:
            return "user"
        }
    }

    static func stripThinkingBlocks(from text: String) -> String {
        guard text.contains("<|channel>") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var cleaned = text

        while let startRange = cleaned.range(of: "<|channel>") {
            if let endRange = cleaned.range(of: "<channel|>", range: startRange.upperBound..<cleaned.endIndex) {
                cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                cleaned.removeSubrange(startRange.lowerBound..<cleaned.endIndex)
                break
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeSampler(config: SamplerConfig) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()

        guard let sampler = llama_sampler_chain_init(params) else {
            throw LLMServiceError.samplerCreationFailed
        }

        guard let topK = llama_sampler_init_top_k(config.topK) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, topK)

        guard let topP = llama_sampler_init_top_p(config.topP, 1) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, topP)

        guard let minP = llama_sampler_init_min_p(config.minP, 1) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, minP)

        guard let temp = llama_sampler_init_temp(Float(config.temperature)) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, temp)

        guard let dist = llama_sampler_init_dist(UInt32.random(in: UInt32.min...UInt32.max)) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, dist)

        return sampler
    }

    static func samplerConfig(for model: OpaquePointer) -> SamplerConfig {
        var config = SamplerConfig.defaults

        if let topK = modelMetadataValue(forKey: "general.sampling.top_k", model: model).flatMap(Int32.init) {
            config.topK = max(1, topK)
        }

        if let topP = modelMetadataValue(forKey: "general.sampling.top_p", model: model).flatMap(Float.init) {
            config.topP = min(max(topP, 0), 1)
        }

        if let temperature = modelMetadataValue(forKey: "general.sampling.temp", model: model).flatMap(Double.init) {
            config.temperature = max(0, temperature)
        }

        AppDiagnostics.shared.record(
            "Loaded sampler defaults from model metadata",
            category: "model",
            metadata: [
                "topK": config.topK,
                "topP": config.topP,
                "temperature": config.temperature
            ]
        )

        return config
    }

    static func modelMetadataValue(forKey key: String, model: OpaquePointer) -> String? {
        var capacity = 128

        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = key.withCString { keyCString in
                llama_model_meta_val_str(model, keyCString, &buffer, buffer.count)
            }

            if length < 0 {
                return nil
            }

            if length < capacity {
                return String(cString: buffer)
            }

            capacity = Int(length) + 1
        }
    }

    static func tokenize(
        _ text: String,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        var capacity = max(256, text.utf8.count + 32)

        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let tokenCount = text.withCString { cString in
                llama_tokenize(
                    vocab,
                    cString,
                    Int32(text.utf8.count),
                    &tokens,
                    Int32(tokens.count),
                    true,
                    true
                )
            }

            if tokenCount >= 0 {
                return Array(tokens.prefix(Int(tokenCount)))
            }

            capacity = max(capacity * 2, Int(-tokenCount) + 8)
            if capacity > 1_000_000 {
                throw LLMServiceError.tokenizationFailed
            }
        }
    }

    static func decode(tokens: [llama_token], context: OpaquePointer) throws {
        try decodeFromPosition(tokens: tokens, startPosition: 0, context: context)
    }

    /// Decodes tokens into the context starting at the given KV cache position.
    static func decodeFromPosition(tokens: [llama_token], startPosition: Int32, context: OpaquePointer) throws {
        guard !tokens.isEmpty else {
            return
        }

        let batchLimit = max(1, Int(llama_n_batch(context)))
        let totalTokens = tokens.count
        var startIndex = 0

        while startIndex < totalTokens {
            let endIndex = min(startIndex + batchLimit, totalTokens)
            let batchTokens = endIndex - startIndex
            var batch = llama_batch_init(Int32(batchTokens), 0, 1)
            defer { llama_batch_free(batch) }

            batch.n_tokens = Int32(batchTokens)

            for batchIndex in 0..<batchTokens {
                let globalIndex = startIndex + batchIndex
                batch.token[batchIndex] = tokens[globalIndex]
                batch.pos[batchIndex] = startPosition + Int32(globalIndex)
                batch.n_seq_id[batchIndex] = 1

                if let seqIds = batch.seq_id, let seqId = seqIds[batchIndex] {
                    seqId[0] = 0
                }

                // Only compute logits for the very last token of the entire sequence
                batch.logits[batchIndex] = (globalIndex == totalTokens - 1) ? 1 : 0
            }

            let status = llama_decode(context, batch)
            guard status == 0 else {
                throw LLMServiceError.decodeFailed(status: status)
            }

            startIndex = endIndex
        }
    }

    static func decodeSingleToken(
        token: llama_token,
        position: Int32,
        context: OpaquePointer
    ) throws {
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = 1
        batch.token[0] = token
        batch.pos[0] = position
        batch.n_seq_id[0] = 1

        if let seqIds = batch.seq_id, let seqId = seqIds[0] {
            seqId[0] = 0
        }

        batch.logits[0] = 1

        let status = llama_decode(context, batch)
        guard status == 0 else {
            throw LLMServiceError.decodeFailed(status: status)
        }
    }

    static func tokenText(
        for token: llama_token,
        vocab: OpaquePointer
    ) throws -> String {
        var capacity = 64

        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)

            if length >= 0 {
                let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }

            capacity = max(capacity * 2, Int(-length) + 1)
            if capacity > 8_192 {
                throw LLMServiceError.tokenConversionFailed
            }
        }
    }
}
