import Foundation

/// Protocol for managing LiteRT-LM model downloads and local state.
/// Phase 1B will provide the real implementation.
protocol AskImageModelStore: AnyObject {
    /// All models in the catalog.
    var availableModels: [LiteRTModelDescriptor] { get }

    /// Current state for a given model ID.
    func state(for modelID: String) -> LiteRTModelState

    /// Start or resume downloading a model.
    func download(_ model: LiteRTModelDescriptor) async throws

    /// Cancel an in-progress download.
    func cancelDownload(_ modelID: String)

    /// Delete a downloaded model from disk.
    func deleteModel(_ modelID: String) throws

    /// Validate that a model's local files are intact.
    func validate(_ modelID: String) -> Bool
}
