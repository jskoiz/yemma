import Foundation

public final class LLMService {
    public private(set) var isModelLoaded = false
    public private(set) var isGenerating = false

    public init() {}

    public func loadModel(from path: String) throws {
        guard !path.isEmpty else {
            throw NSError(
                domain: "Yemma4.LLMService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model path cannot be empty."]
            )
        }

        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        history: [(role: String, content: String)]
    ) -> AsyncStream<String> {
        _ = prompt
        _ = history
        isGenerating = true

        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func stopGeneration() {
        isGenerating = false
    }
}
