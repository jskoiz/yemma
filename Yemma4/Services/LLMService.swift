import Foundation
import Observation
import Darwin
import MLX
import MLXLMCommon
import MLXVLM
import OSLog
import UIKit

private final class BoundedJoinState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return
        }
        didResume = true
        continuation.resume()
    }
}

private final class GenerationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private enum Qwen35InputRoute: String, Sendable {
    case chat
}

@Observable
final class LLMService: @unchecked Sendable {
    var isModelLoaded = false
    var isModelLoading = false
    private var isMLXVisionReady = false
    var isGenerating = false
    private(set) var isSwitchingRuntime = false
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Self.temperatureDefaultsKey) }
    }
    var maxResponseTokens: Int {
        didSet {
            let normalized = Self.normalizedMaxResponseTokens(maxResponseTokens)
            guard normalized == maxResponseTokens else {
                maxResponseTokens = normalized
                return
            }

            defaults.set(maxResponseTokens, forKey: Self.maxTokensDefaultsKey)
        }
    }
    private(set) var selectedRuntime: InferenceRuntime
    private(set) var appleFoundationModelAvailability: AppleFoundationModelAvailability
    var lastError: String?
    var modelLoadStage: ModelLoadStage = .idle
    var lastGenerationStats: GenerationDebugStats?

    var isTextModelReady: Bool {
        switch selectedRuntime {
        case .appleFoundationModel:
            return appleFoundationModelAvailability.isAvailable
        case .qwen35:
            return isModelLoaded
        }
    }

    var isVisionReady: Bool {
        selectedRuntime == .qwen35 && isMLXVisionReady
    }

    var supportsImageInput: Bool {
        selectedRuntime.supportsImageInput
    }

    static let defaultTemperature: Double = ResponseStylePreset.balanced.temperature
    static let defaultMaxResponseTokens: Int = ResponseStylePreset.balanced.maxResponseTokens
    static let supportedMaxResponseTokenOptions = [256, 512, 1024, 2048, 4096]
    private static let temperatureDefaultsKey = "llm_temperature"
    private static let maxTokensDefaultsKey = "llm_maxResponseTokens"
    private static let selectedRuntimeDefaultsKey = "llm_selectedRuntime"
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
    @ObservationIgnored private var modelLoadCoordinator = ModelLoadCoordinator()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var activeGenerationID: UUID?
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private let logger = Logger(
        subsystem: Yemma4AppConfiguration.bundleIdentifier,
        category: "LLMService"
    )

    init(
        defaults: UserDefaults = .standard,
        appleAvailability: AppleFoundationModelAvailability? = nil
    ) {
        self.defaults = defaults
        let resolvedAppleAvailability = appleAvailability
            ?? AppleFoundationModelRuntime.currentAvailability()
        appleFoundationModelAvailability = resolvedAppleAvailability
        selectedRuntime = InferenceRuntime.initialSelection(
            persistedValue: defaults.string(forKey: Self.selectedRuntimeDefaultsKey),
            appleAvailability: resolvedAppleAvailability
        )
        let savedTemperature = defaults.object(forKey: Self.temperatureDefaultsKey) as? Double
        let savedMaxResponseTokens = defaults.object(forKey: Self.maxTokensDefaultsKey) as? Int

        temperature = savedTemperature ?? Self.defaultTemperature
        maxResponseTokens = savedMaxResponseTokens ?? Self.defaultMaxResponseTokens

        maxResponseTokens = Self.normalizedMaxResponseTokens(maxResponseTokens)
        defaults.set(maxResponseTokens, forKey: Self.maxTokensDefaultsKey)

        registerForMemoryWarnings()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        stopGenerationSynchronously()
    }

    /// Frees the multi-GB MLX model when the system reports memory pressure so iOS
    /// can reclaim memory instead of jetsam-killing the app. The unload is skipped
    /// while a response is generating; the model lazily reloads on next use.
    private func registerForMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    @MainActor
    private func handleMemoryWarning() {
        guard !isGenerating else {
            AppDiagnostics.shared.record(
                "Memory warning received during generation; skipping model unload",
                category: "model"
            )
            return
        }

        guard isModelLoaded else {
            return
        }

        guard !isModelLoading else {
            AppDiagnostics.shared.record(
                "Memory warning received while model load is in progress; skipping model unload",
                category: "model"
            )
            return
        }

        AppDiagnostics.shared.record(
            "Memory warning received; unloading MLX model",
            category: "model"
        )

        Task { [weak self] in
            await self?.unloadModel()
        }
    }

    func resetAdvancedSettings() {
        temperature = Self.defaultTemperature
        maxResponseTokens = Self.defaultMaxResponseTokens
    }

    @MainActor
    func refreshAppleFoundationModelAvailability() {
        let availability = AppleFoundationModelRuntime.currentAvailability()
        guard availability != appleFoundationModelAvailability else { return }

        appleFoundationModelAvailability = availability
        AppDiagnostics.shared.record(
            "Apple Foundation Model availability changed",
            category: "model",
            metadata: ["availability": String(describing: availability)]
        )
    }

    @MainActor
    @discardableResult
    func selectRuntime(_ runtime: InferenceRuntime) async -> Bool {
        guard runtime != selectedRuntime else { return true }
        guard !isSwitchingRuntime else { return false }

        isSwitchingRuntime = true
        defer { isSwitchingRuntime = false }

        await stopGeneration()
        guard await waitForGenerationToDrain() else {
            lastError = "The current model is still stopping. Try switching again in a moment."
            AppDiagnostics.shared.record(
                "Inference runtime switch deferred",
                category: "model",
                metadata: ["runtime": runtime.rawValue]
            )
            return false
        }
        if runtime == .appleFoundationModel {
            guard await unloadModel() else { return false }
            refreshAppleFoundationModelAvailability()
        }

        selectedRuntime = runtime
        defaults.set(runtime.rawValue, forKey: Self.selectedRuntimeDefaultsKey)
        lastError = nil

        AppDiagnostics.shared.record(
            "Inference runtime selected",
            category: "model",
            metadata: ["runtime": runtime.rawValue]
        )
        return true
    }

    var activeResponseStylePreset: ResponseStylePreset? {
        ResponseStylePreset.matching(
            temperature: temperature,
            maxResponseTokens: effectiveMaxResponseTokens
        )
    }

    var activeResponseStyleTitle: String {
        activeResponseStylePreset?.title ?? "Custom"
    }

    var availableMaxResponseTokenOptions: [Int] {
        if selectedRuntime == .appleFoundationModel {
            return [256, 512, 1024]
        }
        return Self.availableMaxResponseTokenOptions()
    }

    var effectiveMaxResponseTokens: Int {
        selectedRuntime == .appleFoundationModel
            ? min(maxResponseTokens, 1_024)
            : maxResponseTokens
    }

    var maxResponseTokenSafetyNote: String? {
        if selectedRuntime == .appleFoundationModel {
            return "Apple's on-device model has a shared 4K-token context, so Yemma caps each reply at 1K tokens."
        }

        let deviceCeiling = Self.maxResponseTokenCeiling()
        let highestOption = Self.supportedMaxResponseTokenOptions.last ?? deviceCeiling

        if maxResponseTokens >= 2048 {
            return "Longer replies use more memory and can slow on-device generation."
        }

        if deviceCeiling < highestOption {
            return "This iPhone recommends up to \(Self.tokenLabel(deviceCeiling)) tokens to keep memory use steadier."
        }

        return nil
    }

    func applyResponseStylePreset(_ preset: ResponseStylePreset) {
        temperature = preset.temperature
        maxResponseTokens = preset.maxResponseTokens
    }

    static func availableMaxResponseTokenOptions(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> [Int] {
        let ceiling = maxResponseTokenCeiling(physicalMemory: physicalMemory)
        let options = supportedMaxResponseTokenOptions.filter { $0 <= ceiling }
        return options.isEmpty ? [defaultMaxResponseTokens] : options
    }

    static func maxResponseTokenCeiling(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let sixGigabytes = UInt64(6) * 1024 * 1024 * 1024
        let eightGigabytes = UInt64(8) * 1024 * 1024 * 1024

        if physicalMemory < sixGigabytes {
            return 1024
        }

        if physicalMemory < eightGigabytes {
            return 2048
        }

        return 4096
    }

    static func normalizedMaxResponseTokens(
        _ value: Int,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let options = availableMaxResponseTokenOptions(physicalMemory: physicalMemory)

        if options.contains(value) {
            return value
        }

        if let clamped = options.last(where: { value >= $0 }) {
            return clamped
        }

        return options.first ?? defaultMaxResponseTokens
    }

    private static func tokenLabel(_ count: Int) -> String {
        if count >= 1024 {
            return String(format: "%.1fK", Double(count) / 1024.0)
        }

        return "\(count)"
    }

    func loadModel(from path: String) async throws {
        guard selectedRuntime == .qwen35 else {
            throw LLMServiceError.qwenRuntimeNotSelected
        }

        let resolvedPath = (path as NSString).expandingTildeInPath

        var loadTicket: ModelLoadTicket?
        while loadTicket == nil {
            let isAlreadyLoaded = withLock { () -> Bool in
                loadedModelPath == resolvedPath && modelContainer != nil
            }
            if isAlreadyLoaded {
                return
            }

            loadTicket = withLock {
                modelLoadCoordinator.begin(path: resolvedPath)
            }
            if loadTicket != nil {
                break
            }

            // Another physical load still owns the MLX loader. Wait for it to
            // settle before deciding whether this request needs a replacement.
            // This is especially important after an unload invalidates a load:
            // the logical state is idle, but the detached 3.05 GB load may still
            // be consuming memory.
            while withLock({ modelLoadCoordinator.loadingPath != nil }) {
                guard !Task.isCancelled else { return }
                let shouldKeepWaiting = await MainActor.run {
                    selectedRuntime == .qwen35
                }
                guard shouldKeepWaiting else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }

            let shouldRetry = await MainActor.run {
                selectedRuntime == .qwen35 && lastError == nil
            }
            guard shouldRetry else { return }
        }
        guard let loadTicket else { return }

        defer {
            _ = withLock {
                modelLoadCoordinator.finish(loadTicket)
            }
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
                try await Qwen35ModelLoader.loadContainer(at: URL(fileURLWithPath: resolvedPath))
            }.value

            let canActivate = await MainActor.run {
                selectedRuntime == .qwen35 && withLock {
                    modelLoadCoordinator.isCurrent(loadTicket)
                }
            }
            guard canActivate else {
                AppDiagnostics.shared.record(
                    "Discarded stale MLX model load",
                    category: "model",
                    metadata: ["path": resolvedPath]
                )
                return
            }

            await MainActor.run {
                modelLoadStage = .activatingModel
            }

            let didActivate = await MainActor.run { () -> Bool in
                guard selectedRuntime == .qwen35 else { return false }

                let installed = withLock { () -> Bool in
                    guard modelLoadCoordinator.isCurrent(loadTicket) else { return false }
                    modelContainer = loaded
                    loadedModelPath = resolvedPath
                    return true
                }
                guard installed else { return false }

                isModelLoaded = true
                isModelLoading = false
                isMLXVisionReady = true
                modelLoadStage = .ready
                lastError = nil
                return true
            }
            guard didActivate else {
                AppDiagnostics.shared.record(
                    "Discarded stale MLX model load",
                    category: "model",
                    metadata: ["path": resolvedPath]
                )
                return
            }

            AppDiagnostics.shared.record(
                "MLX model bundle loaded",
                category: "model",
                metadata: ["path": resolvedPath]
            )
        } catch {
            let shouldPublishFailure = withLock {
                modelLoadCoordinator.isCurrent(loadTicket)
            }
            guard shouldPublishFailure else {
                AppDiagnostics.shared.record(
                    "Ignored failure from stale MLX model load",
                    category: "model",
                    metadata: ["path": resolvedPath]
                )
                return
            }

            logger.error("MLX model load failed: \(error.localizedDescription, privacy: .public)")
            await publishLoadFailure(error)
            throw error
        }
    }

    func generate(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        if !Yemma4AppConfiguration.supportsLocalModelRuntime {
            return makeSimulatorStream(prompt: prompt, history: history)
        }

        guard !isSwitchingRuntime else {
            Task { @MainActor in
                self.lastError = "The on-device model is still switching. Try again in a moment."
            }
            return Self.finishedStream()
        }

        switch selectedRuntime {
        case .appleFoundationModel:
            return generateWithAppleFoundationModel(prompt: prompt, history: history)
        case .qwen35:
            return generateWithQwen35(prompt: prompt, history: history)
        }
    }

    private func generateWithQwen35(
        prompt: PromptMessageInput,
        history: [PromptMessageInput]
    ) -> AsyncStream<String> {
        let container = withLock { modelContainer }
        guard let container else {
            // Route the Observable mutation through the main actor like every other
            // mutation of `lastError` in this file; `generate` itself is not isolated.
            let message = LLMServiceError.modelNotLoaded.localizedDescription
            Task { @MainActor in
                self.lastError = message
            }
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let conversation = Self.promptMessagesForQwen35(from: history + [prompt])
        let promptRoute: Qwen35InputRoute = .chat
        let promptMode = conversation.contains { !$0.imageURLs.isEmpty } ? "multimodal" : "text-only"
        let conversationImageCount = conversation.reduce(into: 0) { $0 += $1.imageURLs.count }
        let roleSummary = "[\(conversation.map(\.role).joined(separator: ","))]"
        let latestUserPrompt = conversation.last(where: { Self.chatRole(for: $0.role) == .user })?.content ?? ""
        let responseStyle = activeResponseStylePreset?.rawValue ?? "custom"
        let taskHint = PromptTaskHint.classify( latestUserPrompt)

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
                "latestUserChars": latestUserPrompt.count,
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

        let generationStartUptime = ProcessInfo.processInfo.systemUptime
        let generationStartMemoryFootprint = Self.currentMemoryFootprintBytes()
        let generationID = UUID()

        let stream = AsyncStream<String> { continuation in
            let startGate = GenerationStartGate()
            let task = Task {
                await startGate.wait()
                do {
                    let parameters = self.generationParameters(for: conversation)
                    let rawTokenStream = try await container.perform { context in
                        let lmInput: LMInput
                        do {
                            let userInput = self.makeQwen35UserInput(from: conversation)
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

                        if promptMode == "multimodal"
                            && Yemma4AutomationConfiguration.current.multimodalFirstTokenTraceEnabled
                        {
                            do {
                                let firstTokenTrace = try Qwen35TokenDiagnostics.computeFirstTokenTrace(
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
                                        "summary": Qwen35TokenDiagnostics.summarizeFirstTokenTrace(firstTokenTrace)
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
                    var parser: Qwen35ResponseTokenParser? = nil

                    for await generation in tokenStream {
                        if Task.isCancelled {
                            break
                        }

                        switch generation {
                        case let .token(tokenID):
                            if parser == nil {
                                let tokenizer = await container.tokenizer
                                parser = Qwen35ResponseTokenParser(tokenizer: tokenizer)
                            }
                            if let chunk = parser?.append(tokenID: tokenID), !chunk.isEmpty {
                                continuation.yield(chunk)
                            }

                        case let .info(info):
                            let elapsedSeconds = max(ProcessInfo.processInfo.systemUptime - generationStartUptime, 0)
                            let memoryFootprintBytes = Self.currentMemoryFootprintBytes()
                            let memoryFootprintDeltaBytes: Int64? = {
                                guard let start = generationStartMemoryFootprint,
                                      let end = memoryFootprintBytes else {
                                    return nil
                                }
                                return Int64(end) - Int64(start)
                            }()
                            let generationStats = GenerationDebugStats(
                                generationID: generationID,
                                promptTokenCount: info.promptTokenCount,
                                generationTokenCount: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond,
                                elapsedSeconds: elapsedSeconds,
                                memoryFootprintBytes: memoryFootprintBytes,
                                memoryFootprintDeltaBytes: memoryFootprintDeltaBytes,
                                stopReason: String(describing: info.stopReason),
                                isSimulated: false
                            )
                            await MainActor.run {
                                self.lastGenerationStats = generationStats
                            }

                            var completionMetadata: [String: CustomStringConvertible] = [
                                "promptTokens": info.promptTokenCount,
                                "generationTokens": info.generationTokenCount,
                                "tokensPerSecond": String(format: "%.1f", info.tokensPerSecond),
                                "elapsedSeconds": String(format: "%.2f", elapsedSeconds),
                                "stopReason": String(describing: info.stopReason)
                            ]
                            if let memoryFootprintBytes {
                                completionMetadata["memoryFootprint"] = Self.byteCountText(memoryFootprintBytes)
                            }
                            if let memoryFootprintDeltaBytes {
                                completionMetadata["memoryDelta"] = Self.signedByteDeltaText(memoryFootprintDeltaBytes)
                            }
                            AppDiagnostics.shared.record(
                                "Generation finished",
                                category: "generation",
                                metadata: completionMetadata
                            )
                            if let parser {
                                if Yemma4AutomationConfiguration.current.rawTokenLoggingEnabled {
                                    logger.debug(
                                        "Qwen35 raw stream mode=\(promptMode, privacy: .public) tokens=\(parser.totalTokenCount, privacy: .public) visibleChunks=\(parser.visibleChunkCount, privacy: .public) visibleChars=\(parser.visibleCharacterCount, privacy: .public) preview=[\(parser.tokenPreviewSummary, privacy: .private)]"
                                    )
                                }
                            }
                        }
                    }

                    if Task.isCancelled {
                        completionTask.cancel()
                    }
                    // Bound the join on the MLX completion task. During a long
                    // prefill the underlying TokenIterator only observes
                    // cancellation between tokens, so awaiting its full result
                    // can block well past the user's stop request. Cancel and
                    // detach if it does not settle promptly; the AsyncStream
                    // continuation is still finished below regardless.
                    await Self.joinOrDetach(completionTask)
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

                    await self.finishGeneration(generationID: generationID)
                    continuation.finish()
                }

            self.publishGenerationTask(task, generationID: generationID)

            Task { @MainActor [weak self] in
                self?.isGenerating = true
                self?.lastError = nil
                self?.lastGenerationStats = nil
                startGate.open()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return stream
    }

    private func generateWithAppleFoundationModel(
        prompt: PromptMessageInput,
        history: [PromptMessageInput]
    ) -> AsyncStream<String> {
        let availability = appleFoundationModelAvailability
        guard availability.isAvailable else {
            let message = AppleFoundationModelRuntimeError.unavailable(availability).localizedDescription
            Task { @MainActor in
                self.lastError = message
            }
            return Self.finishedStream()
        }

        guard prompt.images.isEmpty else {
            let message = AppleFoundationModelRuntimeError.imagesUnsupported.localizedDescription
            Task { @MainActor in
                self.lastError = message
            }
            return Self.finishedStream()
        }

        guard history.allSatisfy({ $0.images.isEmpty }) else {
            let message = AppleFoundationModelRuntimeError.imageHistoryUnsupported.localizedDescription
            Task { @MainActor in
                self.lastError = message
            }
            return Self.finishedStream()
        }

        guard #available(iOS 26.0, *) else {
            let message = AppleFoundationModelRuntimeError
                .unavailable(.requiresIOS26)
                .localizedDescription
            Task { @MainActor in
                self.lastError = message
            }
            return Self.finishedStream()
        }

        let generationID = UUID()
        let generationStartUptime = ProcessInfo.processInfo.systemUptime
        let instructions = appleInstructions(for: prompt)

        AppDiagnostics.shared.record(
            "Generation requested",
            category: "generation",
            metadata: [
                "historyMessages": history.count,
                "images": 0,
                "runtime": selectedRuntime.rawValue,
                "style": activeResponseStylePreset?.rawValue ?? "custom"
            ]
        )

        return AsyncStream { continuation in
            let startGate = GenerationStartGate()
            let task = Task {
                await startGate.wait()
                do {
                    try await AppleFoundationModelRuntime.streamResponse(
                        instructions: instructions,
                        history: history,
                        prompt: prompt,
                        temperature: temperature,
                        maximumResponseTokens: effectiveMaxResponseTokens
                    ) { delta in
                        continuation.yield(delta)
                    }

                    AppDiagnostics.shared.record(
                        "Generation finished",
                        category: "generation",
                        metadata: [
                            "elapsedSeconds": String(
                                format: "%.2f",
                                max(ProcessInfo.processInfo.systemUptime - generationStartUptime, 0)
                            ),
                            "runtime": InferenceRuntime.appleFoundationModel.rawValue
                        ]
                    )
                } catch is CancellationError {
                    // User-initiated cancellation is an expected terminal state.
                } catch {
                    if !Task.isCancelled {
                        await self.setLastError(error.localizedDescription)
                        AppDiagnostics.shared.record(
                            "Generation failed",
                            category: "generation",
                            metadata: [
                                "error": error.localizedDescription,
                                "runtime": InferenceRuntime.appleFoundationModel.rawValue
                            ]
                        )
                    }
                }

                await self.finishGeneration(generationID: generationID)
                continuation.finish()
            }

            publishGenerationTask(task, generationID: generationID)

            Task { @MainActor [weak self] in
                self?.isGenerating = true
                self?.lastError = nil
                self?.lastGenerationStats = nil
                startGate.open()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func appleInstructions(for prompt: PromptMessageInput) -> String {
        var instructions = [Self.baseSystemPrompt]

        if let preset = activeResponseStylePreset {
            instructions.append(preset.instructionPrompt)
            instructions.append(preset.lengthTargetPrompt)
        }

        if let taskHint = PromptTaskHint.classify( prompt.text) {
            instructions.append(taskHint.instructionPrompt)
        }

        return instructions.joined(separator: "\n\n")
    }

    private static func finishedStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopGeneration() async {
        let task = takeGenerationTask()
        task?.cancel()
        // Cancel-and-detach rather than cancel-and-join. The generation task may
        // be parked inside a slow MLX prefill that only observes cancellation
        // between tokens, so an unconditional `await task?.result` can block
        // indefinitely — stalling loadModel/unloadModel which call this first.
        // Race a bounded join against a timeout and return promptly either way;
        // the detached task still finalizes itself (resets isGenerating, finishes
        // its stream continuation) once MLX yields.
        if let task {
            await Self.joinOrDetach(task)
        }
        await MainActor.run {
            isGenerating = false
        }
    }

    private func waitForGenerationToDrain() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while withLock({ activeGenerationID != nil }) {
            if clock.now >= deadline {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }

        return true
    }

    /// Awaits a generation task's completion, but only up to a short bound.
    /// If the task does not settle within the deadline (e.g. MLX is mid-prefill
    /// and not yet observing cancellation), this returns and lets the task drain
    /// on its own. Callers must not rely on the task being finished on return.
    private static func joinOrDetach(_ task: Task<Void, Never>) async {
        let timeoutNanoseconds: UInt64 = 250_000_000 // 0.25s
        await withCheckedContinuation { continuation in
            let state = BoundedJoinState()
            Task {
                _ = await task.result
                state.resumeOnce(continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                state.resumeOnce(continuation)
            }
        }
    }

    func stopGenerationSynchronously() {
        // Called from deinit, which is not isolated to the main actor. Only cancel
        // the in-flight generation task here; do not write `isGenerating` (an
        // Observation-tracked property), which must be mutated on the main actor.
        let task = takeGenerationTask()
        task?.cancel()
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

    @discardableResult
    func unloadModel() async -> Bool {
        await stopGeneration()
        guard await waitForGenerationToDrain() else {
            await setLastError("The current model is still stopping. Try again in a moment.")
            AppDiagnostics.shared.record(
                "MLX model unload deferred",
                category: "model"
            )
            return false
        }
        withLock {
            modelLoadCoordinator.invalidate()
            modelContainer = nil
            loadedModelPath = nil
        }
        await MainActor.run {
            isModelLoaded = false
            isModelLoading = false
            isMLXVisionReady = false
            modelLoadStage = .idle
            lastError = nil
        }
        AppDiagnostics.shared.record("MLX model unloaded", category: "model")
        return true
    }

    private func finishGeneration(generationID finishedGenerationID: UUID) async {
        let shouldPublish = withLock {
            guard activeGenerationID == finishedGenerationID else {
                return false
            }
            generationTask = nil
            activeGenerationID = nil
            return true
        }
        guard shouldPublish else {
            return
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
            isMLXVisionReady = hasLoadedModel
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

    static func promptMessagesForQwen35(
        from messages: [PromptMessageInput]
    ) -> [Qwen35ConversationMessage] {
        messages.compactMap { message in
            let imageURLs = message.images.map { URL(fileURLWithPath: $0.filePath) }
            let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty || !imageURLs.isEmpty else {
                return nil
            }

            let content = if Self.chatRole(for: message.role) == .user,
                trimmedText.isEmpty,
                !imageURLs.isEmpty
            {
                Qwen35MLXSupport.defaultImagePrompt
            } else {
                message.text
            }

            return Qwen35ConversationMessage(
                role: message.role,
                content: content,
                imageURLs: imageURLs
            )
        }
    }

}

extension LLMService {
    static let hiddenChannelTokenBudget = 48
    static let recommendedMultimodalMaxTokens = 256

    func generationParameters(for messages: [Qwen35ConversationMessage]) -> GenerateParameters {
        if messages.contains(where: { !$0.imageURLs.isEmpty }) {
            return GenerateParameters(
                maxTokens: min(maxResponseTokens, Self.recommendedMultimodalMaxTokens),
                temperature: 0
            )
        }

        return GenerateParameters(
            maxTokens: maxResponseTokens,
            temperature: Float(temperature),
            topP: 0.8,
            topK: 20
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

        return Qwen35HiddenChannelBudgetProcessor(
            tokenizer: tokenizer,
            hiddenChannelTokenBudget: Self.hiddenChannelTokenBudget,
            baseProcessor: baseProcessor
        )
    }

    func makeQwen35UserInput(
        from messages: [Qwen35ConversationMessage]
    ) -> UserInput {
        // Qwen requires exactly one system message at the beginning.
        let instructions = promptInstructionMessages(for: messages)
            + messages.filter { Self.chatRole(for: $0.role) == .system }
        let system = Qwen35ConversationMessage(
            role: "system", content: instructions.map(\.content).joined(separator: "\n\n"), imageURLs: []
        )
        let promptMessages = [system] + messages.filter { Self.chatRole(for: $0.role) != .system }

        return UserInput(
            chat: promptMessages.map { message in
                Chat.Message(
                    role: Self.chatRole(for: message.role),
                    content: message.content,
                    images: message.imageURLs.map(UserInput.Image.url)
                )
            },
            processing: .init(resize: CGSize(width: 768, height: 768)),
            additionalContext: Qwen35MLXSupport.templateContext
        )
    }

    func promptInstructionMessages(
        for conversationMessages: [Qwen35ConversationMessage]
    ) -> [Qwen35ConversationMessage] {
        var instructionMessages = [
            Qwen35ConversationMessage(
                role: "system",
                content: Self.baseSystemPrompt,
                imageURLs: []
            )
        ]

        if let stylePrompt = activeResponseStylePreset?.instructionPrompt {
            instructionMessages.append(
                Qwen35ConversationMessage(
                    role: "developer",
                    content: stylePrompt,
                    imageURLs: []
                )
            )
        }

        if let lengthTargetPrompt = activeResponseStylePreset?.lengthTargetPrompt {
            instructionMessages.append(
                Qwen35ConversationMessage(
                    role: "developer",
                    content: lengthTargetPrompt,
                    imageURLs: []
                )
            )
        }

        if let latestUserPrompt = conversationMessages.last(where: { Self.chatRole(for: $0.role) == .user })?.content,
            let taskHint = PromptTaskHint.classify( latestUserPrompt)
        {
            instructionMessages.append(
                Qwen35ConversationMessage(
                    role: "developer",
                    content: taskHint.instructionPrompt,
                    imageURLs: []
                )
            )
        }

        return instructionMessages
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

    func publishGenerationTask(_ task: Task<Void, Never>, generationID: UUID) {
        withLock {
            self.generationTask = task
            activeGenerationID = generationID
        }
    }

    func makeSimulatorStream(prompt: PromptMessageInput, history: [PromptMessageInput]) -> AsyncStream<String> {
        let transcriptCount = history.count + 1
        let response = Self.simulatorResponse(
            for: prompt,
            transcriptCount: transcriptCount
        )
        let generationID = UUID()

        return AsyncStream { continuation in
            let startGate = GenerationStartGate()
            let task = Task { [weak self] in
                await startGate.wait()
                for chunk in response.map(String.init) {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(chunk)
                    try? await Task.sleep(for: .milliseconds(14))
                }

                await self?.finishGeneration(generationID: generationID)
                continuation.finish()
            }

            publishGenerationTask(task, generationID: generationID)

            Task { @MainActor [weak self] in
                self?.isGenerating = true
                self?.lastError = nil
                self?.lastGenerationStats = nil
                startGate.open()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func currentMemoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return info.phys_footprint
    }

    private static func byteCountText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func signedByteDeltaText(_ deltaBytes: Int64) -> String {
        let prefix = deltaBytes >= 0 ? "+" : "-"
        return "\(prefix)\(ByteCountFormatter.string(fromByteCount: abs(deltaBytes), countStyle: .memory))"
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
        Simulator mode reply: the local UI loop is working, but real on-device inference still requires a physical iPhone.

        Prompt received: \(promptText.isEmpty ? "[image only]" : promptText)

        Conversation turns in memory: \(transcriptCount)

        Attached images in this turn: \(prompt.images.count)
        """
    }


}
