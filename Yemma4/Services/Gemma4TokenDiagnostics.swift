import Foundation
import MLX
import MLXLMCommon

struct FirstTokenCandidate: Sendable {
    let tokenID: Int
    let logit: Float
    let rawDecoded: String
    let cleanedDecoded: String
}

struct FirstTokenTrace: Sendable {
    let sampledTokenID: Int
    let sampledRawDecoded: String
    let sampledCleanedDecoded: String
    let candidates: [FirstTokenCandidate]
}

enum Gemma4TokenDiagnostics {
    static func formatLogit(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    static func summarizeFirstTokenTrace(_ trace: FirstTokenTrace) -> String {
        let sampledDescription = describeFirstTokenCandidate(
            tokenID: trace.sampledTokenID,
            rawDecoded: trace.sampledRawDecoded,
            cleanedDecoded: trace.sampledCleanedDecoded
        )
        let candidates = trace.candidates.map { candidate in
            "\(candidate.tokenID):\(formatLogit(candidate.logit)):\(describeFirstTokenCandidate(tokenID: candidate.tokenID, rawDecoded: candidate.rawDecoded, cleanedDecoded: candidate.cleanedDecoded))"
        }.joined(separator: " | ")
        return "sample=\(sampledDescription) topK=[\(candidates)]"
    }

    static func computeFirstTokenTrace(
        context: ModelContext,
        input: LMInput,
        parameters: GenerateParameters,
        processorOverride: LogitProcessor? = nil,
        topK: Int = 5
    ) throws -> FirstTokenTrace {
        var processor = processorOverride ?? parameters.processor()
        processor?.prompt(input.text.tokens)

        let cache = context.model.newCache(parameters: parameters)
        let prepared = try context.model.prepare(
            input,
            cache: cache,
            windowSize: parameters.prefillStepSize
        )

        let logits: MLXArray
        switch prepared {
        case .logits(let output):
            logits = output.logits
        case .tokens(let tokens):
            let output = context.model(
                tokens[text: .newAxis],
                cache: cache.isEmpty ? nil : cache,
                state: nil
            )
            logits = output.logits
        }

        var nextTokenLogits = logits[0..., -1, 0...]
        nextTokenLogits = processor?.process(logits: nextTokenLogits) ?? nextTokenLogits

        let sampler = parameters.sampler()
        let sampledToken = sampler.sample(logits: nextTokenLogits)
        processor?.didSample(token: sampledToken)

        let sampledTokenID = sampledToken.item(Int.self)
        let sampledRawDecoded = context.tokenizer.decode(
            tokenIds: [sampledTokenID],
            skipSpecialTokens: false
        )
        let sampledCleanedDecoded = context.tokenizer.decode(
            tokenIds: [sampledTokenID],
            skipSpecialTokens: true
        )

        let vocabularySize = nextTokenLogits.dim(-1)
        let candidateCount = Swift.max(1, Swift.min(topK, vocabularySize))
        var indices = argPartition(-nextTokenLogits, kth: candidateCount - 1, axis: -1)[
            .ellipsis, ..<candidateCount
        ]
        var values = takeAlong(nextTokenLogits, indices, axis: -1)
        let order = argSort(-values, axis: -1)
        indices = takeAlong(indices, order, axis: -1)
        values = takeAlong(values, order, axis: -1)
        eval(indices, values)

        let tokenIDs = indices.flattened().asArray(Int.self)
        let logitsValues = values.flattened().asArray(Float.self)
        let candidates = zip(tokenIDs, logitsValues).map { tokenID, logit in
            FirstTokenCandidate(
                tokenID: tokenID,
                logit: logit,
                rawDecoded: context.tokenizer.decode(
                    tokenIds: [tokenID],
                    skipSpecialTokens: false
                ),
                cleanedDecoded: context.tokenizer.decode(
                    tokenIds: [tokenID],
                    skipSpecialTokens: true
                )
            )
        }

        return FirstTokenTrace(
            sampledTokenID: sampledTokenID,
            sampledRawDecoded: sampledRawDecoded,
            sampledCleanedDecoded: sampledCleanedDecoded,
            candidates: candidates
        )
    }

    static func describeFirstTokenCandidate(
        tokenID: Int,
        rawDecoded: String,
        cleanedDecoded: String
    ) -> String {
        let raw = sanitizedTokenText(rawDecoded)
        let cleaned = sanitizedTokenText(cleanedDecoded)
        if raw == cleaned {
            return "\(tokenID) '\(raw)'"
        }
        return "\(tokenID) raw='\(raw)' clean='\(cleaned)'"
    }

    static func sanitizedTokenText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

}
