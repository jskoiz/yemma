import Foundation
import MLXLMCommon
import MLXVLM

enum Gemma4ModelPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case defaultE2B = "mlx-community/gemma-4-e2b-it-4bit"
    case hereticUncensored = "deadbydawn101/gemma-4-E2B-Heretic-Uncensored-mlx-4bit"
    case unslothE4B = "unsloth/gemma-4-E4B-it-UD-MLX-4bit"

    var id: String { rawValue }

    var repositoryID: String { rawValue }

    var title: String {
        switch self {
        case .defaultE2B:
            return "Gemma 4 E2B"
        case .hereticUncensored:
            return "Heretic Uncensored"
        case .unslothE4B:
            return "Unsloth E4B"
        }
    }

    var shortTitle: String {
        switch self {
        case .defaultE2B:
            return "Default"
        case .hereticUncensored:
            return "Heretic"
        case .unslothE4B:
            return "Unsloth"
        }
    }

    var detail: String {
        switch self {
        case .defaultE2B:
            return repositoryID
        case .hereticUncensored:
            return repositoryID
        case .unslothE4B:
            return repositoryID
        }
    }

    var approximateDownloadBytes: Int64 {
        Gemma4MLXSupport.defaultApproximateDownloadBytes
    }

    var sourceURL: URL {
        URL(string: "https://huggingface.co/\(repositoryID)")!
    }
}

struct Gemma4ModelSource: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case preset
        case custom
    }

    let kind: Kind
    let repositoryID: String
    let sourceURLString: String?

    var id: String { repositoryID }

    var preset: Gemma4ModelPreset? {
        Gemma4ModelPreset(rawValue: repositoryID)
    }

    var isCustom: Bool {
        kind == .custom && preset == nil
    }

    var title: String {
        preset?.title ?? "Custom model"
    }

    var shortTitle: String {
        preset?.shortTitle ?? repositoryID
    }

    var detail: String {
        preset?.detail ?? repositoryID
    }

    var approximateDownloadBytes: Int64 {
        preset?.approximateDownloadBytes ?? Gemma4MLXSupport.defaultApproximateDownloadBytes
    }

    var sourceURL: URL {
        if let sourceURLString, let url = URL(string: sourceURLString) {
            return url
        }

        return URL(string: "https://huggingface.co/\(repositoryID)")!
    }

    static let defaultSource = preset(.defaultE2B)
    static let debugPresetSources = Gemma4ModelPreset.allCases.map(Self.preset)

    static func preset(_ preset: Gemma4ModelPreset) -> Self {
        Self(
            kind: .preset,
            repositoryID: preset.repositoryID,
            sourceURLString: preset.sourceURL.absoluteString
        )
    }

    static func custom(repositoryID: String, sourceURLString: String? = nil) -> Self {
        if let preset = Gemma4ModelPreset(rawValue: repositoryID) {
            return .preset(preset)
        }

        return Self(
            kind: .custom,
            repositoryID: repositoryID,
            sourceURLString: sourceURLString ?? "https://huggingface.co/\(repositoryID)"
        )
    }

    static func fromUserInput(_ input: String) throws -> Self {
        let repositoryID = try parseRepositoryID(from: input)
        return custom(repositoryID: repositoryID, sourceURLString: "https://huggingface.co/\(repositoryID)")
    }

    private static func parseRepositoryID(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Gemma4ModelSourceInputError.emptyInput
        }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            let supportedHosts = ["huggingface.co", "www.huggingface.co"]
            guard let host = url.host?.lowercased(), supportedHosts.contains(host) else {
                throw Gemma4ModelSourceInputError.unsupportedHost(trimmed)
            }

            let pathComponents = url.pathComponents
                .filter { $0 != "/" }
                .filter { !$0.isEmpty }
            guard pathComponents.count >= 2 else {
                throw Gemma4ModelSourceInputError.missingRepository(trimmed)
            }

            return try normalizeRepositoryID("\(pathComponents[0])/\(pathComponents[1])")
        }

        return try normalizeRepositoryID(trimmed)
    }

    private static func normalizeRepositoryID(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.count == 2 else {
            throw Gemma4ModelSourceInputError.invalidRepositoryID(trimmed)
        }

        guard components.allSatisfy({ !$0.contains(where: { $0.isWhitespace }) }) else {
            throw Gemma4ModelSourceInputError.invalidRepositoryID(trimmed)
        }

        return components.joined(separator: "/")
    }
}

private enum Gemma4ModelSourceInputError: LocalizedError {
    case emptyInput
    case unsupportedHost(String)
    case missingRepository(String)
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a Hugging Face repository URL or an owner/repository id."
        case let .unsupportedHost(input):
            return "Only Hugging Face repository URLs are supported: \(input)"
        case let .missingRepository(input):
            return "That Hugging Face URL does not include an owner and repository: \(input)"
        case let .invalidRepositoryID(input):
            return "Use a repository id like owner/repository or a full Hugging Face URL: \(input)"
        }
    }
}

