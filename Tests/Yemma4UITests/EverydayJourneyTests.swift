import XCTest

final class EverydayJourneyTests: XCTestCase {
    @MainActor
    func testGuidedSummaryReviewsDraftAndSavedAnswerSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["YEMMA_UI_TEST_SESSION"] = UUID().uuidString
        app.launch()
        let composer = app.descendants(matching: .any)["chatDraft"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        pauseAfterNavigation()
        XCTAssertEqual(composer.value as? String, "Audit regression prompt")

        app.buttons["chatTools"].tap()
        pauseAfterClick()
        app.buttons["Summarize"].tap()
        pauseAfterNavigation()
        XCTAssertTrue(app.textViews["Text to summarize"].exists)
        XCTAssertEqual(app.textViews["Text to summarize"].value as? String, "Audit regression prompt")
        let keyboardTutorial = app.buttons["Continue"]
        if keyboardTutorial.exists && keyboardTutorial.isHittable {
            keyboardTutorial.tap()
            pauseAfterNavigation()
        }
        let keyboardDone = app.buttons["taskInputKeyboardDone"]
        if keyboardDone.exists && keyboardDone.isHittable {
            keyboardDone.tap()
            pauseAfterClick()
        }
        keepScreenshot(app, name: "Guided summary review")
        app.buttons["Use draft"].tap()
        pauseAfterNavigation()
        XCTAssertTrue((composer.value as? String)?.contains("Summarize the text below") == true)
        XCTAssertTrue((composer.value as? String)?.hasSuffix("Audit regression prompt") == true)
        // Use draft must not send or generate a response by itself.
        XCTAssertFalse(app.buttons["More options"].exists)

        app.buttons["Send message"].tap()
        pauseAfterClick()
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        pauseAfterClick()
        app.buttons["Save answer"].tap()
        pauseAfterClick()

        app.buttons["New chat"].tap()
        pauseAfterNavigation()
        composer.tap()
        pauseAfterClick()
        for character in "Unsaved question" {
            composer.typeText(String(character))
            Thread.sleep(forTimeInterval: 0.11)
        }
        pauseAfterClick()
        app.buttons["Send message"].tap()
        pauseAfterClick()
        XCTAssertTrue(more.waitForExistence(timeout: 30))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["chatTools"].waitForExistence(timeout: 15))
        pauseAfterNavigation()
        app.buttons["chatTools"].tap()
        pauseAfterClick()
        app.buttons["Search chats and saved answers"].tap()
        pauseAfterNavigation()
        let savedOnly = app.switches["Saved answers only"]
        XCTAssertTrue(savedOnly.waitForExistence(timeout: 10))
        savedOnly.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        pauseAfterNavigation()
        XCTAssertEqual(savedOnly.value as? String, "1", "The saved-only filter must actually be enabled")
        XCTAssertFalse(app.staticTexts["Save an answer from its message menu to find it here."].exists)
        XCTAssertGreaterThanOrEqual(app.cells.count, 2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Summarize the text below")).firstMatch.exists)
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Unsaved question").firstMatch.exists)
        keepScreenshot(app, name: "Saved answer after relaunch")
    }

    @MainActor private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pauseAfterClick() { Thread.sleep(forTimeInterval: 1.1) }
    private func pauseAfterNavigation() { Thread.sleep(forTimeInterval: 2.2) }
}
