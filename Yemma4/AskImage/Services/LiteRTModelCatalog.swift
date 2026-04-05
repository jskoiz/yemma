import Foundation

/// Static catalog of available LiteRT-LM models for Ask Image.
///
/// The catalog is the single source of truth for which models exist
/// and their download metadata. The downloader and UI both read from here.
enum LiteRTModelCatalog {
    /// All models available for download.
    static let allModels: [LiteRTModelDescriptor] = [
        .gemma4E2B,
        .gemma4E4B,
    ]

    /// The default recommended model for first-time users.
    static var recommendedModel: LiteRTModelDescriptor {
        allModels.first(where: \.isRecommended) ?? allModels[0]
    }

    /// Look up a model by its stable identifier.
    static func model(for id: String) -> LiteRTModelDescriptor? {
        allModels.first(where: { $0.id == id })
    }
}
