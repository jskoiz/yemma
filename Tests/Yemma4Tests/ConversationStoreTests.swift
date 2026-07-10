import Foundation
import XCTest
import ExyteChat
@testable import Yemma4

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testAsyncRestoreDecodesIso8601DatesFromPersistedConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let store = ConversationStore(
            fileManager: fixture.fileManager,
            defaults: fixture.defaults,
            storageRootOverride: fixture.storageRoot
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
            url: fixture.storageRoot.appendingPathComponent("draft.png"),
            type: .image
        )

        let conversationID = store.saveConversation(
            id: nil,
            messages: [message],
            draftText: "Draft text",
            draftAttachments: [draftAttachment]
        )

        let reloadedStore = ConversationStore(
            fileManager: fixture.fileManager,
            defaults: fixture.defaults,
            storageRootOverride: fixture.storageRoot
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

    func testLoadIndexRecoversConversationMetadataFromFilesWhenIndexIsCorrupt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let store = fixture.makeStore()
        let conversationID = store.saveConversation(
            id: nil,
            messages: [makeMessage(text: "Plan a quiet weekend")],
            draftText: "Include a beach walk",
            draftAttachments: []
        )

        let indexURL = fixture.storageRoot.appendingPathComponent("index.json")
        try Data("not valid json".utf8).write(to: indexURL, options: .atomic)

        let reloadedStore = fixture.makeStore()
        await reloadedStore.loadIndexIfNeeded()

        XCTAssertEqual(reloadedStore.conversations.map(\.id), [conversationID])
        XCTAssertEqual(reloadedStore.conversations.first?.title, "Plan a quiet weekend")
        XCTAssertEqual(reloadedStore.conversations.first?.preview, "Draft: Include a beach walk")
        XCTAssertEqual(reloadedStore.conversations.first?.messageCount, 1)
        XCTAssertEqual(reloadedStore.conversations.first?.hasDraft, true)

        let rewrittenIndex = try Data(contentsOf: indexURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: rewrittenIndex))
    }

    func testLoadIndexRepairsStaleCurrentConversationSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let store = fixture.makeStore()
        let conversationID = store.saveConversation(
            id: nil,
            messages: [makeMessage(text: "Keep this chat")],
            draftText: "",
            draftAttachments: []
        )

        fixture.defaults.set(UUID().uuidString, forKey: "currentConversationID")

        let reloadedStore = fixture.makeStore()
        await reloadedStore.loadIndexIfNeeded()

        XCTAssertEqual(reloadedStore.currentConversationID, conversationID)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "currentConversationID"),
            conversationID.uuidString
        )
    }

    func testLoadIndexClearsStaleSelectionWhenNoConversationsRemain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.defaults.set(UUID().uuidString, forKey: "currentConversationID")

        let store = fixture.makeStore()
        await store.loadIndexIfNeeded()

        XCTAssertNil(store.currentConversationID)
        XCTAssertNil(fixture.defaults.string(forKey: "currentConversationID"))
    }

    private func makeMessage(text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            user: .user,
            status: .sent,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: text,
            attachments: []
        )
    }

    private func makeFixture() throws -> Fixture {
        let identifier = UUID().uuidString
        let defaultsName = "ConversationStoreTests-\(identifier)"
        return Fixture(
            fileManager: .default,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)),
            defaultsName: defaultsName,
            storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConversationStoreTests-\(identifier)",
                isDirectory: true
            )
        )
    }

    private struct Fixture {
        let fileManager: FileManager
        let defaults: UserDefaults
        let defaultsName: String
        let storageRoot: URL

        @MainActor
        func makeStore() -> ConversationStore {
            ConversationStore(
                fileManager: fileManager,
                defaults: defaults,
                storageRootOverride: storageRoot
            )
        }

        @MainActor
        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? fileManager.removeItem(at: storageRoot)
        }
    }
}
