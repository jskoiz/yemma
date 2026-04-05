import Foundation
import Observation

/// Production implementation of ``AskImageRuntime`` backed by the
/// Objective-C++ ``LiteRTLMBridge``.
///
/// Wraps the LiteRT-LM Engine/Conversation lifecycle and exposes it
/// through the Swift ``AskImageRuntime`` protocol using ``AsyncStream``
/// for token streaming.
///
/// Thread-safety: the bridge itself serialises access via ``NSLock``.
/// This class layers an additional ``NSLock`` for Swift-side state
/// (``isModelReady``, generation fence counter) and is declared
/// ``@unchecked Sendable`` to match the pattern used by ``LLMService``.
@Observable
final class LiteRTLMRuntime: AskImageRuntime, @unchecked Sendable {

    // MARK: - AskImageRuntime conformance

    private(set) var isModelReady: Bool = false

    // MARK: - Private state

    @ObservationIgnored private let bridge = LiteRTLMBridge()
    @ObservationIgnored private let lock = NSLock()

    /// Monotonically increasing generation ID used for best-effort
    /// cancellation fencing. When ``cancelGeneration()`` is called,
    /// any in-flight stream whose captured fence ID no longer matches
    /// the current value will stop yielding chunks.
    @ObservationIgnored private var generationFence: UInt64 = 0

    /// Whether a cancel has been requested for the current generation.
    @ObservationIgnored private var isCancelled = false

    private func withStateLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func markPrepared() {
        withStateLock {
            isModelReady = true
            isCancelled = false
            generationFence = 0
        }
    }

    private func markUnloaded() {
        withStateLock {
            isModelReady = false
            isCancelled = true
            generationFence &+= 1
        }
    }

    private func beginReset() {
        withStateLock {
            isCancelled = true
            generationFence &+= 1
        }
    }

    private func finishReset() {
        withStateLock {
            isCancelled = false
        }
    }

    private func beginGeneration() -> UInt64 {
        withStateLock {
            isCancelled = false
            generationFence &+= 1
            return generationFence
        }
    }

    private func generationState(for fence: UInt64) -> (fenceMatch: Bool, cancelled: Bool) {
        withStateLock {
            (generationFence == fence, isCancelled)
        }
    }

    private func markCancelled() {
        withStateLock {
            isCancelled = true
            generationFence &+= 1
        }
    }

    // MARK: - Engine lifecycle

    func prepareModel(at path: String) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        AppDiagnostics.shared.record(
            "ask_image: engine create start",
            category: "ask_image",
            metadata: ["path": path]
        )

        // Engine creation is synchronous in the bridge but may be
        // expensive. Run on a utility thread to keep the main actor free.
        let bridge = self.bridge
        try await Task.detached(priority: .utility) {
            do {
                try bridge.createEngine(withModelPath: path)
            } catch {
                let message = (error as NSError).localizedDescription
                throw AskImageRuntimeError.generationFailed(underlying: message)
            }
        }.value

        // Create the initial conversation.
        do {
            try bridge.createConversation()
        } catch {
            let message = (error as NSError).localizedDescription
            AppDiagnostics.shared.record(
                "ask_image: conversation create failed",
                category: "ask_image",
                metadata: ["error": message]
            )
            throw AskImageRuntimeError.generationFailed(underlying: message)
        }

        markPrepared()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        AppDiagnostics.shared.record(
            "ask_image: engine create end",
            category: "ask_image",
            metadata: ["elapsed_s": String(format: "%.2f", elapsed)]
        )
    }

    func unloadModel() async {
        markUnloaded()

        bridge.destroyEngine()

        AppDiagnostics.shared.record(
            "ask_image: engine destroyed",
            category: "ask_image"
        )
    }

    // MARK: - Conversation management

    func resetConversation() {
        beginReset()

        bridge.resetConversation()

        // Re-create a fresh conversation if the engine is still loaded.
        if bridge.isEngineReady {
            do {
                try bridge.createConversation()
                AppDiagnostics.shared.record(
                    "ask_image: conversation reset",
                    category: "ask_image"
                )
            } catch {
                AppDiagnostics.shared.record(
                    "ask_image: conversation reset failed",
                    category: "ask_image",
                    metadata: ["error": (error as NSError).localizedDescription]
                )
            }
        }

        finishReset()
    }

    // MARK: - Generation

    func generate(prompt: String, imagePath: String) -> AsyncStream<String> {
        let currentFence = beginGeneration()

        let requestStart = CFAbsoluteTimeGetCurrent()
        AppDiagnostics.shared.record(
            "ask_image: request start",
            category: "ask_image",
            metadata: ["prompt": String(prompt.prefix(80))]
        )

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            var isFirstChunk = true
            var totalChunks = 0

            self.bridge.sendMessage(prompt, imagePath: imagePath) { [weak self] chunk, done, error in
                guard let self else {
                    continuation.finish()
                    return
                }

                // Fence check: if a newer generation or cancel has been
                // initiated, stop delivering chunks from this stream.
                let (fenceMatch, cancelled) = self.generationState(for: currentFence)

                if !fenceMatch || cancelled {
                    continuation.finish()
                    return
                }

                if let error {
                    let code = (error as NSError).code
                    if code == LiteRTLMBridgeErrorCode.cancelled.rawValue {
                        AppDiagnostics.shared.record(
                            "ask_image: generation cancelled",
                            category: "ask_image"
                        )
                    } else {
                        AppDiagnostics.shared.record(
                            "ask_image: generation failed",
                            category: "ask_image",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                    continuation.finish()
                    return
                }

                if done {
                    let elapsed = CFAbsoluteTimeGetCurrent() - requestStart
                    AppDiagnostics.shared.record(
                        "ask_image: generation complete",
                        category: "ask_image",
                        metadata: [
                            "chunks": String(totalChunks),
                            "elapsed_s": String(format: "%.2f", elapsed),
                        ]
                    )
                    continuation.finish()
                    return
                }

                // Deliver the chunk.
                if isFirstChunk {
                    let ttft = CFAbsoluteTimeGetCurrent() - requestStart
                    AppDiagnostics.shared.record(
                        "ask_image: first chunk (TTFT)",
                        category: "ask_image",
                        metadata: ["ttft_s": String(format: "%.3f", ttft)]
                    )
                    isFirstChunk = false
                }

                totalChunks += 1
                continuation.yield(chunk)
            }
        }
    }

    // MARK: - Cancellation

    func cancelGeneration() {
        markCancelled()

        bridge.cancelGeneration()

        AppDiagnostics.shared.record(
            "ask_image: cancel requested",
            category: "ask_image"
        )
    }
}
