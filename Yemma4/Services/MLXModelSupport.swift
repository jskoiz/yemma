import Foundation
import MLXLMCommon
import MLXVLM

enum Qwen35MLXSupport {
    // One immutable, combined language + vision package. No separate projector download.
    static let repositoryID = "dream-vault-community/Qwen3.5-4B-4bit-Abliterated"
    static let repositoryRevision = "a40c9a8d5c6f6f70d678120ccb46a3f6456c727c"
    static let sourceURL = URL(string: "https://huggingface.co/\(repositoryID)")!
    static let approximateDownloadBytes: Int64 = 3_054_414_391
    static let defaultImagePrompt = "Describe the scene in this image in one short paragraph."
    static let automatedSmokeImageAssetName = "Qwen35SmokeImage"
    static let templateContext: [String: any Sendable] = ["enable_thinking": false]
    static let downloadPatterns = [
        "model.safetensors", "model.safetensors.index.json", "config.json",
        "preprocessor_config.json", "processor_config.json", "tokenizer.json",
        "tokenizer_config.json", "chat_template.jinja", "LICENSE", "PROVENANCE.json"
    ]

    static func validateAssetContract(_ directory: ValidatedModelDirectory) throws {
        let decoder = JSONDecoder.json5()
        let configData = try Data(contentsOf: directory.configURL)
        let config = try decoder.decode(Qwen35Configuration.self, from: configData)
        guard config.modelType == "qwen3_5", config.textConfiguration.hiddenLayers == 32,
              config.textConfiguration.hiddenSize == 2560,
              config.imageTokenId == 248056, config.visionStartTokenId == 248053,
              config.visionEndTokenId == 248054,
              config.visionConfiguration.depth == 24, config.visionConfiguration.patchSize == 16,
              config.visionConfiguration.spatialMergeSize == 2,
              config.visionConfiguration.temporalPatchSize == 2 else {
            throw Qwen35AssetValidationError.invalid("Expected the Qwen3.5 4B vision-language configuration.")
        }
        guard directory.processorConfigFileName == "preprocessor_config.json" else {
            throw Qwen35AssetValidationError.invalid("The flat vision preprocessor configuration is missing.")
        }
        let processor = try decoder.decode(
            Qwen3VLProcessorConfiguration.self,
            from: Data(contentsOf: directory.processorConfigURL)
        )
        guard processor.patchSize == 16, processor.mergeSize == 2,
              processor.temporalPatchSize == 2,
              processor.imageMean == [0.5, 0.5, 0.5], processor.imageStd == [0.5, 0.5, 0.5] else {
            throw Qwen35AssetValidationError.invalid("The vision preprocessor does not match this model.")
        }
        // Swift Tokenizers can read the template embedded in tokenizer_config.json.
        // Validate both copies so the actual loader cannot silently select a text-only template.
        let template = try String(contentsOf: directory.location.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let tokenizerConfig = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.location.appendingPathComponent("tokenizer_config.json"))
        ) as? [String: Any]
        guard let embedded = tokenizerConfig?["chat_template"] as? String,
              embedded == template,
              template.contains("<|vision_start|><|image_pad|><|vision_end|>"),
              template.contains("item.type == 'image'"), template.contains("enable_thinking") else {
            throw Qwen35AssetValidationError.invalid("The image-aware chat template is missing or inconsistent.")
        }
        try validateVisionWeights(in: directory)
    }

    private struct TensorDescriptor: Decodable {
        let dataOffsets: [UInt64]
        enum CodingKeys: String, CodingKey { case dataOffsets = "data_offsets" }
    }

    // Read only safetensors headers, not the multi-GB tensors. The pinned
    // package has one combined safetensors file and an index that maps every
    // text and vision tensor into that file. The index is part of the runtime
    // contract because it is what the MLX loader uses to discover the text
    // weights.
    private static func validateVisionWeights(in directory: ValidatedModelDirectory) throws {
        var tensorNames = Set<String>()
        for name in directory.weightFileNames {
            let url = directory.location.appendingPathComponent(name)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
                throw Qwen35AssetValidationError.invalid("Invalid safetensors header in \(name).")
            }
            let headerLength = prefix.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            guard headerLength > 0, headerLength <= 16 * 1024 * 1024,
                  let header = try handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength),
                  let entries = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
                throw Qwen35AssetValidationError.invalid("Invalid safetensors header in \(name).")
            }
            let fileSize = try handle.seekToEnd()
            let payloadSize = fileSize - 8 - headerLength
            for (key, value) in entries where key != "__metadata__" {
                let tensor = try JSONDecoder().decode(TensorDescriptor.self, from: JSONSerialization.data(withJSONObject: value))
                guard tensor.dataOffsets.count == 2, tensor.dataOffsets[0] < tensor.dataOffsets[1],
                      tensor.dataOffsets[1] <= payloadSize else {
                    throw Qwen35AssetValidationError.invalid("Truncated tensor \(key) in \(name).")
                }
                tensorNames.insert(key)
            }
        }
        guard !directory.indexedWeightFileNames.isEmpty,
              !directory.indexedTensorNames.isEmpty,
              tensorNames == directory.indexedTensorNames else {
            throw Qwen35AssetValidationError.invalid(
                "The combined package has no complete safetensors weight index. Download the complete model again."
            )
        }

        let requiredVision = ["vision_tower.patch_embed.proj.weight", "vision_tower.merger.linear_fc1.weight",
                              "vision_tower.merger.linear_fc2.weight"]
            + (0..<24).map { "vision_tower.blocks.\($0).attn.qkv.weight" }
        guard requiredVision.allSatisfy(tensorNames.contains),
              tensorNames.filter({ $0.hasPrefix("vision_tower.") }).count == 297 else {
            throw Qwen35AssetValidationError.invalid("The combined package is missing language or vision weights. Download the complete model again.")
        }

        guard expectedTextWeightNames.isSubset(of: tensorNames) else {
            throw Qwen35AssetValidationError.invalid(
                "The combined package is missing text weights required by Qwen3.5 4B. Download the complete model again."
            )
        }
    }

    private static var expectedTextWeightNames: Set<String> {
        var names: Set<String> = [
            "language_model.model.embed_tokens.biases",
            "language_model.model.embed_tokens.scales",
            "language_model.model.embed_tokens.weight",
            "language_model.model.norm.weight"
        ]

        let quantizedProjectionNames = ["biases", "scales", "weight"]
        for layer in 0..<32 {
            let prefix = "language_model.model.layers.\(layer)"
            names.insert("\(prefix).input_layernorm.weight")
            names.insert("\(prefix).post_attention_layernorm.weight")
            for projection in ["down_proj", "gate_proj", "up_proj"] {
                for suffix in quantizedProjectionNames {
                    names.insert("\(prefix).mlp.\(projection).\(suffix)")
                }
            }

            if layer % 4 == 3 {
                for projection in ["k_proj", "o_proj", "q_proj", "v_proj"] {
                    for suffix in quantizedProjectionNames {
                        names.insert("\(prefix).self_attn.\(projection).\(suffix)")
                    }
                }
                names.insert("\(prefix).self_attn.k_norm.weight")
                names.insert("\(prefix).self_attn.q_norm.weight")
            } else {
                names.insert("\(prefix).linear_attn.A_log")
                names.insert("\(prefix).linear_attn.conv1d.weight")
                names.insert("\(prefix).linear_attn.dt_bias")
                names.insert("\(prefix).linear_attn.norm.weight")
                for projection in ["in_proj_a", "in_proj_b", "in_proj_qkv", "in_proj_z", "out_proj"] {
                    for suffix in quantizedProjectionNames {
                        names.insert("\(prefix).linear_attn.\(projection).\(suffix)")
                    }
                }
            }
        }

        return names
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

private enum Qwen35AssetValidationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return "Qwen model validation failed. " + message }
    }
}

struct ValidatedModelDirectory: Sendable {
    let location: URL
    let configURL: URL
    let processorConfigURL: URL
    let processorConfigFileName: String
    let weightFileNames: [String]
    let indexedWeightFileNames: [String]
    let indexedTensorNames: Set<String>
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
        var indexedTensorNames: Set<String> = []
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
            indexedTensorNames.formUnion(parsedIndex.weightMap.keys)
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
            indexedWeightFileNames: Array(Set(indexedWeightFileNames)).sorted(),
            indexedTensorNames: indexedTensorNames
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
