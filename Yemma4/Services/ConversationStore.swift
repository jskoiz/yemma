import Foundation
import Observation

struct ConversationMetadata: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var preview: String
    var createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var hasDraft: Bool
    var isCustomTitle: Bool
}

struct ConversationSnapshot: Sendable {
    let id: UUID
    let title: String
    let messages: [ChatMessage]
    let draftText: String
    let draftAttachments: [Attachment]
}

private struct ConversationIndexLoadResult: Sendable {
    let conversations: [ConversationMetadata]
    let recoveredFromConversationFiles: Bool
}

enum ConversationAttachmentStore {
    private static let directoryName = "chat-attachments"

    /// At-rest protection for locally stored chat attachments.
    ///
    /// `.completeUntilFirstUserAuthentication` keeps data encrypted while the
    /// device is locked before the first unlock after boot, but still allows
    /// background access afterwards. `.complete` is intentionally avoided so
    /// background download/restore is not broken.
    static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    static func directoryURL(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) -> URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride.appendingPathComponent(directoryName, isDirectory: true)
        }

        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to locate application support for attachment storage.")
        }

        return supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func legacyDirectoryURL(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) -> URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride.appendingPathComponent("Caches/chat-attachments", isDirectory: true)
        }
        return fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Move existing images without rewriting every conversation. Old URLs are
    /// resolved by filename when a conversation is decoded. A failed move leaves
    /// the original available, and the next launch retries remaining files.
    static func migrateLegacyFiles(
        fileManager: FileManager = .default,
        legacyDirectory: URL? = nil,
        baseDirectoryOverride: URL? = nil
    ) throws {
        let source = legacyDirectory ?? legacyDirectoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = try prepareDirectory(
            fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride
        )
        for file in try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let target = destination.appendingPathComponent(file.lastPathComponent)
            // Do not replace an existing image or delete an unresolved collision.
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.moveItem(at: file, to: target)
            try fileManager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: target.path)
        }
    }

    static func restoredURL(_ url: URL, baseDirectoryOverride: URL? = nil) -> URL {
        guard url.isFileURL,
              url.deletingLastPathComponent().lastPathComponent == directoryName else { return url }
        let target = directoryURL(baseDirectoryOverride: baseDirectoryOverride)
            .appendingPathComponent(url.lastPathComponent)
        // Prefer an existing original if migration did not finish.
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return FileManager.default.fileExists(atPath: target.path) ? target : url
    }

    /// Creates the attachment directory (if needed) with data protection applied,
    /// and returns its URL. Callers should use this instead of creating the
    /// directory directly so attachments are encrypted at rest.
    @discardableResult
    static func prepareDirectory(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws -> URL {
        let directory = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: fileProtection]
        )
        try? fileManager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: directory.path)
        return directory
    }

    /// File-write options that apply data protection to a newly written attachment.
    static var writeOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    static func removeAll(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws -> Int {
        let directories = [
            directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride),
            legacyDirectoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        ]
        var removedCount = 0
        var firstError: Error?
        // Attempt both locations even if one fails; preserve the error for retry.
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            do {
                let count = fileCount(in: directory, fileManager: fileManager)
                try fileManager.removeItem(at: directory)
                removedCount += count
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return removedCount
    }

    static func removeFiles(
        at urls: [URL],
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) -> Int {
        let directory = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        let directoryPath = directory.standardizedFileURL.path + "/"
        var removedCount = 0

        for url in Set(urls.map { restoredURL($0, baseDirectoryOverride: baseDirectoryOverride).standardizedFileURL }) where url.path.hasPrefix(directoryPath) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removedCount += 1
            } catch {
                continue
            }
        }

        return removedCount
    }

    private static func fileCount(in directory: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}

private struct PersistedConversation: Codable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [PersistedMessage]
    var draftText: String
    var draftAttachments: [Attachment]
}

private struct PersistedMessage: Codable, Sendable {
    let id: String
    let user: User
    let status: ChatMessage.Status?
    let createdAt: Date
    let text: String
    let attachments: [Attachment]

    init(message: ChatMessage) {
        id = message.id
        user = message.user
        status = message.status
        createdAt = message.createdAt
        text = message.text
        attachments = message.attachments
    }

