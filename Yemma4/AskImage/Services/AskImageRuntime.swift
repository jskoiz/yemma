import Foundation

/// Errors surfaced by the Ask Image runtime layer.
enum AskImageRuntimeError: LocalizedError, Sendable {
    case modelNotLoaded
    case imageNotFound(path: String)
    case imageDecodeFailed
    case generationFailed(underlying: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model is loaded. Download a model first."
        case .imageNotFound(let path):
            "Image file not found at \(path)."
        case .imageDecodeFailed:
            "Could not decode the attached image."
        case .generationFailed(let underlying):
            "Generation failed: \(underlying)"
        case .cancelled:
            "Generation was cancelled."
        }
    }
}

/// Protocol for Ask Image inference backends.
/// Phase 1A will provide a real LiteRT-LM implementation.
/// The stub implementation allows UI development without native dependencies.
protocol AskImageRuntime: AnyObject, Sendable {
    /// Whether a model is currently loaded and ready for inference.
    var isModelReady: Bool { get }

    /// Prepare/load a model from a local path. May be slow.
    func prepareModel(at path: String) async throws

    /// Unload the current model and free resources.
    func unloadModel() async

    /// Reset the current conversation state without unloading the model.
    func resetConversation()

    /// Send a multimodal prompt (text + image path) and receive streamed text chunks.
    func generate(prompt: String, imagePath: String) -> AsyncStream<String>

    /// Best-effort cancellation of the current generation.
    func cancelGeneration()
}
