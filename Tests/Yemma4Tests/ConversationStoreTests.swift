import Foundation
import XCTest
import ExyteChat
@testable import Yemma4

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testAsyncRestoreDecodesIso8601DatesFromPersistedConversation() async throws {
        let fileManager = FileManager.default
        let storageRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ConversationStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let defaultsName = "ConversationStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)
        XCTAssertNotNil(defaults)

        guard let defaults else {
            return
        }

        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? fileManager.removeItem(at: storageRoot)
        }

        let store = ConversationStore(
            fileManager: fileManager,
            defaults: defaults,
            storageRootOverride: storageRoot
        )

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let message = ChatMessage(
            id: "message-1",
            user: .user,
            status: .sent,
            createdAt: createdAt,
            text: "Hello",
            attachments: []
        )
        let draftAttachment = Attachment(
            id: "attachment-1",
            url: storageRoot.appendingPathComponent("draft.png"),
            type: .image
        )

        let conversationID = store.saveConversation(
            id: nil,
            messages: [message],
            draftText: "Draft text",
            draftAttachments: [draftAttachment]
        )

        let reloadedStore = ConversationStore(
            fileManager: fileManager,
            defaults: defaults,
            storageRootOverride: storageRoot
        )

        await reloadedStore.loadIndexIfNeeded()

        XCTAssertEqual(reloadedStore.conversations.count, 1)
        XCTAssertEqual(reloadedStore.conversations.first?.id, conversationID)
        XCTAssertEqual(reloadedStore.conversations.first?.messageCount, 1)
        XCTAssertEqual(reloadedStore.conversations.first?.hasDraft, true)
        XCTAssertEqual(reloadedStore.currentConversationID, conversationID)

        let snapshot = await reloadedStore.loadConversationAsync(id: conversationID)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.id, conversationID)
        XCTAssertEqual(snapshot?.title, "Hello")
        XCTAssertEqual(snapshot?.draftText, "Draft text")
        XCTAssertEqual(snapshot?.draftAttachments.count, 1)
        XCTAssertEqual(snapshot?.messages.count, 1)
        XCTAssertEqual(snapshot?.messages.first?.createdAt, createdAt)
        XCTAssertEqual(snapshot?.messages.first?.text, "Hello")
    }
}
