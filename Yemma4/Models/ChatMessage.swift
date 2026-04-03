import Foundation
import ExyteChat

public typealias ChatMessage = ExyteChat.Message

public extension ExyteChat.Message {
    var isCurrentUser: Bool {
        user.isCurrentUser
    }
}

public extension ExyteChat.User {
    static let user = ExyteChat.User(
        id: "user",
        name: "You",
        avatarURL: nil,
        isCurrentUser: true
    )

    static let yemma = ExyteChat.User(
        id: "yemma",
        name: "Yemma",
        avatarURL: nil,
        isCurrentUser: false
    )
}
