import Foundation
import MLX
import MLXLMCommon

final class Qwen35HiddenChannelBudgetProcessor: LogitProcessor, @unchecked Sendable {
    private var baseProcessor: LogitProcessor?
    private let channelStartTokenID: Int?
    private let channelEndTokenID: Int?
    private let hiddenChannelTokenBudget: Int

    private var isInsideHiddenChannel = false
    private var hiddenChannelTokenCount = 0

    init(
        tokenizer: any MLXLMCommon.Tokenizer,
        hiddenChannelTokenBudget: Int,
        baseProcessor: LogitProcessor? = nil
    ) {
        self.baseProcessor = baseProcessor
        self.channelStartTokenID = tokenizer.convertTokenToId("<think>")
        self.channelEndTokenID = tokenizer.convertTokenToId("</think>")
        self.hiddenChannelTokenBudget = hiddenChannelTokenBudget
    }

    func prompt(_ prompt: MLXArray) {
        resetState()
        baseProcessor?.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        let processedLogits = baseProcessor?.process(logits: logits) ?? logits

        let vocabularySize = processedLogits.shape.last ?? 0
        guard let forcedValues = forcedChannelEndLogits(vocabularySize: vocabularySize) else {
            return processedLogits
        }

        return MLXArray(forcedValues)
            .reshaped(processedLogits.shape)
            .asType(processedLogits.dtype)
    }

    func didSample(token: MLXArray) {
        let tokenID = token.item(Int.self)

        defer {
            baseProcessor?.didSample(token: token)
        }

        didSample(tokenID: tokenID)
    }

    func resetState() {
        isInsideHiddenChannel = false
        hiddenChannelTokenCount = 0
    }

    private func didSample(tokenID: Int) {
        guard let channelStartTokenID, let channelEndTokenID else {
            return
        }

        if tokenID == channelStartTokenID {
            isInsideHiddenChannel = true
            hiddenChannelTokenCount = 0
            return
        }

        guard isInsideHiddenChannel else {
            return
        }

        if tokenID == channelEndTokenID {
            isInsideHiddenChannel = false
            hiddenChannelTokenCount = 0
            return
        }

        hiddenChannelTokenCount += 1
    }

    private func forcedChannelEndLogits(vocabularySize: Int) -> [Float]? {
        guard isInsideHiddenChannel,
            hiddenChannelTokenCount >= hiddenChannelTokenBudget,
            let channelEndTokenID,
            vocabularySize > channelEndTokenID
        else {
            return nil
        }

        var forcedValues = Array(repeating: Float(-1_000_000), count: vocabularySize)
        forcedValues[channelEndTokenID] = 0
        return forcedValues
    }
}

private struct SpecialTokenSkippingDetokenizer {
    private let tokenizer: any MLXLMCommon.Tokenizer
    private var segmentTokens = [Int]()
    private var segment = ""

    init(tokenizer: any MLXLMCommon.Tokenizer) {
        self.tokenizer = tokenizer
    }

    mutating func append(token: Int) {
        segmentTokens.append(token)
    }

    mutating func next() -> String? {
        let newSegment = tokenizer.decode(tokenIds: segmentTokens, skipSpecialTokens: true)
        let previousUTF8 = Array(segment.utf8)
        let newUTF8 = Array(newSegment.utf8)

        guard newUTF8.count >= previousUTF8.count else {
            segment = newSegment
            return nil
        }

        // String.count measures extended grapheme clusters, not the decoded
        // byte/scalar prefix. A combining mark or a ZWJ can leave that count
        // unchanged while still adding visible content. Decode the delta from
        // the UTF-8 prefix instead, which keeps the operation boundary-safe.
        guard newUTF8.starts(with: previousUTF8) else {
            // The tokenizer can occasionally revise an incomplete token. Do
            // not invent a suffix or duplicate the revised prefix; wait for a
            // subsequent cumulative decode that is append-only again.
            segment = newSegment
            return nil
        }

        let new = String(decoding: newUTF8.dropFirst(previousUTF8.count), as: UTF8.self)
        if new.last == "\u{fffd}" {
            return nil
        }

        if new.hasSuffix("\n") {
            startNewSegment()
        } else {
            segment = newSegment
        }

        return new.isEmpty ? nil : String(new)
    }

