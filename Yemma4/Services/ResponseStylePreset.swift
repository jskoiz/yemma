import Foundation

enum ResponseStylePreset: String, CaseIterable, Identifiable, Sendable {
    case focused
    case balanced
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focused:
            return "Focused"
        case .balanced:
            return "Balanced"
        case .detailed:
            return "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .focused:
            return "Brief, direct answers."
        case .balanced:
            return "Clear answers, light context."
        case .detailed:
            return "More depth when useful."
        }
    }

    var temperature: Double {
        switch self {
        case .focused:
            return 0.3
        case .balanced:
            return 0.6
        case .detailed:
            return 0.8
        }
    }

    var maxResponseTokens: Int {
        switch self {
        case .focused:
            return 256
        case .balanced:
            return 512
        case .detailed:
            return 1024
        }
    }

    var instructionPrompt: String {
        switch self {
        case .focused:
            return """
                Response style: Focused.
                Prioritize brevity and directness.
                Give the answer first.
                Prefer one short paragraph.
                Do not include filler, repetition, background, caveats, or extra suggestions unless necessary.
                """
        case .balanced:
            return """
                Response style: Balanced.
                Be clear and moderately concise.
                Give the answer first, then brief explanation if helpful.
                Avoid repetition and unnecessary filler.
                """
        case .detailed:
            return """
                Response style: Detailed.
                Be thorough and well-structured.
                Give the answer first, then explain context, tradeoffs, and important caveats when helpful.
                Use sections or lists only when they improve clarity.
                Do not be verbose for its own sake.
                """
        }
    }

    var lengthTargetPrompt: String {
        switch self {
        case .focused:
            return """
                Length target: 30 to 80 words unless the user explicitly asks for more detail.
                Format: Start with the direct answer. Add at most one short clarification if needed. Stop once the answer is sufficient.
                """
        case .balanced:
            return """
                Length target: 80 to 180 words unless the user explicitly asks for more detail.
                Format: Answer first, then brief explanation if helpful. Prefer 1 to 3 short paragraphs.
                """
        case .detailed:
            return """
                Length target: usually 180 to 400 words when extra detail helps.
                Format: Answer first, then add context, reasoning, tradeoffs, and caveats as needed. Exceed this only when the user clearly asks for depth.
                """
        }
    }

    static func matching(temperature: Double, maxResponseTokens: Int) -> Self? {
        allCases.first { preset in
            abs(preset.temperature - temperature) < 0.05
                && preset.maxResponseTokens == maxResponseTokens
        }
    }
}
