import Foundation
import XCTest
import MLXLMCommon
import Jinja
@testable import Yemma4

final class Qwen35AssetContractTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFixture()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func validate() throws {
        try Qwen35MLXSupport.validateAssetContract(ModelDirectoryValidator.validatedDirectory(at: directory))
    }

    func testPinnedImageTemplateRendersWithCurrentSwiftEngine() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chat_template", withExtension: "jinja", subdirectory: "Fixtures/Qwen35"))
        let template = try Template(String(contentsOf: url, encoding: .utf8))
        let rendered = try template.render([
            "messages": [
                ["role": "system", "content": "Be helpful."],
                ["role": "user", "content": [
                    ["type": "image"], ["type": "text", "text": "Describe this image."]
                ]]
            ],
            "add_generation_prompt": true,
            "enable_thinking": false
        ])
        XCTAssertTrue(rendered.contains("<|vision_start|><|image_pad|><|vision_end|>"))
        XCTAssertTrue(rendered.contains("Describe this image."))
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    func testTokenParserHidesReasoningAndKeepsAnswer() {
        var parser = Qwen35ResponseTokenParser(tokenizer: FixtureTokenizer())
        let output = [0, 2, 1, 3, 4].compactMap { parser.append(tokenID: $0) }.joined()
        XCTAssertEqual(output, "Answer")
    }

    func testTokenParserDoesNotExposeUnfinishedReasoning() {
        var parser = Qwen35ResponseTokenParser(tokenizer: FixtureTokenizer())
        XCTAssertEqual([0, 2].compactMap { parser.append(tokenID: $0) }.joined(), "")
    }

    func testCombinedVisionBundleAccepted() throws { XCTAssertNoThrow(try validate()) }

    func testTextOnlyWeightsRejectedEvenWithVisionConfigAndIndex() throws {
        try writeWeights(names: ["language_model.model.embed_tokens.weight"])
        XCTAssertThrowsError(try validate())
    }

    func testMissingVisionBlockRejected() throws {
        try writeWeights(names: Self.tensorNames.filter { $0 != "vision_tower.blocks.23.attn.qkv.weight" })
        XCTAssertThrowsError(try validate())
    }

    func testTruncatedWeightPayloadRejected() throws {
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("model.safetensors"))
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 1)
        try handle.close()
        XCTAssertThrowsError(try validate())
    }

    func testMissingFlatVisionProcessorRejected() throws {
        try FileManager.default.moveItem(at: directory.appendingPathComponent("preprocessor_config.json"),
                                        to: directory.appendingPathComponent("processor_config.json"))
        XCTAssertThrowsError(try validate())
    }

    func testTextOnlyEmbeddedTemplateRejected() throws {
        try Data(#"{"chat_template":"{{messages}}"}"#.utf8).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        XCTAssertThrowsError(try validate())
    }

    func testGemmaConfigRejected() throws {
        try Data(#"{"model_type":"gemma4"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try validate())
    }

    func testDownloadManifestIncludesVisionMetadataAndCombinedWeights() {
        for file in ["model.safetensors", "model.safetensors.index.json", "preprocessor_config.json", "chat_template.jinja", "tokenizer_config.json"] {
            XCTAssertTrue(Qwen35MLXSupport.downloadPatterns.contains(file))
        }
        XCTAssertEqual(InferenceRuntime.allCases, [.appleFoundationModel, .qwen35])
        // A previous Gemma selection cannot make old weights ready or start a Qwen download.
        XCTAssertEqual(InferenceRuntime.initialSelection(persistedValue: "gemma4", appleAvailability: .available), .appleFoundationModel)
    }

    func testPromptHasOneSystemMessageAndKeepsImage() throws {
        let suite = "qwen-input-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LLMService(defaults: defaults, appleAvailability: .available)
        let input = service.makeQwen35UserInput(from: [
            .init(role: "developer", content: "Extra instruction", imageURLs: []),
            .init(role: "user", content: "Describe", imageURLs: [URL(fileURLWithPath: "/tmp/image.jpg")])
        ])
        guard case .chat(let messages) = input.prompt else { return XCTFail("Expected structured chat") }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.contains("Extra instruction"))
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(input.images.count, 1)
        XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(input.processing.resize?.width, 768)
    }

    private func writeFixture() throws {
        try Data(Self.modelConfig.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(Self.processorConfig.utf8).write(to: directory.appendingPathComponent("preprocessor_config.json"))
        let template = "item.type == 'image' <|vision_start|><|image_pad|><|vision_end|> enable_thinking"
        try Data(template.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        try JSONSerialization.data(withJSONObject: ["chat_template": template]).write(to: directory.appendingPathComponent("tokenizer_config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try writeWeights(names: Self.tensorNames)
    }

    private func writeWeights(names: [String]) throws {
        let entries = Dictionary(uniqueKeysWithValues: names.enumerated().map { i, name in
            (name, ["dtype": "U8", "shape": [1], "data_offsets": [i, i + 1]] as [String: Any])
        })
        let header = try JSONSerialization.data(withJSONObject: entries)
        var length = UInt64(header.count).littleEndian
        var file = withUnsafeBytes(of: &length) { Data($0) }
        file.append(header)
        file.append(Data(repeating: 0, count: names.count))
        try file.write(to: directory.appendingPathComponent("model.safetensors"))
    }

    // Metadata from the pinned package; fixture payloads above remain tiny.
    private static let modelConfig = #"""
{
    "architectures": [
        "Qwen3_5ForConditionalGeneration"
    ],
    "eos_token_id": 248046,
    "image_token_id": 248056,
    "model_name": "unsloth/Qwen3.5-4B",
    "model_type": "qwen3_5",
    "pad_token_id": 248055,
    "quantization": {
        "group_size": 64,
        "bits": 4,
        "mode": "affine"
    },
    "quantization_config": {
        "group_size": 64,
        "bits": 4,
        "mode": "affine"
    },
    "text_config": {
        "attention_bias": false,
        "attention_dropout": 0.0,
        "attn_output_gate": true,
        "bos_token_id": null,
        "torch_dtype": "bfloat16",
        "eos_token_id": 248044,
        "full_attention_interval": 4,
        "head_dim": 256,
        "hidden_act": "silu",
        "hidden_size": 2560,
        "initializer_range": 0.02,
        "intermediate_size": 9216,
        "layer_types": [
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention",
            "linear_attention",
            "linear_attention",
            "linear_attention",
            "full_attention"
        ],
        "linear_conv_kernel_dim": 4,
        "linear_key_head_dim": 128,
        "linear_num_key_heads": 16,
        "linear_num_value_heads": 32,
        "linear_value_head_dim": 128,
        "mamba_ssm_dtype": "float32",
        "max_position_embeddings": 262144,
        "mlp_only_layers": [],
        "model_type": "qwen3_5_text",
        "mtp_num_hidden_layers": 1,
        "mtp_use_dedicated_embeddings": false,
        "num_attention_heads": 16,
        "num_hidden_layers": 32,
        "num_key_value_heads": 4,
        "pad_token_id": null,
        "partial_rotary_factor": 0.25,
        "rms_norm_eps": 1e-06,
        "rope_parameters": {
            "mrope_interleaved": true,
            "mrope_section": [
                11,
                11,
                10
            ],
            "partial_rotary_factor": 0.25,
            "rope_theta": 10000000,
            "rope_type": "default"
        },
        "tie_word_embeddings": true,
        "use_cache": true,
        "vocab_size": 248320
    },
    "tie_word_embeddings": true,
    "unsloth_fixed": true,
    "unsloth_version": "2026.3.3",
    "use_cache": false,
    "video_token_id": 248057,
    "vision_config": {
        "deepstack_visual_indexes": [],
        "depth": 24,
        "torch_dtype": "bfloat16",
        "hidden_act": "gelu_pytorch_tanh",
        "hidden_size": 1024,
        "in_channels": 3,
        "initializer_range": 0.02,
        "intermediate_size": 4096,
        "model_type": "qwen3_5",
        "num_heads": 16,
        "num_position_embeddings": 2304,
        "out_hidden_size": 2560,
        "patch_size": 16,
        "spatial_merge_size": 2,
        "temporal_patch_size": 2
    },
    "vision_end_token_id": 248054,
    "vision_start_token_id": 248053
}
"""#
    private static let processorConfig = #"""
{
  "data_format": "channels_first",
  "do_convert_rgb": true,
  "do_normalize": true,
  "do_rescale": true,
  "do_resize": true,
  "image_mean": [
    0.5,
    0.5,
    0.5
  ],
  "image_processor_type": "Qwen2VLImageProcessorFast",
  "image_std": [
    0.5,
    0.5,
    0.5
  ],
  "merge_size": 2,
  "patch_size": 16,
  "resample": 3,
  "rescale_factor": 0.00392156862745098,
  "size": {
    "max_pixels": 16777216,
    "min_pixels": 65536
  },
  "temporal_patch_size": 2,
  "processor_class": "Qwen3VLProcessor"
}

"""#
    private static let tensorNames: [String] = [
        "vision_tower.merger.linear_fc1.bias",
        "vision_tower.merger.linear_fc1.weight",
        "vision_tower.merger.linear_fc2.bias",
        "vision_tower.merger.linear_fc2.weight",
        "vision_tower.merger.norm.bias",
        "vision_tower.merger.norm.weight",
        "vision_tower.patch_embed.proj.bias",
        "vision_tower.patch_embed.proj.weight",
        "vision_tower.pos_embed.weight",
        "language_model.model.embed_tokens.weight",
    ] + (0..<24).flatMap { block in
        [
            "attn.proj.bias",
            "attn.proj.weight",
            "attn.qkv.bias",
            "attn.qkv.weight",
            "mlp.linear_fc1.bias",
            "mlp.linear_fc1.weight",
            "mlp.linear_fc2.bias",
            "mlp.linear_fc2.weight",
            "norm1.bias",
            "norm1.weight",
            "norm2.bias",
            "norm2.weight",
        ].map { "vision_tower.blocks.\(block).\($0)" }
    }
}

private struct FixtureTokenizer: MLXLMCommon.Tokenizer {
    let vocabulary = ["<think>", "</think>", "private reasoning", "Answer", "<|im_end|>"]
    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { vocabulary.firstIndex(of: text).map { [$0] } ?? [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { vocabulary[$0] }.joined() }
    func convertTokenToId(_ token: String) -> Int? { vocabulary.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { vocabulary[id] }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}
