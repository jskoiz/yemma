import Foundation
import Observation
import ExyteChat

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

enum ConversationAttachmentStore {
    private static let directoryName = "chat-attachments"

    static func directoryURL(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) -> URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride.appendingPathComponent(directoryName, isDirectory: true)
        }

        guard let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            fatalError("Unable to locate the caches directory for attachment storage.")
        }

        return cachesDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func removeAll(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil
    ) -> Int {
        let directory = directoryURL(fileManager: fileManager, baseDirectoryOverride: baseDirectoryOverride)
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }

        let removedCount = fileCount(in: directory, fileManager: fileManager)
        try? fileManager.removeItem(at: directory)
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

        for url in Set(urls.map(\.standardizedFileURL)) where url.path.hasPrefix(directoryPath) {
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
    enum Status: String, Codable, Sendable {
        case sending
        case sent
        case delivered
        case read
        case error
    }

    let id: String
    let user: User
    let status: Status?
    let createdAt: Date
    let text: String
    let attachments: [Attachment]

    private var placeholderDraftMessage: DraftMessage {
        DraftMessage(
            id: id,
            text: text,
            medias: [],
            giphyMedia: nil,
            recording: nil,
            replyMessage: nil,
            createdAt: createdAt
        )
    }

    init(message: ChatMessage) {
        id = message.id
        user = message.user
        status = switch message.status {
        case .sending:
            .sending
        case .sent:
            .sent
        case .delivered:
            .delivered
        case .read:
            .read
        case .error:
            .error
        case nil:
            nil
        }
        createdAt = message.createdAt
        text = message.text
        attachments = message.attachments
    }

    func makeMessage() -> ChatMessage {
        let messageStatus: ChatMessage.Status? = switch status {
        case .sending:
            .sending
        case .sent:
            .sent
        case .delivered:
            .delivered
        case .read:
            .read
        case .error:
            .error(placeholderDraftMessage)
        case nil:
            nil
        }

        return ChatMessage(
            id: id,
            user: user,
            status: messageStatus,
            createdAt: createdAt,
            text: text,
            attachments: attachments
        )
    }
}

@MainActor
@Observable
final class ConversationStore {
    var conversations: [ConversationMetadata] = []
    var currentConversationID: UUID?

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let storageRootOverride: URL?
    // Protects persisted store mutations so file I/O helpers remain safe if they are ever reused off the main actor.
    private let ioLock = NSLock()
    @ObservationIgnored private var hasLoadedConversationIndex = false
    @ObservationIgnored private var isLoadingConversationIndex = false

