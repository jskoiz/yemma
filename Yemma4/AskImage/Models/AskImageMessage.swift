import Foundation

/// A single message in an Ask Image conversation transcript.
struct AskImageMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let attachment: AskImageAttachment?
    let createdAt: Date

    /// Whether this message is still being streamed.
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        attachment: AskImageAttachment? = nil,
        isStreaming: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachment = attachment
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}
