import Foundation

/// Stateless token sanitization for streamed LLM output.
///
/// Extracts all control-marker stripping, boundary detection, and thinking-block
/// removal so that ChatView (and tests) can rely on a single, pure-function pipeline.
struct StreamingRenderer: Sendable {

    // MARK: - Marker Tables

    private static let controlMarkers = [
        "<start_of_turn>",
        "<end_of_turn>",
        "<|start_of_turn|>",
        "<|end_of_turn|>",
        "<|turn>",
        "<turn|>",
        "<|channel>",
        "<channel|>",
        "<|think|>",
        "<|tool>",
        "<tool|>",
        "<|tool_call>",
        "<tool_call|>",
        "<|tool_response>",
        "<tool_response|>",
        "<eos>",
        "<bos>"
    ]

    private static let responseBoundaryMarkers = [
        "<end_of_turn>",
        "<|end_of_turn|>",
        "<turn|>",
        "<start_of_turn>user",
        "<|start_of_turn|>user",
        "<|turn>user",
        "<|turn>system"
    ]

    private static let rolePrefixes = [
        "model\n",
        "assistant\n",
        "user\n",
        "system\n",
        "<|turn>model\n",
        "<|turn>assistant\n",
        "<|turn>user\n",
        "<|turn>system\n",
        "<start_of_turn>model\n",
        "<start_of_turn>assistant\n",
        "<start_of_turn>user\n",
        "<|start_of_turn|>model\n",
        "<|start_of_turn|>assistant\n",
        "<|start_of_turn|>user\n"
    ]

    // MARK: - Public API

    /// Optimized version that only checks the tail of the string.
    /// Boundary markers are short (<30 chars), so checking the last ~100 chars suffices
    /// for the streaming hot path where tokens are appended incrementally.
    static func shouldStopStreaming(tailOf text: String) -> Bool {
        let checkLength = 100
        let tail: Substring
        if text.count > checkLength {
            tail = text.suffix(checkLength)
        } else {
            tail = text[...]
        }
        return responseBoundaryMarkers.contains { tail.contains($0) }
    }

    /// Full sanitization pipeline applied each time the visible text is refreshed.
    ///
    /// Order of operations:
    /// 1. Strip leading control preamble (role prefixes + whitespace, looped until stable)
    /// 2. Remove thinking/channel blocks
    /// 3. Truncate at the first response boundary marker
    /// 4. Replace all remaining control markers with empty string
    /// 5. Strip a leading role prefix (post-marker-removal)
    /// 6. Trim any partial control marker at the trailing edge
    /// 7. Trim surrounding whitespace
    static func sanitize(_ text: String) -> String {
        var cleaned = stripLeadingControlPreamble(from: text)
        cleaned = stripThinkingBlocks(from: cleaned)

        if let firstMarkerRange = firstBoundaryMarkerRange(in: cleaned) {
            cleaned = String(cleaned[..<firstMarkerRange.lowerBound])
        }

        for marker in controlMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }

        cleaned = stripLeadingRolePrefix(from: cleaned)
        cleaned = trimTrailingControlPrefix(from: cleaned)
        cleaned = normalizeMarkdownFriendlySymbols(in: cleaned)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Final pass applied once streaming is complete. Currently identical to `sanitize`.
    static func finalize(_ text: String) -> String {
        sanitize(text)
    }

    /// Streaming-only pass that keeps the trailing in-progress fragment off screen
    /// until a word or punctuation boundary lands. This reduces reflow flicker at
    /// line endings while the next word is still arriving token-by-token.
    static func streamingVisibleText(_ text: String) -> String {
        trimTrailingUnstableFragment(from: sanitize(text))
    }

