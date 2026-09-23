import XCTest
@testable import Yemma4

final class StreamingRendererTests: XCTestCase {
    func testQwenThinkingAndTurnBoundaries() {
        XCTAssertEqual(StreamingRenderer.sanitize("<think>hidden reasoning</think>Hello<|im_end|>"), "Hello")
        XCTAssertEqual(StreamingRenderer.sanitize("<think>unfinished reasoning"), "")
        XCTAssertTrue(StreamingRenderer.shouldStopStreaming(tailOf: "Hello<|im_end|>"))
    }

    func testSanitizeRemovesControlMarkersAndThinkingBlocks() {
        let raw = "<start_of_turn>model\n<|channel>thinking<channel|>Hello<end_of_turn>user"

        XCTAssertEqual(StreamingRenderer.sanitize(raw), "Hello")
    }

    func testStreamingVisibleTextAndStopDetection() {
        XCTAssertEqual(StreamingRenderer.streamingVisibleText("Hello wor"), "Hello")
        XCTAssertTrue(StreamingRenderer.shouldStopStreaming(tailOf: "prefix <|end_of_turn|>"))
        XCTAssertFalse(StreamingRenderer.shouldStopStreaming(tailOf: "prefix Hello"))
    }

    func testStopDetectionOnlyUsesTheBoundedTail() {
        let marker = "<end_of_turn>"

        XCTAssertTrue(
            StreamingRenderer.shouldStopStreaming(
                tailOf: String(repeating: "a", count: 90) + marker
            )
        )
        XCTAssertFalse(
            StreamingRenderer.shouldStopStreaming(
                tailOf: marker + String(repeating: "a", count: 100)
            )
        )
    }

    func testUpdatePolicyTracksGraphemesAcrossTokenBoundaries() {
        var policy = StreamingUpdatePolicy()
        let tokens = [
            "Hello Cafe",
            "\u{301}",
            " ",
            "🌺",
            " ",
            "👨",
            "\u{200D}",
            "👩",
            "\u{200D}",
            "👧",
            "\u{200D}",
            "👦",
        ]
        let expected = tokens.joined()
        let firstUpdate = ContinuousClock.now.advanced(by: .seconds(1))

        for (index, token) in tokens.enumerated() {
            _ = policy.append(
                token,
                now: firstUpdate.advanced(by: .milliseconds(index * 100))
            )
        }

        XCTAssertEqual(policy.rawText, expected)
        XCTAssertEqual(policy.rawCharacterCount, expected.count)
        XCTAssertEqual(policy.finalize(), expected)
    }

    func testUpdatePolicyPreservesStopAndFinalFlushBehavior() {
        var policy = StreamingUpdatePolicy()
        let firstUpdate = ContinuousClock.now.advanced(by: .seconds(1))

        let initialUpdate = policy.append("Hello 🌺", now: firstUpdate)
        let stopUpdate = policy.append(
            "<|end_of_turn|>",
            now: firstUpdate.advanced(by: .milliseconds(100))
        )

        XCTAssertTrue(initialUpdate.didAdvance)
        XCTAssertEqual(initialUpdate.visibleText, "Hello 🌺")
        XCTAssertTrue(stopUpdate.shouldStop)
        XCTAssertFalse(stopUpdate.didAdvance)
        XCTAssertNil(stopUpdate.visibleText)
        XCTAssertEqual(policy.finalize(), "Hello 🌺")
    }

    func testStreamingTokenPartsPreserveLongUnicodeTokens() {
        let token = String(repeating: "界", count: 73)
        let parts = StreamingRenderer.streamingTokenParts(token, maxCharacters: 16)

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.joined(), token)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 16 })
    }

    func testMarkdownHeuristicsRecognizeTableAndSingleEmphasis() {
        XCTAssertTrue(
            MarkdownHeuristics.looksLikeMarkdown(
                "| Name | Value |\n| --- | --- |\n| A | B |"
            )
        )
        XCTAssertTrue(MarkdownHeuristics.looksLikeMarkdown("*italic only*"))
        XCTAssertTrue(MarkdownHeuristics.looksLikeMarkdown("_italic only_"))
        XCTAssertFalse(MarkdownHeuristics.looksLikeMarkdown("A plain sentence with a * stray mark"))
    }

    func testStreamingPolicyFinalOutputMatchesDirectSanitizer() {
        let tokens = [
            "model\n",
            "<think>",
            "private reasoning",
            "</think>",
            "Visible ",
            "answer",
            "<|end_of_turn|>"
        ]
        let raw = tokens.joined()
        var policy = StreamingUpdatePolicy()
        let firstUpdate = ContinuousClock.now.advanced(by: .seconds(1))
        var accumulated = ""

        for (index, token) in tokens.enumerated() {
            accumulated += token
            let update = policy.append(
                token,
                now: firstUpdate.advanced(by: .milliseconds(index * 120))
            )

            if let visibleText = update.visibleText {
                let expected = update.shouldStop
                    ? StreamingRenderer.sanitize(accumulated)
                    : StreamingRenderer.streamingVisibleText(accumulated)
                XCTAssertEqual(visibleText, expected)
            }
        }

        XCTAssertEqual(policy.finalize(), StreamingRenderer.sanitize(raw))
    }
}
