import Foundation

/// Describes a LiteRT-LM model available for Ask Image inference.
struct LiteRTModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let shortDescription: String
    let parameterLabel: String
    let downloadURL: URL
    let fileName: String
    let expectedBytes: Int64
    let isRecommended: Bool

    /// Where this model is stored locally.
    var localDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("litert-models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    var localModelPath: URL {
        localDirectory.appendingPathComponent(fileName)
    }
}

// MARK: - Catalog Defaults

extension LiteRTModelDescriptor {
    /// Gemma 4 E2B — small, fast, default for Ask Image.
    static let gemma4E2B = LiteRTModelDescriptor(
        id: "gemma4-e2b-askimage",
        displayName: "Gemma 4 E2B",
        shortDescription: "Fast, lightweight image understanding",
        parameterLabel: "2B",
        downloadURL: URL(string: "https://huggingface.co/placeholder/gemma-4-e2b-litert/resolve/main/gemma-4-e2b.task")!,
        fileName: "gemma-4-e2b.task",
        expectedBytes: 0,
        isRecommended: true
    )

    /// Gemma 4 E4B — larger, higher-quality responses.
    static let gemma4E4B = LiteRTModelDescriptor(
        id: "gemma4-e4b-askimage",
        displayName: "Gemma 4 E4B",
        shortDescription: "Higher quality, uses more memory",
        parameterLabel: "4B",
        downloadURL: URL(string: "https://huggingface.co/placeholder/gemma-4-e4b-litert/resolve/main/gemma-4-e4b.task")!,
        fileName: "gemma-4-e4b.task",
        expectedBytes: 0,
        isRecommended: false
    )
}
