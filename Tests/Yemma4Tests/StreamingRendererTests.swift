import XCTest
@testable import Yemma4

final class StreamingRendererTests: XCTestCase {
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

    func testUpdatePolicyTracksASCIIAndComposedUnicodeIncrementally() {
        var policy = StreamingUpdatePolicy()
        let tokens = ["Hello ", "Cafe\u{301}", " ", "🌺", " ", "👨‍👩‍👧‍👦"]
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

        _ = policy.append("Hello 🌺", now: firstUpdate)
        let stopUpdate = policy.append(
            "<|end_of_turn|>",
            now: firstUpdate.advanced(by: .milliseconds(100))
        )

        XCTAssertTrue(stopUpdate.shouldStop)
        XCTAssertTrue(stopUpdate.didAdvance)
        XCTAssertEqual(stopUpdate.visibleText, "Hello 🌺")
        XCTAssertEqual(policy.finalize(), "Hello 🌺")
    }
}
