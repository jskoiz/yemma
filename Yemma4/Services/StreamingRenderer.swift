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

    /// Returns `true` when the accumulated text contains a response boundary marker,
    /// indicating the model has started a new turn and streaming should stop.
    static func shouldStopStreaming(for text: String) -> Bool {
        responseBoundaryMarkers.contains { text.contains($0) }
    }

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

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Final pass applied once streaming is complete. Currently identical to `sanitize`.
    static func finalize(_ text: String) -> String {
        sanitize(text)
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
}
