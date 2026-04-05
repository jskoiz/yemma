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

    /// Expected file extension for validation.
    var expectedExtension: String {
        (fileName as NSString).pathExtension
    }

    /// Where this model is stored locally.
    var localDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("litert-models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    var localModelPath: URL {
        localDirectory.appendingPathComponent(fileName)
    }

    /// Resume data file path in Caches directory.
    var resumeDataPath: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("litert-\(id).resume-data")
    }

    /// Cached ETag metadata path alongside the model.
    var etagPath: URL {
        localDirectory.appendingPathComponent(".\(id).etag")
    }
}

// MARK: - Catalog Defaults

extension LiteRTModelDescriptor {
    /// Gemma 4 E2B -- small, fast, default for Ask Image.
    static let gemma4E2B = LiteRTModelDescriptor(
        id: "gemma4-e2b-askimage",
        displayName: "Gemma 4 E2B",
        shortDescription: "Fast, lightweight image understanding",
        parameterLabel: "2B",
        downloadURL: URL(string: "https://huggingface.co/google/gemma-4-e2b-it-litert/resolve/main/gemma-4-e2b-it-gpu-int4.task")!,
        fileName: "gemma-4-e2b-it-gpu-int4.task",
        expectedBytes: 1_610_612_736, // ~1.5 GB
        isRecommended: true
    )

    /// Gemma 4 E4B -- larger, higher-quality responses.
    static let gemma4E4B = LiteRTModelDescriptor(
        id: "gemma4-e4b-askimage",
        displayName: "Gemma 4 E4B",
        shortDescription: "Higher quality, uses more memory",
        parameterLabel: "4B",
        downloadURL: URL(string: "https://huggingface.co/google/gemma-4-e4b-it-litert/resolve/main/gemma-4-e4b-it-gpu-int4.task")!,
        fileName: "gemma-4-e4b-it-gpu-int4.task",
        expectedBytes: 3_221_225_472, // ~3 GB
        isRecommended: false
    )
}
