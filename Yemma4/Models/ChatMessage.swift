import Foundation

public struct ChatMessage: Identifiable, Hashable {
    public let id: UUID
    public var text: String
    public var isCurrentUser: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        isCurrentUser: Bool,
        createdAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.isCurrentUser = isCurrentUser
        self.createdAt = createdAt
    }
}
