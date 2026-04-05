import Foundation

/// Stub runtime that streams fake responses for UI development.
/// Used on simulator or when the real LiteRT-LM bridge is not yet available.
@Observable
final class StubAskImageRuntime: AskImageRuntime, @unchecked Sendable {
    private(set) var isModelReady = false
    private var isCancelled = false

    func prepareModel(at path: String) async throws {
        // Simulate model loading delay
        try await Task.sleep(for: .milliseconds(800))
        isModelReady = true
        AppDiagnostics.shared.record(
            "ask_image: stub model prepared",
            category: "ask_image",
            metadata: ["path": path]
        )
    }

    func unloadModel() async {
        isModelReady = false
    }

    func resetConversation() {
        isCancelled = false
    }

    func generate(prompt: String, imagePath: String) -> AsyncStream<String> {
        isCancelled = false
        AppDiagnostics.shared.record(
            "ask_image: stub generation started",
            category: "ask_image",
            metadata: ["prompt": String(prompt.prefix(80))]
        )

        return AsyncStream { [weak self] continuation in
            Task { [weak self] in
                let response = StubAskImageRuntime.stubResponse(for: prompt)
                let words = response.split(separator: " ", omittingEmptySubsequences: false)

                for (index, word) in words.enumerated() {
                    guard self?.isCancelled != true else {
                        continuation.finish()
                        return
                    }

                    let chunk = index == 0 ? String(word) : " " + String(word)
                    continuation.yield(chunk)

                    // Simulate variable latency
                    let delay = index == 0 ? 200 : Int.random(in: 20...60)
                    try? await Task.sleep(for: .milliseconds(delay))
                }

                continuation.finish()
            }
        }
    }

    func cancelGeneration() {
        isCancelled = true
    }

    private static func stubResponse(for prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("describe") {
            return "This image shows a well-composed scene with clear subject matter. The lighting is natural and the colors are vibrant. I can see several distinct elements that create an interesting visual composition. The main subject appears centered with supporting details around the edges."
        } else if lower.contains("text") || lower.contains("read") {
            return "I can see text in this image. The text appears to be printed in a clear, readable font. Due to the stub runtime, I cannot provide the actual text content, but the real model will be able to extract and transcribe visible text accurately."
        } else if lower.contains("summarize") || lower.contains("scene") {
            return "This scene captures a moment with several notable elements. The composition suggests a casual, everyday setting. There are both foreground and background elements that provide depth and context to the overall image."
        } else {
            return "Based on the image you've shared, I can provide some observations. The image contains visual elements that are worth noting. For a more detailed and accurate analysis, the full LiteRT-LM model will provide richer descriptions. This is a placeholder response from the stub runtime."
        }
    }
}