enum Gemma4MLXSupport {
    static let defaultApproximateDownloadBytes: Int64 = 4_200_000_000
    static let defaultModelSource = Gemma4ModelSource.defaultSource
    static let repositoryID = defaultModelSource.repositoryID
    static let legacyRepositoryIDsByPrimaryRepository = [
        Gemma4ModelPreset.defaultE2B.repositoryID: ["EZCon/gemma-4-E2B-it-4bit-mlx"]
    ]
    static let repositoryRevision = "main"
    static let approximateDownloadBytes: Int64 = defaultApproximateDownloadBytes
    static let defaultImagePrompt = "Describe the scene in this image in one short paragraph."
    static let automatedSmokeImageAssetName = "Gemma4SmokeImage"
    static let templateContext: [String: any Sendable] = ["enable_thinking": false]
    static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    static func knownRepositoryIDs(for source: Gemma4ModelSource) -> [String] {
        [source.repositoryID] + legacyRepositoryIDs(for: source)
    }

    static func legacyRepositoryIDs(for source: Gemma4ModelSource) -> [String] {
        legacyRepositoryIDsByPrimaryRepository[source.repositoryID] ?? []
    }

    @discardableResult
    static func normalizeAssetContractIfNeeded(_ validatedDirectory: ValidatedModelDirectory) throws -> Bool {
        try normalizeConfigIfNeeded(at: validatedDirectory.configURL)
    }

    static func validateAssetContract(_ validatedDirectory: ValidatedModelDirectory) throws {
        let decoder = JSONDecoder.json5()
        let modelConfiguration = try decodeJSON(
            Gemma4Configuration.self,
            from: validatedDirectory.configURL,
            fileName: validatedDirectory.configURL.lastPathComponent,
            using: decoder
        )
        let processorConfiguration = try decodeJSON(
            Gemma4ProcessorConfiguration.self,
            from: validatedDirectory.processorConfigURL,
            fileName: validatedDirectory.processorConfigURL.lastPathComponent,
            using: decoder
        )

        try validateAssetContract(
            modelConfiguration: modelConfiguration,
            processorConfiguration: processorConfiguration
        )
    }

    static func validateAssetContract(
        modelConfiguration: Gemma4Configuration,
        processorConfiguration: Gemma4ProcessorConfiguration
    ) throws {
        let processorSoftTokens = processorConfiguration.imageSeqLength
        let processorImageSoftTokens = processorConfiguration.imageProcessor.softTokenBudget
        let modelSoftTokens = modelConfiguration.visionSoftTokensPerImage
        let modelVisionDefault = modelConfiguration.visionConfiguration.defaultOutputLength

        guard processorSoftTokens == processorImageSoftTokens else {
            throw Gemma4AssetValidationError.mismatch(
                key: "processor image soft tokens",
                expected: String(processorSoftTokens),
                actual: String(processorImageSoftTokens)
            )
        }

        guard processorSoftTokens == modelSoftTokens else {
            throw Gemma4AssetValidationError.mismatch(
                key: "vision soft tokens per image",
                expected: String(modelSoftTokens),
                actual: String(processorSoftTokens)
            )
        }

        guard processorSoftTokens == modelVisionDefault else {
            throw Gemma4AssetValidationError.mismatch(
                key: "vision default output length",
                expected: String(modelVisionDefault),
                actual: String(processorSoftTokens)
            )
        }

        guard
            processorConfiguration.imageProcessor.patchSize
                == modelConfiguration.visionConfiguration.patchSize
        else {
            throw Gemma4AssetValidationError.mismatch(
                key: "vision patch size",
                expected: String(modelConfiguration.visionConfiguration.patchSize),
                actual: String(processorConfiguration.imageProcessor.patchSize)
            )
        }

        guard
            processorConfiguration.imageProcessor.poolingKernelSize
                == modelConfiguration.visionConfiguration.poolingKernelSize
        else {
            throw Gemma4AssetValidationError.mismatch(
                key: "vision pooling kernel size",
                expected: String(modelConfiguration.visionConfiguration.poolingKernelSize),
                actual: String(processorConfiguration.imageProcessor.poolingKernelSize)
            )
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from fileURL: URL,
        fileName: String,
        using decoder: JSONDecoder
    ) throws -> T {
        let data = try readValidatedFile(at: fileURL, fileName: fileName)

        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw Gemma4AssetValidationError.invalidJSON(
                fileName: fileName,
                reason: describe(decodingError: error)
            )
        } catch {
            throw Gemma4AssetValidationError.invalidJSON(
                fileName: fileName,
                reason: error.localizedDescription
            )
        }
    }

