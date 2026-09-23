import Foundation

enum PromptTaskHint: String, Sendable {
    case rewrite
    case summarize
    case recommendation
    case coding

    var instructionPrompt: String {
        switch self {
        case .rewrite:
            return """
                Task hint: Rewrite.
                Return the revised text only unless the user explicitly asks for explanation, commentary, or alternatives.
                Keep the original intent and tone constraints intact.
                """
        case .summarize:
            return """
                Task hint: Summarize.
                Start with a short summary first.
                Keep only the essential points and do not add new information.
                """
        case .recommendation:
            return """
                Task hint: Recommendation.
                Give the direct recommendation first, then one brief reason why.
                Mention tradeoffs only if they are important to making the choice.
                """
        case .coding:
            return """
                Task hint: Coding.
                Give the fix, code, or diagnosis first.
                Keep explanation brief unless the user explicitly asks for more detail.
                """
        }
    }
}

extension PromptTaskHint {
    static func classify(_ prompt: String) -> PromptTaskHint? {
        let normalizedPrompt = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedPrompt.isEmpty else { return nil }

        if looksLikeRewriteTask(normalizedPrompt) {
            return .rewrite
        }

        if looksLikeSummarizeTask(normalizedPrompt) {
            return .summarize
        }

        if looksLikeCodingTask(normalizedPrompt) {
            return .coding
        }

        if looksLikeRecommendationTask(normalizedPrompt) {
            return .recommendation
        }

        return nil
    }

    static func looksLikeRewriteTask(_ prompt: String) -> Bool {
        let rewriteIndicators = [
            "rewrite",
            "rephrase",
            "revise",
            "edit this",
            "polish this",
            "improve this writing",
            "make this sound",
            "fix grammar",
            "rewrite this",
            "rewrite my",
            "rewrite the",
        ]

        guard containsAny(rewriteIndicators, in: prompt) else { return false }
        return !looksLikeCodingTask(prompt)
    }

    static func looksLikeSummarizeTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "summarize",
                "summary",
                "tl;dr",
                "tldr",
                "condense",
                "brief summary",
                "short summary",
            ],
            in: prompt
        )
    }

    static func looksLikeRecommendationTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "should i",
                "what should i",
                "which should i",
                "which one should i",
                "recommend",
                "recommendation",
                "best option",
                "best way",
                "which is better",
                "worth it",
                "advice",
                "pick one",
            ],
            in: prompt
        )
    }

    static func looksLikeCodingTask(_ prompt: String) -> Bool {
        containsAny(
            [
                "code",
                "bug",
                "debug",
                "stack trace",
                "exception",
                "compiler",
                "compile",
                "xcode",
                "swift",
                "python",
                "javascript",
                "typescript",
                "react",
                "sql",
                "function",
                "class",
                "error",
                "crash",
                "fix this code",
                "why is my code",
            ],
            in: prompt
        )
    }

    static func containsAny(_ candidates: [String], in prompt: String) -> Bool {
        candidates.contains { prompt.contains($0) }
    }

}
