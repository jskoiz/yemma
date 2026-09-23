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

enum ConversationStoreError: Error, Equatable, LocalizedError, Sendable {
    case conversationNotFound(UUID)
    case corruptConversation(requestedID: UUID, payloadID: UUID?, reason: String)
    case conversationDeleted(UUID)
    case saveSuperseded(UUID)

    var errorDescription: String? {
        switch self {
        case let .conversationNotFound(id):
            return "Conversation \(id.uuidString) was not found."
        case let .corruptConversation(requestedID, payloadID, reason):
            let payload = payloadID?.uuidString ?? "unknown"
            return "Conversation \(requestedID.uuidString) is corrupt (payload ID: \(payload)). \(reason)"
        case let .conversationDeleted(id):
            return "Conversation \(id.uuidString) was deleted and cannot accept a late save."
        case let .saveSuperseded(id):
            return "An older save for conversation \(id.uuidString) was superseded by a newer save."
        }
    }
}

private struct ConversationIndexLoadResult: Sendable {
    let conversations: [ConversationMetadata]
    let corruptConversationIDs: Set<UUID>
    let referencedAttachmentPaths: Set<String>
    let allConversationFilesDecoded: Bool
    let requiresIndexRewrite: Bool
}

private struct IndexedConversationLoad: Sendable {
    let result: ConversationIndexLoadResult
    let revision: UInt64
}

private struct ConversationSaveResult: Sendable {
    let id: UUID
    let metadata: ConversationMetadata
    let conversations: [ConversationMetadata]
    let revision: UInt64
}

private final class ConversationStoreStorage: @unchecked Sendable {
    let fileManager: FileManager
    let rootDirectory: URL
    let storageRootOverride: URL?
    let lock = NSLock()
    var deletedConversationIDs = Set<UUID>()
    var revision: UInt64 = 0
    var highestSaveRevisions = [UUID: UInt64]()
    var rejectConversationSaves = false

