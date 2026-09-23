import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

private enum MLXRuntimeEnvironment {
    static let lock = NSLock()
    nonisolated(unsafe) static var didPrepare = false
}

enum Gemma4ModelLoader {
    static func loadContainer(at modelDirectory: URL) async throws -> ModelContainer {
        try await prepareMLXRuntimeInBackground()
        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            let validatedDirectory = try ModelDirectoryValidator.validatedDirectory(at: modelDirectory)
            AppDiagnostics.shared.record(
                "Validated MLX model directory before load",
                category: "model",
                metadata: [
                    "path": validatedDirectory.location.path,
                    "processorConfig": validatedDirectory.processorConfigFileName,
                    "weightFiles": validatedDirectory.weightFileNames.count,
                    "indexedWeightFiles": validatedDirectory.indexedWeightFileNames.count
                ]
            )
            if try Gemma4MLXSupport.normalizeAssetContractIfNeeded(validatedDirectory) {
                AppDiagnostics.shared.record(
                    "Normalized Gemma 4 config for compatibility",
                    category: "model",
                    metadata: [
                        "path": validatedDirectory.configURL.path,
                        "injectedKey": "pad_token_id"
                    ]
                )
            }
            try Gemma4MLXSupport.validateAssetContract(validatedDirectory)
        } catch {
            throw LLMServiceError.assetValidationFailed(error)
        }

        let tokenizerLoader = SwiftTokenizersLoader(
            willLoad: {
                AppDiagnostics.shared.record("Loading tokenizer...", category: "model")
            },
            didLoad: {
                AppDiagnostics.shared.record("Loading model weights...", category: "model")
            }
        )

        let context = try await VLMModelFactory.shared._load(
            configuration: .init(directory: modelDirectory),
            tokenizerLoader: tokenizerLoader
        )
        return ModelContainer(context: context)
    }

    static func prepareMLXRuntimeInBackground() async throws {
        try await Task.detached(priority: .userInitiated) {
            try prepareMLXRuntimeIfNeeded()
        }.value
    }

    static func prepareMLXRuntimeIfNeeded() throws {
        MLXRuntimeEnvironment.lock.lock()
        defer { MLXRuntimeEnvironment.lock.unlock() }

        if MLXRuntimeEnvironment.didPrepare {
            return
        }

        guard let source = bundledMetalLibraryURL() else {
            throw LLMServiceError.modelLoadFailed(path: "default.metallib")
        }

        let fileManager = FileManager.default
        let runtimeDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "mlx-runtime", directoryHint: .isDirectory)
            ?? fileManager.temporaryDirectory.appending(path: "mlx-runtime", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let runtimeMetalLib = runtimeDirectory.appending(path: "default.metallib")
        if !fileManager.fileExists(atPath: runtimeMetalLib.path) {
            try? fileManager.removeItem(at: runtimeMetalLib)
            try fileManager.copyItem(at: source, to: runtimeMetalLib)
        }

        guard fileManager.changeCurrentDirectoryPath(runtimeDirectory.path) else {
            throw LLMServiceError.modelLoadFailed(path: runtimeDirectory.path)
        }

        MLXRuntimeEnvironment.didPrepare = true
    }

    static func bundledMetalLibraryURL() -> URL? {
        let directCandidates: [URL?] = [
            Bundle.main.url(
                forResource: "default",
                withExtension: "metallib",
                subdirectory: "mlx-swift_Cmlx.bundle"
            ),
            Bundle.main.resourceURL?.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"),
        ]

        for candidate in directCandidates {
            if let candidate, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let bundles = Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles where bundle.bundleURL.lastPathComponent == "mlx-swift_Cmlx.bundle" {
            if let candidate = bundle.url(forResource: "default", withExtension: "metallib"),
                FileManager.default.fileExists(atPath: candidate.path)
            {
                return candidate
            }
        }

        return nil
    }
}

private struct SwiftTokenizersLoader: TokenizerLoader {
    var willLoad: @Sendable () -> Void = {}
    var didLoad: @Sendable () -> Void = {}

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        willLoad()
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        didLoad()
        return TokenizersAdapter(upstream: tokenizer)
    }
}

private struct TokenizersAdapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