    private static let indexFileName = "index.json"
    private static let conversationFileName = "conversation.json"
    private static let currentConversationDefaultsKey = "currentConversationID"

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        storageRootOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.storageRootOverride = storageRootOverride
        if let rawID = defaults.string(forKey: Self.currentConversationDefaultsKey),
           let conversationID = UUID(uuidString: rawID) {
            currentConversationID = conversationID
        }
    }

    func ensureCurrentConversation() -> UUID {
        if let currentConversationID {
            return currentConversationID
        }

        return startFreshConversation()
    }

    @discardableResult
    func startFreshConversation(title: String? = nil) -> UUID {
        let conversationID = UUID()
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

        persist(conversation: conversation, metadata: metadata)
        setCurrentConversation(id: conversationID)
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
        guard let conversation = readConversation(id: id) else {
            return nil
        }

        return ConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            messages: conversation.messages.map { $0.makeMessage() },
            draftText: conversation.draftText,
            draftAttachments: conversation.draftAttachments
        )
    }

    func loadConversationAsync(id: UUID) async -> ConversationSnapshot? {
        let conversationURL = conversationURL(for: id)
        return await Task.detached(priority: .utility) {
            ConversationSnapshotLoader.load(from: conversationURL)
        }.value
    }

    func loadIndexIfNeeded() async {
        guard !hasLoadedConversationIndex else { return }
        guard !isLoadingConversationIndex else { return }
        isLoadingConversationIndex = true
        await loadIndexAsync()
    }

    @discardableResult
    func saveConversation(
        id: UUID?,
        messages: [ChatMessage],
        draftText: String,
        draftAttachments: [Attachment]
    ) -> UUID {
        let conversationID = id ?? currentConversationID ?? startFreshConversation()
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

        persist(conversation: conversation, metadata: metadata)
        if currentConversationID == nil {
            setCurrentConversation(id: conversationID)
        }
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
        conversations[metadataIndex].title = trimmedTitle
        conversations[metadataIndex].updatedAt = updatedAt
        conversations[metadataIndex].isCustomTitle = true

        ensureRootDirectoryLocked()
        ensureConversationDirectoryLocked(id: conversation.id)
        writeConversationLocked(conversation)
        writeIndexLocked()
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
        writeIndexLocked()

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

    func deleteAllConversations() {
        ioLock.lock()
        defer { ioLock.unlock() }

        if fileManager.fileExists(atPath: rootDirectory.path) {
            try? fileManager.removeItem(at: rootDirectory)
        }

        let removedAttachmentFiles = ConversationAttachmentStore.removeAll(
            fileManager: fileManager,
            baseDirectoryOverride: storageRootOverride
        )

        conversations = []
        currentConversationID = nil
        defaults.removeObject(forKey: Self.currentConversationDefaultsKey)

        if removedAttachmentFiles > 0 {
            AppDiagnostics.shared.record(
                "Conversation attachments cleared",
                category: "storage",
                metadata: ["files": removedAttachmentFiles]
            )
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
        let decoded = await Task.detached(priority: .utility) { [indexURL] in
            let decoder = JSONDecoder()
            guard let data = try? Data(contentsOf: indexURL) else {
                return [ConversationMetadata]()
            }

            do {
                return try decoder.decode([ConversationMetadata].self, from: data)
            } catch {
                return [ConversationMetadata]()
            }
        }.value

        await MainActor.run {
            ioLock.lock()
            defer { ioLock.unlock() }
            conversations = decoded.sorted(by: Self.sortConversations)
            hasLoadedConversationIndex = true
            isLoadingConversationIndex = false
        }
    }

    private func persist(conversation: PersistedConversation, metadata: ConversationMetadata) {
        ioLock.lock()
        defer { ioLock.unlock() }

        ensureRootDirectoryLocked()
        ensureConversationDirectoryLocked(id: conversation.id)
        writeConversationLocked(conversation)

        if let index = conversations.firstIndex(where: { $0.id == metadata.id }) {
            conversations[index] = metadata
        } else {
            conversations.append(metadata)
        }
        conversations.sort(by: Self.sortConversations)
        writeIndexLocked()
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

    private func writeConversationLocked(_ conversation: PersistedConversation) {
        guard let data = try? Self.encoder.encode(conversation) else { return }
        try? data.write(to: conversationURL(for: conversation.id), options: .atomic)
    }

    private func writeIndexLocked() {
        guard let data = try? Self.encoder.encode(conversations) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func ensureRootDirectoryLocked() {
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        }
    }

    private func ensureConversationDirectoryLocked(id: UUID) {
        let directory = conversationDirectory(for: id)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
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

    private static func previewText(messages: [ChatMessage], draftText: String, draftAttachments: [Attachment]) -> String {
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

    private static func compactTitle(_ text: String) -> String {
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
    static func load(from conversationURL: URL) -> ConversationSnapshot? {
        guard let data = try? Data(contentsOf: conversationURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        guard let conversation = try? decoder.decode(PersistedConversation.self, from: data) else {
            return nil
        }

        return ConversationSnapshot(
            id: conversation.id,
            title: conversation.title,
            messages: conversation.messages.map { $0.makeMessage() },
            draftText: conversation.draftText,
            draftAttachments: conversation.draftAttachments
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
            let newID = store.startFreshConversation()
            if let currentConversationID {
                store.setCurrentConversation(id: currentConversationID)
            } else {
                store.setCurrentConversation(id: newID)
            }
            return store
        }

        var selectedID: UUID?
        for snapshot in conversations {
            let savedID = store.saveConversation(
                id: snapshot.id,
                messages: snapshot.messages,
                draftText: snapshot.draftText,
                draftAttachments: snapshot.draftAttachments
            )
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
