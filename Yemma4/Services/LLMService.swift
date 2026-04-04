import Foundation
import Observation
import LlamaSwift

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
    var temperature = 1.0
    var lastError: String?
    var modelLoadStage: ModelLoadStage = .idle

    @ObservationIgnored private var model: OpaquePointer?
    @ObservationIgnored private var context: OpaquePointer?
    @ObservationIgnored private var vocab: OpaquePointer?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGroup: DispatchGroup?
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private var samplerConfig = SamplerConfig.defaults

    @ObservationIgnored private static let backendInitialized: Void = {
        llama_backend_init()
    }()

    init() {}

    deinit {
        stopGenerationSynchronously()
        freeLoadedModel()
    }

    func loadModel(from path: String) async throws {
        let resolvedPath = (path as NSString).expandingTildeInPath
        let loadStart = Date()
        await stopGeneration()
        await MainActor.run {
            isModelLoading = true
            modelLoadStage = .preparingRuntime
            lastError = nil
        }
        AppDiagnostics.shared.record("Loading model", category: "model", metadata: ["path": resolvedPath])

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
                        "backendInitMs": backendInitMs
                    ]
                )

                await self?.setModelLoadStage(.loadingModel)

                let resourceLoadStart = Date()
                let loadedResources = try Self.loadResources(from: resolvedPath)
                let resourceLoadMs = Int(Date().timeIntervalSince(resourceLoadStart) * 1000)
                AppDiagnostics.shared.record(
                    "Model weights loaded",
                    category: "model",
                    metadata: [
                        "path": resolvedPath,
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

            let oldResources: (model: OpaquePointer?, context: OpaquePointer?) = withLock {
                let old = (model: model, context: context)
                model = preparedResources.loadedResources.model
                context = preparedResources.loadedResources.context
                vocab = preparedResources.loadedResources.vocab
                samplerConfig = preparedResources.loadedResources.samplerConfig
                return old
            }

            Task.detached(priority: .utility) {
                Self.freeResources(model: oldResources.model, context: oldResources.context)
            }

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

    func generate(prompt: String, history: [(role: String, content: String)]) -> AsyncStream<String> {
        Self.ensureBackendInitialized()

#if targetEnvironment(simulator)
        return makeSimulatorStream(prompt: prompt, history: history)
#else
        let currentResources = withLock {
            (model: model, context: context, vocab: vocab)
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
                "promptChars": prompt.count,
                "temperature": generationConfig.temperature,
                "topK": generationConfig.topK,
                "topP": generationConfig.topP
            ]
        )

        let completionGroup = CompletionGroupBox()
        completionGroup.enter()

        let stream = AsyncStream<String> { continuation in
            let continuationBox = StreamContinuationBox(continuation)
            let job = GenerationJob(
                service: self,
                formattedPrompt: formattedPrompt,
                context: currentContext,
                vocab: currentVocab,
                samplerConfig: generationConfig,
                continuation: continuationBox,
                completionGroup: completionGroup
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

    func makeSimulatorStream(prompt: String, history: [(role: String, content: String)]) -> AsyncStream<String> {
        let transcriptCount = history.count + 1
        let response = """
        Simulator mode reply: the local UI loop is working, and the model file is present.

        Prompt received: \(prompt)

        Conversation turns in memory: \(transcriptCount)

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
    static let maxGeneratedTokens = 512

    struct ModelLoadThreadCounts: Sendable {
        let decode: Int32
        let batch: Int32
    }

    struct LoadedResources: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
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

    static func recommendedThreadCounts() -> ModelLoadThreadCounts {
        let activeCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let decodeThreads = max(1, activeCores - 2)
        let batchThreads = max(1, min(4, decodeThreads))
        return ModelLoadThreadCounts(
            decode: Int32(decodeThreads),
            batch: Int32(batchThreads)
        )
    }

    static func loadResources(from path: String) throws -> LoadedResources {
        var modelParams = llama_model_default_params()
#if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
#else
        modelParams.n_gpu_layers = 99
#endif

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512

        let threadCounts = recommendedThreadCounts()
        contextParams.n_threads = threadCounts.decode
        contextParams.n_threads_batch = threadCounts.batch

        guard let newModel = path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            throw LLMServiceError.modelLoadFailed(path: path)
        }

        guard let newContext = llama_init_from_model(newModel, contextParams) else {
            llama_model_free(newModel)
            throw LLMServiceError.contextCreationFailed(path: path)
        }

        guard let newVocab = llama_model_get_vocab(newModel) else {
            llama_free(newContext)
            llama_model_free(newModel)
            throw LLMServiceError.contextCreationFailed(path: path)
        }

        return LoadedResources(
            model: newModel,
            context: newContext,
            vocab: newVocab,
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
        let formattedPrompt: String
        let context: OpaquePointer
        let vocab: OpaquePointer
        let samplerConfig: SamplerConfig
        let continuation: StreamContinuationBox<String>
        let completionGroup: CompletionGroupBox

        init(
            service: LLMService,
            formattedPrompt: String,
            context: OpaquePointer,
            vocab: OpaquePointer,
            samplerConfig: SamplerConfig,
            continuation: StreamContinuationBox<String>,
            completionGroup: CompletionGroupBox
        ) {
            self.service = service
            self.formattedPrompt = formattedPrompt
            self.context = context
            self.vocab = vocab
            self.samplerConfig = samplerConfig
            self.continuation = continuation
            self.completionGroup = completionGroup
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
            temperature: 1.0
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
            Self.resetContextMemory(job.context)

            let sampler = try Self.makeSampler(config: job.samplerConfig)
            defer { llama_sampler_free(sampler) }

            let promptTokens = try Self.tokenize(job.formattedPrompt, vocab: job.vocab)
            let contextLimit = max(1, Int(llama_n_ctx(job.context)))
            let promptTokenLimit = max(1, contextLimit - maxGeneratedTokens)
            AppDiagnostics.shared.record(
                "Prompt tokenized",
                category: "generation",
                metadata: [
                    "promptTokens": promptTokens.count,
                    "contextLimit": contextLimit,
                    "promptTokenLimit": promptTokenLimit
                ]
            )

            guard promptTokens.count <= promptTokenLimit else {
                throw LLMServiceError.promptTooLong(tokenCount: promptTokens.count, limit: promptTokenLimit)
            }

            try Self.decode(tokens: promptTokens, context: job.context)

            var nextPosition = Int32(promptTokens.count)
            var emittedTokenCount = 0

            while !Task.isCancelled {
                guard emittedTokenCount < maxGeneratedTokens else {
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
            }

            AppDiagnostics.shared.record(
                "Generation finished",
                category: "generation",
                metadata: [
                    "emittedTokens": emittedTokenCount,
                    "finalPosition": nextPosition,
                    "contextLimit": contextLimit
                ]
            )
        } catch {
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
            model != nil && context != nil && vocab != nil
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
            let current = (model: model, context: context)
            model = nil
            context = nil
            vocab = nil
            isModelLoaded = false
            return current
        }

        Self.freeResources(model: resources.model, context: resources.context)
    }

    static func freeResources(model: OpaquePointer?, context: OpaquePointer?) {
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
        prompt: String,
        history: [(role: String, content: String)],
        model: OpaquePointer
    ) -> String {
        let conversation = history + [(role: "user", content: prompt)]

        if let templatedPrompt = tryApplyChatTemplate(conversation: conversation, model: model) {
            return templatedPrompt
        }

        var pieces = ["<bos>"]
        pieces.reserveCapacity((conversation.count * 2) + 2)

        for message in conversation {
            let role = serializedRole(message.role)
            let content = role == "model"
                ? stripThinkingBlocks(from: message.content)
                : message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            pieces.append("<|turn>\(role)\n\(content)<turn|>\n")
        }

        pieces.append("<|turn>model\n")
        return pieces.joined()
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

    static func resetContextMemory(_ context: OpaquePointer) {
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
    }

    static func templateRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "assistant"
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
        guard !tokens.isEmpty else {
            return
        }

        let batchLimit = max(1, Int(llama_n_batch(context)))
        var startIndex = 0

        while startIndex < tokens.count {
            let endIndex = min(startIndex + batchLimit, tokens.count)
            let batchTokens = endIndex - startIndex
            var batch = llama_batch_init(Int32(batchTokens), 0, 1)
            defer { llama_batch_free(batch) }

            batch.n_tokens = Int32(batchTokens)

            for (batchIndex, tokenIndex) in (startIndex..<endIndex).enumerated() {
                batch.token[batchIndex] = tokens[tokenIndex]
                batch.pos[batchIndex] = Int32(tokenIndex)
                batch.n_seq_id[batchIndex] = 1

                if let seqIds = batch.seq_id, let seqId = seqIds[batchIndex] {
                    seqId[0] = 0
                }

                batch.logits[batchIndex] = tokenIndex == tokens.count - 1 ? 1 : 0
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
