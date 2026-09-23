import Foundation

enum PromptRevision {
    enum RevisionError: LocalizedError {
        case missingQuestion
        var errorDescription: String? { "This question is no longer available to edit." }
    }
    struct Draft: Sendable {
        let messages: [ChatMessage]
        let text: String
        let attachments: [Attachment]
        let copiedFiles: [URL]
    }

    /// A revision is a new conversation. Images must be copied so deleting either
    /// conversation cannot break the other one's attachments.
    static func prepare(messages: [ChatMessage], messageID: String, text: String,
                        baseDirectoryOverride: URL? = nil) throws -> Draft {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].user.isCurrentUser else {
            throw RevisionError.missingQuestion
        }
        var copiedFiles: [URL] = []
        func copy(_ source: URL) throws -> URL {
            guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let directory = try ConversationAttachmentStore.prepareDirectory(baseDirectoryOverride: baseDirectoryOverride)
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            copiedFiles.append(destination)
            try FileManager.default.setAttributes([.protectionKey: ConversationAttachmentStore.fileProtection], ofItemAtPath: destination.path)
            return destination
        }
        func copyAttachments(_ attachments: [Attachment]) throws -> [Attachment] {
            try attachments.map { attachment in
                let thumbnail = try copy(attachment.thumbnail)
                let full = attachment.full == attachment.thumbnail ? thumbnail : try copy(attachment.full)
                return Attachment(id: UUID().uuidString, thumbnail: thumbnail, full: full, type: attachment.type)
            }
        }
        do {
            let history = try messages.prefix(index).map { original in
                var message = original
                message.attachments = try copyAttachments(original.attachments)
                return message
            }
            let attachments = try copyAttachments(messages[index].attachments)
            return Draft(messages: history, text: text, attachments: attachments, copiedFiles: copiedFiles)
        } catch {
            _ = ConversationAttachmentStore.removeFiles(at: copiedFiles, baseDirectoryOverride: baseDirectoryOverride)
            throw error
        }
    }
}
