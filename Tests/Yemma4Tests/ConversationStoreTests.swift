import Foundation
import XCTest
@testable import Yemma4

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testInitialRestoreMigratesAttachmentsBeforeSidebarLoadsIndex() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let legacy = ConversationAttachmentStore.legacyDirectoryURL(baseDirectoryOverride: fixture.storageRoot)
        try fixture.fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = legacy.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: original)
        let attachment = Attachment(id: "photo", url: original, type: .image)
        let id = try fixture.makeStore().saveConversation(
            id: nil, messages: [ChatMessage(id: "message", user: .user, attachments: [attachment])],
            draftText: "Draft", draftAttachments: [attachment]
        )
        let store = fixture.makeStore()
        // Match app startup: restore the selected chat before opening its sidebar.
        let selectedID = try store.ensureCurrentConversation()
        XCTAssertEqual(selectedID, id)
        let loaded = await store.loadConversationAsync(id: selectedID)
        let snapshot = try XCTUnwrap(loaded)
        let restoredImage = try XCTUnwrap(snapshot.messages.first?.attachments.first?.full)
        XCTAssertNotEqual(restoredImage, original)
        XCTAssertEqual(snapshot.draftAttachments.first?.full, restoredImage)
        await store.loadIndexIfNeeded()
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: restoredImage.path))
        XCTAssertEqual(try Data(contentsOf: restoredImage), Data([1, 2, 3]))
        XCTAssertEqual(store.loadConversation(id: id)?.draftAttachments.first?.full, restoredImage)
    }

    func testFailedMigrationDoesNotMoveFilesAfterSnapshotIsLoaded() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let legacy = ConversationAttachmentStore.legacyDirectoryURL(baseDirectoryOverride: fixture.storageRoot)
        try fixture.fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = legacy.appendingPathComponent("photo.jpg")
        try Data([4]).write(to: original)
        let id = try fixture.makeStore().saveConversation(
            id: nil, messages: [], draftText: "Draft",
            draftAttachments: [Attachment(id: "photo", url: original, type: .image)]
        )
        let manager = FailingAttachmentFileManager()
        manager.blockedMove = original
        let store = ConversationStore(fileManager: manager, defaults: fixture.defaults, storageRootOverride: fixture.storageRoot)
        let snapshot = store.loadConversation(id: id)
        XCTAssertEqual(snapshot?.draftAttachments.first?.full, original)
        manager.blockedMove = nil
        await store.loadIndexIfNeeded()
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: original.path))
        let reopened = fixture.makeStore().loadConversation(id: id)
        XCTAssertNotEqual(reopened?.draftAttachments.first?.full, original)
    }

    func testDeleteHistoryRemovesDurableAndCollidingLegacyImages() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let durable = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: fixture.storageRoot)
        let legacy = ConversationAttachmentStore.legacyDirectoryURL(baseDirectoryOverride: fixture.storageRoot)
        try fixture.fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: durable.appendingPathComponent("collision.jpg"))
        try Data([2]).write(to: legacy.appendingPathComponent("collision.jpg"))
        try ConversationAttachmentStore.migrateLegacyFiles(baseDirectoryOverride: fixture.storageRoot)
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: legacy.appendingPathComponent("collision.jpg").path))
        let store = fixture.makeStore()
        _ = try store.startFreshConversation()
        XCTAssertTrue(store.deleteAllConversations())
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: durable.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: legacy.path))
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNil(store.currentConversationID)
    }

    func testFailedHistoryDeletionKeepsSelectionAndCanRetryLegacyCleanup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let durable = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: fixture.storageRoot)
        let legacy = ConversationAttachmentStore.legacyDirectoryURL(baseDirectoryOverride: fixture.storageRoot)
        try fixture.fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: durable.appendingPathComponent("new.jpg"))
        try Data([2]).write(to: legacy.appendingPathComponent("old.jpg"))
        let manager = FailingAttachmentFileManager()
        manager.blockedRemoval = legacy
        let store = ConversationStore(fileManager: manager, defaults: fixture.defaults, storageRootOverride: fixture.storageRoot)
        let id = try store.startFreshConversation()
        XCTAssertFalse(store.deleteAllConversations())
        XCTAssertNotNil(store.historyDeletionError)
        XCTAssertEqual(store.currentConversationID, id)
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: durable.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: legacy.path))
        manager.blockedRemoval = nil
        XCTAssertTrue(store.deleteAllConversations())
        XCTAssertNil(store.historyDeletionError)
        XCTAssertNil(store.currentConversationID)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: legacy.path))
    }

    func testFailedFirstSaveRetainsIDAcrossRetriesAndRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let index = fixture.storageRoot.appendingPathComponent("index.json")
        try fixture.fileManager.createDirectory(at: index, withIntermediateDirectories: true)
        let store = fixture.makeStore()
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.saveConversation(
                id: nil, messages: [makeMessage(text: "Keep this")], draftText: "Draft", draftAttachments: []
            ))
        }
        // A new store simulates a process restart with only UserDefaults and files retained.
        let restarted = fixture.makeStore()
        XCTAssertThrowsError(try restarted.saveConversation(
            id: nil, messages: [makeMessage(text: "Keep this")], draftText: "Latest draft", draftAttachments: []
        ))
        let ids = try fixture.fileManager.contentsOfDirectory(at: fixture.storageRoot, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
        XCTAssertEqual(ids.count, 1)
        XCTAssertNil(restarted.currentConversationID)
        XCTAssertTrue(restarted.conversations.isEmpty)
        try fixture.fileManager.removeItem(at: index)
        let recovered = fixture.makeStore()
        let id = try recovered.ensureCurrentConversation()
        XCTAssertEqual(id, ids.first)
        XCTAssertEqual(recovered.loadConversation(id: id)?.draftText, "Latest draft")
        XCTAssertEqual(recovered.loadConversation(id: id)?.messages.first?.text, "Keep this")
        XCTAssertNil(fixture.defaults.string(forKey: "pendingConversationID"))
    }

    func testFailedSaveDoesNotPublishConversationOrSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // A regular file in place of the storage directory deterministically fails writes.
        try fixture.fileManager.createDirectory(
            at: fixture.storageRoot.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("blocked".utf8).write(to: fixture.storageRoot)
        let store = fixture.makeStore()
        XCTAssertThrowsError(try store.saveConversation(
            id: nil, messages: [makeMessage(text: "Unsaved")], draftText: "", draftAttachments: []
        ))
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNil(store.currentConversationID)
        XCTAssertThrowsError(try store.startFreshConversation())
        XCTAssertNil(store.currentConversationID)
    }

    func testFailedIndexWriteDoesNotPublishNewMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let id = try store.saveConversation(
            id: nil, messages: [makeMessage(text: "Original")], draftText: "", draftAttachments: []
        )
        let index = fixture.storageRoot.appendingPathComponent("index.json")
        try fixture.fileManager.removeItem(at: index)
        try fixture.fileManager.createDirectory(at: index, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.saveConversation(
            id: id, messages: [makeMessage(text: "Changed")], draftText: "", draftAttachments: []
        ))
        XCTAssertEqual(store.conversations.first?.title, "Original")
    }

    func testLegacyAttachmentMigrationPreservesImageAndResolvesSavedURL() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let legacy = fixture.storageRoot.appendingPathComponent("Caches/chat-attachments")
        try fixture.fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let oldURL = legacy.appendingPathComponent("retained.jpg")
        let imageData = Data([1, 2, 3])
        try imageData.write(to: oldURL)
        let attachment = Attachment(id: "image", url: oldURL, type: .image)
        let store = fixture.makeStore()
        let id = try store.saveConversation(
            id: nil, messages: [ChatMessage(id: "message", user: .user, attachments: [attachment])],
            draftText: "", draftAttachments: [attachment]
        )
        try ConversationAttachmentStore.migrateLegacyFiles(
            legacyDirectory: legacy, baseDirectoryOverride: fixture.storageRoot
        )
        let newURL = ConversationAttachmentStore.directoryURL(baseDirectoryOverride: fixture.storageRoot)
            .appendingPathComponent("retained.jpg")
        XCTAssertEqual(try Data(contentsOf: newURL), imageData)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: oldURL.path))
        let snapshot = await store.loadConversationAsync(id: id)
        XCTAssertEqual(snapshot?.messages.first?.attachments.first?.full, newURL)
        XCTAssertEqual(snapshot?.draftAttachments.first?.full, newURL)
        XCTAssertEqual(store.loadConversation(id: id)?.draftAttachments.first?.full, newURL)
        XCTAssertEqual(ConversationAttachmentStore.removeFiles(
            at: [oldURL], baseDirectoryOverride: fixture.storageRoot
        ), 1)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: newURL.path))
    }

    func testAttachmentDirectoryUsesDurableApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(ConversationAttachmentStore.directoryURL().deletingLastPathComponent(), support)
    }

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

        let conversationID = try store.saveConversation(
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
        let conversationID = try store.saveConversation(
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
        let conversationID = try store.saveConversation(
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

        let conversationID = try fixture.makeStore().saveConversation(
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

    func testRemovingAttachmentFilesIsScopedAndDeduplicated() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let attachmentDirectory = try ConversationAttachmentStore.prepareDirectory(
            fileManager: fixture.fileManager,
            baseDirectoryOverride: fixture.storageRoot
        )
        let removedAttachmentURL = attachmentDirectory.appendingPathComponent("removed.png")
        let retainedAttachmentURL = attachmentDirectory.appendingPathComponent("retained.png")
        let outsideURL = fixture.storageRoot.appendingPathComponent("outside.png")

        for url in [removedAttachmentURL, retainedAttachmentURL, outsideURL] {
            try Data("image".utf8).write(to: url)
        }

        let removedCount = ConversationAttachmentStore.removeFiles(
            at: [removedAttachmentURL, removedAttachmentURL, outsideURL],
            fileManager: fixture.fileManager,
            baseDirectoryOverride: fixture.storageRoot
        )

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: removedAttachmentURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: retainedAttachmentURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: outsideURL.path))
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

private final class FailingAttachmentFileManager: FileManager, @unchecked Sendable {
    var blockedMove: URL?
    var blockedRemoval: URL?

    override func moveItem(at source: URL, to destination: URL) throws {
        if source == blockedMove { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
    }

    override func removeItem(at url: URL) throws {
        if url == blockedRemoval { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
