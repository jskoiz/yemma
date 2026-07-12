import Foundation
import XCTest
@testable import Yemma4

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testAsyncRestoreDecodesIso8601DatesFromPersistedConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let store = fixture.makeStore()
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

        let reloadedStore = fixture.makeStore()
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
        XCTAssertEqual(snapshot?.draftAttachments, [draftAttachment])
        XCTAssertEqual(snapshot?.messages.count, 1)
        XCTAssertEqual(snapshot?.messages.first?.createdAt, createdAt)
        XCTAssertEqual(snapshot?.messages.first?.text, "Hello")
        XCTAssertEqual(snapshot?.messages.first?.status, .sent)
        XCTAssertEqual(snapshot?.messages.first?.user, .user)
        XCTAssertEqual(snapshot?.messages.first?.user.isCurrentUser, true)
    }

    func testRestoreDecodesCurrentPersistedConversationFormat() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let conversationID = UUID()
        let attachmentURL = fixture.storageRoot.appendingPathComponent("existing.png")
        let conversationDirectory = fixture.storageRoot.appendingPathComponent(
            conversationID.uuidString,
            isDirectory: true
        )
        try fixture.fileManager.createDirectory(
            at: conversationDirectory,
            withIntermediateDirectories: true
        )

        let persistedPayload: [String: Any] = [
            "id": conversationID.uuidString,
            "title": "Existing chat",
            "createdAt": "2023-11-14T22:13:20Z",
            "updatedAt": "2023-11-14T22:13:20Z",
            "messages": [[
                "id": "existing-message",
                "user": [
                    "id": "user",
                    "name": "You",
                    "type": 0,
                ],
                "status": "error",
                "createdAt": "2023-11-14T22:13:20Z",
                "text": "Still here",
                "attachments": [[
                    "id": "existing-attachment",
                    "thumbnail": attachmentURL.absoluteString,
                    "full": attachmentURL.absoluteString,
                    "type": "image",
                ]],
            ]],
            "draftText": "",
            "draftAttachments": [],
        ]
        let persistedData = try JSONSerialization.data(withJSONObject: persistedPayload, options: [.sortedKeys])
        try persistedData.write(to: conversationDirectory.appendingPathComponent("conversation.json"))

        let snapshot = await fixture.makeStore().loadConversationAsync(id: conversationID)

        XCTAssertEqual(snapshot?.id, conversationID)
        XCTAssertEqual(snapshot?.title, "Existing chat")
        XCTAssertEqual(snapshot?.messages.first?.id, "existing-message")
        XCTAssertEqual(snapshot?.messages.first?.status, .error)
        XCTAssertEqual(snapshot?.messages.first?.user, .user)
        XCTAssertEqual(snapshot?.messages.first?.isCurrentUser, true)
        XCTAssertEqual(snapshot?.messages.first?.attachments.first?.thumbnail, attachmentURL)
        XCTAssertEqual(snapshot?.messages.first?.attachments.first?.full, attachmentURL)
        XCTAssertEqual(snapshot?.messages.first?.attachments.first?.type, .image)
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

    func testPersistedConversationFilesUseCompleteUntilFirstUserAuthenticationProtection() throws {
        #if os(iOS)
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let conversationID = fixture.makeStore().saveConversation(
            id: nil,
            messages: [makeMessage(text: "Hello")],
            draftText: "",
            draftAttachments: []
        )

        let indexURL = fixture.storageRoot.appendingPathComponent("index.json")
        let conversationURL = fixture.storageRoot
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("conversation.json")

        func protection(of url: URL) throws -> FileProtectionType? {
            try fixture.fileManager.attributesOfItem(atPath: url.path)[.protectionKey]
                as? FileProtectionType
        }

        let protections = try [indexURL, conversationURL, fixture.storageRoot].map(protection)
        guard protections.contains(where: { $0 != nil }) else {
            throw XCTSkip("This simulator filesystem did not report file-protection attributes.")
        }

        XCTAssertEqual(protections[0], .completeUntilFirstUserAuthentication)
        XCTAssertEqual(protections[1], .completeUntilFirstUserAuthentication)
        XCTAssertEqual(protections[2], .completeUntilFirstUserAuthentication)
        #else
        throw XCTSkip("File protection attributes are only enforced on iOS.")
        #endif
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
        let storageBase = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        return Fixture(
            fileManager: .default,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)),
            defaultsName: defaultsName,
            storageRoot: storageBase.appendingPathComponent(
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
