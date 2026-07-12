import Foundation

public enum UserType: Int, Codable, Sendable {
    case current
    case other
    case system
}

public struct User: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: URL?
    public let avatarCacheKey: String?
    public let type: UserType

    public var isCurrentUser: Bool {
        type == .current
    }

    public init(
        id: String,
        name: String,
        avatarURL: URL?,
        avatarCacheKey: String? = nil,
        isCurrentUser: Bool
    ) {
        self.init(
            id: id,
            name: name,
            avatarURL: avatarURL,
            avatarCacheKey: avatarCacheKey,
            type: isCurrentUser ? .current : .other
        )
    }

    public init(
        id: String,
        name: String,
        avatarURL: URL?,
        avatarCacheKey: String? = nil,
        type: UserType
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.avatarCacheKey = avatarCacheKey
        self.type = type
    }

    public static let user = User(
        id: "user",
        name: "You",
        avatarURL: nil,
        isCurrentUser: true
    )

    public static let yemma = User(
        id: "yemma",
        name: "Yemma",
        avatarURL: nil,
        isCurrentUser: false
    )
}

public enum AttachmentType: String, Codable, Sendable {
    case image
    case video
}

public struct Attachment: Codable, Identifiable, Hashable, Sendable {
    public enum UploadStatus: Codable, Hashable, Sendable {
        case inProgress(Int?)
        case complete
        case cancelled
        case error
    }

    public let id: String
    public let thumbnail: URL
    public let full: URL
    public let fullUploadStatus: UploadStatus?
    public let type: AttachmentType
    public let thumbnailCacheKey: String?
    public let fullCacheKey: String?

    public init(
        id: String,
        thumbnail: URL,
        full: URL,
        type: AttachmentType,
        thumbnailCacheKey: String? = nil,
        fullCacheKey: String? = nil,
        fullUploadStatus: UploadStatus? = nil
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.full = full
        self.fullUploadStatus = fullUploadStatus
        self.type = type
        self.thumbnailCacheKey = thumbnailCacheKey
        self.fullCacheKey = fullCacheKey
    }

    public init(id: String, url: URL, type: AttachmentType, cacheKey: String? = nil) {
        self.init(
            id: id,
            thumbnail: url,
            full: url,
            type: type,
            thumbnailCacheKey: cacheKey,
            fullCacheKey: cacheKey
        )
    }
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case sending
        case sent
        case delivered
        case read
        case error
    }

    public var id: String
    public var user: User
    public var status: Status?
    public var createdAt: Date
    public var text: String
    public var attachments: [Attachment]

    public var isCurrentUser: Bool {
        user.isCurrentUser
    }

    public init(
        id: String,
        user: User,
        status: Status? = nil,
        createdAt: Date = Date(),
        text: String = "",
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.user = user
        self.status = status
        self.createdAt = createdAt
        self.text = text
        self.attachments = attachments
    }
}
