import Foundation
import CoreTransferable
import UniformTypeIdentifiers
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
        guard let imported = try await item.loadTransferable(type: ImportedPhoto.self) else { return nil }
        defer { try? FileManager.default.removeItem(at: imported.url) }
        try Task.checkCancellation()
        let attachment = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let size = try imported.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 100 * 1_024 * 1_024,
                      let source = CGImageSourceCreateWithURL(imported.url as CFURL, nil),
                      let image = downsampledCGImage(from: source, maxPixelDimension: modelInputMaxPixelDimension),
                      let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let fileURL = try Self.storeAttachmentData(data, fileExtension: "jpg")
                return Attachment(id: UUID().uuidString, url: fileURL, type: .image)
            }
        }.value
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: attachment.full)
            throw CancellationError()
        }
        return attachment
    }

    private struct ImportedPhoto: Transferable, Sendable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .image) { received in
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("yemma-photo-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: received.file, to: target)
                return Self(url: target)
            }
        }
    }

    nonisolated private static func storeAttachmentData(_ data: Data, fileExtension: String) throws -> URL {
        let directory = try ConversationAttachmentStore.prepareDirectory()

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: fileURL, options: ConversationAttachmentStore.writeOptions)
        return fileURL
    }
}
