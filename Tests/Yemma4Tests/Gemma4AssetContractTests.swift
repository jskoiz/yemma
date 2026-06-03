import Foundation
import XCTest
@testable import Yemma4

final class Gemma4AssetContractTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Gemma4AssetContractTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A model `config.json` whose token ids and vision soft-token budget line up
    /// with the processor fixture below.
    private func writeModelConfig(
        softTokens: Int = 256,
        defaultOutputLength: Int = 256,
        imageTokenId: Int = 262_144,
        boiTokenId: Int = 255_999,
        eoiTokenId: Int? = 256_000,
        includePadTokenID: Bool = true
    ) throws -> URL {
        var config: [String: Any] = [
            "vision_config": ["default_output_length": defaultOutputLength],
            "image_token_id": imageTokenId,
            "boi_token_id": boiTokenId,
            "vision_soft_tokens_per_image": softTokens,
        ]
        if let eoiTokenId {
            config["eoi_token_id"] = eoiTokenId
        }
        if includePadTokenID {
            config["pad_token_id"] = 0
        }
        let url = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        return url
    }

    private func writeProcessorConfig(
        imageSeqLength: Int = 256,
        imageTokenId: Int = 262_144,
        boiTokenId: Int = 255_999,
        eoiTokenId: Int? = 256_000
    ) throws -> URL {
        var config: [String: Any] = [
            "processor_class": "Gemma4Processor",
            "image_seq_length": imageSeqLength,
            "image_token_id": imageTokenId,
            "boi_token_id": boiTokenId,
        ]
        if let eoiTokenId {
            config["eoi_token_id"] = eoiTokenId
        }
        let url = directory.appendingPathComponent("preprocessor_config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        return url
    }

    private func makeValidatedDirectory(
        configURL: URL,
        processorConfigURL: URL
    ) -> ValidatedModelDirectory {
        ValidatedModelDirectory(
            location: directory,
            configURL: configURL,
            processorConfigURL: processorConfigURL,
            processorConfigFileName: processorConfigURL.lastPathComponent,
            weightFileNames: ["model.safetensors"],
            indexedWeightFileNames: []
        )
    }

    // MARK: - Passing contract

    func testValidateAssetContractAcceptsConsistentBundle() throws {
        let configURL = try writeModelConfig()
        let processorConfigURL = try writeProcessorConfig()
        let validated = makeValidatedDirectory(
            configURL: configURL,
            processorConfigURL: processorConfigURL
        )

        XCTAssertNoThrow(try Gemma4MLXSupport.validateAssetContract(validated))
    }

    // MARK: - Failing contract

    func testValidateAssetContractRejectsSoftTokenMismatch() throws {
        // Processor advertises a different soft-token budget than the model.
        let configURL = try writeModelConfig(softTokens: 256, defaultOutputLength: 256)
        let processorConfigURL = try writeProcessorConfig(imageSeqLength: 128)
        let validated = makeValidatedDirectory(
            configURL: configURL,
            processorConfigURL: processorConfigURL
        )

        XCTAssertThrowsError(try Gemma4MLXSupport.validateAssetContract(validated))
    }

    func testValidateAssetContractRejectsImageTokenIdMismatch() throws {
        let configURL = try writeModelConfig(imageTokenId: 262_144)
        let processorConfigURL = try writeProcessorConfig(imageTokenId: 111_111)
        let validated = makeValidatedDirectory(
            configURL: configURL,
            processorConfigURL: processorConfigURL
        )

        XCTAssertThrowsError(try Gemma4MLXSupport.validateAssetContract(validated))
    }

    // MARK: - Config normalization

    func testNormalizeInjectsMissingPadTokenID() throws {
        let configURL = try writeModelConfig(includePadTokenID: false)
        let processorConfigURL = try writeProcessorConfig()
        let validated = makeValidatedDirectory(
            configURL: configURL,
            processorConfigURL: processorConfigURL
        )

        let didNormalize = try Gemma4MLXSupport.normalizeAssetContractIfNeeded(validated)
        XCTAssertTrue(didNormalize)

        let normalized = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any]
        XCTAssertNotNil(normalized?["pad_token_id"])

        // Second pass is a no-op once the key is present.
        let didNormalizeAgain = try Gemma4MLXSupport.normalizeAssetContractIfNeeded(validated)
        XCTAssertFalse(didNormalizeAgain)
    }
}