    func makeMessage(baseDirectoryOverride: URL? = nil) -> ChatMessage {
        return ChatMessage(
            id: id,
            user: user,
            status: status,
            createdAt: createdAt,
            text: text,
            attachments: attachments.map { $0.restored(baseDirectoryOverride: baseDirectoryOverride) }
        )
    }
}

private extension Attachment {
    func restored(baseDirectoryOverride: URL?) -> Attachment {
        Attachment(
            id: id,
            thumbnail: ConversationAttachmentStore.restoredURL(thumbnail, baseDirectoryOverride: baseDirectoryOverride),
            full: ConversationAttachmentStore.restoredURL(full, baseDirectoryOverride: baseDirectoryOverride),
            type: type
        )
    }
}

@MainActor
@Observable
final class ConversationStore {
    var conversations: [ConversationMetadata] = []
    var currentConversationID: UUID?
    var storageError: String?
    var historyDeletionError: String?

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let storageRootOverride: URL?
    // Protects persisted store mutations so file I/O helpers remain safe if they are ever reused off the main actor.
    private let ioLock = NSLock()
    @ObservationIgnored private var hasAttemptedAttachmentMigration = false
    @ObservationIgnored private var pendingNewConversationID: UUID?
    @ObservationIgnored private var hasLoadedConversationIndex = false
    @ObservationIgnored private var isLoadingConversationIndex = false

    private static let indexFileName = "index.json"
    private static let conversationFileName = "conversation.json"
    private static let currentConversationDefaultsKey = "currentConversationID"
    private static let pendingConversationDefaultsKey = "pendingConversationID"

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        storageRootOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.storageRootOverride = storageRootOverride
        pendingNewConversationID = defaults.string(forKey: Self.pendingConversationDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        if let rawID = defaults.string(forKey: Self.currentConversationDefaultsKey),
           let conversationID = UUID(uuidString: rawID) {
            currentConversationID = conversationID
        }
    }

    func ensureCurrentConversation() throws -> UUID {
        if let currentConversationID {
            return currentConversationID
        }

        if let pendingID = pendingNewConversationID,
           let pending = readConversation(id: pendingID) {
            try persist(conversation: pending, metadata: Self.recoveredMetadata(from: pending))
            setCurrentConversation(id: pendingID)
            finishPendingConversation(id: pendingID)
            return pendingID
        }
        return try startFreshConversation()
    }

    private func pendingConversationID() -> UUID {
        if let pendingNewConversationID { return pendingNewConversationID }
        let id = UUID()
        pendingNewConversationID = id
        defaults.set(id.uuidString, forKey: Self.pendingConversationDefaultsKey)
        return id
    }

    private func finishPendingConversation(id: UUID) {
        guard pendingNewConversationID == id else { return }
        pendingNewConversationID = nil
        defaults.removeObject(forKey: Self.pendingConversationDefaultsKey)
    }

    @discardableResult
    func startFreshConversation(title: String? = nil) throws -> UUID {
        let conversationID = pendingConversationID()
        let createdAt = Date()
        let resolvedTitle = cleanedTitle(title) ?? "New chat"
        let isCustomTitle = cleanedTitle(title) != nil
        let metadata = ConversationMetadata(
            id: conversationID,
            title: resolvedTitle,
            preview: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            messageCount: 0,
            hasDraft: false,
            isCustomTitle: isCustomTitle
        )
        let conversation = PersistedConversation(
            id: conversationID,
            title: resolvedTitle,
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: [],
            draftText: "",
            draftAttachments: []
        )

        try persist(conversation: conversation, metadata: metadata)
        setCurrentConversation(id: conversationID)
        finishPendingConversation(id: conversationID)
        return conversationID
    }

    func setCurrentConversation(id: UUID) {
        currentConversationID = id
        defaults.set(id.uuidString, forKey: Self.currentConversationDefaultsKey)
    }

    func recentConversations(limit: Int) -> [ConversationMetadata] {
        guard limit > 0 else { return [] }

        let sortedConversations = conversations.sorted(by: Self.sortConversations)
        let recentSlice = Array(sortedConversations.prefix(limit))

        guard let currentConversationID,
              !recentSlice.contains(where: { $0.id == currentConversationID }),
              let currentConversation = sortedConversations.first(where: { $0.id == currentConversationID }) else {
            return recentSlice
        }

        var recent = recentSlice
        if recent.count == limit {
            recent.removeLast()
        }
        recent.insert(currentConversation, at: 0)
        return recent
    }

