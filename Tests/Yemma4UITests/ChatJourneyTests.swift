import XCTest

/// Simulator integration coverage. Fixtures never use the regular conversation directory.
@MainActor
final class ChatJourneyTests: XCTestCase {
    func testDraftSendResponseAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["YEMMA_UI_TEST_SESSION"] = UUID().uuidString
        app.launch()
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 20))
        let sendReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [sendReady], timeout: 20), .completed, "The restored draft should be sendable")
        Thread.sleep(forTimeInterval: 2)
        send.tap()
        let response = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Simulator mode reply")).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 30))
        let retry = app.buttons["Retry response"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Completed simulator chat"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(response.waitForExistence(timeout: 20), "Completed chat must restore after relaunch")
        XCTAssertTrue(app.buttons["Send message"].exists)
    }

    func testSetupShowsExplicitModelChoice() {
        let app = XCUIApplication()
        app.launchEnvironment["YEMMA_UI_TEST_SESSION"] = UUID().uuidString
        app.launchArguments = ["--yemma-force-onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Choose your model"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Qwen3.5")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Setup at accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
