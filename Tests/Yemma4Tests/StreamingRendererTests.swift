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
}