    private static func readValidatedFile(at fileURL: URL, fileName: String) throws -> Data {
        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw Gemma4AssetValidationError.unreadableFile(
                fileName: fileName,
                reason: error.localizedDescription
            )
        }
    }

    private static func normalizeConfigIfNeeded(at configURL: URL) throws -> Bool {
        let fileName = configURL.lastPathComponent
        let data = try readValidatedFile(at: configURL, fileName: fileName)

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Gemma4AssetValidationError.invalidJSON(
                fileName: fileName,
                reason: error.localizedDescription
            )
        }

        guard var config = jsonObject as? [String: Any] else {
            throw Gemma4AssetValidationError.invalidJSON(
                fileName: fileName,
                reason: "Top-level JSON object is not a dictionary."
            )
        }

        guard config["pad_token_id"] == nil else {
            return false
        }

        let fallbackPadTokenID: Int
        if let textConfig = config["text_config"] as? [String: Any],
            let nestedPadTokenID = (textConfig["pad_token_id"] as? NSNumber)?.intValue
        {
            fallbackPadTokenID = nestedPadTokenID
        } else {
            fallbackPadTokenID = 0
        }

        config["pad_token_id"] = fallbackPadTokenID

        let normalizedData: Data
        do {
            normalizedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw Gemma4AssetValidationError.invalidJSON(
                fileName: fileName,
                reason: "Could not serialize normalized config: \(error.localizedDescription)"
            )
        }

        do {
            try normalizedData.write(to: configURL, options: .atomic)
        } catch {
            throw Gemma4AssetValidationError.unreadableFile(
                fileName: fileName,
                reason: "Could not write normalized config: \(error.localizedDescription)"
            )
        }

        return true
    }

    private static func describe(decodingError: DecodingError) -> String {
        switch decodingError {
        case let .keyNotFound(key, context):
            return "Missing key `\(codingPathString(context.codingPath + [key]))`."
        case let .valueNotFound(_, context):
            return "Missing value at `\(codingPathString(context.codingPath))`."
        case let .typeMismatch(_, context):
            return "Type mismatch at `\(codingPathString(context.codingPath))`: \(context.debugDescription)"
        case let .dataCorrupted(context):
            let codingPath = codingPathString(context.codingPath)
            if codingPath.isEmpty {
                return context.debugDescription
            }
            return "Invalid data at `\(codingPath)`: \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private static func codingPathString(_ codingPath: [any CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }

    static func directorySize(at directory: URL, includingHiddenFiles: Bool = false) -> Int64 {
        let options: FileManager.DirectoryEnumerationOptions = includingHiddenFiles ? [] : [.skipsHiddenFiles]

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: options
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }

            total += Int64(values.fileSize ?? 0)
        }

        return total
    }
}

private enum Gemma4AssetValidationError: LocalizedError {
    case unreadableFile(fileName: String, reason: String)
    case invalidJSON(fileName: String, reason: String)
    case mismatch(key: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(fileName, reason):
            return "Could not read \(fileName). \(reason)"
        case let .invalidJSON(fileName, reason):
            return "Could not decode \(fileName). \(reason)"
        case let .mismatch(key, expected, actual):
            return "Gemma 4 asset mismatch for \(key). Expected \(expected) but found \(actual)."
        }
    }
}

struct ValidatedModelDirectory: Sendable {
    let location: URL
    let configURL: URL
    let processorConfigURL: URL
    let processorConfigFileName: String
    let weightFileNames: [String]
    let indexedWeightFileNames: [String]
}

private struct SafetensorsIndex: Decodable {
    let weightMap: [String: String]

    enum CodingKeys: String, CodingKey {
        case weightMap = "weight_map"
    }
}

private enum ModelDirectoryValidationError: LocalizedError {
    case missingRequiredFile(String)
    case unreadableFile(String)
    case emptyFile(String)
    case brokenSymlink(String)
    case invalidWeightIndex(String)
    case missingIndexedWeightShard(indexFile: String, shardFile: String)
    case noWeightFiles

    var errorDescription: String? {
        switch self {
        case let .missingRequiredFile(fileName):
            return "Required model file is missing: \(fileName)."
        case let .unreadableFile(fileName):
            return "Model file is unreadable: \(fileName)."
        case let .emptyFile(fileName):
            return "Model file is empty: \(fileName)."
        case let .brokenSymlink(fileName):
            return "Model file points to a broken symlink: \(fileName)."
        case let .invalidWeightIndex(fileName):
            return "Weight index file is invalid: \(fileName)."
        case let .missingIndexedWeightShard(indexFile, shardFile):
            return "Weight index \(indexFile) references a missing shard: \(shardFile)."
        case .noWeightFiles:
            return "No safetensors weights were found in the model directory."
        }
    }
}

