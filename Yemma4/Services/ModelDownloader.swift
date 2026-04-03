import Foundation

public final class ModelDownloader {
    public var downloadProgress: Double = 0.0
    public var isDownloading = false
    public var isDownloaded = false
    public var error: String?
    public var modelPath: String?

    private let fileName = "gemma-4-e4b-it-q4km.gguf"

    public init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let candidatePath = documents?.appendingPathComponent(fileName)

        if let candidatePath, FileManager.default.fileExists(atPath: candidatePath.path) {
            isDownloaded = true
            modelPath = candidatePath.path
            downloadProgress = 1.0
        }
    }

    public func downloadModel() async {
        if isDownloaded {
            downloadProgress = 1.0
            return
        }

        error = nil
        isDownloading = true
        isDownloading = false
    }

    public func deleteModel() {
        guard let modelPath else {
            return
        }

        do {
            try FileManager.default.removeItem(atPath: modelPath)
            downloadProgress = 0.0
            isDownloaded = false
            self.modelPath = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
