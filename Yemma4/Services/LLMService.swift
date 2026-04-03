import Foundation
import Observation
import LlamaSwift

enum LLMServiceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(path: String)
    case contextCreationFailed(path: String)
    case samplerCreationFailed
    case tokenizationFailed
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
    var lastError: String?

    @ObservationIgnored private var model: OpaquePointer?
    @ObservationIgnored private var context: OpaquePointer?
    @ObservationIgnored private var vocab: UnsafePointer<llama_vocab>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGroup: DispatchGroup?
    @ObservationIgnored private let stateLock = NSLock()

    @ObservationIgnored private static let backendInitialized: Void = {
        llama_backend_init()
    }()

    init() {
        _ = Self.backendInitialized
    }

    deinit {
        stopGeneration()
        freeLoadedModel()
    }

    func loadModel(from path: String) throws {
        _ = Self.backendInitialized

        stopGeneration()

        let resolvedPath = (path as NSString).expandingTildeInPath

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
    }

    func generate(prompt: String, history: [(role: String, content: String)]) -> AsyncStream<String> {
        stopGeneration()

        let currentContext = withLock { context }
        let currentVocab = withLock { vocab }

        guard isModelLoaded, let currentContext, let currentVocab else {
            let error = LLMServiceError.modelNotLoaded
            setLastError(error.localizedDescription)
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let formattedPrompt = Self.formatPrompt(prompt: prompt, history: history)

        let completionGroup = DispatchGroup()
        completionGroup.enter()

        let stream = AsyncStream<String> { continuation in
            let task = Task { [weak self] in
                defer {
                    completionGroup.leave()
                }

                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    let sampler = try Self.makeSampler()
                    defer { llama_sampler_free(sampler) }

                    let promptTokens = try Self.tokenize(formattedPrompt, vocab: currentVocab)
                    try Self.decode(tokens: promptTokens, context: currentContext)

                    var nextPosition = Int32(promptTokens.count)

                    while !Task.isCancelled {
                        let nextToken = llama_sampler_sample(sampler, currentContext, -1)

                        if llama_vocab_is_eog(currentVocab, nextToken) {
                            break
                        }

                        llama_sampler_accept(sampler, nextToken)

                        let piece = try Self.tokenText(for: nextToken, vocab: currentVocab)
                        if !piece.isEmpty {
                            continuation.yield(piece)
                        }

                        try Self.decodeSingleToken(
                            token: nextToken,
                            position: nextPosition,
                            context: currentContext
                        )
                        nextPosition += 1
                    }
                } catch {
                    if !Task.isCancelled {
                        self.setLastError(error.localizedDescription)
                    }
                }

                self.finishGeneration()
                continuation.finish()
            }

            self.withLock {
                generationTask = task
                generationGroup = completionGroup
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
}

private extension LLMService {
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

    static func normalizedRole(_ role: String) -> String {
        let lowercased = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowercased {
        case "assistant", "model":
            return "model"
        default:
            return "user"
        }
    }

    static func makeSampler() throws -> OpaquePointer {
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

        guard let temp = llama_sampler_init_temp(1.0) else {
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
        vocab: UnsafePointer<llama_vocab>
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

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(tokens.count)

        for index in tokens.indices {
            batch.token[index] = tokens[index]
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1

            if let seqIds = batch.seq_id, let seqId = seqIds[index] {
                seqId[0] = 0
            }

            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }

        let status = llama_decode(context, batch)
        guard status == 0 else {
            throw LLMServiceError.decodeFailed(status: status)
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
        vocab: UnsafePointer<llama_vocab>
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