enum ModelDirectoryValidator {
    private static let requiredMetadataFiles = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
    ]

    static func validatedDirectory(at location: URL) throws -> ValidatedModelDirectory {
        let fileManager = FileManager.default
        let cachedFiles = try fileManager.contentsOfDirectory(
            at: location,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let fileMap = Dictionary(uniqueKeysWithValues: cachedFiles.map { ($0.lastPathComponent, $0) })

        for requiredFile in requiredMetadataFiles {
            guard let fileURL = fileMap[requiredFile] else {
                throw ModelDirectoryValidationError.missingRequiredFile(requiredFile)
            }
            try validateReadableFile(at: fileURL, fileName: requiredFile, eagerlyReadContents: true)
        }

        let processorConfigURL: URL
        if let preprocessorConfigURL = fileMap["preprocessor_config.json"] {
            processorConfigURL = preprocessorConfigURL
        } else if let processorURL = fileMap["processor_config.json"] {
            processorConfigURL = processorURL
        } else {
            throw ModelDirectoryValidationError.missingRequiredFile(
                "processor_config.json or preprocessor_config.json"
            )
        }
        try validateReadableFile(
            at: processorConfigURL,
            fileName: processorConfigURL.lastPathComponent,
            eagerlyReadContents: true
        )

        if let chatTemplateURL = fileMap["chat_template.jinja"] ?? fileMap["chat_template.json"] {
            try validateReadableFile(
                at: chatTemplateURL,
                fileName: chatTemplateURL.lastPathComponent,
                eagerlyReadContents: true
            )
        }

        let weightFiles = cachedFiles
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !weightFiles.isEmpty else {
            throw ModelDirectoryValidationError.noWeightFiles
        }
        for weightFile in weightFiles {
            try validateReadableFile(
                at: weightFile,
                fileName: weightFile.lastPathComponent,
                eagerlyReadContents: false
            )
        }

        let indexFiles = cachedFiles
            .filter { $0.lastPathComponent.hasSuffix(".safetensors.index.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var indexedWeightFileNames: [String] = []
        for indexFile in indexFiles {
            try validateReadableFile(
                at: indexFile,
                fileName: indexFile.lastPathComponent,
                eagerlyReadContents: true
            )

            let data = try Data(contentsOf: indexFile)
            let parsedIndex: SafetensorsIndex
            do {
                parsedIndex = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
            } catch {
                throw ModelDirectoryValidationError.invalidWeightIndex(indexFile.lastPathComponent)
            }

            let shardFileNames = Array(Set(parsedIndex.weightMap.values)).sorted()
            for shardFileName in shardFileNames {
                guard let shardURL = fileMap[shardFileName] else {
                    throw ModelDirectoryValidationError.missingIndexedWeightShard(
                        indexFile: indexFile.lastPathComponent,
                        shardFile: shardFileName
                    )
                }

                try validateReadableFile(
                    at: shardURL,
                    fileName: shardFileName,
                    eagerlyReadContents: false
                )
            }
            indexedWeightFileNames.append(contentsOf: shardFileNames)
        }

        return ValidatedModelDirectory(
            location: location,
            configURL: fileMap["config.json"]!,
            processorConfigURL: processorConfigURL,
            processorConfigFileName: processorConfigURL.lastPathComponent,
            weightFileNames: weightFiles.map(\.lastPathComponent),
            indexedWeightFileNames: Array(Set(indexedWeightFileNames)).sorted()
        )
    }

    private static func validateReadableFile(
        at fileURL: URL,
        fileName: String,
        eagerlyReadContents: Bool
    ) throws {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            if FileManager.default.destinationOfSymbolicLinkSafe(atPath: fileURL.path) != nil {
                throw ModelDirectoryValidationError.brokenSymlink(fileName)
            }
            throw ModelDirectoryValidationError.unreadableFile(fileName)
        }

        if values.isSymbolicLink == true && values.isRegularFile != true {
            throw ModelDirectoryValidationError.brokenSymlink(fileName)
        }

        guard values.isRegularFile == true else {
            throw ModelDirectoryValidationError.unreadableFile(fileName)
        }

        guard (values.fileSize ?? 0) > 0 else {
            throw ModelDirectoryValidationError.emptyFile(fileName)
        }

        do {
            if eagerlyReadContents {
                _ = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } else {
                let handle = try FileHandle(forReadingFrom: fileURL)
                try handle.close()
            }
        } catch {
            throw ModelDirectoryValidationError.unreadableFile(fileName)
        }
    }
}

private extension FileManager {
    func destinationOfSymbolicLinkSafe(atPath path: String) -> String? {
        try? destinationOfSymbolicLink(atPath: path)
    }
}