    private mutating func startNewSegment() {
        let lastToken = segmentTokens.last
        segmentTokens.removeAll()
        if let lastToken {
            segmentTokens.append(lastToken)
            segment = tokenizer.decode(tokenIds: segmentTokens, skipSpecialTokens: true)
        } else {
            segment = ""
        }
    }
}

struct Qwen35ResponseTokenParser {
    private enum State {
        case normal
        case suppressing(untilTokenID: Int)
    }

    private static let suppressedBlocks = [
        ("<think>", "</think>"),
        ("<tool_call>", "</tool_call>"),
        ("<tool_response>", "</tool_response>"),
    ]

    private static let oneShotControlTokens = [
        "<|im_start|>", "<|im_end|>", "<|endoftext|>",
        "<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>", "</think>"
    ]

    private let tokenizer: any MLXLMCommon.Tokenizer
    private let suppressedBlockTokenIDs: [Int: Int]
    private let oneShotControlTokenIDs: Set<Int>
    private var state = State.normal
    private var detokenizer: SpecialTokenSkippingDetokenizer
    private var tokenPreview: [String] = []
    private(set) var totalTokenCount = 0
    private(set) var visibleChunkCount = 0
    private(set) var visibleCharacterCount = 0

    init(tokenizer: any MLXLMCommon.Tokenizer) {
        self.tokenizer = tokenizer
        self.detokenizer = SpecialTokenSkippingDetokenizer(tokenizer: tokenizer)
        self.suppressedBlockTokenIDs = Dictionary(
            uniqueKeysWithValues: Self.suppressedBlocks.compactMap { start, end in
                guard
                    let startID = tokenizer.convertTokenToId(start),
                    let endID = tokenizer.convertTokenToId(end)
                else {
                    return nil
                }
                return (startID, endID)
            }
        )
        self.oneShotControlTokenIDs = Set(
            Self.oneShotControlTokens.compactMap { tokenizer.convertTokenToId($0) }
        )
    }

    mutating func append(tokenID: Int) -> String? {
        totalTokenCount += 1

        if tokenPreview.count < 24 {
            tokenPreview.append(Self.describeToken(tokenID, tokenizer: tokenizer))
        }

        switch state {
        case .normal:
            if let endTokenID = suppressedBlockTokenIDs[tokenID] {
                state = .suppressing(untilTokenID: endTokenID)
                return nil
            }

            if oneShotControlTokenIDs.contains(tokenID) {
                return nil
            }

            detokenizer.append(token: tokenID)
            guard let chunk = detokenizer.next(), !chunk.isEmpty else {
                return nil
            }

            visibleChunkCount += 1
            visibleCharacterCount += chunk.count
            return chunk

        case let .suppressing(untilTokenID):
            if tokenID == untilTokenID {
                state = .normal
            }
            return nil
        }
    }

    var tokenPreviewSummary: String {
        tokenPreview.joined(separator: " | ")
    }

    private static func describeToken(
        _ tokenID: Int,
        tokenizer: any MLXLMCommon.Tokenizer
    ) -> String {
        let raw = tokenizer.convertIdToToken(tokenID)
            ?? tokenizer.decode(tokenIds: [tokenID], skipSpecialTokens: false)
        let cleaned = tokenizer.decode(tokenIds: [tokenID], skipSpecialTokens: true)
        let rawText = sanitizedTokenText(raw)
        let cleanedText = sanitizedTokenText(cleaned)
        if rawText == cleanedText {
            return "\(tokenID) '\(rawText)'"
        }
        return "\(tokenID) raw='\(rawText)' clean='\(cleanedText)'"
    }

    private static func sanitizedTokenText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return normalized.isEmpty ? "<empty>" : normalized
    }
}
