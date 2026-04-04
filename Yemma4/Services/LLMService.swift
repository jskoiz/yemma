import Foundation
import Observation
import LlamaSwift

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
    var isGenerating = false
    var temperature = 1.0
    var lastError: String?

    @ObservationIgnored private var model: OpaquePointer?
    @ObservationIgnored private var context: OpaquePointer?
    @ObservationIgnored private var vocab: OpaquePointer?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGroup: DispatchGroup?
    @ObservationIgnored private let stateLock = NSLock()

    @ObservationIgnored private static let backendInitialized: Void = {
        llama_backend_init()
    }()

    init() {}

    deinit {
        stopGeneration()
        freeLoadedModel()
    }

    func loadModel(from path: String) throws {
        Self.ensureBackendInitialized()

        stopGeneration()

        let resolvedPath = (path as NSString).expandingTildeInPath
        AppDiagnostics.shared.record("Loading model", category: "model", metadata: ["path": resolvedPath])

#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            let error = LLMServiceError.modelLoadFailed(path: resolvedPath)
            setLastError(error.localizedDescription)
            throw error
        }

        withLock {
            freeResources(model: model, context: context)
            model = nil
            context = nil
            vocab = nil
            isModelLoaded = true
            lastError = nil
        }
        AppDiagnostics.shared.record("Simulator model stub ready", category: "model")
        return
#endif

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        contextParams.n_threads = Int32(cores)
        contextParams.n_threads_batch = Int32(cores)

        guard let newModel = resolvedPath.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            let error = LLMServiceError.modelLoadFailed(path: resolvedPath)
            setLastError(error.localizedDescription)
            throw error
        }

        guard let newContext = llama_init_from_model(newModel, contextParams) else {
            llama_model_free(newModel)
            let error = LLMServiceError.contextCreationFailed(path: resolvedPath)
            setLastError(error.localizedDescription)
            throw error
        }

        guard let newVocab = llama_model_get_vocab(newModel) else {
            llama_free(newContext)
            llama_model_free(newModel)
            let error = LLMServiceError.contextCreationFailed(path: resolvedPath)
            setLastError(error.localizedDescription)
            throw error
        }

        let oldResources: (model: OpaquePointer?, context: OpaquePointer?) = withLock {
            let old = (model: model, context: context)
            model = newModel
            context = newContext
            vocab = newVocab
            isModelLoaded = true
            lastError = nil
            return old
        }

        freeResources(model: oldResources.model, context: oldResources.context)
        AppDiagnostics.shared.record(
            "Model loaded",
            category: "model",
            metadata: [
                "path": resolvedPath,
                "context": llama_n_ctx(newContext),
                "batch": llama_n_batch(newContext)
            ]
        )
    }

    func generate(prompt: String, history: [(role: String, content: String)]) -> AsyncStream<String> {
        stopGeneration()

        Self.ensureBackendInitialized()

#if targetEnvironment(simulator)
        return makeSimulatorStream(prompt: prompt, history: history)
#endif

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
            setLastError(error.localizedDescription)
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let formattedPrompt = Self.formatPrompt(prompt: prompt, history: history)
        let currentTemperature = withLock { temperature }
        AppDiagnostics.shared.record(
            "Generation requested",
            category: "generation",
            metadata: [
                "historyCount": history.count,
                "promptChars": prompt.count,
                "temperature": currentTemperature
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
                temperature: currentTemperature,
                continuation: continuationBox,
                completionGroup: completionGroup
            )
            let task = Task {
                await Self.runGeneration(job)
            }

            self.withLock {
                generationTask = task
                generationGroup = completionGroup.group
                isGenerating = true
                lastError = nil
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return stream
    }

    func stopGeneration() {
        let taskAndGroup: (task: Task<Void, Never>?, group: DispatchGroup?) = withLock {
            let pair = (task: generationTask, group: generationGroup)
            generationTask = nil
            generationGroup = nil
            isGenerating = false
            return pair
        }

        taskAndGroup.task?.cancel()
        taskAndGroup.group?.wait()
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

                self.finishGeneration()
                continuation.finish()
            }

            self.withLock {
                generationTask = task
                generationGroup = nil
                isGenerating = true
                lastError = nil
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private extension LLMService {
    static let maxGeneratedTokens = 512

    static func ensureBackendInitialized() {
        _ = backendInitialized
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
        let temperature: Double
        let continuation: StreamContinuationBox<String>
        let completionGroup: CompletionGroupBox

        init(
            service: LLMService,
            formattedPrompt: String,
            context: OpaquePointer,
            vocab: OpaquePointer,
            temperature: Double,
            continuation: StreamContinuationBox<String>,
            completionGroup: CompletionGroupBox
        ) {
            self.service = service
            self.formattedPrompt = formattedPrompt
            self.context = context
            self.vocab = vocab
            self.temperature = temperature
            self.continuation = continuation
            self.completionGroup = completionGroup
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

            let sampler = try Self.makeSampler(temperature: job.temperature)
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
                service.setLastError(error.localizedDescription)
            }
        }

        service.finishGeneration()
        job.continuation.finish()
    }

    func finishGeneration() {
        withLock {
            generationTask = nil
            generationGroup = nil
            isGenerating = false
        }
    }

    func setLastError(_ message: String) {
        withLock {
            lastError = message
            isGenerating = false
        }
        AppDiagnostics.shared.record("Service error recorded", category: "generation", metadata: ["error": message])
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

        freeResources(model: resources.model, context: resources.context)
    }

    func freeResources(model: OpaquePointer?, context: OpaquePointer?) {
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

    static func formatPrompt(
        prompt: String,
        history: [(role: String, content: String)]
    ) -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(history.count + 1)

        for message in history {
            let role = normalizedRole(message.role)
            pieces.append("<start_of_turn>\(role)\n\(message.content)<end_of_turn>\n")
        }

        pieces.append("<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n")
        return pieces.joined()
    }

    static func resetContextMemory(_ context: OpaquePointer) {
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
    }

    static func normalizedRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "model"
        default:
            return "user"
        }
    }

    static func makeSampler(temperature: Double) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()

        guard let sampler = llama_sampler_chain_init(params) else {
            throw LLMServiceError.samplerCreationFailed
        }

        guard let topK = llama_sampler_init_top_k(64) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, topK)

        guard let topP = llama_sampler_init_top_p(0.95, 1) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, topP)

        guard let minP = llama_sampler_init_min_p(0.0, 1) else {
            llama_sampler_free(sampler)
            throw LLMServiceError.samplerCreationFailed
        }
        llama_sampler_chain_add(sampler, minP)

        guard let temp = llama_sampler_init_temp(Float(temperature)) else {
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