    static func isStandaloneStreamingUnit(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            if scalar.properties.isEmojiPresentation || scalar.properties.generalCategory == .otherSymbol {
                return true
            }

            return standaloneStreamingScalarRanges.contains { $0.contains(scalar.value) }
        }
    }

    // MARK: - Pipeline Steps

    /// Repeatedly strips a leading role prefix and trims whitespace until the
    /// string stabilises. Handles cases where the model emits multiple preamble
    /// tokens before actual content (e.g. `"model\n  assistant\n Hello"`).
    static func stripLeadingControlPreamble(from text: String) -> String {
        var cleaned = text

        while true {
            let updated = stripLeadingRolePrefix(from: cleaned)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if updated == cleaned {
                return cleaned
            }

            cleaned = updated
        }
    }

    /// Removes `<|channel>...<channel|>` thinking blocks. If an opening tag has
    /// no matching close tag the remainder of the string is removed (the block
    /// is still being streamed).
    static func stripThinkingBlocks(from text: String) -> String {
        guard text.contains("<|channel>") else {
            return text
        }

        var cleaned = text

        while let startRange = cleaned.range(of: "<|channel>") {
            if let endRange = cleaned.range(of: "<channel|>", range: startRange.upperBound..<cleaned.endIndex) {
                cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                cleaned.removeSubrange(startRange.lowerBound..<cleaned.endIndex)
                break
            }
        }

        return cleaned
    }

    /// Strips a single leading role prefix (e.g. `"model\n"`, `"<start_of_turn>assistant\n"`).
    static func stripLeadingRolePrefix(from text: String) -> String {
        for prefix in rolePrefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// Returns the range of the first response boundary marker found in `text`,
    /// or `nil` if none is present.
    static func firstBoundaryMarkerRange(in text: String) -> Range<String.Index>? {
        responseBoundaryMarkers
            .compactMap { marker in text.range(of: marker) }
            .min(by: { $0.lowerBound < $1.lowerBound })
    }

    /// Trims a partial control marker that may be accumulating at the end of the
    /// streamed text. For example if the model has emitted `"Hello<start_of_tu"`
    /// the incomplete tag is removed so it doesn't flash on screen.
    static func trimTrailingControlPrefix(from text: String) -> String {
        guard !text.isEmpty else { return text }

        for marker in controlMarkers {
            guard marker.count > 1 else { continue }

            for prefixLength in stride(from: marker.count - 1, through: 1, by: -1) {
                let prefix = String(marker.prefix(prefixLength))
                if text.hasSuffix(prefix) {
                    return String(text.dropLast(prefixLength))
                }
            }
        }

        return text
    }

    private static func normalizeMarkdownFriendlySymbols(in text: String) -> String {
        text
            .replacingOccurrences(of: "$\\rightarrow$", with: " -> ")
            .replacingOccurrences(of: "$\\Rightarrow$", with: " => ")
            .replacingOccurrences(of: "\\rightarrow", with: "->")
            .replacingOccurrences(of: "\\Rightarrow", with: "=>")
    }

    private static func trimTrailingUnstableFragment(from text: String) -> String {
        guard let lastCharacter = text.last else { return text }
        guard !isStableStreamingBoundary(lastCharacter) else { return text }
        guard !isStandaloneStreamingUnit(lastCharacter) else { return text }

        guard let boundaryIndex = text.lastIndex(where: {
            isStableStreamingBoundary($0) || isStandaloneStreamingUnit($0)
        }) else {
            return text
        }

        let stablePrefix = String(text[...boundaryIndex])
        return stablePrefix.trimmingCharacters(in: .whitespaces)
    }

    private static func isStableStreamingBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline {
            return true
        }

        return ".,!?;:)]}\"'".contains(character)
    }

    private static let standaloneStreamingScalarRanges: [ClosedRange<UInt32>] = [
        0x1100...0x11FF,
        0x3040...0x30FF,
        0x3130...0x318F,
        0x31F0...0x31FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xAC00...0xD7AF,
        0xF900...0xFAFF,
        0xFF66...0xFF9D,
        0x20000...0x2A6DF,
        0x2A700...0x2B73F,
        0x2B740...0x2B81F,
        0x2B820...0x2CEAF,
        0x2CEB0...0x2EBEF,
        0x30000...0x3134F
    ]
}

struct StreamingRenderUpdate: Sendable {
    let visibleText: String?
    let shouldStop: Bool
    let didAdvance: Bool
}

/// Shared flush policy for streamed assistant text.
///
/// Keeps the hot path light by only sanitizing when a visible update is likely
/// to improve the transcript: after a short cadence interval, at a word or
/// punctuation boundary, or once enough raw characters have accumulated.
struct StreamingUpdatePolicy: Sendable {
    private struct FlushCadence {
        let generalInterval: Duration
        let boundaryInterval: Duration
        let minimumInterval: Duration
        let rawCharacterThreshold: Int
    }

    private(set) var rawText = ""

    private var lastFlush = ContinuousClock.now
    private var lastRenderedRawCount = 0
    private var lastVisibleText = ""

    mutating func append(_ token: String, now: ContinuousClock.Instant = ContinuousClock.now) -> StreamingRenderUpdate {
        rawText.append(token)

        let shouldStop = StreamingRenderer.shouldStopStreaming(tailOf: rawText)
        let elapsed = now - lastFlush
        let rawDelta = rawText.count - lastRenderedRawCount
        let cadence = flushCadence(for: rawText.count)
        let endsClause = token.last.map { ".!?,:;)\n".contains($0) } ?? false
        let atWordBoundary =
            token.last?.isWhitespace == true
            || endsClause
            || token.last.map(StreamingRenderer.isStandaloneStreamingUnit) == true
        let shouldFlush =
            shouldStop
            || elapsed >= cadence.generalInterval
            || (atWordBoundary && elapsed >= cadence.boundaryInterval)
            || (rawDelta >= cadence.rawCharacterThreshold && elapsed >= cadence.minimumInterval)

        guard shouldFlush else {
            return StreamingRenderUpdate(visibleText: nil, shouldStop: shouldStop, didAdvance: false)
        }

        let visibleText = shouldStop
            ? StreamingRenderer.finalize(rawText)
            : StreamingRenderer.streamingVisibleText(rawText)
        let didAdvance = visibleText != lastVisibleText

        lastFlush = now
        lastRenderedRawCount = rawText.count
        lastVisibleText = visibleText

        return StreamingRenderUpdate(
            visibleText: didAdvance ? visibleText : nil,
            shouldStop: shouldStop,
            didAdvance: didAdvance
        )
    }

    func finalize() -> String {
        StreamingRenderer.finalize(rawText)
    }

    private func flushCadence(for rawCharacterCount: Int) -> FlushCadence {
        switch rawCharacterCount {
        case ..<600:
            return FlushCadence(
                generalInterval: .milliseconds(70),
                boundaryInterval: .milliseconds(28),
                minimumInterval: .milliseconds(22),
                rawCharacterThreshold: 32
            )
        case ..<1400:
            return FlushCadence(
                generalInterval: .milliseconds(84),
                boundaryInterval: .milliseconds(34),
                minimumInterval: .milliseconds(28),
                rawCharacterThreshold: 48
            )
        default:
            return FlushCadence(
                generalInterval: .milliseconds(104),
                boundaryInterval: .milliseconds(42),
                minimumInterval: .milliseconds(34),
                rawCharacterThreshold: 72
            )
        }
    }
}