    init(fileManager: FileManager, rootDirectory: URL, storageRootOverride: URL?) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
        self.storageRootOverride = storageRootOverride
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
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
        let destinationDirectory = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        if fileManager.fileExists(atPath: destinationDirectory.path) {
            excludeFromBackup(destinationDirectory)
            if let enumerator = fileManager.enumerator(
                at: destinationDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) {
                for case let file as URL in enumerator {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        continue
                    }
                    try applyProtection(to: file, fileManager: fileManager)
                }
            }
        }
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = try prepareDirectory(
            fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride
        )
        excludeFromBackup(source)
        for file in try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let target = destination.appendingPathComponent(file.lastPathComponent)
            // Do not replace an existing image or delete an unresolved collision.
            // Reapply both policies to existing targets because a prior launch may
            // have been interrupted after the move and before attributes were set.
            if fileManager.fileExists(atPath: target.path) {
                try applyProtection(to: target, fileManager: fileManager)
                continue
            }
            try fileManager.moveItem(at: file, to: target)
            try applyProtection(to: target, fileManager: fileManager)
        }
    }

    static func restoredURL(
        _ url: URL,
        baseDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        guard url.isFileURL,
              url.deletingLastPathComponent().lastPathComponent == directoryName else { return url }
        let target = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
            .appendingPathComponent(url.lastPathComponent)
        // Prefer an existing original if migration did not finish.
        if fileManager.fileExists(atPath: url.path) { return url }
        return fileManager.fileExists(atPath: target.path) ? target : url
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
        excludeFromBackup(directory)
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
        (try? removeFilesThrowing(
            at: urls,
            fileManager: fileManager,
            baseDirectoryOverride: baseDirectoryOverride
        )) ?? 0
    }

    static func removeFilesThrowing(
        at urls: [URL],
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws -> Int {
        let directory = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        let legacyDirectory = legacyDirectoryURL(
            fileManager: fileManager,
            baseDirectoryOverride: baseDirectoryOverride
        )
        var removedCount = 0
        var firstError: Error?

        let candidates = Set(urls.flatMap { url in
            [
                url.standardizedFileURL,
                restoredURL(
                    url,
                    baseDirectoryOverride: baseDirectoryOverride,
                    fileManager: fileManager
                ).standardizedFileURL
            ]
        })
        for url in candidates where isContained(url, in: directory) || isContained(url, in: legacyDirectory) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                removedCount += 1
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError { throw firstError }
        return removedCount
    }

    static func removeOrphanedFiles(
        referencedPaths: Set<String>,
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) throws -> Int {
        let directories = [
            directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride),
            legacyDirectoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        ]
        let durableDirectory = directories[0].standardizedFileURL
        let legacyDirectory = directories[1].standardizedFileURL
        var protectedPaths = Set(referencedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })

        // A same-named durable/legacy collision is intentionally preserved on
        // both sides. The store cannot prove which copy belongs to an unreadable
        // or interrupted migration, so cleanup must remain conservative.
        for path in referencedPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.lastPathComponent.isEmpty == false,
                  url.deletingLastPathComponent().lastPathComponent == directoryName else { continue }
            protectedPaths.insert(durableDirectory.appendingPathComponent(url.lastPathComponent).path)
            protectedPaths.insert(legacyDirectory.appendingPathComponent(url.lastPathComponent).path)
        }

        var removedCount = 0
        var firstError: Error?
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            for file in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                guard !protectedPaths.contains(file.standardizedFileURL.path) else { continue }
                do {
                    try fileManager.removeItem(at: file)
                    removedCount += 1
                } catch {
                    firstError = firstError ?? error
                }
            }
        }

        if let firstError { throw firstError }
        return removedCount
    }

    static func excludeFromBackup(_ url: URL) {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }

    static func repairBackupExclusions(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) {
        let directories = [
            directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride),
            legacyDirectoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        ]
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            excludeFromBackup(directory)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
            ) else { continue }
            for case let url as URL in enumerator {
                excludeFromBackup(url)
            }
        }
    }

    private static func applyProtection(to url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
        excludeFromBackup(url)
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let rootPath = directory.standardizedFileURL.path.hasSuffix("/")
            ? directory.standardizedFileURL.path
            : directory.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(rootPath)
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
    var conversationDeletionError: String?

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let storageRootOverride: URL?
    private let storage: ConversationStoreStorage
    @ObservationIgnored private var hasAttemptedAttachmentMigration = false
    @ObservationIgnored private var pendingNewConversationID: UUID?
    @ObservationIgnored private var hasLoadedConversationIndex = false
    @ObservationIgnored private var isLoadingConversationIndex = false
    @ObservationIgnored private var indexLoadTask: Task<IndexedConversationLoad, Never>?
    @ObservationIgnored private var corruptConversationIDs = Set<UUID>()
    @ObservationIgnored private var nextSaveRevision: UInt64 = 0

    nonisolated private static let indexFileName = "index.json"
    nonisolated private static let conversationFileName = "conversation.json"
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
        let rootDirectory: URL
        if let storageRootOverride {
            rootDirectory = storageRootOverride
        } else {
            guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                fatalError("Unable to locate the documents directory for conversation storage.")
            }
            rootDirectory = documentsDirectory.appendingPathComponent("chat-history", isDirectory: true)
        }
        self.storage = ConversationStoreStorage(
            fileManager: fileManager,
            rootDirectory: rootDirectory,
            storageRootOverride: storageRootOverride
        )
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
        if let pendingNewConversationID,
           !storage.withLock({
               storage.rejectConversationSaves || storage.deletedConversationIDs.contains(pendingNewConversationID)
           }) {
            return pendingNewConversationID
        }
        if pendingNewConversationID != nil {
            self.pendingNewConversationID = nil
            defaults.removeObject(forKey: Self.pendingConversationDefaultsKey)
        }
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
        ensureConversationIndexLoadedSynchronously()
        let conversationID = pendingConversationID()
        storage.withLock {
            storage.rejectConversationSaves = false
            storage.deletedConversationIDs.remove(conversationID)
        }
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
        return conversations
            .sorted(by: Self.sortConversations)
            .filter { !recentIDs.contains($0.id) }
    }

    func loadConversation(id: UUID) -> ConversationSnapshot? {
        try? loadConversationThrowing(id: id)
    }

    func loadConversationThrowing(id: UUID) throws -> ConversationSnapshot {
        ensureConversationIndexLoadedSynchronously()
        prepareAttachmentsBeforeRestore()
        return try storage.withLock {
            try ConversationSnapshotLoader.load(
                from: conversationURL(for: id),
                requestedID: id,
                storageRootOverride: storageRootOverride,
                fileManager: fileManager
            )
        }
    }

    func loadConversationAsync(id: UUID) async -> ConversationSnapshot? {
        try? await loadConversationAsyncThrowing(id: id)
    }

    func loadConversationAsyncThrowing(id: UUID) async throws -> ConversationSnapshot {
        prepareAttachmentsBeforeRestore()
        await loadIndexIfNeeded()
        let conversationURL = conversationURL(for: id)
        let rootOverride = storageRootOverride
        let storage = storage
        return try await Task.detached(priority: .utility) {
            try storage.withLock {
                try ConversationSnapshotLoader.load(
                    from: conversationURL,
                    requestedID: id,
                    storageRootOverride: rootOverride,
                    fileManager: storage.fileManager
                )
            }
        }.value
    }

    func loadIndexIfNeeded() async {
        guard !hasLoadedConversationIndex else { return }
        if let indexLoadTask {
            let candidate = await indexLoadTask.value
            applyIndexLoadCandidate(candidate)
            return
        }

        isLoadingConversationIndex = true
        prepareAttachmentsBeforeRestore()
        let storage = storage
        let rootDirectory = rootDirectory
        let indexURL = indexURL
        let task = Task.detached(priority: .utility) {
            storage.withLock {
                IndexedConversationLoad(
                    result: Self.loadConversationIndex(
                        rootDirectory: rootDirectory,
                        indexURL: indexURL,
                        fileManager: storage.fileManager
                    ),
                    revision: storage.revision
                )
            }
        }
        indexLoadTask = task
        let candidate = await task.value
        applyIndexLoadCandidate(candidate)
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
        ConversationAttachmentStore.repairBackupExclusions(
            fileManager: fileManager,
            baseDirectoryOverride: storageRootOverride
        )
    }

    @discardableResult
    func saveConversation(
        id: UUID?,
        messages: [ChatMessage],
        draftText: String,
        draftAttachments: [Attachment]
    ) throws -> UUID {
        ensureConversationIndexLoadedSynchronously()
        let conversationID = id ?? currentConversationID ?? pendingConversationID()
        let saveRevision = allocateSaveRevision()
        guard canSaveConversation(id: conversationID) else {
            throw ConversationStoreError.conversationDeleted(conversationID)
        }

        let fallbackMetadata = conversations.first(where: { $0.id == conversationID })
        let result = try storage.withLock {
            try Self.persistConversationLocked(
                storage: storage,
                id: conversationID,
                messages: messages,
                draftText: draftText,
                draftAttachments: draftAttachments,
                fallbackMetadata: fallbackMetadata,
                saveRevision: saveRevision
            )
        }
        conversations = result.conversations
        corruptConversationIDs.remove(conversationID)
        if currentConversationID == nil {
            setCurrentConversation(id: conversationID)
        }
        finishPendingConversation(id: conversationID)
        return conversationID
    }

    @discardableResult
    func saveConversationAsync(
        id: UUID?,
        messages: [ChatMessage],
        draftText: String,
        draftAttachments: [Attachment]
    ) async throws -> UUID {
        let saveRevision = allocateSaveRevision()
        let conversationID = id ?? currentConversationID ?? pendingConversationID()
        guard canSaveConversation(id: conversationID) else {
            throw ConversationStoreError.conversationDeleted(conversationID)
        }
        await loadIndexIfNeeded()
        guard canSaveConversation(id: conversationID) else {
            throw ConversationStoreError.conversationDeleted(conversationID)
        }

        let fallbackMetadata = conversations.first(where: { $0.id == conversationID })
        let storage = storage
        let result = try await Task.detached(priority: .utility) {
            try storage.withLock {
                try Self.persistConversationLocked(
                    storage: storage,
                    id: conversationID,
                    messages: messages,
                    draftText: draftText,
                    draftAttachments: draftAttachments,
                    fallbackMetadata: fallbackMetadata,
                    saveRevision: saveRevision
                )
            }
        }.value

        // A synchronous delete may have completed while disk I/O was in flight.
        // Do not republish its metadata or move the current selection backward.
        guard canSaveConversation(id: result.id) else {
            throw ConversationStoreError.conversationDeleted(result.id)
        }
        let currentDiskState = storage.withLock {
            Self.loadConversationIndex(
                rootDirectory: rootDirectory,
                indexURL: indexURL,
                fileManager: fileManager
            )
        }
        conversations = currentDiskState.conversations.sorted(by: Self.sortConversations)
        corruptConversationIDs = currentDiskState.corruptConversationIDs
        corruptConversationIDs.remove(result.id)
        finishPendingConversation(id: result.id)
        return result.id
    }

    func canSaveConversation(id: UUID?) -> Bool {
        return storage.withLock {
            guard !storage.rejectConversationSaves else { return false }
            guard let id else { return true }
            return !storage.deletedConversationIDs.contains(id)
        }
    }

    @discardableResult
    func cleanupOrphanedAttachmentFiles() -> Int {
        ensureConversationIndexLoadedSynchronously()
        do {
            return try storage.withLock {
                let index = Self.loadConversationIndex(
                    rootDirectory: rootDirectory,
                    indexURL: indexURL,
                    fileManager: fileManager
                )
                guard index.allConversationFilesDecoded else { return 0 }
                return try ConversationAttachmentStore.removeOrphanedFiles(
                    referencedPaths: index.referencedAttachmentPaths,
                    fileManager: fileManager,
                    baseDirectoryOverride: storageRootOverride
                )
            }
        } catch {
            reportStorageError(error)
            return 0
        }
    }

    private func allocateSaveRevision() -> UInt64 {
        nextSaveRevision &+= 1
        return nextSaveRevision
    }

    func renameConversation(id: UUID, title: String) {
        guard let trimmedTitle = cleanedTitle(title) else { return }
        ensureConversationIndexLoadedSynchronously()

        do {
            let updated = try storage.withLock { () -> [ConversationMetadata] in
                guard var conversation = readConversationLocked(id: id) else { return conversations }
                let diskIndex = Self.loadConversationIndex(
                    rootDirectory: rootDirectory,
                    indexURL: indexURL,
                    fileManager: fileManager
                )
                guard let metadataIndex = diskIndex.conversations.firstIndex(where: { $0.id == id }) else {
                    return conversations
                }

                let updatedAt = Date()
                conversation.title = trimmedTitle
                conversation.updatedAt = updatedAt
                var metadata = diskIndex.conversations[metadataIndex]
                metadata.title = trimmedTitle
                metadata.updatedAt = updatedAt
                metadata.isCustomTitle = true

                try ensureRootDirectoryLocked()
                try ensureConversationDirectoryLocked(id: conversation.id)
                try writeConversationLocked(conversation)
                var updated = diskIndex.conversations
                updated[metadataIndex] = metadata
                updated.sort(by: Self.sortConversations)
                try writeIndexLocked(updated)
                return updated
            }
            conversations = updated
        } catch {
            reportStorageError(error)
        }
    }

    @discardableResult
    func deleteConversation(id: UUID) -> Bool {
        deleteConversations(ids: Set([id])) == 1
    }

    @discardableResult
    func deleteArchivedConversations(keepingRecentLimit limit: Int) -> Int {
        let archivedIDs = Set(archivedConversations(limit: limit).map(\.id))
        return deleteConversations(ids: archivedIDs)
    }

    @discardableResult
    func deleteConversations(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }

        ensureConversationIndexLoadedSynchronously()
        var removedAttachmentFiles = 0
        var successfulIDs = Set<UUID>()
        var failures: [UUID: Error] = [:]

        let updatedConversations = storage.withLock { () -> [ConversationMetadata] in
            var updated = Self.loadConversationIndex(
                rootDirectory: rootDirectory,
                indexURL: indexURL,
                fileManager: fileManager
            ).conversations
            for id in ids {
                storage.deletedConversationIDs.insert(id)
                do {
                    if let conversation = readConversationLocked(id: id) {
                        removedAttachmentFiles += try ConversationAttachmentStore.removeFilesThrowing(
                            at: Self.attachmentURLs(in: conversation),
                            fileManager: fileManager,
                            baseDirectoryOverride: storageRootOverride
                        )
                    }

                    let directory = conversationDirectory(for: id)
                    if fileManager.fileExists(atPath: directory.path) {
                        try fileManager.removeItem(at: directory)
                    }
                    storage.revision &+= 1
                    successfulIDs.insert(id)
                    updated.removeAll { $0.id == id }
                } catch {
                    storage.deletedConversationIDs.remove(id)
                    failures[id] = error
                }
            }

            updated.sort(by: Self.sortConversations)
            if !successfulIDs.isEmpty {
                do {
                    try writeIndexLocked(updated)
                } catch {
                    reportStorageError(error)
                }
            }
            return updated
        }

        conversations = updatedConversations
        corruptConversationIDs.subtract(successfulIDs)

        if let currentID = currentConversationID, successfulIDs.contains(currentID) {
            if let nextConversation = conversations.first {
                currentConversationID = nextConversation.id
                defaults.set(nextConversation.id.uuidString, forKey: Self.currentConversationDefaultsKey)
            } else {
                currentConversationID = nil
                defaults.removeObject(forKey: Self.currentConversationDefaultsKey)
            }
        }

        if let firstFailure = failures.values.first {
            conversationDeletionError = "This chat could not be fully deleted. Try again. "
                + firstFailure.localizedDescription
        } else {
            conversationDeletionError = nil
        }

        if !successfulIDs.isEmpty {
            _ = cleanupOrphanedAttachmentFiles()
        }
        if removedAttachmentFiles > 0 {
            AppDiagnostics.shared.record(
                "Conversation attachments deleted",
                category: "storage",
                metadata: [
                    "conversations": successfulIDs.count,
                    "files": removedAttachmentFiles
                ]
            )
        }

        return successfulIDs.count
    }

    @discardableResult
    func deleteAllConversations() -> Bool {
        do {
            let removedAttachmentFiles = try storage.withLock { () -> Int in
                let removedAttachmentFiles = try ConversationAttachmentStore.removeAll(
                    fileManager: fileManager,
                    baseDirectoryOverride: storageRootOverride
                )
                if fileManager.fileExists(atPath: rootDirectory.path) {
                    try fileManager.removeItem(at: rootDirectory)
                }
                storage.deletedConversationIDs.formUnion(conversations.map(\.id))
                if let currentConversationID {
                    storage.deletedConversationIDs.insert(currentConversationID)
                }
                if let pendingNewConversationID {
                    storage.deletedConversationIDs.insert(pendingNewConversationID)
                }
                storage.rejectConversationSaves = true
                storage.revision &+= 1
                return removedAttachmentFiles
            }

            conversations = []
            corruptConversationIDs.removeAll()
            currentConversationID = nil
            pendingNewConversationID = nil
            defaults.removeObject(forKey: Self.currentConversationDefaultsKey)
            defaults.removeObject(forKey: Self.pendingConversationDefaultsKey)
            historyDeletionError = nil
            conversationDeletionError = nil
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

    private var rootDirectory: URL {
        storage.rootDirectory
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

    private func ensureConversationIndexLoadedSynchronously() {
        guard !hasLoadedConversationIndex else { return }
        prepareAttachmentsBeforeRestore()
        let candidate = storage.withLock {
            IndexedConversationLoad(
                result: Self.loadConversationIndex(
                    rootDirectory: rootDirectory,
                    indexURL: indexURL,
                    fileManager: fileManager
                ),
                revision: storage.revision
            )
        }
        indexLoadTask?.cancel()
        indexLoadTask = nil
        applyIndexLoadCandidate(candidate)
    }

    private func applyIndexLoadCandidate(_ candidate: IndexedConversationLoad) {
        guard !hasLoadedConversationIndex else { return }

        var reconciliationError: Error?
        let effectiveResult = storage.withLock { () -> ConversationIndexLoadResult in
            var result: ConversationIndexLoadResult
            guard storage.revision == candidate.revision else {
                result = Self.loadConversationIndex(
                    rootDirectory: rootDirectory,
                    indexURL: indexURL,
                    fileManager: fileManager
                )
                if result.requiresIndexRewrite {
                    do {
                        try ensureRootDirectoryLocked()
                        try writeIndexLocked(result.conversations)
                    } catch {
                        reconciliationError = error
                    }
                }
                return result
            }
            result = candidate.result
            if result.requiresIndexRewrite {
                do {
                    try ensureRootDirectoryLocked()
                    try writeIndexLocked(result.conversations)
                } catch {
                    reconciliationError = error
                }
            }
            return result
        }

        conversations = effectiveResult.conversations.sorted(by: Self.sortConversations)
        corruptConversationIDs = effectiveResult.corruptConversationIDs
        repairCurrentConversationSelectionLocked()
        if let reconciliationError {
            reportStorageError(reconciliationError)
        } else if effectiveResult.requiresIndexRewrite {
            AppDiagnostics.shared.record(
                "Conversation index reconciled",
                category: "storage",
                metadata: ["conversations": conversations.count]
            )
        }
        hasLoadedConversationIndex = true
        isLoadingConversationIndex = false
        indexLoadTask = nil
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
        indexURL: URL,
        fileManager: FileManager
    ) -> ConversationIndexLoadResult {
        repairBackupExclusions(rootDirectory: rootDirectory, fileManager: fileManager)
        let decoder = makeDecoder()
        let indexedConversations: [ConversationMetadata]?
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? decoder.decode([ConversationMetadata].self, from: data) {
            indexedConversations = decoded
        } else {
            indexedConversations = nil
        }
        let directoryURLs = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var directoryIDs = Set<UUID>()
        var validConversations = [UUID: PersistedConversation]()
        var corruptDirectoryIDs = Set<UUID>()
        var referencedAttachmentPaths = Set<String>()
        var allConversationFilesDecoded = true

        for directoryURL in directoryURLs {
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let directoryID = UUID(uuidString: directoryURL.lastPathComponent) else { continue }
            directoryIDs.insert(directoryID)
            let conversationURL = directoryURL.appendingPathComponent(conversationFileName)
            guard let data = try? Data(contentsOf: conversationURL) else {
                allConversationFilesDecoded = false
                corruptDirectoryIDs.insert(directoryID)
                continue
            }
            guard let conversation = try? decoder.decode(PersistedConversation.self, from: data),
                  conversation.id == directoryID else {
                allConversationFilesDecoded = false
                corruptDirectoryIDs.insert(directoryID)
                continue
            }

            validConversations[directoryID] = conversation
            referencedAttachmentPaths.formUnion(attachmentPaths(in: conversation))
        }

        let indexedIDs = Set(indexedConversations?.map(\.id) ?? [])
        var conversations: [ConversationMetadata] = []
        var requiresIndexRewrite = indexedConversations == nil && fileManager.fileExists(atPath: indexURL.path)
        var corruptConversationIDs = Set<UUID>()

        if let indexedConversations {
            for metadata in indexedConversations {
                if validConversations[metadata.id] != nil {
                    conversations.append(metadata)
                } else if directoryIDs.contains(metadata.id) {
                    // Keep a visible entry for a corrupt payload so restore can
                    // report an explicit error instead of silently creating a new chat.
                    conversations.append(metadata)
                    corruptConversationIDs.insert(metadata.id)
                } else {
                    // The payload is gone. Do not republish stale index metadata.
                    requiresIndexRewrite = true
                }
            }
        } else {
            conversations = validConversations.values.map(recoveredMetadata(from:))
            requiresIndexRewrite = fileManager.fileExists(atPath: indexURL.path) || !validConversations.isEmpty
        }

        let recoveredIDs = Set(conversations.map(\.id))
        for (id, conversation) in validConversations where !recoveredIDs.contains(id) {
            conversations.append(recoveredMetadata(from: conversation))
            requiresIndexRewrite = true
        }
        if !corruptDirectoryIDs.isDisjoint(with: indexedIDs) {
            corruptConversationIDs.formUnion(corruptDirectoryIDs.intersection(indexedIDs))
        }
        if Set(conversations.map(\.id)) != indexedIDs {
            requiresIndexRewrite = true
        }

        return ConversationIndexLoadResult(
            conversations: conversations.sorted(by: sortConversations),
            corruptConversationIDs: corruptConversationIDs,
            referencedAttachmentPaths: referencedAttachmentPaths,
            allConversationFilesDecoded: allConversationFilesDecoded,
            requiresIndexRewrite: requiresIndexRewrite
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

    nonisolated private static func persistConversationLocked(
        storage: ConversationStoreStorage,
        id: UUID,
        messages: [ChatMessage],
        draftText: String,
        draftAttachments: [Attachment],
        fallbackMetadata: ConversationMetadata?,
        saveRevision: UInt64,
        forcedTitle: String? = nil,
        forcedCustomTitle: Bool? = nil
    ) throws -> ConversationSaveResult {
        guard !storage.rejectConversationSaves else {
            throw ConversationStoreError.conversationDeleted(id)
        }
        guard !storage.deletedConversationIDs.contains(id) else {
            throw ConversationStoreError.conversationDeleted(id)
        }
        guard saveRevision >= (storage.highestSaveRevisions[id] ?? 0) else {
            throw ConversationStoreError.saveSuperseded(id)
        }
        storage.highestSaveRevisions[id] = saveRevision

        let diskIndex = loadConversationIndex(
            rootDirectory: storage.rootDirectory,
            indexURL: storage.rootDirectory.appendingPathComponent(indexFileName),
            fileManager: storage.fileManager
        )
        let existingMetadata = diskIndex.conversations.first(where: { $0.id == id }) ?? fallbackMetadata
        let existingConversation = readPersistedConversation(
            fileManager: storage.fileManager,
            rootDirectory: storage.rootDirectory,
            id: id
        )
        let createdAt = existingMetadata?.createdAt ?? existingConversation?.createdAt ?? Date()
        let updatedAt = Date()
        let isCustomTitle = forcedCustomTitle ?? existingMetadata?.isCustomTitle ?? false
        let title = forcedTitle
            ?? (isCustomTitle ? (existingMetadata?.title ?? "New chat") : suggestedTitle(for: messages))
        let metadata = ConversationMetadata(
            id: id,
            title: title,
            preview: previewText(messages: messages, draftText: draftText, draftAttachments: draftAttachments),
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            hasDraft: !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draftAttachments.isEmpty,
            isCustomTitle: isCustomTitle
        )
        let conversation = PersistedConversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages.map(PersistedMessage.init(message:)),
            draftText: draftText,
            draftAttachments: draftAttachments
        )

        try ensureProtectedDirectory(at: storage.rootDirectory, fileManager: storage.fileManager)
        try ensureProtectedDirectory(
            at: storage.rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true),
            fileManager: storage.fileManager
        )
        try writePersistedConversation(conversation, storage: storage)

        var updated = diskIndex.conversations
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index] = metadata
        } else {
            updated.append(metadata)
        }
        updated.sort(by: sortConversations)
        try writeConversationIndex(updated, storage: storage)

        let postSaveIndex = loadConversationIndex(
            rootDirectory: storage.rootDirectory,
            indexURL: storage.rootDirectory.appendingPathComponent(indexFileName),
            fileManager: storage.fileManager
        )
        if postSaveIndex.allConversationFilesDecoded {
            _ = try? ConversationAttachmentStore.removeOrphanedFiles(
                referencedPaths: postSaveIndex.referencedAttachmentPaths,
                fileManager: storage.fileManager,
                baseDirectoryOverride: storage.storageRootOverride
            )
        }

        return ConversationSaveResult(
            id: id,
            metadata: metadata,
            conversations: updated,
            revision: storage.revision
        )
    }

    nonisolated private static func readPersistedConversation(
        fileManager: FileManager,
        rootDirectory: URL,
        id: UUID
    ) -> PersistedConversation? {
        let url = rootDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(conversationFileName)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(PersistedConversation.self, from: data)
    }

    nonisolated private static func writePersistedConversation(
        _ conversation: PersistedConversation,
        storage: ConversationStoreStorage
    ) throws {
        let data = try makeEncoder().encode(conversation)
        let url = storage.rootDirectory
            .appendingPathComponent(conversation.id.uuidString, isDirectory: true)
            .appendingPathComponent(conversationFileName)
        try data.write(to: url, options: fileWriteOptions)
        try setBackupExclusion(url)
        storage.revision &+= 1
    }

    nonisolated private static func writeConversationIndex(
        _ entries: [ConversationMetadata],
        storage: ConversationStoreStorage
    ) throws {
        let data = try makeEncoder().encode(entries.sorted(by: sortConversations))
        let url = storage.rootDirectory.appendingPathComponent(indexFileName)
        try data.write(to: url, options: fileWriteOptions)
        try setBackupExclusion(url)
        storage.revision &+= 1
    }

    nonisolated private static func ensureProtectedDirectory(
        at directory: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: fileProtection]
            )
        }
        try fileManager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: directory.path)
        try setBackupExclusion(directory)
    }

    nonisolated private static func setBackupExclusion(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    nonisolated private static func repairBackupExclusions(
        rootDirectory: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        ConversationAttachmentStore.excludeFromBackup(rootDirectory)
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator {
            ConversationAttachmentStore.excludeFromBackup(url)
        }
    }

    nonisolated private static func attachmentPaths(in conversation: PersistedConversation) -> Set<String> {
        let attachments = conversation.messages.flatMap(\.attachments)
            + conversation.draftAttachments
        return Set(attachments
            .flatMap { [$0.thumbnail, $0.full] }
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.path })
    }

    private func persist(conversation: PersistedConversation, metadata: ConversationMetadata) throws {
        let saveRevision = allocateSaveRevision()
        let messages = conversation.messages.map {
            $0.makeMessage(baseDirectoryOverride: storageRootOverride)
        }
        let result = try storage.withLock {
            try Self.persistConversationLocked(
                storage: storage,
                id: conversation.id,
                messages: messages,
                draftText: conversation.draftText,
                draftAttachments: conversation.draftAttachments.map {
                    $0.restored(baseDirectoryOverride: storageRootOverride)
                },
                fallbackMetadata: metadata,
                saveRevision: saveRevision,
                forcedTitle: metadata.title,
                forcedCustomTitle: metadata.isCustomTitle
            )
        }
        conversations = result.conversations
        corruptConversationIDs.remove(conversation.id)
    }

    func reportStorageError(_ error: Error) {
        storageError = "Your latest changes could not be saved. Keep this chat open and try again. "
            + error.localizedDescription
    }

    private func readConversation(id: UUID) -> PersistedConversation? {
        storage.withLock { readConversationLocked(id: id) }
    }

    private func readConversationLocked(id: UUID) -> PersistedConversation? {
        Self.readPersistedConversation(
            fileManager: fileManager,
            rootDirectory: rootDirectory,
            id: id
        )
    }

    private func writeConversationLocked(_ conversation: PersistedConversation) throws {
        try Self.writePersistedConversation(
            conversation,
            storage: storage
        )
    }

    private func writeIndexLocked(_ entries: [ConversationMetadata]? = nil) throws {
        try Self.writeConversationIndex(
            entries ?? conversations,
            storage: storage
        )
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
        try Self.ensureProtectedDirectory(at: directory, fileManager: fileManager)
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

    nonisolated private static func suggestedTitle(for messages: [ChatMessage]) -> String {
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

    nonisolated private static func sortConversations(lhs: ConversationMetadata, rhs: ConversationMetadata) -> Bool {
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
    nonisolated private static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    nonisolated private static let fileWriteOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication
    ]

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

}

private enum ConversationSnapshotLoader {
    static func load(
        from conversationURL: URL,
        requestedID: UUID,
        storageRootOverride: URL?,
        fileManager: FileManager
    ) throws -> ConversationSnapshot {
        guard fileManager.fileExists(atPath: conversationURL.path),
              let data = try? Data(contentsOf: conversationURL) else {
            throw ConversationStoreError.conversationNotFound(requestedID)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversation: PersistedConversation
        do {
            conversation = try decoder.decode(PersistedConversation.self, from: data)
        } catch {
            throw ConversationStoreError.corruptConversation(
                requestedID: requestedID,
                payloadID: nil,
                reason: error.localizedDescription
            )
        }
        guard conversation.id == requestedID else {
            throw ConversationStoreError.corruptConversation(
                requestedID: requestedID,
                payloadID: conversation.id,
                reason: "The payload ID does not match its directory ID."
            )
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
