import Foundation
import PhotosUI
import SwiftUI
import ImageIO
import UIKit

#if canImport(UIKit)
enum ChatAttachmentImagePipeline {
    struct EncodedImage: Sendable {
        let data: Data
        let fileExtension: String
    }

    struct DecodedImage: @unchecked Sendable {
        let image: UIImage
    }

    private static let modelInputMaxPixelDimension = 2_048

    nonisolated static func encodedModelImage(from data: Data) throws -> EncodedImage {
        guard let image = downsampledImage(from: data, maxPixelDimension: modelInputMaxPixelDimension) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            return EncodedImage(data: jpegData, fileExtension: "jpg")
        }

        if let pngData = image.pngData() {
            return EncodedImage(data: pngData, fileExtension: "png")
        }

        throw CocoaError(.fileWriteUnknown)
    }

    nonisolated static func decodedThumbnail(
        at url: URL,
        maxPixelDimension: Int
    ) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = downsampledCGImage(from: source, maxPixelDimension: maxPixelDimension) else {
            return nil
        }

        return DecodedImage(image: UIImage(cgImage: cgImage))
    }

    nonisolated private static func downsampledImage(
        from data: Data,
        maxPixelDimension: Int
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = downsampledCGImage(from: source, maxPixelDimension: maxPixelDimension) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func downsampledCGImage(
        from source: CGImageSource,
        maxPixelDimension: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
#endif

extension ChatAttachmentImagePipeline {
    static func makeAttachment(from item: PhotosPickerItem) async throws -> Attachment? {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }

#if canImport(UIKit)
        return try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let encodedImage = try ChatAttachmentImagePipeline.encodedModelImage(from: data)
                let fileURL = try Self.storeAttachmentData(
                    encodedImage.data,
                    fileExtension: encodedImage.fileExtension
                )
                return Attachment(id: UUID().uuidString, url: fileURL, type: .image)
            }
        }.value
#else
        let fileURL = try Self.storeAttachmentData(data, fileExtension: "bin")
        return Attachment(id: UUID().uuidString, url: fileURL, type: .image)
#endif
    }

    nonisolated private static func storeAttachmentData(_ data: Data, fileExtension: String) throws -> URL {
        let directory = try ConversationAttachmentStore.prepareDirectory()

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: ConversationAttachmentStore.writeOptions)
        return fileURL
    }
}
