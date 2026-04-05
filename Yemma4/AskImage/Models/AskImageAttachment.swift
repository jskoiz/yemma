import Foundation
import SwiftUI

/// An image attached to an Ask Image session for multimodal inference.
struct AskImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let originalURL: URL
    let thumbnailData: Data?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        originalURL: URL,
        thumbnailData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originalURL = originalURL
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
    }

    /// Display-ready thumbnail image, if available.
    var thumbnailImage: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }
}
