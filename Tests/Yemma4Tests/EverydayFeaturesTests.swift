import XCTest
@testable import Yemma4

@MainActor final class EverydayFeaturesTests: XCTestCase {
    func testGuidedTasksIncludeTheUsersInputWithoutInventingAQuestion() {
        XCTAssertEqual(GuidedTask.ask.prompt(input: "  Why is the sky blue? \n"), "Why is the sky blue?")
        let source = "Please move our meeting to Friday."
        let rewrite = GuidedTask.rewrite.prompt(input: source, tone: "Friendly")
        XCTAssertTrue(rewrite.contains("friendly tone"))
        XCTAssertTrue(rewrite.hasSuffix(source))
        XCTAssertTrue(GuidedTask.summarize.prompt(input: source).hasSuffix(source))
        XCTAssertTrue(GuidedTask.decide.prompt(input: "Bus or train?").hasSuffix("Bus or train?"))
    }

    func testPreferencesCanBeSavedClearedAndBounded() throws {
        let name = "EverydayPreferencesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(PersonalPreferences.instruction(defaults: defaults))
        PersonalPreferences.save("Use metric units.", defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(PersonalPreferences.instruction(defaults: defaults)).contains("Use metric units."))
        PersonalPreferences.save(String(repeating: "a", count: 700), defaults: defaults)
        XCTAssertEqual(PersonalPreferences.savedText(defaults: defaults).count, 500)
        PersonalPreferences.save(" \n ", defaults: defaults)
        XCTAssertNil(PersonalPreferences.instruction(defaults: defaults))
    }

    func testEnabledAppLockStartsLockedAndClearsErrorOnBackgroundLock() throws {
        let name = "EverydayPrivacyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AppPrivacyController.enabledStorageKey)
        let privacy = AppPrivacyController(defaults: defaults)
        XCTAssertTrue(privacy.enabled)
        XCTAssertFalse(privacy.unlocked)
        privacy.error = "Previous cancellation"
        privacy.lock()
        XCTAssertFalse(privacy.unlocked)
        XCTAssertNil(privacy.error)
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyController.enabledStorageKey))
    }

    func testSavedAnswerReferencesAndPinsSurviveReloadAndPrune() throws {
        let name = "EverydayFeaturesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID()
        let deleted = UUID()
        let store = ChatLibraryStore(defaults: defaults)
        store.togglePin(first)
        store.togglePin(deleted)
        store.toggleSaved(conversationID: first, messageID: "answer")
        store.toggleSaved(conversationID: deleted, messageID: "removed")
        let restored = ChatLibraryStore(defaults: defaults)
        XCTAssertTrue(restored.isSaved(conversationID: first, messageID: "answer"))
        restored.prune(conversationIDs: [first])
        let pruned = ChatLibraryStore(defaults: defaults)
        XCTAssertEqual(pruned.pinnedIDs, [first])
        XCTAssertEqual(pruned.savedAnswers.count, 1)
        XCTAssertFalse(pruned.isSaved(conversationID: deleted, messageID: "removed"))
        pruned.toggleSaved(conversationID: first, messageID: "answer")
        XCTAssertTrue(ChatLibraryStore(defaults: defaults).savedAnswers.isEmpty)
    }

    func testSearchExcerptFindsTextBeyondPreviewWithUnicode() {
        let text = String(repeating: "Earlier words 🐈 ", count: 80) + "Résumé deadline Friday" + String(repeating: " later", count: 100)
        let excerpt = ChatSearchResult.excerpt(from: text, matching: "resume")
        XCTAssertTrue(excerpt.contains("Résumé deadline Friday"))
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertLessThan(excerpt.count, 200)
    }

    func testRevisionKeepsEarlierContextAndCopiesImagesIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: root)
        let original = directory.appendingPathComponent("original.jpg")
        try Data([1, 2, 3]).write(to: original)
        let attachment = Attachment(id: "image", url: original, type: .image)
        let messages = [
            ChatMessage(id: "first", user: .user, text: "Context"),
            ChatMessage(id: "answer", user: .yemma, text: "Earlier answer"),
            ChatMessage(id: "edit", user: .user, text: "Original question", attachments: [attachment]),
            ChatMessage(id: "later", user: .yemma, text: "Original response")
        ]
        let revision = try PromptRevision.prepare(messages: messages, messageID: "edit", text: "New question", baseDirectoryOverride: root)
        XCTAssertEqual(revision.messages.map(\.id), ["first", "answer"])
        XCTAssertEqual(revision.text, "New question")
        XCTAssertEqual(revision.copiedFiles.count, 1)
        XCTAssertNotEqual(revision.attachments.first?.full, original)
        XCTAssertEqual(revision.attachments.first?.thumbnail, revision.attachments.first?.full)
        _ = ConversationAttachmentStore.removeFiles(at: revision.copiedFiles, baseDirectoryOverride: root)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        XCTAssertEqual(messages[2].text, "Original question")
    }

    func testFailedRevisionCleansOnlyNewCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: root)
        let original = directory.appendingPathComponent("original.jpg")
        try Data([1]).write(to: original)
        let missing = directory.appendingPathComponent("missing.jpg")
        let messages = [ChatMessage(id: "edit", user: .user, text: "Question", attachments: [
            Attachment(id: "valid", url: original, type: .image),
            Attachment(id: "missing", url: missing, type: .image)
        ])]
        XCTAssertThrowsError(try PromptRevision.prepare(messages: messages, messageID: "edit", text: "Edit", baseDirectoryOverride: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["original.jpg"])
    }

    func testRemovingRevisedDraftImageDoesNotRemoveEarlierContextImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: root)
        let original = directory.appendingPathComponent("image.jpg")
        try Data([1]).write(to: original)
        let attachment = Attachment(id: "shared", url: original, type: .image)
        let messages = [
            ChatMessage(id: "earlier", user: .user, text: "First look", attachments: [attachment]),
            ChatMessage(id: "edit", user: .user, text: "Another look", attachments: [attachment])
        ]
        let revision = try PromptRevision.prepare(messages: messages, messageID: "edit", text: "Edit", baseDirectoryOverride: root)
        let contextImage = try XCTUnwrap(revision.messages.first?.attachments.first?.full)
        let draftImage = try XCTUnwrap(revision.attachments.first?.full)
        XCTAssertNotEqual(contextImage, draftImage)
        _ = ConversationAttachmentStore.removeFiles(at: [draftImage], baseDirectoryOverride: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contextImage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