    func archivedConversations(limit: Int) -> [ConversationMetadata] {
        let recentIDs = Set(recentConversations(limit: limit).map(\.id))
        return conversations.filter { !recentIDs.contains($0.id) }
    }

    func loadConversation(id: UUID) -> ConversationSnapshot? {
        prepareAttachmentsBeforeRestore()
        guard let conversation = readConversation(id: id) else {
            return nil
        }

        return ConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            messages: conversation.messages.map { $0.makeMessage(baseDirectoryOverride: storageRootOverride) },
            draftText: conversation.draftText,
            draftAttachments: conversation.draftAttachments.map { $0.restored(baseDirectoryOverride: storageRootOverride) }
        )
    }

    func loadConversationAsync(id: UUID) async -> ConversationSnapshot? {
        prepareAttachmentsBeforeRestore()
        let conversationURL = conversationURL(for: id)
        let rootOverride = storageRootOverride
        return await Task.detached(priority: .utility) {
            ConversationSnapshotLoader.load(from: conversationURL, storageRootOverride: rootOverride)
        }.value
    }

    func loadIndexIfNeeded() async {
        guard !hasLoadedConversationIndex else { return }
        guard !isLoadingConversationIndex else { return }
        isLoadingConversationIndex = true
        prepareAttachmentsBeforeRestore()
        await loadIndexAsync()
    }

    private func prepareAttachmentsBeforeRestore() {
        guard !hasAttemptedAttachmentMigration else { return }
        // Never move files after handing a snapshot to the UI. If a move fails,
        // existing cache URLs stay usable and migration retries next launch.
        hasAttemptedAttachmentMigration = true
        do {
            try ConversationAttachmentStore.migrateLegacyFiles(
                fileManager: fileManager, baseDirectoryOverride: storageRootOverride
            )
        } catch {
            AppDiagnostics.shared.record(
                "Attachment migration deferred until next launch",
                category: "storage",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    @discardableResult
    func saveConversation(
        id: UUID?,
        messages: [ChatMessage],
        draftText: String,
        draftAttachments: [Attachment]
    ) throws -> UUID {
        let conversationID = id ?? currentConversationID ?? pendingConversationID()
        let existingMetadata = conversations.first(where: { $0.id == conversationID })
        let existingConversation = readConversation(id: conversationID)
        let createdAt = existingMetadata?.createdAt ?? existingConversation?.createdAt ?? Date()
        let updatedAt = Date()
        let isCustomTitle = existingMetadata?.isCustomTitle ?? false
        let title = isCustomTitle
            ? (existingMetadata?.title ?? "New chat")
            : Self.suggestedTitle(for: messages)
        let preview = Self.previewText(messages: messages, draftText: draftText, draftAttachments: draftAttachments)

        let metadata = ConversationMetadata(
            id: conversationID,
            title: title,
            preview: preview,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            hasDraft: !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty,
            isCustomTitle: isCustomTitle
        )
        let conversation = PersistedConversation(
            id: conversationID,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages.map(PersistedMessage.init(message:)),
            draftText: draftText,
            draftAttachments: draftAttachments
        )

        try persist(conversation: conversation, metadata: metadata)
        if currentConversationID == nil {
            setCurrentConversation(id: conversationID)
        }
        finishPendingConversation(id: conversationID)
        return conversationID
    }

    func renameConversation(id: UUID, title: String) {
        guard let trimmedTitle = cleanedTitle(title) else { return }
        ioLock.lock()
        defer { ioLock.unlock() }

        guard var conversation = readConversationLocked(id: id) else { return }
        guard let metadataIndex = conversations.firstIndex(where: { $0.id == id }) else { return }

        let updatedAt = Date()
        conversation.title = trimmedTitle
        conversation.updatedAt = updatedAt
        var metadata = conversations[metadataIndex]
        metadata.title = trimmedTitle
        metadata.updatedAt = updatedAt
        metadata.isCustomTitle = true

        do {
            try ensureRootDirectoryLocked()
            try ensureConversationDirectoryLocked(id: conversation.id)
            try writeConversationLocked(conversation)
            var updated = conversations
            updated[metadataIndex] = metadata
            try writeIndexLocked(updated)
            conversations = updated
        } catch {
            reportStorageError(error)
        }
    }

    func deleteConversation(id: UUID) {
        _ = deleteConversations(ids: Set([id]))
    }

    @discardableResult
    func deleteArchivedConversations(keepingRecentLimit limit: Int) -> Int {
        let archivedIDs = Set(archivedConversations(limit: limit).map(\.id))
        return deleteConversations(ids: archivedIDs)
    }

    @discardableResult
    func deleteConversations(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }

        ioLock.lock()
        defer { ioLock.unlock() }

        var removedAttachmentFiles = 0
        for id in ids {
            removedAttachmentFiles += readConversationLocked(id: id).map { conversation in
                ConversationAttachmentStore.removeFiles(
                    at: Self.attachmentURLs(in: conversation),
                    fileManager: fileManager,
                    baseDirectoryOverride: storageRootOverride
                )
            } ?? 0

            let directory = conversationDirectory(for: id)
            if fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
        }

        conversations.removeAll { ids.contains($0.id) }
        conversations.sort(by: Self.sortConversations)
        do { try writeIndexLocked() } catch { reportStorageError(error) }

        if let currentID = currentConversationID, ids.contains(currentID) {
            if let nextConversation = conversations.first {
                currentConversationID = nextConversation.id
                defaults.set(nextConversation.id.uuidString, forKey: Self.currentConversationDefaultsKey)
            } else {
                currentConversationID = nil
                defaults.removeObject(forKey: Self.currentConversationDefaultsKey)
            }
        }

        if removedAttachmentFiles > 0 {
            AppDiagnostics.shared.record(
                "Conversation attachments deleted",
                category: "storage",
                metadata: [
                    "conversations": ids.count,
                    "files": removedAttachmentFiles
                ]
            )
        }

        return ids.count
    }

    @discardableResult
    func deleteAllConversations() -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }

        do {
            let removedAttachmentFiles = try ConversationAttachmentStore.removeAll(
                fileManager: fileManager,
                baseDirectoryOverride: storageRootOverride
            )
            if fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.removeItem(at: rootDirectory)
            }

            conversations = []
            currentConversationID = nil
            pendingNewConversationID = nil
            defaults.removeObject(forKey: Self.currentConversationDefaultsKey)
            defaults.removeObject(forKey: Self.pendingConversationDefaultsKey)
            historyDeletionError = nil
            AppDiagnostics.shared.record(
                "Conversation history cleared",
                category: "storage",
                metadata: ["attachmentFiles": removedAttachmentFiles]
            )
            return true
        } catch {
            historyDeletionError = "Some history or attached images could not be removed. Try deleting again. "
                + error.localizedDescription
            return false
        }
    }

    private var documentsDirectory: URL {
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Unable to locate the documents directory for conversation storage.")
        }
        return documentsDirectory
    }

    private var rootDirectory: URL {
        if let storageRootOverride {
            return storageRootOverride
        }
        return documentsDirectory.appendingPathComponent("chat-history", isDirectory: true)
    }

    private var indexURL: URL {
        rootDirectory.appendingPathComponent(Self.indexFileName)
    }

    private func conversationDirectory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func conversationURL(for id: UUID) -> URL {
        conversationDirectory(for: id).appendingPathComponent(Self.conversationFileName)
    }

    private func loadIndexAsync() async {
        let rootDirectory = rootDirectory
        let indexURL = indexURL
        let result = await Task.detached(priority: .utility) {
            Self.loadConversationIndex(rootDirectory: rootDirectory, indexURL: indexURL)
        }.value

        await MainActor.run {
            ioLock.lock()
            defer { ioLock.unlock() }
            conversations = result.conversations.sorted(by: Self.sortConversations)
            repairCurrentConversationSelectionLocked()
            if result.recoveredFromConversationFiles {
                do {
                    try ensureRootDirectoryLocked()
                    try writeIndexLocked()
                    AppDiagnostics.shared.record(
                        "Conversation index recovered",
                        category: "storage",
                        metadata: ["conversations": conversations.count]
                    )
                } catch {
                    reportStorageError(error)
                }
            }
            hasLoadedConversationIndex = true
            isLoadingConversationIndex = false
        }
    }

    private func repairCurrentConversationSelectionLocked() {
        guard let currentConversationID else { return }
        guard !conversations.contains(where: { $0.id == currentConversationID }) else { return }

        if let firstConversationID = conversations.first?.id {
            self.currentConversationID = firstConversationID
            defaults.set(firstConversationID.uuidString, forKey: Self.currentConversationDefaultsKey)
        } else {
            self.currentConversationID = nil
            defaults.removeObject(forKey: Self.currentConversationDefaultsKey)
        }
    }

    nonisolated private static func loadConversationIndex(
        rootDirectory: URL,
        indexURL: URL
    ) -> ConversationIndexLoadResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: indexURL),
           let conversations = try? decoder.decode([ConversationMetadata].self, from: data) {
            return ConversationIndexLoadResult(
                conversations: conversations,
                recoveredFromConversationFiles: false
            )
        }

        let fileManager = FileManager.default
        let directoryURLs = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let conversations = directoryURLs.compactMap { directoryURL -> ConversationMetadata? in
            guard UUID(uuidString: directoryURL.lastPathComponent) != nil else { return nil }
            let conversationURL = directoryURL.appendingPathComponent("conversation.json")
            guard let data = try? Data(contentsOf: conversationURL),
                  let conversation = try? decoder.decode(PersistedConversation.self, from: data),
                  conversation.id.uuidString == directoryURL.lastPathComponent else {
                return nil
            }

            return recoveredMetadata(from: conversation)
        }

        return ConversationIndexLoadResult(
            conversations: conversations,
            recoveredFromConversationFiles: !directoryURLs.isEmpty || fileManager.fileExists(atPath: indexURL.path)
        )
    }

    nonisolated private static func recoveredMetadata(
        from conversation: PersistedConversation
    ) -> ConversationMetadata {
        let messages = conversation.messages.map { $0.makeMessage() }
        return ConversationMetadata(
            id: conversation.id,
            title: conversation.title,
            preview: previewText(
                messages: messages,
                draftText: conversation.draftText,
                draftAttachments: conversation.draftAttachments
            ),
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messageCount: messages.count,
            hasDraft: !conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !conversation.draftAttachments.isEmpty,
            // A recovered index cannot distinguish generated titles from user-edited titles.
            // Preserve the stored title instead of risking a future save overwriting it.
            isCustomTitle: true
        )
    }

    private func persist(conversation: PersistedConversation, metadata: ConversationMetadata) throws {
        ioLock.lock()
        defer { ioLock.unlock() }

        try ensureRootDirectoryLocked()
        try ensureConversationDirectoryLocked(id: conversation.id)
        try writeConversationLocked(conversation)

        var updated = conversations
        if let index = updated.firstIndex(where: { $0.id == metadata.id }) {
            updated[index] = metadata
        } else {
            updated.append(metadata)
        }
        updated.sort(by: Self.sortConversations)
        try writeIndexLocked(updated)
        conversations = updated
    }

    func reportStorageError(_ error: Error) {
        storageError = "Your latest changes could not be saved. Keep this chat open and try again. "
            + error.localizedDescription
    }

    private func readConversation(id: UUID) -> PersistedConversation? {
        ioLock.lock()
        defer { ioLock.unlock() }

        return readConversationLocked(id: id)
    }

    private func readConversationLocked(id: UUID) -> PersistedConversation? {
        let conversationURL = conversationURL(for: id)
        guard let data = try? Data(contentsOf: conversationURL) else {
            return nil
        }

        return try? Self.decoder.decode(PersistedConversation.self, from: data)
    }

    private func writeConversationLocked(_ conversation: PersistedConversation) throws {
        let data = try Self.encoder.encode(conversation)
        try data.write(to: conversationURL(for: conversation.id), options: Self.fileWriteOptions)
    }

    private func writeIndexLocked(_ entries: [ConversationMetadata]? = nil) throws {
        let data = try Self.encoder.encode(entries ?? conversations)
        try data.write(to: indexURL, options: Self.fileWriteOptions)
    }

    private func ensureRootDirectoryLocked() throws {
        try ensureProtectedDirectory(at: rootDirectory)
    }

    private func ensureConversationDirectoryLocked(id: UUID) throws {
        try ensureProtectedDirectory(at: conversationDirectory(for: id))
    }

    /// Creates `directory` (if needed) with data protection applied and ensures the
    /// protection attribute is set so chat history is encrypted at rest.
    private func ensureProtectedDirectory(at directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: Self.fileProtection]
            )
        }
        try fileManager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: directory.path)
    }

    private func cleanedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func attachmentURLs(in conversation: PersistedConversation) -> [URL] {
        let messageAttachments = conversation.messages.flatMap(\.attachments).flatMap { [$0.thumbnail, $0.full] }
        let draftAttachments = conversation.draftAttachments.flatMap { [$0.thumbnail, $0.full] }
        return Array(Set(messageAttachments + draftAttachments))
    }

    private static func suggestedTitle(for messages: [ChatMessage]) -> String {
        if let firstText = messages.first(where: { $0.user.isCurrentUser && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text {
            return compactTitle(firstText)
        }

        if let firstAttachmentMessage = messages.first(where: { $0.user.isCurrentUser && !$0.attachments.isEmpty }) {
            return firstAttachmentMessage.attachments.first?.type == .image ? "Image prompt" : "New chat"
        }

        return "New chat"
    }

    nonisolated private static func previewText(messages: [ChatMessage], draftText: String, draftAttachments: [Attachment]) -> String {
        if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Draft: \(compactTitle(draftText))"
        }

        if !draftAttachments.isEmpty {
            return "Draft with image"
        }

        if let latestMessage = messages.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return compactTitle(latestMessage.text)
        }

        if let attachmentMessage = messages.last(where: { !$0.attachments.isEmpty }) {
            return attachmentMessage.attachments.first?.type == .image ? "Image prompt" : "New chat"
        }

        return "No messages yet"
    }

    nonisolated private static func compactTitle(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 48 else { return collapsed }
        return String(collapsed.prefix(45)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func sortConversations(lhs: ConversationMetadata, rhs: ConversationMetadata) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    /// At-rest protection for locally stored chat history.
    ///
    /// `.completeUntilFirstUserAuthentication` keeps data encrypted while the
    /// device is locked before the first unlock after boot while still allowing
    /// background access afterwards. `.complete` is intentionally avoided so
    /// background restore/persistence is not broken.
    private static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    private static let fileWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication
    ]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

}

private enum ConversationSnapshotLoader {
    static func load(from conversationURL: URL, storageRootOverride: URL?) -> ConversationSnapshot? {
        guard let data = try? Data(contentsOf: conversationURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let conversation = try? decoder.decode(PersistedConversation.self, from: data) else {
            return nil
        }

        return ConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            messages: conversation.messages.map { $0.makeMessage(baseDirectoryOverride: storageRootOverride) },
            draftText: conversation.draftText,
            draftAttachments: conversation.draftAttachments.map { $0.restored(baseDirectoryOverride: storageRootOverride) }
        )
    }
}

#if DEBUG
extension ConversationStore {
    static func preview(
        currentConversationID: UUID? = nil,
        conversations: [ConversationSnapshot] = []
    ) -> ConversationStore {
        let store = ConversationStore(
            fileManager: FileManager.default,
            defaults: UserDefaults(suiteName: "ConversationStorePreview-\(UUID().uuidString)") ?? .standard,
            storageRootOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConversationStorePreview-\(UUID().uuidString)", isDirectory: true)
        )
        store.deleteAllConversations()
        if conversations.isEmpty {
            guard let newID = try? store.startFreshConversation() else { return store }
            if let currentConversationID {
                store.setCurrentConversation(id: currentConversationID)
            } else {
                store.setCurrentConversation(id: newID)
            }
            return store
        }

        var selectedID: UUID?
        for snapshot in conversations {
            guard let savedID = try? store.saveConversation(
                id: snapshot.id,
                messages: snapshot.messages,
                draftText: snapshot.draftText,
                draftAttachments: snapshot.draftAttachments
            ) else { continue }
            let trimmedTitle = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                store.renameConversation(id: savedID, title: trimmedTitle)
            }
            if selectedID == nil {
                selectedID = savedID
            }
        }

        if let currentConversationID {
            store.setCurrentConversation(id: currentConversationID)
        } else if let selectedID {
            store.setCurrentConversation(id: selectedID)
        }
        return store
    }
}
#endif
